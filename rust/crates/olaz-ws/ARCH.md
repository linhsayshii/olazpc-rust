# olaz-ws architecture

Wave 1 is socket-free and has no async runtime. Wave 2 (built) adds a tokio-tungstenite
transport behind the cargo feature `transport` (on by default). `--no-default-features`
builds only the pure core (no tokio, no olaz-crypto).

## Pure layer (wave 1)

| Module | Swift origin | Role |
|---|---|---|
| `frame` | `encodeFrame`, `decodeFrame`, `encodeRequestFrame`, `pullFrame`, `sendPing` | `u8 ver \| u16 LE cmd \| u8 sub` + JSON; `Frame`, golden-tested bytes |
| `consts` | `ZaloWebSocket` statics, `ZaloDomains` ws bits | cmd numbers, ping/timeouts, default endpoints |
| `queue` | `ZaloWSQueue*`, `queueCursors`, `queuesFromAuth`, `highestActionId` | cursor rules + serde snapshot (`{"lastId","preIds"}`) |
| `files` | `waitForFileDone`, `recordFileDone`, `extractFileDoneEvents` | waiter bookkeeping keyed by `WaiterToken` |
| `requests` | `requestWaiters` | `reqId -> token` |
| `policy` | `runLoop`, `buildSocketURL`, header setup | `ReconnectPolicy` (2s start, x2, cap 30s, reset after >30s session, endpoint idx +1), URL, headers |
| `core` | `handleBinaryFrame`, `nextReqId`, auth flow | `WsCore::handle_binary_frame(bytes, &dyn FrameDecryptor) -> FrameOutcome` |

`FrameDecryptor` is the hook for `ZaloCrypto.decryptWSFrame` (olaz-crypto). This crate
does not depend on it; the transport (or `olaz-ffi`) passes a closure/impl.

## Wave 2 transport (feature `transport`, `src/transport/`)

```
WsClient::start(WsConfig, Arc<dyn FrameDecryptor + Send + Sync>) -> (WsHandle, mpsc::Receiver<WsEvent>)
```

| File | Role |
|---|---|
| `mod.rs` | `WsConfig` (endpoints, zpw_sek, seed cursors, cursor observer, `WsTimings`, event capacity), `WsClient::start`, `CursorMap` |
| `actor.rs` | the single task: owns the socket, `WsCore`, waiter channels and a timer map. No Mutex |
| `handle.rs` | clonable `WsHandle`, commands over `mpsc`, replies over `oneshot` |
| `crypto.rs` | `CryptoDecryptor`: the only user of `olaz-crypto` (`decrypt_ws_frame`) |
| `tls.rs` | rustls (ring provider) + macOS system roots via `rustls-native-certs` |

`WsHandle` (all async): `send_frame`, `send_frame_versioned`, `send_request` /
`send_request_with_timeout` (10 s default, `Option<Map>`), `wait_for_file_done` /
`..._with_timeout` (12 s default), `seed_cursors`, `current_cursors`, `is_authed`,
`stop(reset_cursors) -> CursorMap`, and sync `watch_cursors() -> watch::Receiver<CursorMap>`.
Cursors are also pushed to `WsConfig::on_cursors_changed` (the `wsQueueCursors` persistence hook).
After the task ends every method returns its failure value (false / None / last cursors).

Actor loop (`run`): `policy.current_endpoint()` -> build URL/headers (`policy`) -> TLS connector for
`wss://` -> connect (60 s timeout, still serving commands) -> session `select!` over
{socket read, command, ping tick, earliest timer} -> `core.on_disconnect()` (pending requests -> `None`)
-> `policy.on_session_ended` -> back off (still serving commands) -> next endpoint.
Per inbound frame the outcome is applied in this order: resolve request, wake file waiters, send
`outcome.sends`, forward event, publish cursors, close 1008 on `close`.
Request/file timeouts live in the actor (a `BTreeMap<(Instant, seq), Timer>`), so a dropped caller
future cannot leak a timer-less waiter; a stale file timer is ignored if its own waiter already woke.
`stop` sends Close 1000, resolves all waiters with `None`, ends the event channel and the task.
Dropping every `WsHandle` also stops the task.

Logging: `tracing` only, shape-only (host, cmd, sub, byte lengths, `WsCore` log lines). `zpw_sek`,
payloads and keys are never logged.

### Differences from `ZaloWebSocket.swift`

- `start` after `stop` is a new `WsClient::start`; to keep cursors across a restart (Swift
  `stop(resetCursors:false)` then `start`), pass the map returned by `stop` as `seed_cursors`.
- Event channel is bounded (default 1024); a slow consumer applies backpressure (Swift: unbounded).
- Request/file timeouts are task-owned timers instead of detached sleeping tasks; a stale file
  timer no longer kills a newer waiter of the same file id.
- A request whose frame write fails resolves `None` immediately (as Swift), an unauthenticated
  `send_request` returns `None` without waiting.
- TLS: rustls with the system root store (macOS keychain) instead of URLSession; ring provider
  set explicitly so it does not depend on workspace feature unification.
- Timings are configurable (`WsTimings`); defaults equal the Swift constants.
- Tests use shrunk timings on real time: tokio's paused clock auto-advances while loopback I/O is
  pending and makes handshakes race, so no paused-clock socket test.
