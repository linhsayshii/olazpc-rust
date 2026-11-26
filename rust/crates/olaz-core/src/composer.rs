//! Composer side actions: own contact card, reminders, confirm queue, and reporting (U13).
//!
//! `Debug` implementations emit shape-only summaries without PII or message text (ADR-008).

use std::collections::{BTreeMap, VecDeque};
use std::fmt;

/// Delay in milliseconds before promoting the next queued composer confirm.
pub const CONFIRM_PROMOTE_DELAY_MS: u64 = 300;
/// Maximum raw UTF-16 code units allowed in a reminder title (exclusive upper bound: `< 3000`).
pub const REMINDER_TITLE_MAX_CHARS: i64 = 3000;
/// Maximum trimmed UTF-8 byte length allowed in a reminder title (inclusive upper bound: `<= 3700`).
pub const REMINDER_TITLE_MAX_BYTES: i64 = 3700;
/// Generic composer failure message (`ComposerOutcome.genericFailure`).
pub const COMPOSER_GENERIC_FAILURE: &str = "Không gửi được. Hãy thử lại.";
/// Validation error when a reminder title exceeds official limits (user-decisions item 13.2).
pub const REMINDER_TOO_LONG_FAILURE: &str = "Bạn đã nhập quá số kí tự cho phép";
/// Failure message when the reminder API call fails.
pub const REMINDER_API_FAILURE: &str = "Không tạo được nhắc hẹn. Hãy thử lại.";
/// Failure message when `send_my_card` is called before a profile is loaded.
pub const NOT_LOGGED_IN_FAILURE: &str = "Chưa đăng nhập.";

/// Result of a composer side action (matches Swift `ComposerOutcome`).
#[derive(Clone, PartialEq, Eq)]
pub enum ComposerOutcome {
    Done,
    Cancelled,
    Failed(String),
    Pending(String),
}

impl fmt::Debug for ComposerOutcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Done => f.write_str("Done"),
            Self::Cancelled => f.write_str("Cancelled"),
            Self::Failed(_) => f.write_str("Failed"),
            Self::Pending(_) => f.write_str("Pending"),
        }
    }
}

/// Confirmation dialog queued for composer actions (e.g. oversized file fallback).
#[derive(Clone, PartialEq, Eq)]
pub struct ComposerConfirm {
    pub id: String,
    pub conv_id: String,
    pub title: String,
    pub message: String,
    pub ok: String,
    pub cancel: String,
}

impl fmt::Debug for ComposerConfirm {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ComposerConfirm")
            .field("id_len", &self.id.len())
            .field("conv_id_len", &self.conv_id.len())
            .finish()
    }
}

/// Own contact card info returned by `my_card` (matches Swift `MyCardInfo`).
#[derive(Clone, PartialEq, Eq)]
pub struct MyCardInfo {
    pub uid: String,
    pub name: String,
    pub avatar: Option<String>,
    pub phone: String,
    pub with_phone: bool,
}

impl fmt::Debug for MyCardInfo {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MyCardInfo")
            .field("has_avatar", &self.avatar.is_some())
            .field("with_phone", &self.with_phone)
            .finish()
    }
}

/// Capabilities and limits of the reminder compose sheet for a conversation.
#[derive(Clone, PartialEq, Eq)]
pub struct ReminderComposeInfo {
    pub allowed: bool,
    pub hidden: bool,
    pub text: String,
    pub is_group: bool,
    pub can_pin: bool,
    pub pin_toggle: bool,
    pub title_max_chars: i64,
    pub title_max_bytes: i64,
}

impl ReminderComposeInfo {
    /// Official reminder title limit check (`ReminderComposeInfo.titleTooLong`):
    /// returns `true` when raw UTF-16 code units `>= title_max_chars` (3000) or trimmed UTF-8
    /// byte length `> title_max_bytes` (3700).
    #[must_use]
    pub fn title_too_long(&self, raw: &str) -> bool {
        let utf16_len = i64::try_from(raw.encode_utf16().count()).unwrap_or(i64::MAX);
        let trimmed_utf8_len = i64::try_from(raw.trim().len()).unwrap_or(i64::MAX);
        utf16_len >= self.title_max_chars || trimmed_utf8_len > self.title_max_bytes
    }

    /// Evaluates the standard reminder title limits (3000 UTF-16 units / 3700 trimmed UTF-8 bytes).
    #[must_use]
    pub fn is_title_too_long_default(raw: &str) -> bool {
        let utf16_len = i64::try_from(raw.encode_utf16().count()).unwrap_or(i64::MAX);
        let trimmed_utf8_len = i64::try_from(raw.trim().len()).unwrap_or(i64::MAX);
        utf16_len >= REMINDER_TITLE_MAX_CHARS || trimmed_utf8_len > REMINDER_TITLE_MAX_BYTES
    }
}

impl fmt::Debug for ReminderComposeInfo {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ReminderComposeInfo")
            .field("allowed", &self.allowed)
            .field("hidden", &self.hidden)
            .field("is_group", &self.is_group)
            .field("can_pin", &self.can_pin)
            .finish()
    }
}

/// Shared contact-card send request specification used by `send_my_card` (U13) and `forward` (U8).
#[derive(Clone)]
pub struct ContactCardSendSpec {
    pub conv_id: String,
    pub contact_uid: String,
    pub title: String,
    pub avatar: Option<String>,
    pub phone: Option<String>,
    pub qr_code_url: String,
    pub client_id: Option<i64>,
    pub now_ms: i64,
    pub is_e2ee_override: Option<bool>,
}

/// Continuation invoked when an in-flight contact-card send completes.
#[derive(Clone)]
pub(crate) enum ContactCardContinuation {
    SendMyCard { op_id: Option<u64> },
}

#[derive(Clone)]
pub(crate) struct PendingContactCard {
    pub spec: ContactCardSendSpec,
    pub is_e2ee: bool,
    pub on_done: ContactCardContinuation,
}

/// In-memory composer state owned by the core actor.
#[derive(Clone, Default)]
pub struct ComposerState {
    pub active_confirm: Option<ComposerConfirm>,
    pub queued_confirms: VecDeque<ComposerConfirm>,
    pub(crate) confirm_timer_gen: u64,
    pub(crate) next_card_send_id: u64,
    pub(crate) in_flight_contact_cards: BTreeMap<u64, PendingContactCard>,
}

impl ComposerState {
    pub(crate) fn alloc_card_send_id(&mut self) -> u64 {
        self.next_card_send_id = self.next_card_send_id.wrapping_add(1).max(1);
        self.next_card_send_id
    }

    pub(crate) fn bump_confirm_timer_gen(&mut self) -> u64 {
        self.confirm_timer_gen = self.confirm_timer_gen.wrapping_add(1).max(1);
        self.confirm_timer_gen
    }
}

impl fmt::Debug for ComposerState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ComposerState")
            .field("has_active_confirm", &self.active_confirm.is_some())
            .field("queued_confirms_count", &self.queued_confirms.len())
            .field("in_flight_cards", &self.in_flight_contact_cards.len())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn title_too_long_enforces_utf16_and_trimmed_utf8_bounds() {
        // 2999 ASCII chars -> ok
        let ok_ascii = "a".repeat(2999);
        assert!(!ReminderComposeInfo::is_title_too_long_default(&ok_ascii));

        // 3000 ASCII chars -> too long (>= 3000 UTF-16)
        let too_long_utf16 = "a".repeat(3000);
        assert!(ReminderComposeInfo::is_title_too_long_default(
            &too_long_utf16
        ));

        // 1500 emoji (each is 2 UTF-16 code units = 3000 UTF-16, 6000 UTF-8) -> too long
        let emoji = "😀".repeat(1500);
        assert!(ReminderComposeInfo::is_title_too_long_default(&emoji));

        // 1234 Vietnamese 3-byte chars = 1234 UTF-16 (< 3000), 3702 UTF-8 (> 3700) -> too long
        let vn_3702 = "ệ".repeat(1234);
        assert_eq!(vn_3702.encode_utf16().count(), 1234);
        assert_eq!(vn_3702.len(), 3702);
        assert!(ReminderComposeInfo::is_title_too_long_default(&vn_3702));

        // 1233 Vietnamese 3-byte chars = 3699 UTF-8 + surrounding whitespace -> trimmed 3699 <= 3700 -> ok
        let vn_3699_padded = format!("   {}   ", "ệ".repeat(1233));
        assert!(!ReminderComposeInfo::is_title_too_long_default(
            &vn_3699_padded
        ));
    }
}
