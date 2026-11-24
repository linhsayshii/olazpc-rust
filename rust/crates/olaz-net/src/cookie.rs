//! `zpw_sek` session cookie handling. There is no cookie jar: the cookie is read out of
//! `Set-Cookie` / login JSON and sent back by hand as a header.

use serde_json::{Map, Value};

/// Swift `isValidZpwSek`: non-empty after trimming, not `EXPIRED`/`deleted`/`null`, and it
/// contains a `.` (real session keys are dotted; the `zpw_wpsk` VAPID key is not).
pub fn is_valid_zpw_sek(candidate: Option<&str>) -> bool {
    let Some(raw) = candidate.map(str::trim) else {
        return false;
    };
    !raw.is_empty() && raw != "EXPIRED" && raw != "deleted" && raw != "null" && raw.contains('.')
}

/// Swift `extractZpwSek(from:)`: `zpw_sek` from the JSON root, `data`, or `data.account`.
pub fn extract_zpw_sek(json: &Map<String, Value>) -> Option<String> {
    let data = json.get("data").and_then(Value::as_object);
    let account = data
        .and_then(|d| d.get("account"))
        .and_then(Value::as_object);
    for container in [Some(json), data, account].into_iter().flatten() {
        if let Some(Value::String(val)) = container.get("zpw_sek") {
            let trimmed = val.trim();
            if is_valid_zpw_sek(Some(trimmed)) {
                return Some(trimmed.to_owned());
            }
        }
    }
    None
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Parses cookie `Expires` dates (`Thu, 01-Jan-1970 00:00:01 GMT`, `Thu, 01 Jan 1970 ...`) into
/// Unix seconds. `None` when the shape is not recognised.
fn parse_cookie_date(raw: &str) -> Option<i64> {
    let cleaned = raw.replace(',', " ");
    let mut day = None;
    let mut month = None;
    let mut year = None;
    let mut time = None;
    for tok in cleaned.split(|c: char| c.is_whitespace() || c == '-') {
        if tok.is_empty() {
            continue;
        }
        if tok.contains(':') && time.is_none() {
            let mut it = tok.split(':').map(|p| p.parse::<i64>().ok());
            time = Some((
                it.next()??,
                it.next().flatten().unwrap_or(0),
                it.next().flatten().unwrap_or(0),
            ));
        } else if let Ok(n) = tok.parse::<i64>() {
            if day.is_none() && tok.len() <= 2 {
                day = Some(n);
            } else if year.is_none() {
                year = Some(if tok.len() <= 2 {
                    if n < 70 { n + 2000 } else { n + 1900 }
                } else {
                    n
                });
            }
        } else if month.is_none() && tok.len() >= 3 {
            const MONTHS: [&str; 12] = [
                "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
            ];
            let lower = tok.to_lowercase();
            month = MONTHS
                .iter()
                .position(|m| lower.starts_with(m))
                .map(|i| i as i64 + 1);
        }
    }
    let (h, mi, s) = time?;
    Some(days_from_civil(year?, month?, day?) * 86_400 + h * 3600 + mi * 60 + s)
}

/// Splits a combined `Set-Cookie` string (several cookies joined by `, `) without breaking on the
/// comma inside `Expires=Thu, 01-Jan-1970 ...`.
fn split_set_cookie(joined: &str) -> Vec<String> {
    let mut parts: Vec<String> = Vec::new();
    let mut current = String::new();
    for (i, ch) in joined.char_indices() {
        if ch == ',' {
            let lower = current.to_lowercase();
            let in_expires_weekday = lower.rfind("expires=").is_some_and(|pos| {
                let after = lower[pos + "expires=".len()..].trim();
                !after.is_empty() && after.chars().all(|c| c.is_ascii_alphabetic())
            });
            let rest = joined[i + 1..].trim_start();
            let starts_cookie = rest
                .split(';')
                .next()
                .is_some_and(|first| first.contains('=') && !first.contains(' '));
            if !in_expires_weekday && starts_cookie {
                parts.push(std::mem::take(&mut current));
                continue;
            }
        }
        current.push(ch);
    }
    parts.push(current);
    parts
}

/// Swift `extractZpwSekCookie(headers:url:)`.
///
/// Reads every `Set-Cookie` header (several are joined with `, ` as `URLSession` does). First
/// pass: well-formed `zpw_sek` cookies whose `Expires` is in the future (relative to `now_unix`),
/// `Max-Age` positive and value valid; the last wins. Fallback pass: the Swift regex
/// `zpw_sek=([^;,\s]+)` anywhere in the header text, skipping tokens whose next 140 characters
/// mention `max-age=0` or `1970`.
pub fn extract_zpw_sek_cookie(headers: &[(String, String)], now_unix: i64) -> Option<String> {
    let set_cookie: Vec<&str> = headers
        .iter()
        .filter(|(k, _)| k.eq_ignore_ascii_case("set-cookie"))
        .map(|(_, v)| v.as_str())
        .collect();
    if set_cookie.is_empty() {
        return None;
    }
    let joined = set_cookie.join(", ");

    let mut last_valid: Option<String> = None;
    for cookie in split_set_cookie(&joined) {
        let mut attrs = cookie.split(';');
        let Some((name, value)) = attrs.next().and_then(|nv| nv.split_once('=')) else {
            continue;
        };
        if name.trim() != "zpw_sek" {
            continue;
        }
        let mut expired = false;
        for attr in attrs {
            let Some((an, av)) = attr.split_once('=') else {
                continue;
            };
            match an.trim().to_lowercase().as_str() {
                "max-age" => {
                    if av.trim().parse::<i64>().is_ok_and(|n| n <= 0) {
                        expired = true;
                    }
                }
                "expires" if parse_cookie_date(av.trim()).is_some_and(|t| t <= now_unix) => {
                    expired = true;
                }
                _ => {}
            }
        }
        if expired {
            continue;
        }
        let val = value.trim();
        if is_valid_zpw_sek(Some(val)) {
            last_valid = Some(val.to_owned());
        }
    }
    if last_valid.is_some() {
        return last_valid;
    }

    let needle = "zpw_sek=";
    let mut search_from = 0;
    while let Some(rel) = joined[search_from..].find(needle) {
        let start = search_from + rel + needle.len();
        search_from = start;
        let token: String = joined[start..]
            .chars()
            .take_while(|c| !c.is_whitespace() && *c != ';' && *c != ',')
            .collect();
        if token.is_empty() || !is_valid_zpw_sek(Some(&token)) {
            continue;
        }
        let tail: String = joined[start + token.len()..]
            .chars()
            .take(140)
            .collect::<String>()
            .to_lowercase();
        if tail.contains("max-age=0") || tail.contains("1970") {
            continue;
        }
        last_valid = Some(token);
    }
    last_valid
}
