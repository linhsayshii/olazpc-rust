//! Command numbers and protocol constants (mirrors `ZaloWebSocket` statics).

pub const CMD_AUTHEN: u16 = 1;
pub const CMD_PING: u16 = 2;
pub const CMD_PING_ACTIVE: u16 = 4;
pub const SUB_KEEP_CONNECTION: u8 = 1;
pub const SUB_KEEP_ACTIVE: u8 = 2;

pub const CMD_CTRL_PUSH_CTRL: u16 = 601;
pub const CMD_CTRL_ACTION: u16 = 602;
pub const CMD_CTRL_PULL_CTRL: u16 = 603;
pub const CMD_CTRL_PULL_VOIP: u16 = 604;

pub const CMD_PUSH_MSG_11: u16 = 501;
pub const CMD_PULL_MSG_11: u16 = 510;
pub const CMD_PULL_MSG_GROUP: u16 = 511;
pub const CMD_PULL_MSG_513: u16 = 513;
pub const CMD_PULL_MSG_514: u16 = 514;
pub const CMD_PULL_MSG_515: u16 = 515;
pub const CMD_PULL_MSG_517: u16 = 517;
pub const CMD_PULL_MSG_518: u16 = 518;
pub const CMD_PUSH_MSG_GROUP: u16 = 521;
pub const CMD_VERIFY_MSG: u16 = 532;
pub const CMD_HAS_MSG: u16 = 533;
pub const CMD_PUSH_MISS_MSG: u16 = 534;
pub const CMD_GET_MSG: u16 = 570;
pub const CMD_SYNC_REQUEST: u16 = 590;
pub const CMD_SYNC_ACK_DELETE: u16 = 591;
pub const CMD_SYNC_MOBILE_WAKE_UP: u16 = 592;

/// `ZaloE2EEManager` commands that are also routed as chat events.
pub const CMD_E2EE_PUSH_MISS: u16 = 535;
pub const CMD_E2EE_SUBMIT_BUNDLE: u16 = 540;
pub const CMD_E2EE_RECEIVE_ONE_ONE: u16 = 551;
pub const CMD_E2EE_RECEIVE_GROUP: u16 = 552;

/// Frame version byte used by every outgoing frame.
pub const FRAME_VERSION: u8 = 1;

pub use olaz_client::identity::CLIENT_TYPE as ZPW_TYPE;
/// `ZaloDomains.zpwVer` / `zpwType` (PC macOS) used in the socket URL.
pub use olaz_client::identity::CLIENT_VERSION as ZPW_VER;
pub use olaz_client::identity::USER_AGENT;
pub use olaz_client::identity::WS_ORIGIN;

/// Default endpoints (`ZaloDomains().ws`).
pub const DEFAULT_WS_ENDPOINTS: [&str; 4] = [
    "wss://ws1-msg.chat.zalo.me",
    "wss://ws2-msg.chat.zalo.me",
    "wss://ws3-msg.chat.zalo.me",
    "wss://ws4-msg.chat.zalo.me",
];

/// Keep-alive ping interval (seconds).
pub const PING_INTERVAL_SECS: u64 = 15;
/// Default `sendRequestFrame` timeout (seconds).
pub const REQUEST_TIMEOUT_SECS: f64 = 10.0;
/// Default `waitForFileDone` timeout (seconds).
pub const FILE_WAIT_TIMEOUT_SECS: f64 = 12.0;
/// Completed file-url cache size before eviction.
pub const COMPLETED_FILE_CAP: usize = 200;
