#![allow(clippy::expect_used, clippy::unwrap_used)]
//! Focused unit & state-machine tests for U7 board-pins reducer & ChangeHub delivery:
//! - Stale board refresh dropped after optimistic pin (`board_gen` monotonicity)
//! - Concurrent pin / unpin busy guard (`BTreeSet` deterministic keys)
//! - Pin limit confirmation & ChooseMany card
//! - Logout / session reset clearing `pins.lists` & `pins.raw_topics` with `DirtyKey::Pins`
//! - `ChangeHub` coalescing `DirtyKey::Pins` into `CoreChanges.pins`

use std::collections::BTreeMap;

use olaz_core::actions::MessageConfirmAction;
use olaz_core::changes::{ChangeHub, DirtyKey};
use olaz_core::effect::{Effect, HostCall};
use olaz_core::input::{Command, Input};
use olaz_core::pins::{BoardRawTopics, PinnedItem, PinnedList, RefreshBoardFollowup};
use olaz_core::reduce::reduce;
use olaz_core::state::{CoreState, Phase, Profile};
use olaz_wire::{ChatMessage, Kind, MessageMenu, Status};
use serde_json::json;

fn make_msg(id: &str, conv_id: &str, sender_id: &str, text: &str) -> ChatMessage {
    ChatMessage {
        id: id.to_owned(),
        conversation_id: conv_id.to_owned(),
        sender_id: sender_id.to_owned(),
        sender_name: "Alice".to_owned(),
        sender_avatar: None,
        is_mine: sender_id == "me_1",
        kind: Kind::Text,
        text: text.to_owned(),
        date_ms: 1_700_000_000_000,
        status: Status::Sent,
        quote: None,
        reactions: Vec::new(),
        is_e2ee: false,
        mentions: Vec::new(),
        card_buttons: Vec::new(),
        suggests_stickers: false,
        menu: MessageMenu::default(),
        fallback_urls: Vec::new(),
        client_id: format!("cli_{id}"),
        text_styles: Vec::new(),
        ttl_ms: 0,
        urgency: 0,
    }
}

fn ready_state_with_board(conv_id: &str, items: Vec<PinnedItem>, limit: i64) -> CoreState {
    let mut state = CoreState::default();
    state.session.phase = Phase::Ready;
    state.session.profile = Some(Profile {
        user_id: "me_1".to_owned(),
        display_name: "Me".to_owned(),
        avatar: None,
        phone: None,
    });
    state.conversations.open_conversation_id = Some(conv_id.to_owned());
    state.pins.lists.insert(
        conv_id.to_owned(),
        PinnedList {
            ready: true,
            can_pin: true,
            limit,
            items,
        },
    );
    state.pins.raw_topics.insert(
        conv_id.to_owned(),
        BoardRawTopics {
            version: 1,
            topics: BTreeMap::new(),
        },
    );
    state
}

#[test]
fn p01_stale_board_refresh_does_not_clobber_optimistic_pin() {
    let existing = PinnedItem {
        ref_id: "t_old".to_owned(),
        kind: "message".to_owned(),
        title: "Old".to_owned(),
        sender: "Alice".to_owned(),
        thumbnail: None,
        msg_id: "100".to_owned(),
        cli_msg_id: "cli_100".to_owned(),
    };
    let mut state = ready_state_with_board("g900", vec![existing], 3);
    state.messages.windows.insert(
        "g900".to_owned(),
        vec![make_msg("200", "g900", "me_1", "New pin")],
    );

    // 1. Start a board refresh before the pin (captures req_gen = 0).
    let out_refresh = reduce(
        &mut state,
        Input::Command(Command::RefreshBoardPins {
            conv_id: "g900".to_owned(),
        }),
    );
    let stale_req_gen = out_refresh
        .effects
        .iter()
        .find_map(|e| match e {
            Effect::RefreshBoardPins { req_gen, .. } => Some(*req_gen),
            _ => None,
        })
        .expect("expected RefreshBoardPins");
    assert_eq!(stale_req_gen, 0);

    // 2. User pins message 200 optimistically -> bumps board_gen to 1.
    let out_pin = reduce(
        &mut state,
        Input::Command(Command::Pin {
            conv_id: "g900".to_owned(),
            msg_id: "200".to_owned(),
            replacing: None,
        }),
    );
    assert!(out_pin.dirty.contains(&DirtyKey::Pins));
    assert_eq!(state.pins.lists["g900"].items.len(), 2);
    assert_eq!(state.pins.lists["g900"].items[0].ref_id, "local:200");

    // 3. Stale board refresh (req_gen = 0) arrives with only the old item -> MUST BE IGNORED.
    let stale_box = json!({
        "boardVersion": 1,
        "pinLimit": 3,
        "items": [{"id": "t_old", "type": 2, "params": {"title": "Old", "senderName": "Alice", "globalMsgId": "100"}}]
    })
    .as_object()
    .unwrap()
    .clone();
    let out_stale = reduce(
        &mut state,
        Input::BoardPinsFetched {
            conv_id: "g900".to_owned(),
            req_gen: stale_req_gen,
            result: Ok(stale_box),
            followup: RefreshBoardFollowup::Standalone { op_id: Some(77) },
        },
    );
    // Op still completes, but pins list stays intact with optimistic `local:200`!
    assert!(!out_stale.dirty.contains(&DirtyKey::Pins));
    assert!(
        out_stale
            .effects
            .iter()
            .any(|e| matches!(e, Effect::CompleteOp { op_id: 77, .. }))
    );
    assert_eq!(state.pins.lists["g900"].items.len(), 2);
    assert_eq!(state.pins.lists["g900"].items[0].ref_id, "local:200");

    // 4. Fresh post-pin board refresh (req_gen = 1) settles authoritative server list.
    let fresh_box = json!({
        "boardVersion": 2,
        "pinLimit": 3,
        "items": [
            {"id": "t_200", "type": 2, "params": {"title": "New pin", "senderName": "Me", "globalMsgId": "200"}},
            {"id": "t_old", "type": 2, "params": {"title": "Old", "senderName": "Alice", "globalMsgId": "100"}}
        ]
    })
    .as_object()
    .unwrap()
    .clone();
    let out_fresh = reduce(
        &mut state,
        Input::BoardPinsFetched {
            conv_id: "g900".to_owned(),
            req_gen: 1,
            result: Ok(fresh_box),
            followup: RefreshBoardFollowup::Standalone { op_id: None },
        },
    );
    assert!(out_fresh.dirty.contains(&DirtyKey::Pins));
    assert_eq!(state.pins.lists["g900"].items.len(), 2);
    assert_eq!(state.pins.lists["g900"].items[0].ref_id, "t_200");
    assert_eq!(state.pins.raw_topics["g900"].version, 2);
}

#[test]
fn p02_pin_limit_confirm_and_choose_many_card() {
    let old1 = PinnedItem {
        ref_id: "t1".to_owned(),
        kind: "message".to_owned(),
        title: "First".to_owned(),
        sender: "Alice".to_owned(),
        thumbnail: None,
        msg_id: "1".to_owned(),
        cli_msg_id: String::new(),
    };
    let old2 = PinnedItem {
        ref_id: "t2".to_owned(),
        kind: "note".to_owned(),
        title: "Oldest".to_owned(),
        sender: "Alice".to_owned(),
        thumbnail: None,
        msg_id: String::new(),
        cli_msg_id: String::new(),
    };
    let mut state = ready_state_with_board("g901", vec![old1, old2], 2);
    state.messages.windows.insert(
        "g901".to_owned(),
        vec![make_msg("3", "g901", "me_1", "Third")],
    );

    let out = reduce(
        &mut state,
        Input::Command(Command::PinMessage {
            conv_id: "g901".to_owned(),
            msg_id: "3".to_owned(),
        }),
    );
    assert!(out.dirty.contains(&DirtyKey::MessageConfirm));
    let confirm = state.actions.message_confirm.as_ref().expect("confirm");
    assert_eq!(
        confirm.action,
        MessageConfirmAction::Pin {
            msg_id: "3".to_owned(),
            replacing_ref: Some("t2".to_owned()),
        }
    );

    // Cancel clears confirm; lower limit to 1 so 2 >= 1 + 1 triggers ChooseMany card.
    let _ = reduce(
        &mut state,
        Input::Command(Command::AnswerMessageConfirm {
            ok: false,
            now_ms: 1_700_000_000_000,
        }),
    );
    state.pins.lists.get_mut("g901").unwrap().limit = 1;
    let out_many = reduce(
        &mut state,
        Input::Command(Command::PinMessage {
            conv_id: "g901".to_owned(),
            msg_id: "3".to_owned(),
        }),
    );
    assert!(out_many.effects.iter().any(|e| matches!(
        e,
        Effect::Host(HostCall::ShowCard { conv_id, text })
            if conv_id == "g901" && text.contains("ít nhất 2 ghim")
    )));
}

#[test]
fn p03_logout_resets_pins_and_hub_coalesces_pins_snapshot() {
    let mut state = ready_state_with_board(
        "g902",
        vec![PinnedItem {
            ref_id: "t9".to_owned(),
            kind: "note".to_owned(),
            title: "Note".to_owned(),
            sender: "Bob".to_owned(),
            thumbnail: None,
            msg_id: String::new(),
            cli_msg_id: String::new(),
        }],
        3,
    );
    let hub = ChangeHub::new();
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("rt");

    hub.publish(
        &olaz_core::changes::DirtySet::from([DirtyKey::Pins]),
        &state,
    );
    let out = reduce(&mut state, Input::Command(Command::LogOut));
    assert!(out.dirty.contains(&DirtyKey::Pins));
    assert!(state.pins.lists.is_empty());
    assert!(state.pins.raw_topics.is_empty());
    hub.publish(&out.dirty, &state);

    let batch = rt.block_on(hub.next_changes()).expect("batch");
    let pins = batch.pins.expect("coalesced pins");
    assert!(pins.lists.is_empty());
    assert!(pins.raw_topics.is_empty());
}
