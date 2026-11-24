//! `ZaloWSEvent` model.

use serde_json::{Map, Value};

use crate::consts::*;

#[derive(Debug, Clone, PartialEq)]
pub struct WsEvent {
    pub cmd: u16,
    pub sub_cmd: u8,
    pub version: u8,
    pub payload: Map<String, Value>,
}

impl WsEvent {
    pub fn is_chat_push_or_pull(&self) -> bool {
        matches!(
            self.cmd,
            CMD_PUSH_MSG_11
                | CMD_PUSH_MSG_GROUP
                | CMD_PULL_MSG_11
                | CMD_PULL_MSG_GROUP
                | CMD_PULL_MSG_513
                | CMD_PULL_MSG_514
                | CMD_PULL_MSG_515
                | CMD_PULL_MSG_517
                | CMD_PULL_MSG_518
                | CMD_PUSH_MISS_MSG
                | CMD_GET_MSG
                | CMD_E2EE_RECEIVE_ONE_ONE
                | CMD_E2EE_RECEIVE_GROUP
                | CMD_E2EE_PUSH_MISS
        )
    }

    pub fn is_control_event(&self) -> bool {
        matches!(
            self.cmd,
            CMD_CTRL_PUSH_CTRL | CMD_CTRL_ACTION | CMD_CTRL_PULL_CTRL | CMD_CTRL_PULL_VOIP
        )
    }
}
