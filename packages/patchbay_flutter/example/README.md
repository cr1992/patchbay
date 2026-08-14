# Patchbay Flutter minimal consumer

English | [简体中文](README.zh-CN.md)

This example exercises only the general-purpose integration surface. It depends on no business app
and contains no Android / iOS platform projects:

- the composition root registers one `PatchbayFlutterServiceHost`;
- the app identity is `dev.patchbay.example`;
- the consumer declares its own `example.counter.increment` domain command;
- `Semantics.identifier` exposes the stable counter value and button targets;
- a single `TextField` swaps its existing `key` for a `PatchbayKey.text`.

Mechanical verification:

```text
flutter analyze
flutter test
```

Having no platform directories means this is not a real-device demo you can `flutter run`
directly. Real-device transport, port discovery, and product lifecycle wiring are the actual app's
responsibility; this example exists to prove that the public API can close the loop across
identity, catalog, Flutter observation, and domain invoke.
