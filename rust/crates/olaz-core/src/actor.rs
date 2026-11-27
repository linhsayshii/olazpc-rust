//! Single tokio actor owning [`CoreState`] (D1, ADR-016).
//!
//! The actor loop never awaits I/O or host callbacks inline: it runs `reduce(&mut state, input)`,
//! publishes dirty keys to [`ChangeHub`], and hands effects to [`EffectRunner`].

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use tokio::runtime::Handle;
use tokio::sync::{Notify, mpsc, oneshot};

use crate::changes::{ChangeHub, CoreChanges};
use crate::cloud::{CloudActionResult, CloudFetch, CloudPage, MediaResolutionOutcome};
use crate::composer::{ComposerOutcome, MyCardInfo, ReminderComposeInfo};
use crate::conversations::{ConversationActionResult, IdentityTable, PinBoard};
use crate::effect::{Effect, OpResult};
use crate::forward::ForwardOutcome;
use crate::input::{Command, Input};
use crate::messages::IdentitySnapshot;
use crate::reduce::reduce;
use crate::runner::EffectRunner;
use crate::state::{CoreSnapshot, CoreState, SessionSnapshot};
use crate::stickers::{CardActionOutcome, StickerEntry, StickerSuggestSetting, StickerTab};

enum ActorMsg {
    Input {
        input: Box<Input>,
        ack: Option<oneshot::Sender<u64>>,
    },
    CoalescedIdentities,
    OpRequest {
        cmd: Box<Command>,
        reply: oneshot::Sender<(OpResult, u64)>,
    },
    DrainChatPolling {
        max_batches: u32,
        notify_incoming: bool,
        reply: oneshot::Sender<u32>,
    },
    Snapshot(oneshot::Sender<SessionSnapshot>),
    FullSnapshot(oneshot::Sender<CoreSnapshot>),
    Settle(oneshot::Sender<u64>),
    Stop,
}

/// Shared tracker counting queued inputs plus active effects so tests can await quiescence
/// without polling or sleeps.
struct ActivityTracker {
    count: AtomicUsize,
    idle_notify: Notify,
}

impl ActivityTracker {
    fn new() -> Self {
        Self {
            count: AtomicUsize::new(0),
            idle_notify: Notify::new(),
        }
    }

    fn increment(&self) {
        self.count.fetch_add(1, Ordering::AcqRel);
    }

    fn decrement(&self) {
        if self.count.fetch_sub(1, Ordering::AcqRel) == 1 {
            self.idle_notify.notify_waiters();
        }
    }

    fn current(&self) -> usize {
        self.count.load(Ordering::Acquire)
    }

    async fn wait_idle(&self) {
        loop {
            let notified = self.idle_notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.current() == 0 {
                return;
            }
            notified.await;
        }
    }
}

/// RAII token keeping the actor's in-flight counter elevated until an effect finishes.
pub struct InFlightGuard {
    tracker: Arc<ActivityTracker>,
}

impl Drop for InFlightGuard {
    fn drop(&mut self) {
        self.tracker.decrement();
    }
}

/// Cloneable handle passed to [`EffectRunner`] for feeding effect completions back to the actor.
#[derive(Clone)]
pub struct ActorSink {
    tx: mpsc::UnboundedSender<ActorMsg>,
    tracker: Arc<ActivityTracker>,
}

impl ActorSink {
    /// Creates an in-flight guard covering one queued or spawned effect.
    #[must_use]
    pub fn track(&self) -> InFlightGuard {
        self.tracker.increment();
        InFlightGuard {
            tracker: Arc::clone(&self.tracker),
        }
    }

    /// Posts an [`Input`] back to the actor. Increments the activity counter before enqueueing
    /// so there is never an idle gap between an effect finishing and the actor reducing its input.
    pub fn send(&self, input: Input) {
        self.tracker.increment();
        if self
            .tx
            .send(ActorMsg::Input {
                input: Box::new(input),
                ack: None,
            })
            .is_err()
        {
            self.tracker.decrement();
        }
    }
}

/// Handle for sending commands to the actor and pulling coalesced changes.
pub struct CoreHandle {
    tx: mpsc::UnboundedSender<ActorMsg>,
    changes: Arc<ChangeHub>,
    tracker: Arc<ActivityTracker>,
    state_notify: Arc<Notify>,
    identity_snapshot: Arc<Mutex<Arc<IdentitySnapshot>>>,
    latest_identities: Arc<Mutex<Option<IdentityTable>>>,
}

impl CoreHandle {
    /// Spawns the core actor on `runtime` with a fresh default [`CoreState`].
    #[must_use]
    pub fn start(runner: Arc<dyn EffectRunner>, runtime: Handle) -> Self {
        Self::start_with_state(CoreState::default(), runner, runtime)
    }

    /// Spawns the core actor on `runtime` with an initial [`CoreState`] (useful for seeded tests).
    #[must_use]
    pub fn start_with_state(
        initial: CoreState,
        runner: Arc<dyn EffectRunner>,
        runtime: Handle,
    ) -> Self {
        let (tx, rx) = mpsc::unbounded_channel();
        let changes = Arc::new(ChangeHub::new());
        let tracker = Arc::new(ActivityTracker::new());
        let state_notify = Arc::new(Notify::new());
        let identity_snapshot = Arc::new(Mutex::new(Arc::new(initial.identity_snapshot())));
        let latest_identities = Arc::new(Mutex::new(None));
        let sink = ActorSink {
            tx: tx.clone(),
            tracker: Arc::clone(&tracker),
        };
        runtime.spawn(run_actor(
            initial,
            rx,
            runner,
            sink,
            Arc::clone(&changes),
            Arc::clone(&tracker),
            Arc::clone(&state_notify),
            Arc::clone(&identity_snapshot),
            Arc::clone(&latest_identities),
        ));
        Self {
            tx,
            changes,
            tracker,
            state_notify,
            identity_snapshot,
            latest_identities,
        }
    }

    /// Instant non-async clone of the latest [`IdentitySnapshot`] for Frame 1 synchronous WAL decode.
    #[must_use]
    pub fn identity_snapshot(&self) -> Arc<IdentitySnapshot> {
        Arc::clone(
            &self
                .identity_snapshot
                .lock()
                .unwrap_or_else(PoisonError::into_inner),
        )
    }

    /// Enqueues a command without blocking.
    ///
    /// Burst `Command::UpdateIdentities` calls coalesce in place via `latest_identities` so the
    /// actor mailbox holds at most one pending identity update per burst.
    pub fn send(&self, command: Command) {
        if let Command::UpdateIdentities(table) = command {
            let mut slot = self
                .latest_identities
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            let was_none = slot.is_none();
            *slot = Some(table);
            if was_none {
                self.tracker.increment();
                if self.tx.send(ActorMsg::CoalescedIdentities).is_err() {
                    *slot = None;
                    self.tracker.decrement();
                }
            }
            return;
        }
        self.tracker.increment();
        if self
            .tx
            .send(ActorMsg::Input {
                input: Box::new(Input::Command(command)),
                ack: None,
            })
            .is_err()
        {
            self.tracker.decrement();
        }
    }

    /// Enqueues a command and awaits the change revision produced by its `reduce` step.
    /// Returns `None` if the actor has already stopped.
    pub async fn send_and_ack(&self, command: Command) -> Option<u64> {
        let (ack_tx, ack_rx) = oneshot::channel();
        self.tracker.increment();
        if self
            .tx
            .send(ActorMsg::Input {
                input: Box::new(Input::Command(command)),
                ack: Some(ack_tx),
            })
            .is_err()
        {
            self.tracker.decrement();
            return None;
        }
        ack_rx.await.ok()
    }

    /// Sends a request-reply command and awaits its completion `(OpResult, settled_version)`.
    pub async fn request_with_version(&self, command: Command) -> Option<(OpResult, u64)> {
        let (reply, rx) = oneshot::channel();
        self.tracker.increment();
        if self
            .tx
            .send(ActorMsg::OpRequest {
                cmd: Box::new(command),
                reply,
            })
            .is_err()
        {
            self.tracker.decrement();
            return None;
        }
        rx.await.ok()
    }

    /// Sends a request-reply command and awaits its completion [`OpResult`].
    pub async fn request(&self, command: Command) -> Option<OpResult> {
        self.request_with_version(command).await.map(|(res, _)| res)
    }

    /// U14: Searches in-memory and SQLite messages for `conv_id`, returning `(matches, settled_version)`.
    pub async fn search_messages(
        &self,
        conv_id: String,
        query: String,
        limit: i64,
    ) -> (Vec<olaz_wire::ChatMessage>, u64) {
        match self
            .request_with_version(Command::SearchMessages {
                conv_id,
                query,
                limit,
            })
            .await
        {
            Some((OpResult::SearchMessages(msgs), ver)) => (msgs, ver),
            _ => (Vec::new(), self.current_version()),
        }
    }

    /// U14: Ensures `message` is loaded into `messages.windows[conv_id]`, returning `(loaded, settled_version)`.
    pub async fn ensure_message_loaded(
        &self,
        conv_id: String,
        message: olaz_wire::ChatMessage,
    ) -> (bool, u64) {
        match self
            .request_with_version(Command::EnsureMessageLoaded {
                conv_id,
                message: Box::new(message),
            })
            .await
        {
            Some((OpResult::Bool(loaded), ver)) => (loaded, ver),
            _ => (false, self.current_version()),
        }
    }

    /// U14: Finds and loads the message quoted by `message` in `conv_id`, returning `(id, settled_version)`.
    pub async fn load_quoted_message(
        &self,
        conv_id: String,
        message: olaz_wire::ChatMessage,
    ) -> (Option<String>, u64) {
        match self
            .request_with_version(Command::LoadQuotedMessage {
                conv_id,
                message: Box::new(message),
            })
            .await
        {
            Some((OpResult::OptionalString(id), ver)) => (id, ver),
            _ => (None, self.current_version()),
        }
    }

    /// Awaits a request-reply command that completes with `OpResult::Unit`.
    pub async fn request_unit(&self, command: Command) {
        let _ = self.request(command).await;
    }

    /// Awaits a conversation action returning [`ConversationActionResult`].
    pub async fn request_action(&self, command: Command) -> ConversationActionResult {
        match self.request(command).await {
            Some(OpResult::ActionResult(res)) => res,
            _ => ConversationActionResult::fail(
                "Chưa nhận được phản hồi. Hãy kiểm tra lại trước khi thử lại.",
            ),
        }
    }

    /// Awaits [`Command::RequestPinBoard`].
    pub async fn request_pin_board(&self, id: String) -> Option<PinBoard> {
        match self.request(Command::RequestPinBoard { id }).await {
            Some(OpResult::PinBoard(board)) => board,
            _ => None,
        }
    }

    /// Awaits [`Command::HiddenSearch`].
    pub async fn request_hidden_search(&self, query: String) -> Option<Vec<String>> {
        match self.request(Command::HiddenSearch { query }).await {
            Some(OpResult::HiddenSearch(ids)) => ids,
            _ => None,
        }
    }

    /// Awaits a U8 forward command returning [`ForwardOutcome`].
    pub async fn request_forward_outcome(&self, command: Command) -> ForwardOutcome {
        match self.request(command).await {
            Some(OpResult::Forward(outcome)) => outcome,
            _ => ForwardOutcome::Failed("Có lỗi khi chia sẻ tin nhắn".to_owned()),
        }
    }

    /// Awaits a request-reply command returning `bool` (e.g., `UnlockFromPinSearch`).
    pub async fn request_bool(&self, command: Command) -> bool {
        matches!(self.request(command).await, Some(OpResult::Bool(true)))
    }

    // U12
    /// Awaits [`Command::PollVoters`].
    pub async fn request_poll_voters(&self, id: String) -> Option<crate::polls::PollVoters> {
        match self.request(Command::PollVoters { id }).await {
            Some(OpResult::PollVoters(v)) => v,
            _ => None,
        }
    }

    pub async fn request_opt_i64(&self, command: Command) -> Option<i64> {
        match self.request(command).await {
            Some(OpResult::OptI64(v)) => v,
            _ => None,
        }
    }

    /// Awaits [`Command::RefreshPollPin`].
    pub async fn request_poll_pin_state(
        &self,
        id: String,
        conv_id: String,
    ) -> crate::polls::PollPinState {
        match self.request(Command::RefreshPollPin { id, conv_id }).await {
            Some(OpResult::PollPinState(s)) => s,
            _ => crate::polls::PollPinState::default(),
        }
    }

    /// Awaits [`Command::PinPoll`].
    pub async fn request_poll_pin_outcome(
        &self,
        id: String,
        conv_id: String,
        confirming: Option<String>,
    ) -> crate::polls::PollPinOutcome {
        match self
            .request(Command::PinPoll {
                id,
                conv_id,
                confirming,
            })
            .await
        {
            Some(OpResult::PollPinOutcome(o)) => o,
            _ => crate::polls::PollPinOutcome::Failed(crate::polls::PollActionResult::err(Some(
                "network",
            ))),
        }
    }

    /// Awaits a poll mutation command returning [`crate::polls::PollActionResult`].
    pub async fn request_poll_action(&self, command: Command) -> crate::polls::PollActionResult {
        match self.request(command).await {
            Some(OpResult::PollActionResult(r)) => r,
            _ => crate::polls::PollActionResult::err(Some("network")),
        }
    }

    /// Awaits [`Command::PollCapabilities`].
    pub async fn request_poll_capabilities(
        &self,
        conv_id: String,
    ) -> crate::polls::PollCapabilities {
        match self.request(Command::PollCapabilities { conv_id }).await {
            Some(OpResult::PollCapabilities(c)) => c,
            _ => crate::polls::PollCapabilities::default(),
        }
    }

    // U11: zCloud request-reply helpers
    pub async fn request_cloud_page(&self, command: Command) -> CloudPage {
        match self.request(command).await {
            Some(OpResult::CloudPage(page)) => page,
            _ => CloudPage::default(),
        }
    }

    pub async fn request_cloud_fetch(&self, command: Command) -> CloudFetch {
        match self.request(command).await {
            Some(OpResult::CloudFetch(res)) => res,
            _ => CloudFetch::Failed(crate::cloud::CLOUD_FETCH_FAILED_ERROR.to_owned()),
        }
    }

    pub async fn request_cloud_action(&self, command: Command) -> CloudActionResult {
        match self.request(command).await {
            Some(OpResult::CloudAction(res)) => res,
            _ => CloudActionResult::default(),
        }
    }

    pub async fn request_media_resolution(&self, command: Command) -> MediaResolutionOutcome {
        match self.request(command).await {
            Some(OpResult::MediaResolution(res)) => res,
            _ => MediaResolutionOutcome::Unavailable,
        }
    }

    // U13 typed request helpers
    pub async fn request_sticker_tabs(&self) -> Option<Vec<StickerTab>> {
        match self.request(Command::StickerTabs).await {
            Some(OpResult::StickerTabs(v)) => v,
            _ => None,
        }
    }

    pub async fn request_sticker_entries(&self, command: Command) -> Option<Vec<StickerEntry>> {
        match self.request(command).await {
            Some(OpResult::StickerEntries(v)) => v,
            _ => None,
        }
    }

    pub async fn request_sticker_suggest_setting(
        &self,
        command: Command,
    ) -> Option<StickerSuggestSetting> {
        match self.request(command).await {
            Some(OpResult::StickerSuggestSetting(s)) => s,
            _ => None,
        }
    }

    pub async fn request_card_action(&self, command: Command) -> CardActionOutcome {
        match self.request(command).await {
            Some(OpResult::CardActionOutcome(o)) => o,
            _ => CardActionOutcome::Failed("Không gửi được sticker. Hãy thử lại.".to_owned()),
        }
    }

    pub async fn request_composer_outcome(&self, command: Command) -> ComposerOutcome {
        match self.request(command).await {
            Some(OpResult::ComposerOutcome(o)) => o,
            _ => ComposerOutcome::Failed(crate::composer::COMPOSER_GENERIC_FAILURE.to_owned()),
        }
    }

    pub async fn request_my_card(&self) -> Option<MyCardInfo> {
        match self.request(Command::MyCard).await {
            Some(OpResult::MyCard(c)) => c,
            _ => None,
        }
    }

    pub async fn request_reminder_info(&self, conv_id: String) -> Option<ReminderComposeInfo> {
        match self.request(Command::ReminderComposeInfo { conv_id }).await {
            Some(OpResult::ReminderComposeInfo(r)) => r,
            _ => None,
        }
    }

    /// Drains up to `max_batches` long-poll batches serialized behind any in-flight drain
    /// (ADR-018) and returns the total applied event count (`0` if long-poll or actor is stopped).
    pub async fn drain_chat_polling(&self, max_batches: u32, notify_incoming: bool) -> u32 {
        let (reply, rx) = oneshot::channel();
        self.tracker.increment();
        if self
            .tx
            .send(ActorMsg::DrainChatPolling {
                max_batches,
                notify_incoming,
                reply,
            })
            .is_err()
        {
            self.tracker.decrement();
            return 0;
        }
        rx.await.unwrap_or(0)
    }

    /// Pulls the next batch of dirty domain snapshots (`None` once stopped and drained).
    pub async fn next_changes(&self) -> Option<CoreChanges> {
        self.changes.next_changes().await
    }

    /// Returns the latest monotonic revision published to the change hub.
    #[must_use]
    pub fn current_version(&self) -> u64 {
        self.changes.current_version()
    }

    /// Enqueues a barrier on the actor mailbox and returns the change revision once every input
    /// enqueued before this call has been reduced and published. Returns `None` once stopped.
    pub async fn settle(&self) -> Option<u64> {
        let (tx, rx) = oneshot::channel();
        if self.tx.send(ActorMsg::Settle(tx)).is_err() {
            return None;
        }
        rx.await.ok()
    }

    /// Reads the current [`SessionSnapshot`] directly from the actor (tests / diagnostics).
    pub async fn snapshot(&self) -> Option<SessionSnapshot> {
        let (tx, rx) = oneshot::channel();
        if self.tx.send(ActorMsg::Snapshot(tx)).is_err() {
            return None;
        }
        rx.await.ok()
    }

    /// Reads the full [`CoreSnapshot`] across session, conversations, messages, and contacts domains.
    pub async fn full_snapshot(&self) -> Option<CoreSnapshot> {
        let (tx, rx) = oneshot::channel();
        if self.tx.send(ActorMsg::FullSnapshot(tx)).is_err() {
            return None;
        }
        rx.await.ok()
    }

    /// Waits until no inputs are queued and no effects are in flight.
    pub async fn wait_idle(&self) {
        self.tracker.wait_idle().await;
    }

    /// Waits until `predicate(&snapshot)` becomes true or the actor becomes idle (returns the
    /// snapshot at whichever occurred first).
    pub async fn wait_until<F>(&self, mut predicate: F) -> Option<SessionSnapshot>
    where
        F: FnMut(&SessionSnapshot) -> bool,
    {
        loop {
            let state_notified = self.state_notify.notified();
            tokio::pin!(state_notified);
            state_notified.as_mut().enable();

            let idle_notified = self.tracker.idle_notify.notified();
            tokio::pin!(idle_notified);
            idle_notified.as_mut().enable();

            let snap = self.snapshot().await?;
            if predicate(&snap) {
                return Some(snap);
            }
            if self.tracker.current() == 0 {
                // Re-check snapshot once after observing idle so we never miss the final reduce.
                let final_snap = self.snapshot().await?;
                return Some(final_snap);
            }

            tokio::select! {
                () = &mut state_notified => {}
                () = &mut idle_notified => {}
            }
        }
    }

    /// Waits until `predicate(&snapshot)` becomes true (or the actor stops), without returning
    /// early when no tracked effects are in flight (needed when waiting for background timers such
    /// as periodic long-poll ticks).
    pub async fn wait_for_predicate<F>(&self, mut predicate: F) -> Option<SessionSnapshot>
    where
        F: FnMut(&SessionSnapshot) -> bool,
    {
        loop {
            let state_notified = self.state_notify.notified();
            tokio::pin!(state_notified);
            state_notified.as_mut().enable();

            let snap = self.snapshot().await?;
            if predicate(&snap) {
                return Some(snap);
            }

            state_notified.await;
        }
    }

    // --- Board pins domain (U7) ---

    pub async fn refresh_board_pins(&self, conv_id: String) -> Option<()> {
        match self.request(Command::RefreshBoardPins { conv_id }).await {
            Some(OpResult::Unit) => Some(()),
            _ => None,
        }
    }

    pub async fn load_pinned_message(&self, conv_id: String, topic_ref: String) -> Option<String> {
        match self
            .request(Command::LoadPinnedMessage { conv_id, topic_ref })
            .await
        {
            Some(OpResult::OptString(val)) => val,
            _ => None,
        }
    }

    /// Stops the actor, aborts in-flight effects, and closes `next_changes()`.
    pub fn stop(&self) {
        let _ = self.tx.send(ActorMsg::Stop);
    }

    #[cfg(test)]
    pub(crate) fn test_sink(&self) -> ActorSink {
        ActorSink {
            tx: self.tx.clone(),
            tracker: Arc::clone(&self.tracker),
        }
    }
}

impl Drop for CoreHandle {
    fn drop(&mut self) {
        self.stop();
    }
}

struct ActorWaiters {
    drains: HashMap<u64, oneshot::Sender<u32>>,
    ops: HashMap<u64, oneshot::Sender<(OpResult, u64)>>,
    next_op_id: u64,
}

impl ActorWaiters {
    fn new() -> Self {
        Self {
            drains: HashMap::new(),
            ops: HashMap::new(),
            next_op_id: 0,
        }
    }

    fn alloc_op_id(&mut self) -> u64 {
        self.next_op_id = self.next_op_id.saturating_add(1);
        self.next_op_id
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "Actor dispatch helper borrows all actor-local handles directly"
)]
fn dispatch_reduce_output(
    state: &mut CoreState,
    out: crate::reduce::ReduceOutput,
    runner: &Arc<dyn EffectRunner>,
    sink: &ActorSink,
    changes: &Arc<ChangeHub>,
    state_notify: &Arc<Notify>,
    identity_snapshot: &Arc<Mutex<Arc<IdentitySnapshot>>>,
    waiters: &mut ActorWaiters,
) -> u64 {
    let window_ops = state.messages.take_pending_window_ops();
    // Refresh the lock-free IdentitySnapshot whenever session, conversations, or contacts mutated.
    if out.dirty.contains(&crate::changes::DirtyKey::Session)
        || out.dirty.contains(&crate::changes::DirtyKey::Conversations)
        || out.dirty.contains(&crate::changes::DirtyKey::Contacts)
    {
        let next_snap = Arc::new(state.identity_snapshot());
        *identity_snapshot
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = next_snap;
    }

    let version = changes.publish_with_window_ops(&out.dirty, &window_ops, state);
    if !out.effects.is_empty() {
        let mut runner_effects = Vec::with_capacity(out.effects.len());
        for effect in out.effects {
            match effect {
                Effect::CompleteDrain {
                    drain_id,
                    total_events,
                } => {
                    if let Some(waiter) = waiters.drains.remove(&drain_id) {
                        let _ = waiter.send(total_events);
                    }
                }
                Effect::CompleteOp {
                    op_id,
                    result,
                    after_store: false,
                } => {
                    if let Some(waiter) = waiters.ops.remove(&op_id) {
                        let _ = waiter.send((result, version));
                    }
                }
                other => runner_effects.push(other),
            }
        }
        if !runner_effects.is_empty() {
            runner.dispatch(runner_effects, sink.clone());
        }
    }
    if !out.dirty.is_empty() || !window_ops.is_empty() {
        state_notify.notify_waiters();
    }
    version
}

#[expect(
    clippy::too_many_arguments,
    reason = "Single spawned actor task receives its owned channels and shared handles"
)]
async fn run_actor(
    mut state: CoreState,
    mut rx: mpsc::UnboundedReceiver<ActorMsg>,
    runner: Arc<dyn EffectRunner>,
    sink: ActorSink,
    changes: Arc<ChangeHub>,
    tracker: Arc<ActivityTracker>,
    state_notify: Arc<Notify>,
    identity_snapshot: Arc<Mutex<Arc<IdentitySnapshot>>>,
    latest_identities: Arc<Mutex<Option<IdentityTable>>>,
) {
    let mut waiters = ActorWaiters::new();
    while let Some(msg) = rx.recv().await {
        match msg {
            ActorMsg::CoalescedIdentities => {
                let maybe_table = {
                    let mut slot = latest_identities
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner);
                    slot.take()
                };
                if let Some(table) = maybe_table {
                    let out = reduce(&mut state, Input::Command(Command::UpdateIdentities(table)));
                    let _ = dispatch_reduce_output(
                        &mut state,
                        out,
                        &runner,
                        &sink,
                        &changes,
                        &state_notify,
                        &identity_snapshot,
                        &mut waiters,
                    );
                }
                tracker.decrement();
            }
            ActorMsg::Input { input, ack } => {
                let out = reduce(&mut state, *input);
                let version = dispatch_reduce_output(
                    &mut state,
                    out,
                    &runner,
                    &sink,
                    &changes,
                    &state_notify,
                    &identity_snapshot,
                    &mut waiters,
                );
                if let Some(reply) = ack {
                    let _ = reply.send(version);
                }
                // Decrement AFTER dispatching effects so their InFlightGuards are already active.
                tracker.decrement();
            }
            ActorMsg::OpRequest { cmd, reply } => {
                let op_id = waiters.alloc_op_id();
                waiters.ops.insert(op_id, reply);
                let out = reduce(&mut state, Input::OpRequest { op_id, cmd: *cmd });
                let _ = dispatch_reduce_output(
                    &mut state,
                    out,
                    &runner,
                    &sink,
                    &changes,
                    &state_notify,
                    &identity_snapshot,
                    &mut waiters,
                );
                tracker.decrement();
            }
            ActorMsg::DrainChatPolling {
                max_batches,
                notify_incoming,
                reply,
            } => {
                let drain_id = state.transport.alloc_drain_id();
                waiters.drains.insert(drain_id, reply);
                let out = reduce(
                    &mut state,
                    Input::DrainRequested {
                        drain_id,
                        max_batches,
                        notify_incoming,
                    },
                );
                let _ = dispatch_reduce_output(
                    &mut state,
                    out,
                    &runner,
                    &sink,
                    &changes,
                    &state_notify,
                    &identity_snapshot,
                    &mut waiters,
                );
                tracker.decrement();
            }
            ActorMsg::Snapshot(reply) => {
                let _ = reply.send(state.session.snapshot());
            }
            ActorMsg::FullSnapshot(reply) => {
                let _ = reply.send(state.full_snapshot());
            }
            ActorMsg::Settle(reply) => {
                let _ = reply.send(changes.current_version());
            }
            ActorMsg::Stop => {
                break;
            }
        }
    }
    for (_, waiter) in waiters.drains.drain() {
        let _ = waiter.send(0);
    }
    waiters.ops.clear();
    runner.shutdown();
    changes.close();
    state_notify.notify_waiters();
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    reason = "unit tests assert invariants on synthetic fixtures"
)]
mod tests {
    use olaz_net::LoginAccount;

    use super::*;
    use crate::effect::Effect;
    use crate::state::Profile;

    struct NoopRunner;

    impl EffectRunner for NoopRunner {
        fn dispatch(&self, _effects: Vec<Effect>, _sink: ActorSink) {}
        fn shutdown(&self) {}
    }

    #[tokio::test]
    async fn send_and_ack_returns_revision_delivered_by_next_changes() {
        let core = CoreHandle::start(Arc::new(NoopRunner), Handle::current());
        let acc = LoginAccount {
            user_id: "7".to_owned(),
            display_name: "Minh".to_owned(),
            ..LoginAccount::default()
        };
        let rev = core.send_and_ack(Command::ApplyAccountProfile(acc)).await;
        assert_eq!(rev, Some(1));

        let batch = core.next_changes().await;
        assert_eq!(batch.as_ref().map(|b| b.version), Some(1));
        assert_eq!(
            batch.and_then(|b| b.session).and_then(|s| s.profile),
            Some(Profile {
                user_id: "7".to_owned(),
                display_name: "Minh".to_owned(),
                avatar: None,
                phone: None,
            })
        );
        core.stop();
        assert!(core.next_changes().await.is_none());
    }

    #[tokio::test]
    async fn settle_waits_for_earlier_enqueued_inputs() {
        let core = CoreHandle::start(Arc::new(NoopRunner), Handle::current());
        let acc = LoginAccount {
            user_id: "99".to_owned(),
            display_name: "Barrier".to_owned(),
            ..LoginAccount::default()
        };
        core.send(Command::ApplyAccountProfile(acc));
        let rev = core.settle().await;
        assert_eq!(rev, Some(1));

        let batch = core.next_changes().await;
        assert_eq!(batch.as_ref().map(|b| b.version), Some(1));

        core.stop();
        assert_eq!(core.settle().await, None);
    }

    #[tokio::test]
    async fn drain_chat_polling_when_lp_stopped_resolves_immediately_with_zero() {
        let core = CoreHandle::start(Arc::new(NoopRunner), Handle::current());
        assert_eq!(core.drain_chat_polling(4, false).await, 0);
        core.stop();
        assert_eq!(core.drain_chat_polling(4, false).await, 0);
    }

    #[tokio::test]
    async fn burst_update_identities_coalesces_to_latest_table() {
        let core = CoreHandle::start(Arc::new(NoopRunner), Handle::current());
        for i in 0..2_000usize {
            let mut tbl = IdentityTable::default();
            tbl.aliases.insert("u1".to_owned(), format!("alias-{i}"));
            core.send(Command::UpdateIdentities(tbl));
        }
        let rev = core.settle().await;
        assert!(rev.is_some());
        core.wait_idle().await;
        let full = core.full_snapshot().await.expect("full snapshot");
        assert_eq!(
            full.conversations
                .identities
                .aliases
                .get("u1")
                .map(String::as_str),
            Some("alias-1999")
        );
        core.stop();
    }
}
