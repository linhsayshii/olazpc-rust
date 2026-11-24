//! Single tokio actor owning [`CoreState`] (D1, ADR-016).
//!
//! The actor loop never awaits I/O or host callbacks inline: it runs `reduce(&mut state, input)`,
//! publishes dirty keys to [`ChangeHub`], and hands effects to [`EffectRunner`].

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use tokio::runtime::Handle;
use tokio::sync::{Notify, mpsc, oneshot};

use crate::changes::{ChangeHub, CoreChanges};
use crate::input::{Command, Input};
use crate::reduce::reduce;
use crate::runner::EffectRunner;
use crate::state::{CoreState, SessionSnapshot};

enum ActorMsg {
    Input {
        input: Box<Input>,
        ack: Option<oneshot::Sender<u64>>,
    },
    Snapshot(oneshot::Sender<SessionSnapshot>),
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
        ));
        Self {
            tx,
            changes,
            tracker,
            state_notify,
        }
    }

    /// Enqueues a command without blocking.
    pub fn send(&self, command: Command) {
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

    /// Pulls the next batch of dirty domain snapshots (`None` once stopped and drained).
    pub async fn next_changes(&self) -> Option<CoreChanges> {
        self.changes.next_changes().await
    }

    /// Returns the latest monotonic revision published to the change hub.
    #[must_use]
    pub fn current_version(&self) -> u64 {
        self.changes.current_version()
    }

    /// Reads the current [`SessionSnapshot`] directly from the actor (tests / diagnostics).
    pub async fn snapshot(&self) -> Option<SessionSnapshot> {
        let (tx, rx) = oneshot::channel();
        if self.tx.send(ActorMsg::Snapshot(tx)).is_err() {
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

    /// Stops the actor, aborts in-flight effects, and closes `next_changes()`.
    pub fn stop(&self) {
        let _ = self.tx.send(ActorMsg::Stop);
    }
}

impl Drop for CoreHandle {
    fn drop(&mut self) {
        self.stop();
    }
}

async fn run_actor(
    mut state: CoreState,
    mut rx: mpsc::UnboundedReceiver<ActorMsg>,
    runner: Arc<dyn EffectRunner>,
    sink: ActorSink,
    changes: Arc<ChangeHub>,
    tracker: Arc<ActivityTracker>,
    state_notify: Arc<Notify>,
) {
    while let Some(msg) = rx.recv().await {
        match msg {
            ActorMsg::Input { input, ack } => {
                let out = reduce(&mut state, *input);
                let version = changes.publish(&out.dirty, &state);
                if !out.effects.is_empty() {
                    runner.dispatch(out.effects, sink.clone());
                }
                if !out.dirty.is_empty() {
                    state_notify.notify_waiters();
                }
                if let Some(reply) = ack {
                    let _ = reply.send(version);
                }
                // Decrement AFTER dispatching effects so their InFlightGuards are already active.
                tracker.decrement();
            }
            ActorMsg::Snapshot(reply) => {
                let _ = reply.send(state.session.snapshot());
            }
            ActorMsg::Stop => {
                break;
            }
        }
    }
    runner.shutdown();
    changes.close();
    state_notify.notify_waiters();
}

#[cfg(test)]
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
}
