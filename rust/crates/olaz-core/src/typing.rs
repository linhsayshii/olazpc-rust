//! Incoming and outgoing typing indicator state & pure reducer (U5).
//!
//! Mirrors Swift's `ZaloEngine.typing` / `showTyping` / `handleTyping(state:)` (incoming 10 s
//! display timer with per-conversation generations) and `notifyTyping` / `resetOutgoingTyping` /
//! `OutgoingTypingThrottle` (10 s per-conversation outgoing throttle gated on `Phase::Ready` and
//! `olaz.sendTyping`, default `true`).
//!
//! No I/O and no wall clock live here (D9): `now_ms` enters as a command field and expiry timers
//! run as [`Effect::StartTypingExpiry`] / [`Effect::CancelTypingExpiry`] in `EffectRunner`.

use std::collections::BTreeMap;
use std::fmt;
use std::time::Duration;

use serde_json::{Map, Value};

use crate::changes::DirtyKey;
use crate::effect::{Effect, OpResult};
use crate::input::{Command, Input};
use crate::reduce::ReduceOutput;
use crate::state::{CoreState, Phase};

/// Fallback display name when the typing sender is not in known contacts/profiles
/// (Swift `ZaloEngine.swift:974` / `ZaloEngine+Core.swift:453`).
pub const DEFAULT_TYPING_NAME: &str = "Ai đó";

/// Incoming indicator display lifetime (Swift `TypingStatus.displaySeconds = 10`).
pub const TYPING_DISPLAY_DURATION: Duration = Duration::from_secs(10);

/// Outgoing typing ping throttle interval per conversation in milliseconds
/// (Swift `OutgoingTypingThrottle.defaultInterval = 10`).
pub const OUTGOING_TYPING_THROTTLE_MS: i64 = 10_000;

/// Active incoming typing indicator for one conversation (mirrors Swift `TypingStatus`).
#[derive(Clone, PartialEq, Eq)]
pub struct TypingStatus {
    pub name: String,
    /// `isPC == 1`: peer is typing on Zalo PC/Web.
    pub on_pc: bool,
}

impl fmt::Debug for TypingStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TypingStatus")
            .field("has_name", &!self.name.is_empty())
            .field("on_pc", &self.on_pc)
            .finish()
    }
}

/// Core-owned incoming + outgoing typing state (U5).
#[derive(Clone, PartialEq, Eq)]
pub struct TypingState {
    /// Active incoming typing indicators keyed by conversation id (`ZaloEngine.typing`).
    pub active: BTreeMap<String, TypingStatus>,
    /// User preference `olaz.sendTyping` (defaults to `true`, matching Swift `UserDefaults`).
    pub send_typing_enabled: bool,
    /// Active expiry generation per conversation id; stale `TypingExpired` inputs are ignored.
    active_gen: BTreeMap<String, u64>,
    /// Monotonic expiry generation counter (never reset across clear/logout to prevent ABA).
    next_expiry_gen: u64,
    /// Last outgoing typing ping timestamp (Unix ms) per trimmed conversation id.
    last_outgoing_ms: BTreeMap<String, i64>,
}

impl Default for TypingState {
    fn default() -> Self {
        Self {
            active: BTreeMap::new(),
            send_typing_enabled: true,
            active_gen: BTreeMap::new(),
            next_expiry_gen: 0,
            last_outgoing_ms: BTreeMap::new(),
        }
    }
}

impl fmt::Debug for TypingState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TypingState")
            .field("active_count", &self.active.len())
            .field("send_typing_enabled", &self.send_typing_enabled)
            .field("throttled_count", &self.last_outgoing_ms.len())
            .finish()
    }
}

impl TypingState {
    /// Allocates and stores a fresh expiry generation for `conv_id`.
    pub(crate) fn bump_expiry_gen(&mut self, conv_id: &str) -> u64 {
        self.next_expiry_gen = self.next_expiry_gen.wrapping_add(1);
        let expiry_gen = self.next_expiry_gen;
        self.active_gen.insert(conv_id.to_owned(), expiry_gen);
        expiry_gen
    }

    /// Expires `conv_id` if and only if `expiry_gen` matches the active generation.
    /// Returns `true` if an entry was removed from `active`.
    pub(crate) fn expire(&mut self, conv_id: &str, expiry_gen: u64) -> bool {
        if self.active_gen.get(conv_id) != Some(&expiry_gen) {
            return false;
        }
        self.active_gen.remove(conv_id);
        self.active.remove(conv_id).is_some()
    }

    /// Checks and records the per-conversation 10 s outgoing throttle for `conv_id` at `now_ms`.
    /// Returns the trimmed conversation id when a typing ping should be sent.
    pub(crate) fn try_consume_outgoing(&mut self, conv_id: &str, now_ms: i64) -> Option<String> {
        let target = conv_id.trim();
        if target.is_empty() {
            return None;
        }
        if let Some(&last_ms) = self.last_outgoing_ms.get(target)
            && now_ms.saturating_sub(last_ms) < OUTGOING_TYPING_THROTTLE_MS
        {
            return None;
        }
        self.last_outgoing_ms.insert(target.to_owned(), now_ms);
        Some(target.to_owned())
    }

    /// Clears the outgoing throttle for `conv_id` (called when a message is sent or composer clears).
    pub(crate) fn reset_outgoing(&mut self, conv_id: &str) {
        let target = conv_id.trim();
        if target.is_empty() {
            return;
        }
        self.last_outgoing_ms.remove(target);
    }

    /// Resets per-session typing state on logout / session expiry, preserving the device-level
    /// `send_typing_enabled` preference and monotonic `next_expiry_gen`.
    /// Returns `true` if `active` was non-empty and changed.
    pub(crate) fn reset_session(&mut self) -> bool {
        let had_active = !self.active.is_empty();
        self.active.clear();
        self.active_gen.clear();
        self.last_outgoing_ms.clear();
        had_active
    }
}

/// Records or refreshes an incoming typing indicator and schedules its 10 s expiry timer.
///
/// Mirrors Swift `ZaloEngine.showTyping`: only dirties [`DirtyKey::Typing`] when the visible
/// `(name, on_pc)` value changes, while always bumping the generation and restarting the timer.
pub fn set_typing(
    typing: &mut TypingState,
    conv_id: String,
    name: String,
    on_pc: bool,
    out: &mut ReduceOutput,
) {
    let status = TypingStatus { name, on_pc };
    if typing.active.get(&conv_id) != Some(&status) {
        typing.active.insert(conv_id.clone(), status);
        out.dirty.insert(DirtyKey::Typing);
    }
    let expiry_gen = typing.bump_expiry_gen(&conv_id);
    out.effects.push(Effect::StartTypingExpiry {
        conv_id,
        expiry_gen,
        delay: TYPING_DISPLAY_DURATION,
    });
}

/// Clears any active incoming typing indicator for `conv_id` and cancels its expiry timer.
pub fn clear_typing(typing: &mut TypingState, conv_id: &str, out: &mut ReduceOutput) {
    typing.active_gen.remove(conv_id);
    if typing.active.remove(conv_id).is_some() {
        out.dirty.insert(DirtyKey::Typing);
        out.effects.push(Effect::CancelTypingExpiry {
            conv_id: conv_id.to_owned(),
        });
    }
}

/// Pure reducer for U5 typing commands and expiry inputs.
pub(crate) fn reduce_typing(state: &mut CoreState, input: Input, out: &mut ReduceOutput) {
    match input {
        Input::Command(cmd) => reduce_command(state, cmd, None, out),
        Input::OpRequest { op_id, cmd } => reduce_command(state, cmd, Some(op_id), out),
        Input::TypingExpired {
            conv_id,
            expiry_gen,
        } if state.typing.expire(&conv_id, expiry_gen) => {
            out.dirty.insert(DirtyKey::Typing);
        }
        _ => {}
    }
}

fn reduce_command(state: &mut CoreState, cmd: Command, op_id: Option<u64>, out: &mut ReduceOutput) {
    match cmd {
        Command::HandleTyping { state: raw } => {
            apply_typing_state_json(&mut state.typing, &raw, out);
        }
        Command::NotifyTyping { conv_id, now_ms } => {
            let target = conv_id.trim();
            if !target.is_empty()
                && state.session.phase == Phase::Ready
                && state.typing.send_typing_enabled
                && let Some(conv_id) = state.typing.try_consume_outgoing(target, now_ms)
            {
                out.effects.push(Effect::SendTypingApi { conv_id });
            }
        }
        Command::ResetOutgoingTyping { conv_id } => {
            state.typing.reset_outgoing(&conv_id);
        }
        Command::SetSendTypingEnabled { enabled } => {
            state.typing.send_typing_enabled = enabled;
        }
        _ => {}
    }
    if let Some(id) = op_id {
        out.effects.push(Effect::CompleteOp {
            op_id: id,
            result: OpResult::Unit,
            after_store: false,
        });
    }
}

/// Swift `ZaloEngine.handleTyping(state:)`:
/// expects `{"typing": {"convId": <str>, "name": <str>, "isPC"?: <bool>}}`.
fn apply_typing_state_json(
    typing: &mut TypingState,
    raw: &Map<String, Value>,
    out: &mut ReduceOutput,
) {
    let Some(info) = raw.get("typing").and_then(Value::as_object) else {
        return;
    };
    let Some(conv_id) = info.get("convId").and_then(Value::as_str) else {
        return;
    };
    let Some(name) = info.get("name").and_then(Value::as_str) else {
        return;
    };
    let on_pc = info.get("isPC").and_then(Value::as_bool).unwrap_or(false);
    set_typing(typing, conv_id.to_owned(), name.to_owned(), on_pc, out);
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::reduce::reduce;
    use crate::state::{LoginState, Phase};

    fn json_obj(val: Value) -> Map<String, Value> {
        match val {
            Value::Object(map) => map,
            other => panic!("expected JSON object, got {other:?}"),
        }
    }

    fn ready_state() -> CoreState {
        let mut s = CoreState::default();
        s.session.phase = Phase::Ready;
        s
    }

    #[test]
    fn default_typing_state_enables_send_typing_and_redacts_debug() {
        let mut st = TypingState::default();
        assert!(st.send_typing_enabled);
        assert!(st.active.is_empty());

        let mut out = ReduceOutput::default();
        set_typing(
            &mut st,
            "3000515".to_owned(),
            "SECRET_ALICE".to_owned(),
            true,
            &mut out,
        );
        let dbg_state = format!("{st:?}");
        let Some(entry) = st.active.get("3000515") else {
            panic!("missing entry");
        };
        let dbg_status = format!("{entry:?}");
        assert!(!dbg_state.contains("SECRET_ALICE"));
        assert!(!dbg_state.contains("3000515"));
        assert!(!dbg_status.contains("SECRET_ALICE"));
    }

    #[test]
    fn incoming_set_typing_and_generation_guarded_expiry() {
        let mut state = ready_state();
        let mut out1 = ReduceOutput::default();
        set_typing(
            &mut state.typing,
            "3000515".to_owned(),
            "Alice".to_owned(),
            true,
            &mut out1,
        );
        assert!(out1.dirty.contains(&DirtyKey::Typing));
        assert_eq!(
            state.typing.active.get("3000515"),
            Some(&TypingStatus {
                name: "Alice".to_owned(),
                on_pc: true,
            })
        );
        let gen1 = match &out1.effects[0] {
            Effect::StartTypingExpiry {
                conv_id,
                expiry_gen,
                delay,
            } => {
                assert_eq!(conv_id, "3000515");
                assert_eq!(*delay, TYPING_DISPLAY_DURATION);
                *expiry_gen
            }
            other => panic!("expected StartTypingExpiry, got {other:?}"),
        };

        // Re-ping with identical status restarts timer with new gen without re-dirtying Typing.
        let mut out2 = ReduceOutput::default();
        set_typing(
            &mut state.typing,
            "3000515".to_owned(),
            "Alice".to_owned(),
            true,
            &mut out2,
        );
        assert!(!out2.dirty.contains(&DirtyKey::Typing));
        let gen2 = match &out2.effects[0] {
            Effect::StartTypingExpiry { expiry_gen, .. } => *expiry_gen,
            other => panic!("expected StartTypingExpiry, got {other:?}"),
        };
        assert_ne!(gen1, gen2);

        // Stale expiry from gen1 is ignored.
        let stale = reduce(
            &mut state,
            Input::TypingExpired {
                conv_id: "3000515".to_owned(),
                expiry_gen: gen1,
            },
        );
        assert!(stale.dirty.is_empty());
        assert!(state.typing.active.contains_key("3000515"));

        // Matching expiry from gen2 removes indicator and dirties Typing.
        let expired = reduce(
            &mut state,
            Input::TypingExpired {
                conv_id: "3000515".to_owned(),
                expiry_gen: gen2,
            },
        );
        assert!(expired.dirty.contains(&DirtyKey::Typing));
        assert!(state.typing.active.is_empty());

        // Duplicate expiry is a no-op.
        let dup = reduce(
            &mut state,
            Input::TypingExpired {
                conv_id: "3000515".to_owned(),
                expiry_gen: gen2,
            },
        );
        assert!(dup.dirty.is_empty());
    }

    #[test]
    fn handle_typing_json_matches_send_jsonl_cases() {
        let mut state = ready_state();

        let map1 =
            json_obj(json!({"typing": {"convId": "3000516", "isPC": true, "name": "Charlie"}}));
        let out1 = reduce(
            &mut state,
            Input::Command(Command::HandleTyping { state: map1 }),
        );
        assert!(out1.dirty.contains(&DirtyKey::Typing));
        assert_eq!(
            state.typing.active.get("3000516"),
            Some(&TypingStatus {
                name: "Charlie".to_owned(),
                on_pc: true,
            })
        );

        let map2 = json_obj(json!({"typing": {"convId": "g500516", "name": "Dana"}}));
        let out2 = reduce(
            &mut state,
            Input::Command(Command::HandleTyping { state: map2 }),
        );
        assert!(out2.dirty.contains(&DirtyKey::Typing));
        assert_eq!(
            state.typing.active.get("g500516"),
            Some(&TypingStatus {
                name: "Dana".to_owned(),
                on_pc: false,
            })
        );

        // Unrelated shape is ignored without dirtying or emitting effects.
        let map3 = json_obj(json!({"other": "ignored"}));
        let out3 = reduce(
            &mut state,
            Input::Command(Command::HandleTyping { state: map3 }),
        );
        assert!(out3.dirty.is_empty());
        assert!(out3.effects.is_empty());
        assert_eq!(state.typing.active.len(), 2);
    }

    #[test]
    fn open_conversation_clears_active_typing_and_cancels_timer() {
        let mut state = ready_state();
        let mut out = ReduceOutput::default();
        set_typing(
            &mut state.typing,
            "3000515".to_owned(),
            "Alice".to_owned(),
            false,
            &mut out,
        );
        let gen1 = match &out.effects[0] {
            Effect::StartTypingExpiry { expiry_gen, .. } => *expiry_gen,
            other => panic!("unexpected effect {other:?}"),
        };

        let open_out = reduce(
            &mut state,
            Input::Command(Command::SetOpenConversation {
                id: Some("3000515".to_owned()),
            }),
        );
        assert!(open_out.dirty.contains(&DirtyKey::Typing));
        assert!(state.typing.active.is_empty());
        assert!(open_out.effects.iter().any(|e| matches!(
            e,
            Effect::CancelTypingExpiry { conv_id } if conv_id == "3000515"
        )));

        // Late expiry from cancelled timer is ignored even if a new ping arrives later.
        let mut re_out = ReduceOutput::default();
        set_typing(
            &mut state.typing,
            "3000515".to_owned(),
            "Alice".to_owned(),
            true,
            &mut re_out,
        );
        let stale = reduce(
            &mut state,
            Input::TypingExpired {
                conv_id: "3000515".to_owned(),
                expiry_gen: gen1,
            },
        );
        assert!(stale.dirty.is_empty());
        assert!(state.typing.active.contains_key("3000515"));
    }

    #[test]
    fn outgoing_throttle_trim_reset_pref_and_phase_guards() {
        let mut state = ready_state();

        // Whitespace-only id is ignored.
        let out = reduce(
            &mut state,
            Input::Command(Command::NotifyTyping {
                conv_id: "   \n\t  ".to_owned(),
                now_ms: 1_700_000_000_000,
            }),
        );
        assert!(out.effects.is_empty());

        // Trimmed id fires SendTypingApi and throttles untrimmed equivalent for 10 s.
        let out = reduce(
            &mut state,
            Input::Command(Command::NotifyTyping {
                conv_id: "  3000517  ".to_owned(),
                now_ms: 1_700_000_000_000,
            }),
        );
        assert_eq!(out.effects.len(), 1);
        assert!(matches!(
            &out.effects[0],
            Effect::SendTypingApi { conv_id } if conv_id == "3000517"
        ));

        // 5 s later: throttled.
        let out = reduce(
            &mut state,
            Input::Command(Command::NotifyTyping {
                conv_id: "3000517".to_owned(),
                now_ms: 1_700_000_005_000,
            }),
        );
        assert!(out.effects.is_empty());

        // 9.999 s later: still throttled.
        let out = reduce(
            &mut state,
            Input::Command(Command::NotifyTyping {
                conv_id: "3000517".to_owned(),
                now_ms: 1_700_000_009_999,
            }),
        );
        assert!(out.effects.is_empty());

        // Exactly 10 s later: allowed (`< 10_000` is false).
        let out = reduce(
            &mut state,
            Input::Command(Command::NotifyTyping {
                conv_id: "3000517".to_owned(),
                now_ms: 1_700_000_010_000,
            }),
        );
        assert_eq!(out.effects.len(), 1);

        // ResetOutgoingTyping clears only that conversation's throttle.
        let _ = reduce(
            &mut state,
            Input::Command(Command::NotifyTyping {
                conv_id: "g500".to_owned(),
                now_ms: 1_700_000_010_000,
            }),
        );
        let _ = reduce(
            &mut state,
            Input::Command(Command::ResetOutgoingTyping {
                conv_id: "  3000517 ".to_owned(),
            }),
        );
        let out_reset = reduce(
            &mut state,
            Input::Command(Command::NotifyTyping {
                conv_id: "3000517".to_owned(),
                now_ms: 1_700_000_011_000,
            }),
        );
        assert_eq!(out_reset.effects.len(), 1);
        let out_other = reduce(
            &mut state,
            Input::Command(Command::NotifyTyping {
                conv_id: "g500".to_owned(),
                now_ms: 1_700_000_011_000,
            }),
        );
        assert!(out_other.effects.is_empty());

        // Pref off suppresses outgoing typing without mutating throttle.
        let _ = reduce(
            &mut state,
            Input::Command(Command::SetSendTypingEnabled { enabled: false }),
        );
        let out_off = reduce(
            &mut state,
            Input::Command(Command::NotifyTyping {
                conv_id: "3000518".to_owned(),
                now_ms: 1_700_000_020_000,
            }),
        );
        assert!(out_off.effects.is_empty());
        let _ = reduce(
            &mut state,
            Input::Command(Command::SetSendTypingEnabled { enabled: true }),
        );

        // Non-ready phase suppresses outgoing typing.
        state.session.phase = Phase::Login(LoginState::generating());
        let out_not_ready = reduce(
            &mut state,
            Input::Command(Command::NotifyTyping {
                conv_id: "3000519".to_owned(),
                now_ms: 1_700_000_030_000,
            }),
        );
        assert!(out_not_ready.effects.is_empty());
    }

    #[test]
    fn logout_resets_typing_state_but_preserves_pref_and_monotonic_generation() {
        let mut state = ready_state();
        let _ = reduce(
            &mut state,
            Input::Command(Command::SetSendTypingEnabled { enabled: false }),
        );
        let mut out = ReduceOutput::default();
        set_typing(
            &mut state.typing,
            "3000515".to_owned(),
            "Alice".to_owned(),
            true,
            &mut out,
        );
        let gen_before_logout = match &out.effects[0] {
            Effect::StartTypingExpiry { expiry_gen, .. } => *expiry_gen,
            other => panic!("unexpected effect {other:?}"),
        };

        let logout_out = reduce(&mut state, Input::Command(Command::LogOut));
        assert!(logout_out.dirty.contains(&DirtyKey::Typing));
        assert!(state.typing.active.is_empty());
        assert!(!state.typing.send_typing_enabled);

        // Re-login & new ping gets strictly higher generation (no ABA collision).
        let mut out_after = ReduceOutput::default();
        set_typing(
            &mut state.typing,
            "3000515".to_owned(),
            "Alice".to_owned(),
            true,
            &mut out_after,
        );
        let gen_after_logout = match &out_after.effects[0] {
            Effect::StartTypingExpiry { expiry_gen, .. } => *expiry_gen,
            other => panic!("unexpected effect {other:?}"),
        };
        assert!(gen_after_logout > gen_before_logout);
    }
}
