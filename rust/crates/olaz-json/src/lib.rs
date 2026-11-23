//! The single Rust port of Swift `JSONLossless` plus the Foundation JSON/base64 behaviours Olaz
//! relies on: lossless parse, `string`/`int64`/`bool` coercions, a `JSONSerialization`-compatible
//! writer and `Data(base64Encoded:)`.

#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used))]

mod access;
mod foundation_base64;
mod parse;
mod write;

pub use access::{bool_value, int64, string};
pub use foundation_base64::{
    Base64Error, decode_foundation_base64, decode_foundation_base64_ignoring_unknown,
};
pub use parse::{parse_any, parse_object, parse_object_str, quote_large_integer_literals};
pub use write::{to_swift_json_bytes, to_swift_json_string};
