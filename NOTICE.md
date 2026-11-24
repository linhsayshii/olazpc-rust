# NOTICE

Olaz is an unofficial, reverse-engineered native macOS client for Zalo, licensed under the GNU General Public License v3.0 (see [LICENSE](LICENSE)).

## Copyright

- Copyright © 2026 Quan Nguyen
- Copyright © 2026 linhsayshii and contributors

## Origin

This repository (<https://github.com/linhsayshii/olazpc-rust>) is an independent continuation of **zalo-swift-re** by Quan Nguyen (<https://github.com/qnguyen3/zalo-swift-re>, GPL-3.0). It is no longer a GitHub fork and keeps GPL-3.0.

From the original project:

- the Olaz app, its name and the original Swift codebase;
- the original Zalo reverse-engineering work: wire protocol notes, QR login, `zpw_ws` framing, `ParamCipher`, request signing, service-map failover (see [REVERSE-ENGINEERING-NOTES.md](REVERSE-ENGINEERING-NOTES.md)).

The history starts with Quan Nguyen's first commit `76eb26d` (2026-11-07). Later work, including the Rust core (`rust/`, UniFFI bindings in `Sources/OlazCore`) and many features, is by linhsayshii.

## Third-party components

| Component | Location | License | Notes |
|---|---|---|---|
| Signal `libsignal-protocol` v0.73.0 (patched for Zalo's KDF strings and version byte) | `rust/vendor/libsignal-protocol` | AGPL-3.0-only | Patch documented in `rust/vendor/libsignal-protocol/ZALO-PATCH.md`. This component stays under AGPL-3.0. GPL-3.0 section 13 allows combining GPL-3.0 and AGPL-3.0 works. Its upstream dependencies `libsignal-core` and `signal-crypto` are fetched unpatched from the upstream tag. |
| Rust crates (see `rust/Cargo.lock`) | fetched by Cargo | their own licenses | Not vendored. |

## Design inspiration

[lebad280324/zalolite](https://github.com/lebad280324/zalolite): lightweight native Zalo client design. No code is claimed from it here.

## VNG / Zalo

"Zalo" is a trademark of VNG Corporation. Olaz is not affiliated with, authorized or endorsed by VNG. No VNG files are redistributed in this repository or in releases: the official Zalo runtime (`app.asar`, `ZaloHelper.app` including `ZaloCall`) is downloaded from VNG at first launch, and its signature is verified. Using an unofficial client may conflict with Zalo's terms of service; use it at your own risk.
