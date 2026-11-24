//! Golden vectors produced by running Swift `JSONLossless` and Foundation `Data(base64Encoded:)`
//! (swiftc, macOS). Moved from `olaz-crypto`.
#![allow(clippy::unwrap_used, clippy::expect_used)]
use olaz_json::*;
use serde_json::{Value, json};

fn hx(v: &[u8]) -> String {
    v.iter().map(|b| format!("{b:02x}")).collect()
}

const JSON_VALUES: &str = r#"[0,1,2,-1,0.5,1.5,1.0,1e20,2.50,true,false,"true","1","TRUE"," 1","0","false","x",null,[],{},"  42 ","+5","1.5",123456789012345678,-123456789012345678,9223372036854775807,9223372036854775808,18446744073709551615,1e3,123456789012345,12345678901234,"0x10",3.0,1e-7,100000000000000.5,12345678901234567890123,-0.0,1E2,-5,"-7","",0.1,123.456,1e16,1.7976931348623157e308,-2.5,"True","yes",1.0e0,99999999999999.9]"#;

/// Expected `(string, int64, bool)` per element, from Swift `JSONLossless` accessors.
#[test]
fn swift_golden_json_accessors() {
    let expected: [(&str, Option<i64>, Option<bool>); 51] = [
        ("0", Some(0), Some(false)),
        ("1", Some(1), Some(true)),
        ("2", Some(2), Some(true)),
        ("-1", Some(-1), Some(true)),
        ("0.5", Some(0), Some(false)),
        ("1.5", Some(1), Some(true)),
        ("1", Some(1), Some(true)),
        ("1e+20", Some(9223372036854775807), Some(true)),
        ("2.5", Some(2), Some(true)),
        ("true", Some(1), Some(true)),
        ("false", Some(0), Some(false)),
        ("true", None, Some(true)),
        ("1", Some(1), Some(true)),
        ("TRUE", None, Some(true)),
        (" 1", Some(1), None),
        ("0", Some(0), Some(false)),
        ("false", None, Some(false)),
        ("x", None, None),
        ("", None, None),
        ("", None, None),
        ("", None, None),
        ("  42 ", Some(42), None),
        ("+5", Some(5), None),
        ("1.5", None, None),
        ("123456789012345678", Some(123456789012345678), None),
        ("-123456789012345678", Some(-123456789012345678), Some(true)),
        ("9223372036854775807", Some(9223372036854775807), None),
        ("9223372036854775808", None, None),
        ("18446744073709551615", None, None),
        ("1000", Some(1000), Some(true)),
        ("123456789012345", Some(123456789012345), None),
        ("12345678901234", Some(12345678901234), Some(true)),
        ("0x10", None, None),
        ("3", Some(3), Some(true)),
        ("1e-07", Some(0), Some(false)),
        ("100000000000000.5", Some(100000000000000), Some(true)),
        ("12345678901234567890123", None, None),
        ("-0", Some(0), Some(false)),
        ("100", Some(100), Some(true)),
        ("-5", Some(-5), Some(true)),
        ("-7", Some(-7), None),
        ("", None, None),
        ("0.1", Some(0), Some(false)),
        ("123.456", Some(123), Some(true)),
        ("1e+16", Some(10000000000000000), Some(true)),
        (
            "1.797693134862316e+308",
            Some(9223372036854775807),
            Some(true),
        ),
        ("-2.5", Some(-2), Some(true)),
        ("True", None, Some(true)),
        ("yes", None, None),
        ("1", Some(1), Some(true)),
        ("99999999999999.91", Some(99999999999999), Some(true)),
    ];
    let Some(Value::Array(items)) = parse_any(JSON_VALUES.as_bytes()) else {
        panic!("fixture must be an array");
    };
    assert_eq!(items.len(), expected.len());
    for (i, (v, (s, n, b))) in items.iter().zip(expected).enumerate() {
        assert_eq!(string(Some(v)), s, "string #{i}");
        assert_eq!(int64(Some(v)), n, "int64 #{i}");
        assert_eq!(bool_value(Some(v)), b, "bool #{i}");
    }
    assert_eq!(string(None), "");
    assert_eq!(int64(None), None);
    assert_eq!(bool_value(None), None);
}

#[test]
fn swift_golden_json_parse_object() {
    // nil in Swift and in Rust.
    for s in [
        "[1]",
        "5",
        "\"x\"",
        "",
        "{",
        r#"{"a":1} trailing"#,
        r#"{"a":01}"#,
        r#"{"a":NaN}"#,
    ] {
        assert!(parse_object_str(s).is_none(), "{s:?}");
    }
    let to = |s: &str| serde_json::to_string(&parse_object_str(s).unwrap()).unwrap();
    assert_eq!(to(r#"{"a":1}"#), r#"{"a":1}"#);
    assert_eq!(to(" {\"a\":1} "), r#"{"a":1}"#);
    assert_eq!(to("\u{FEFF}{\"a\":1}"), r#"{"a":1}"#);
    assert_eq!(
        to(r#"{"a":"x\u00e9😀","b":{"c":[1,2,{"d":null}]}}"#),
        r#"{"a":"xé😀","b":{"c":[1,2,{"d":null}]}}"#
    );
    assert_eq!(
        to(r#"{"id":-1234567890123456789}"#),
        r#"{"id":-1234567890123456789}"#
    );
    assert_eq!(
        to(r#"{"s":"1234567890123456789"}"#),
        r#"{"s":"1234567890123456789"}"#
    );
    let o = parse_object_str(r#"{"x":[1234567890123456789,12345678901234567.5]}"#).unwrap();
    let x = o["x"].as_array().unwrap();
    assert_eq!(string(x.first()), "1234567890123456789");
    assert_eq!(int64(x.first()), Some(1_234_567_890_123_456_789));
    // %.16g of the double 12345678901234567.5 (>= 1e16 switches to exponent form).
    assert_eq!(string(x.get(1)), "1.234567890123457e+16");
    let o = parse_object_str(r#"{"e":1234567890123456e2}"#).unwrap();
    assert_eq!(string(o.get("e")), "1.234567890123456e+17");
}

/// Known divergences from Foundation `JSONSerialization` (documented, intentionally not mimicked).
#[test]
fn json_known_divergences_from_swift() {
    // Swift accepted a trailing comma (`{"a":1}`); serde_json rejects it.
    assert!(parse_object_str(r#"{"a":1,}"#).is_none());
    // Swift kept the first duplicate key (`{"a":1}`); serde_json keeps the last.
    let o = parse_object_str(r#"{"a":1,"a":2}"#).unwrap();
    assert_eq!(int64(o.get("a")), Some(2));
}

/// Foundation `Data(base64Encoded:)` probes (strict, then `.ignoreUnknownCharacters`).
#[test]
fn swift_golden_foundation_base64() {
    // (input, strict, ignoring-unknown); None = Swift returned nil.
    let cases: [(&str, Option<&str>, Option<&str>); 22] = [
        ("", Some(""), Some("")),
        ("QQ==", Some("41"), Some("41")),
        ("QR==", Some("41"), Some("41")),
        ("QQ=", None, None),
        ("QQ", None, None),
        ("Q", None, None),
        ("QUJD", Some("414243"), Some("414243")),
        ("QUI=", Some("4142"), Some("4142")),
        ("QUI", None, None),
        ("QUK=", Some("4142"), Some("4142")),
        ("QUJDRA==", Some("41424344"), Some("41424344")),
        ("QUJDRA=", None, None),
        ("=QUJD", None, None),
        ("QUJD=", Some("414243"), Some("414243")),
        ("QUJD====", Some("414243"), Some("414243")),
        ("QU JD", None, Some("414243")),
        ("QUJD\n", None, Some("414243")),
        ("Q=", None, None),
        ("-_QUJD", None, Some("414243")),
        ("QUJD!!!!", None, Some("414243")),
        ("QQ==QQ==", None, Some("41")),
        ("QUJDRA==QUJD", None, Some("41424344")),
    ];
    for (s, strict, ign) in cases {
        let st = decode_foundation_base64(s).ok().map(|v| hx(&v));
        let ig = decode_foundation_base64_ignoring_unknown(s)
            .ok()
            .map(|v| hx(&v));
        assert_eq!(st.as_deref(), strict, "strict {s:?}");
        assert_eq!(ig.as_deref(), ign, "ignoring {s:?}");
    }
    for s in ["!!!", " ", "\n\n", "-", "=", "=="] {
        assert!(
            decode_foundation_base64_ignoring_unknown(s).is_err(),
            "{s:?}"
        );
    }
}

#[test]
fn bom_is_skipped_and_large_ints_are_quoted() {
    assert_eq!(
        quote_large_integer_literals(br#"{"a":123456789012345,"b":12345678901234,"c":"123456789012345678","d":-123456789012345678,"e":1234567890123456.5,"f":1234567890123456e2}"#),
        br#"{"a":"123456789012345","b":12345678901234,"c":"123456789012345678","d":-123456789012345678,"e":1234567890123456.5,"f":1234567890123456e2}"#.to_vec()
    );
    let v = parse_any(b"\xEF\xBB\xBF[1234567890123456789]").unwrap();
    assert_eq!(v, json!(["1234567890123456789"]));
    assert_eq!(parse_any(b"7"), Some(json!(7)));
}

#[test]
fn writer_is_compact_sorted_and_foundation_escaped() {
    let v: Value = serde_json::from_str(
        r#"{"b":"a/b","a":{"z":1,"y":[true,null,"\u0001\n\"x\\"]},"\u00e9":"\u007f/"}"#,
    )
    .unwrap();
    assert_eq!(
        to_swift_json_string(&v),
        "{\"a\":{\"y\":[true,null,\"\\u0001\\n\\\"x\\\\\"],\"z\":1},\"b\":\"a\\/b\",\"\u{e9}\":\"\u{7f}\\/\"}"
    );
    assert_eq!(
        to_swift_json_bytes(&json!({"id": 12})),
        br#"{"id":12}"#.to_vec()
    );
    // Big ids survive a parse -> write round trip as quoted strings.
    let big = parse_object_str(r#"{"id":7412345678901234567}"#).unwrap();
    assert_eq!(
        to_swift_json_string(&Value::Object(big)),
        r#"{"id":"7412345678901234567"}"#
    );
}
