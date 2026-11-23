# Glossary

| Term | Meaning | Rust name |
|---|---|---|
| ParamCipher | AES-CBC encryption of request `params` with the session `zpw_enk` key | `olaz_crypto::ParamCipher` |
| signkey | MD5 over sorted params with an api tag | `olaz_crypto::sign_key` |
| zpw_enk | Base64 session secret key from login | `olaz_crypto::parse_secret_key` |
| zpw_ws frame | `u8 ver \| u16 LE cmd \| u8 subCmd` + JSON body | `olaz_ws::Frame` |
| cmd | WebSocket command number | `olaz_ws::Frame::cmd` |
| JSONLossless | JSON parse that keeps 64-bit ids exact | `serde_json` + `arbitrary_precision` |
| SERVICE_MAP_V3 | Per-service host list used for failover | `olaz_net::ServiceMap` (wave 2) |
