use base64::{
    Engine as _,
    alphabet::STANDARD as ALPHABET,
    engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig},
};

/// Input rejected by Foundation base64 rules.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("invalid base64")]
pub struct Base64Error;

const ENGINE: GeneralPurpose = GeneralPurpose::new(
    &ALPHABET,
    GeneralPurposeConfig::new()
        .with_decode_allow_trailing_bits(true)
        .with_decode_padding_mode(DecodePaddingMode::RequireCanonical),
);

fn is_symbol(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'+' || b == b'/'
}

/// Decodes `symbols` followed by the padding rule shared by both Foundation modes.
fn decode_symbols(symbols: &[u8], pad_count: usize) -> Result<Vec<u8>, Base64Error> {
    let rem = symbols.len() % 4;
    let needed = match rem {
        0 if symbols.is_empty() && pad_count > 0 => return Err(Base64Error),
        0 => 0,
        2 => 2,
        3 => 1,
        _ => return Err(Base64Error),
    };
    if pad_count < needed {
        return Err(Base64Error);
    }
    let mut canon = symbols.to_vec();
    canon.extend(std::iter::repeat_n(b'=', needed));
    ENGINE.decode(&canon).map_err(|_| Base64Error)
}

/// Mirrors Swift `Data(base64Encoded:)` for well-formed input: standard alphabet, padding
/// required, non-canonical trailing bits accepted, any other byte is an error.
pub fn decode_foundation_base64(s: &str) -> Result<Vec<u8>, Base64Error> {
    let bytes = s.as_bytes();
    let n = bytes.iter().take_while(|&&b| is_symbol(b)).count();
    let (symbols, tail) = bytes.split_at(n);
    if !tail.iter().all(|&b| b == b'=') {
        return Err(Base64Error);
    }
    decode_symbols(symbols, tail.len())
}

/// Mirrors Swift `Data(base64Encoded:options: .ignoreUnknownCharacters)`: bytes outside
/// `[A-Za-z0-9+/=]` are skipped (so URL-safe `-`/`_` are dropped, not translated), padding is
/// still required, and decoding stops after the first padding run.
pub fn decode_foundation_base64_ignoring_unknown(s: &str) -> Result<Vec<u8>, Base64Error> {
    let filtered: Vec<u8> = s.bytes().filter(|&b| is_symbol(b) || b == b'=').collect();
    if filtered.is_empty() && !s.is_empty() {
        return Err(Base64Error);
    }
    let n = filtered.iter().take_while(|&&b| is_symbol(b)).count();
    let pads = filtered[n..].iter().take_while(|&&b| b == b'=').count();
    decode_symbols(&filtered[..n], pads)
}
