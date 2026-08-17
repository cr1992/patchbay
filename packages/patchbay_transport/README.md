# Patchbay direct transport

English | [简体中文](https://github.com/cr1992/patchbay/blob/main/packages/patchbay_transport/README.zh-CN.md)

`patchbay_transport` is a consumer-neutral, pure Dart debug transport. It carries `identity`,
`catalog`, `snapshot`, and `invoke` over a fixed HTTP/JSON protocol, with no dependency on Flutter,
the consumer app, plugins, VM Service, or the CLI. The package ships both a host and a client, so
the product assembly layer never has to duplicate the wire codec.

## Security Boundary

- Constructing a host does not listen; only an explicit `start()` binds a socket, defaulting to
  IPv4 loopback and a system-assigned port;
- Binding a non-loopback address requires the additional explicit choice of
  `PatchbayLanExposure.experimentalSameTrustedNetworkOnly`; there is no mDNS, broadcast, scanning,
  or resident discovery;
- `Random.secure` generates a 256-bit, at-most-one-hour short-lived bearer, accepted only as
  `Authorization: Bearer ...`; URI query is always rejected;
- `toString()` on sessions and clients elides the token, and typed errors carry no token, request
  body, or endpoint; this package writes no logs;
- Browser `Origin` and preflight are rejected by default, with no CORS allow headers returned;
- Every response closes its HTTP connection; by default only one request is processed at a time,
  with a configurable hard limit of 1–8;
- Request body, response body, callback timeout, and token TTL all have hard limits;
- `stop()`, TTL expiry, product-notified background / identity change, and identity drift or
  handler timeout detected mid-request all stop accepting new connections;
- Every authenticated request must still carry `schemaVersion`, `applicationId`, and
  `appInstanceId` in a JSON object; before calling the business handler, the host re-reads identity
  and cross-checks it against both the startup identity and the request identity;
- `/patchbay/direct/v1/{identity,catalog,snapshot,invoke}` is the entire reachable surface. Unknown
  fields, paths, methods, query strings, content types, or JSON shapes fail closed; there is no
  remote arbitrary-method reflection.

LAN mode is plaintext HTTP. The bearer provides bearer-holder authentication only — **no
confidentiality, no server identity authentication, and no replay protection**; a passive listener
on the same network can steal the token and the entire payload, and an active attacker can
impersonate endpoints. LAN mode is therefore marked experimental and is only for a trusted,
isolated, same-network setting; it must not be called secure. To cross an untrusted network, add
reviewed TLS and endpoint pinning at the product layer — this document cannot be used to upgrade
the security conclusion.

## Product Assembly

This package does not decide debug/profile/release build policy. Consumers must use compile-time
boundaries to ensure release never constructs a host, and must themselves provide the explicit
user entry point, out-of-band token distribution, foreground/background notifications, and
identity-change notifications. Tokens should not enter ordinary logs, errors, clipboard history,
shell history, URLs, or persistent session files.

Android, iOS, and HarmonyOS all consume only this package's `dart:io` sockets; the package itself
contains no native changes:

- Android — the product layer chooses and declares network permissions and assembles only in
  permitted debug builds; this package does not modify the manifest;
- iOS — whether LAN mode requests the Local Network permission is up to the product assembly
  layer; this package does not modify `Info.plist` and does not trigger permission dialogs. Whether
  loopback alone satisfies your target real-device workflow must also be verified on device;
- HarmonyOS/CPF — this package makes no claim about fork compilation or real-device network policy
  having been validated; verify separately when wiring it up.

The foreground/background hooks are not platform lifecycle listeners; if the product forgets to
call `notifyBackgrounded()`, this package cannot infer that the app has gone to the background.
Likewise, this package cannot safely "discover" clients — the endpoint and token must be delivered
through an out-of-band channel of the product's choosing.

## Fixed Protocol

All requests are `POST`, `application/json`, with the bearer in a header. The base request:

```json
{
  "schemaVersion": 1,
  "applicationId": "dev.consumer.app",
  "appInstanceId": "short-lived-instance"
}
```

`invoke` adds only `command`, `arguments`, and `requestId`. Whether the command exists, its
parameter schema, its gates, concurrency ownership, and fact strength all remain the injected
handler's responsibility; the transport neither infers commands from strings nor upgrades
`accepted` into successful execution. The direct client verifies that the handler result echoes
the same `requestId`; a mismatch returns `requestIdMismatch` and is never handed to the caller as
a business result. An empty `requestId` is rejected with `protocolError` before sending.

A successful response always contains the schema, the re-checked full identity, and the handler
result. Error responses contain only a stable code: `protocolError`, `unauthorized`, `expired`,
`busy`, `bodyTooLarge`, `responseTooLarge`, `originDenied`, `identityMismatch`, `identityDrift`,
`timeout`, or `internalError`.

## Verification

Run in this directory:

```sh
dart analyze
dart test --reporter expanded
```

The tests use real loopback sockets and spawn a separate subprocess to verify client/host wire
compatibility; transport acceptance is not substituted with mock HTTP.
