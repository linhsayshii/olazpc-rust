//! Group event notice formatting (port of `ZaloWireParser+GroupEvents.swift`).
//!
//! Group controls (`cmd 601`, `act_type: "group"`) that the official client turns into synthetic
//! system/info lines in the chat (`_processGroupCtrlEvents_old` -> `addGroupEventMessages`), since
//! the server sends no chat message for them.

use serde_json::{Map, Value};

use crate::ids::strip_user_prefix;
use crate::lossless;

/// Group control acts that synthesize a chat info line (`ZaloWireParser.groupEventNoticeActs`).
pub const GROUP_EVENT_NOTICE_ACTS: &[&str] = &[
    "join",
    "leave",
    "remove_member",
    "block_member",
    "update",
    "update_avatar",
    "add_admin",
    "remove_admin",
    "change_owner",
];

/// Group control acts that invalidate cached group members/details.
pub const GROUP_EVENT_MEMBER_ACTS: &[&str] = &[
    "join",
    "leave",
    "remove_member",
    "block_member",
    "add_admin",
    "remove_admin",
    "change_owner",
];

/// Returns `true` when `act` is a known group-event notice act.
#[must_use]
pub fn is_group_event_notice_act(act: &str) -> bool {
    GROUP_EVENT_NOTICE_ACTS.contains(&act)
}

/// Returns `true` when `act` changes group membership or roles (invalidating cached members/details).
#[must_use]
pub fn is_group_event_member_act(act: &str) -> bool {
    GROUP_EVENT_MEMBER_ACTS.contains(&act)
}

/// The official info line for a group control, or `None` when the act shows none.
///
/// `data`: `{groupId, sourceId, creatorId?, groupName?, updateMembers:[{id, dName}]}`;
/// `name_lookup` resolves a contact name for a `strip_user_prefix`-cleaned uid.
#[must_use]
pub fn group_event_notice<F>(
    act: &str,
    data: &Map<String, Value>,
    my_uid: &str,
    mut name_lookup: F,
) -> Option<String>
where
    F: FnMut(&str) -> Option<String>,
{
    let me = strip_user_prefix(my_uid);
    let is_me = |uid: &str| !uid.is_empty() && (uid == me || uid == "0");
    let mut display = |uid: &str, fallback: &str| -> String {
        if is_me(uid) {
            return "Bạn".to_owned();
        }
        name_lookup(uid)
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| fallback.to_owned())
    };

    // Official: my own entry first, the others named by their local name, else the event's dName.
    let mut members: Vec<(String, String)> = data
        .get("updateMembers")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_object)
                .map(|m| {
                    let id = strip_user_prefix(&lossless::string(m.get("id")));
                    let d_name = lossless::string(m.get("dName"));
                    let shown = display(&id, &d_name);
                    (id, shown)
                })
                .collect()
        })
        .unwrap_or_default();

    if let Some(mine) = members.iter().position(|(id, _)| is_me(id)) {
        let entry = members.remove(mine);
        members.insert(0, entry);
    }

    let names = members
        .iter()
        .map(|(_, n)| n.as_str())
        .filter(|n| !n.is_empty())
        .collect::<Vec<_>>()
        .join(", ");

    let source_id = strip_user_prefix(&lossless::string(data.get("sourceId")));
    let by_me = is_me(&source_id);
    let source = display(&source_id, "");

    match act {
        "join" => {
            if members.is_empty() {
                return None;
            }
            if members.len() == 1 && members[0].0 == source_id {
                let creator = strip_user_prefix(&lossless::string(data.get("creatorId")));
                if creator == members[0].0 {
                    return None;
                }
                return Some(if is_me(&members[0].0) {
                    "Bạn vừa tham gia nhóm".to_owned()
                } else {
                    format!("{} đã tham gia nhóm", members[0].1)
                });
            }
            Some(if by_me {
                format!("{names} được bạn thêm vào nhóm")
            } else {
                format!("{names} được {source} thêm vào nhóm")
            })
        }
        "leave" => members
            .first()
            .map(|(_, name)| format!("{name} đã rời khỏi nhóm")),
        "remove_member" => {
            if names.is_empty() {
                return None;
            }
            Some(if by_me {
                format!("{names} được bạn xóa khỏi nhóm")
            } else {
                format!("{names} được {source} xóa khỏi nhóm")
            })
        }
        "block_member" => {
            if names.is_empty() {
                return None;
            }
            Some(if by_me {
                format!("{names} bị bạn chặn khỏi nhóm này")
            } else {
                format!("{names} bị {source} chặn khỏi nhóm này")
            })
        }
        "update" => {
            let group_name = lossless::string(data.get("groupName"));
            if group_name.is_empty() {
                return None;
            }
            Some(if by_me {
                format!("Tên nhóm đã đổi thành {group_name}")
            } else {
                format!("{source} đổi tên nhóm thành {group_name}")
            })
        }
        "update_avatar" => Some(if by_me {
            "Ảnh đại diện nhóm đã thay đổi".to_owned()
        } else {
            format!("{source} đổi ảnh đại diện nhóm")
        }),
        "add_admin" => {
            if names.is_empty() {
                return None;
            }
            Some(format!("{names} đã được bổ nhiệm thành phó nhóm"))
        }
        "remove_admin" => {
            if names.is_empty() {
                return None;
            }
            Some(format!("{names} đã không còn là phó nhóm"))
        }
        "change_owner" => members.first().map(|(id, name)| {
            if is_me(id) {
                "Bạn trở thành trưởng nhóm.".to_owned()
            } else {
                format!("{name} trở thành trưởng nhóm.")
            }
        }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn notice(act: &str, data: Value) -> Option<String> {
        let obj = data.as_object().unwrap();
        group_event_notice(act, obj, "me", |uid| match uid {
            "100" => Some("Lan".to_owned()),
            "200" => Some("Minh".to_owned()),
            "300" => Some("Hoa".to_owned()),
            _ => None,
        })
    }

    fn members(ids: &[&str]) -> Value {
        Value::Array(
            ids.iter()
                .map(|id| json!({"id": id, "dName": format!("dn{id}")}))
                .collect(),
        )
    }

    #[test]
    fn added_members() {
        assert_eq!(
            notice(
                "join",
                json!({"groupId": "9", "sourceId": "me", "updateMembers": members(&["100"])})
            ),
            Some("Lan được bạn thêm vào nhóm".to_owned())
        );
        assert_eq!(
            notice(
                "join",
                json!({"groupId": "9", "sourceId": "200", "updateMembers": members(&["100", "300"])})
            ),
            Some("Lan, Hoa được Minh thêm vào nhóm".to_owned())
        );
        assert_eq!(
            notice(
                "join",
                json!({"groupId": "9", "sourceId": "200", "updateMembers": members(&["me"])})
            ),
            Some("Bạn được Minh thêm vào nhóm".to_owned())
        );
        assert_eq!(
            notice(
                "join",
                json!({"groupId": "9", "sourceId": "200", "updateMembers": members(&["100", "me"])})
            ),
            Some("Bạn, Lan được Minh thêm vào nhóm".to_owned())
        );
    }

    #[test]
    fn joined_by_themselves() {
        assert_eq!(
            notice(
                "join",
                json!({"groupId": "9", "sourceId": "100", "creatorId": "200", "updateMembers": members(&["100"])})
            ),
            Some("Lan đã tham gia nhóm".to_owned())
        );
        assert_eq!(
            notice(
                "join",
                json!({"groupId": "9", "sourceId": "me", "creatorId": "200", "updateMembers": members(&["me"])})
            ),
            Some("Bạn vừa tham gia nhóm".to_owned())
        );
        assert_eq!(
            notice(
                "join",
                json!({"groupId": "9", "sourceId": "100", "creatorId": "100", "updateMembers": members(&["100"])})
            ),
            None
        );
    }

    #[test]
    fn left_removed_blocked_and_admin_roles() {
        assert_eq!(
            notice(
                "leave",
                json!({"groupId": "9", "sourceId": "100", "updateMembers": members(&["100"])})
            ),
            Some("Lan đã rời khỏi nhóm".to_owned())
        );
        assert_eq!(
            notice(
                "remove_member",
                json!({"groupId": "9", "sourceId": "me", "updateMembers": members(&["100"])})
            ),
            Some("Lan được bạn xóa khỏi nhóm".to_owned())
        );
        assert_eq!(
            notice(
                "remove_member",
                json!({"groupId": "9", "sourceId": "200", "updateMembers": members(&["me"])})
            ),
            Some("Bạn được Minh xóa khỏi nhóm".to_owned())
        );
        assert_eq!(
            notice(
                "block_member",
                json!({"groupId": "9", "sourceId": "me", "updateMembers": members(&["100"])})
            ),
            Some("Lan bị bạn chặn khỏi nhóm này".to_owned())
        );
        assert_eq!(
            notice(
                "block_member",
                json!({"groupId": "9", "sourceId": "200", "updateMembers": members(&["100"])})
            ),
            Some("Lan bị Minh chặn khỏi nhóm này".to_owned())
        );
        assert_eq!(
            notice(
                "add_admin",
                json!({"groupId": "9", "sourceId": "me", "updateMembers": members(&["100"])})
            ),
            Some("Lan đã được bổ nhiệm thành phó nhóm".to_owned())
        );
        assert_eq!(
            notice(
                "remove_admin",
                json!({"groupId": "9", "sourceId": "me", "updateMembers": members(&["100"])})
            ),
            Some("Lan đã không còn là phó nhóm".to_owned())
        );
        assert_eq!(
            notice(
                "change_owner",
                json!({"groupId": "9", "sourceId": "200", "updateMembers": members(&["me"])})
            ),
            Some("Bạn trở thành trưởng nhóm.".to_owned())
        );
        assert_eq!(
            notice(
                "change_owner",
                json!({"groupId": "9", "sourceId": "me", "updateMembers": members(&["100"])})
            ),
            Some("Lan trở thành trưởng nhóm.".to_owned())
        );
    }

    #[test]
    fn rename_avatar_and_unknown_names() {
        assert_eq!(
            notice(
                "update",
                json!({"groupId": "9", "sourceId": "me", "groupName": "Nhà"})
            ),
            Some("Tên nhóm đã đổi thành Nhà".to_owned())
        );
        assert_eq!(
            notice(
                "update",
                json!({"groupId": "9", "sourceId": "200", "groupName": "Nhà"})
            ),
            Some("Minh đổi tên nhóm thành Nhà".to_owned())
        );
        assert_eq!(
            notice("update_avatar", json!({"groupId": "9", "sourceId": "me"})),
            Some("Ảnh đại diện nhóm đã thay đổi".to_owned())
        );
        assert_eq!(
            notice("update_avatar", json!({"groupId": "9", "sourceId": "200"})),
            Some("Minh đổi ảnh đại diện nhóm".to_owned())
        );
        assert_eq!(
            notice(
                "leave",
                json!({"groupId": "9", "sourceId": "555", "updateMembers": [{"id": "555", "dName": "Tú"}]})
            ),
            Some("Tú đã rời khỏi nhóm".to_owned())
        );
        assert_eq!(
            notice("update", json!({"groupId": "9", "sourceId": "200"})),
            None
        );
        assert_eq!(notice("typing", json!({"groupId": "9"})), None);
    }
}
