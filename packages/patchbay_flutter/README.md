# Patchbay Flutter

English | [简体中文](https://github.com/cr1992/patchbay/blob/main/packages/patchbay_flutter/README.zh-CN.md)

`patchbay_flutter` is Patchbay's optional Flutter adapter. Its goal is to provide stable,
discoverable, fail-closed UI debugging capabilities with minimal widget intrusion — not to
implement yet another coordinate-driven black-box automation framework. "Consumer" below means the
app integrating Patchbay.

For quick installation and a first connection, see the
[repository README](https://github.com/cr1992/patchbay/blob/main/README.md#quick-start); for the general protocol and transport
boundaries, see [`../patchbay/README.md`](https://github.com/cr1992/patchbay/blob/main/packages/patchbay/README.md).

## Current Capabilities

| Capability surface | Public API and boundaries |
|---|---|
| **Stable targets** | `PatchbayKey.text`, weak-reference registry, mounted generation, duplicate-ID ambiguity, and stale rejection |
| **Text operations** | `text.set` / `text.enter`, per-operation gates, sensitive input, and side-effect descriptors |
| **Semantics** | Container-free normalized tree, node generations, obscured value redaction, and standard actions rejected by policy default |
| **Navigation and waits** | Composition-root navigation adapter, revision / redirect / timeout semantics, and `ui.wait` conditions |
| **Capture** | Optional root / target capture after N observed frames, bounded pixel diff, and chunked blob output |
| **Keep awake** | Consumer-injected `keepAwakeDelegate`, off by default, auto-released on lease expiry and host disposal |
| **Inspector switch** | `PatchbayInspectPolicy` opt-in on-device select mode: self-restoring lease, refused on non-debug builds |
| **Host composition** | `PatchbayFlutterServiceHost` merges the UI and domain catalogs/operators into one service extension and forwards core redacted audit configuration |

The logging surface lives in core `patchbay` and only enters this host's catalog when the consumer
explicitly injects a `PatchbayArtifactService`. The Widget/Render/Focus diagnostic trees are
proxied by `patchbay_cli` straight to the Flutter runtime extensions, without this package
duplicating the protocol.

The contracts for the Widget/Render/Semantics trees, standard actions, node generations,
redaction, and the DevTools diagnostic proxy are in
[`doc/ui-inspection-and-actions.md`](https://github.com/cr1992/patchbay/blob/main/packages/patchbay_flutter/doc/ui-inspection-and-actions.md) (currently in Chinese).
That document makes it explicit that tree-driven actions are the default low-intrusion path, and
semantic navigation is only a stable enhancement on top.

## Intrusion Levels

| Integration level | Consumer change | Capabilities |
|---|---|---|
| Host only | Start the service host at the app's composition root | identity, domain catalog/snapshot/invoke; no promise of stable widget operations |
| Runtime observation | Start the Flutter host only, without touching the widget tree | Widget/Render/Semantics summaries and standard Semantics actions |
| Optional root bridge | Wrap a root bridge once at the app's top level | Root capture and frame coordination that genuinely needs the root render context |
| Single Key | Swap the target widget's `key` for a `PatchbayKey` | The operations that target declares in the catalog |

No page base class is required, no per-page container, no Keys on every widget, and no central
target list duplicating the widget tree.

## Key Integration

For widgets you need to drive remotely, just swap the Key:

```dart
late final PatchbayKey nameKey = PatchbayKey.text(
  'profile.displayName',
  operationGates: <PatchbayUiOperation, Set<String>>{
    PatchbayUiOperation.textEnter: <String>{'profile.editable'},
  },
);

TextField(
  key: nameKey,
  controller: controller,
  inputFormatters: formatters,
  onChanged: onChanged,
)
```

The `PatchbayKey` *is* the target widget's only `key` — there is no `PatchbayTextTarget` or other
wrapper.

A Key stays the same kind of `GlobalKey` in debug, profile, and release, preserving Element/State
mounting and cross-position move semantics. Release strips only the declaration, the weak
registration, and the operator references; it must not degrade into a different kind of Key.

## Registration and Remount Semantics

This is the part consumers most often end up reverse-engineering from source. Three phrases sum it
up: **registration happens at construction, deregistration is by weak reference, and only
simultaneously mounted instances count as ambiguous.**

### Registration happens at construction

Registration takes place in the **constructor** of `PatchbayKey.text(...)` /
`PatchbayKey.capture(...)`, not when the widget mounts. Therefore:

- a Key that has never mounted still appears in `patchbay catalog`'s `uiTargets`, just with
  `mounted: false` and empty `operations` — the catalog lists "declared targets", not "currently
  operable targets";
- in release, `declaration` is `null` and nothing is registered at all; the Key degrades to a
  plain `GlobalKey`;
- there is no `dispose()`, and none is needed: the consumer creates Keys and does not manage the
  registration lifecycle.

### Deregistration is by weak reference

The registry holds a `WeakReference` to every Key. Once a Key object is garbage collected, its
entry is cleared **the next time it is observed** (reading the catalog, or resolving one call);
once all entries for an ID are cleared, that ID disappears from the catalog.

These are weak-reference semantics, not deterministic destruction: **while a page has already been
destroyed but its Key has not yet been collected, the catalog still shows that `mounted: false`
record**. That is not a leak, and it does not affect operations — mounted state is judged on the
spot from the `Element`.

### mounted, generation, and ambiguity

| Fact | How it is determined |
|---|---|
| `mounted` | Read the Key's `currentContext` on the spot; only an existing `Element` counts as mounted |
| `generation` | One monotonic counter per ID; +1 whenever a change of `Element` identity is observed |
| `ambiguous` | **Counts only simultaneously mounted instances**; set only when >1 |

Several conclusions follow from this that are easy to guess wrong:

- **On the first observed mount the generation is 1, not 0.** An entry that has never mounted is 0.
- **The counter is shared per ID**, not per Key instance. When a second instance of the same ID
  mounts, it takes the globally next number rather than restarting from 1.
- **Moving a GlobalKey across positions does not change the number.** The Element is carried along
  and its identity is unchanged, so the generation is unchanged — one of the reasons the Key must
  retain `GlobalKey` semantics.
- **Duplicate entries that are not mounted do not constitute ambiguity.** With three Keys sharing
  one ID and only one of them mounted, operations execute as usual.
- **The generation only advances when observed.** Three remounts between two observations still
  bump it by only 1; the point is "it changed", not "how many times it changed".

Write operations must carry the most recently observed generation. The stable codes for a failed
resolution are:

| code | Meaning |
|---|---|
| `uiTargetNotFound` | No live entry exists for that ID (never declared, or the Key has been collected) |
| `uiTargetUnmounted` | Entries exist but none of them is mounted |
| `uiTargetAmbiguous` | Several instances of the same ID are mounted simultaneously |
| `uiGenerationStale` | The number does not match; `details.currentGeneration` gives the current value |
| `uiOperationUnavailable` | The target is mounted but does not support this operation (for example, a text target whose widget is not a `TextField`/`EditableText`, or a capture target whose render object is not already a `RenderRepaintBoundary`) |

After an `await` inside a gate, the operator **re-resolves** the ID, generation, and ambiguity
state, so a remount after the gate — or a newly appeared same-named instance — likewise does not
inherit this call's continuation. Late commands aimed at an old instance after a page exits are
therefore rejected stably, and never write into a same-named widget that appeared afterwards.

### Pitfall: constructing a Key inline in `build()` remounts and loses state

```dart
// ❌ a new GlobalKey on every build
@override
Widget build(BuildContext context) {
  return TextField(key: PatchbayKey.text('login.phone'), controller: _controller);
}
```

`PatchbayKey` is a `GlobalKey`, and Flutter decides between reuse and rebuild by Key **instance
identity**. Swapping in a new instance every frame tells Flutter "this is a different widget" every
frame, and the cost is threefold:

1. **State is lost** — the old `Element`/`State` is destroyed and rebuilt, taking input focus,
   scroll position, and animation progress with it;
2. **The generation jumps on every observation** — the number you just read from the catalog is
   already stale by the next resolution, so write operations are stably rejected with
   `uiGenerationStale`, which looks like "the fence is broken" when really the Key is drifting;
3. **Registry entries pile up** — every construction adds another, and only GC clears them.

The right approach is to cache the instance so it stays stable across builds:

```dart
// ✅ a State field: one Key per State instance
class _LoginFormState extends State<LoginForm> {
  late final PatchbayKey _phoneKey = PatchbayKey.text('login.phone');

  @override
  Widget build(BuildContext context) =>
      TextField(key: _phoneKey, controller: _controller);
}
```

The same applies to `StatelessWidget`: the Key belongs in an enclosing `State`, an injected
controller, or a module-level constant table — **never inside `build()`**. This holds for every
`GlobalKey` and is not a Patchbay-specific rule; it is spelled out here because Patchbay's
generation fencing turns it into a stream of baffling `uiGenerationStale` rejections.

### How to confirm a target is mounted

To confirm a widget has appeared after a page switch or an action, the route you take depends on
which kind of ID you labelled it with — **these are two separate identity spaces that do not
interconnect**:

| How it is labelled | How to check whether it is mounted |
|---|---|
| `PatchbayKey.text/capture('id')` | Read `patchbay catalog` and look at that ID's `mounted` / `generation` in `uiTargets` |
| `Semantics(identifier: 'id')` | `patchbay ui wait semantics-mounted <identifier>` (long poll) |

`PatchbayKey` only replaces the widget's `key` and **does not** also write a Semantics
`identifier`; conversely, `ui wait semantics-mounted` walks the Semantics tree and cannot see a
target labelled only with a `PatchbayKey`. For widgets you need to "wait for, then operate on",
label a Semantics `identifier` (or both).

For `ui wait`'s full condition table and the correspondence between CLI subcommands and wire
values, see [the `ui wait` section of the usage guide](https://github.com/cr1992/patchbay/blob/main/docs/guide.md#ui-wait-的-condition-名)
(currently in Chinese).

### requestId

When invoked through `PatchbayFlutterServiceHost`, the text and Semantics operators reuse the
`requestId` passed in by the transport; the bridge generates a local ID only when called directly
by a caller that supplied none. This keeps logs, CLI output, and invocation envelopes stably
correlated to the same request.

## Text Semantics

Two distinct semantics are supported today:

- `text.set` — replaces `TextEditingController.value` directly, invoking neither formatters nor
  `onChanged`; suitable for preparing state;
- `text.enter` — runs the target's `inputFormatters` in order, writes back to the controller, then
  calls the public `onChanged`; suitable for simulating one Flutter-level user input.

Both prove only that the Flutter target accepted and observed the value change — never IME, soft
keyboard UI, or system input method behavior.

Sensitive targets must declare `sensitive: true`. Such inputs are only accepted from CLI stdin,
and the catalog and results return only a length and a redacted marker, never the plaintext.

## Runtime Observation

The widget and Semantics trees do not require the consumer to wrap a root. The Flutter host can
read the current tree through the public binding, Inspector, and Semantics APIs; Semantics actions
require the consumer to inject a policy once at the composition root, and are rejected by default.

Standard components that already carry a label, flags, and actions do not need a `PatchbayKey`.
A bottom tab with `button + label + tap`, for example, can be discovered from the Semantics
snapshot and have its original callback executed, fully reusing the widget's own exit and
switching flow.

When a widget has a stable Semantics identifier, `ui.semantics.tap` folds "resolve → generation
check → dispatch" into a single admission: the caller need not first read the whole tree and then
carry around a `nodeId` that is only valid within the current SemanticsOwner. The fence is not
loosened by this — the bridge pins the resolved generation before the gates, the post-gate
re-resolution must hit that same generation, and a remount during the `await` is still rejected
with `uiSemanticsGenerationStale`; callers may additionally pass a `generation` as their own
up-front fence. Multiple mounted instances of the same identifier are always rejected as
ambiguous, never picked by tree order.

For the same identifier-first flow with another public action, use
`ui.semantics.actionByIdentifier` / `patchbay ui action <identifier> <generation> <action> [text]`.
Unlike the legacy tap command, its caller generation is required: the bridge checks it on the
first resolution, pins it across policy and gates, and checks it again immediately before
dispatch. It exposes only tap, focus, four-direction scroll, and setText; it never substitutes
`latest` or retries a write against a replacement node.

These commands share one action policy with `ui.semantics.action`: with no consumer policy they
neither enter the catalog nor can be dispatched. Misses, ambiguity, and stale generations all
carry details (the mounted identifier list is capped at 20 entries, plus the candidate list and
expected/current generation), and labels of obscured nodes are redacted in those details —
a rejection must be actionable without becoming a second observation surface that bypasses the
tree limits.

Anchored `ui.gesture.pressHold|drag|fling` commands are a separate synthetic-pointer surface, not
Semantics actions. They require an identifier, a caller-supplied Semantics generation, normalized
target-local points, and an independent `PatchbayGesturePolicy`; without that policy they are not
published. The bridge re-resolves after gates and rejects clipping or a blocking overlay before
converting coordinates. Converted global coordinates remain invocation-local and never enter the
response.

For the detailed protocol, privacy boundaries, and staged exit conditions, see
[`doc/ui-inspection-and-actions.md`](https://github.com/cr1992/patchbay/blob/main/packages/patchbay_flutter/doc/ui-inspection-and-actions.md) (currently in Chinese).

## Optional Root Bridge and Capture

When global Flutter observation is needed, the consumer may wrap a root bridge once at the top of
`MaterialApp.builder`:

```dart
MaterialApp.router(
  builder: (context, child) => PatchbayRoot(child: child!),
)
```

The root bridge is responsible only for capture and frame scheduling that genuinely need the root
render context. It does not handle widget/Semantics tree discovery, does not register business
pages, does not automatically turn every descendant into an operable target, and does not change
layout in release; a release build returns the original `child` directly, keeping no runtime
re-enable entry point.

The default path is root capture. When a partial capture is genuinely needed, swap an existing
`RenderRepaintBoundary`'s key for `PatchbayKey.capture('stable.id')`; the Key only provides stable
resolution and generation fencing and **will not** turn an arbitrary widget into a repaint
boundary. If the target is not unique, not mounted, has a stale generation, or its render object
is not already a boundary, it fails closed.

A root capture proves only that the Flutter composition tree produced those pixels in that frame.
`PlatformView`s, textures, system dialogs, and other apps may be absent from the image, so results
always return the `flutterSubtreeOnly`, `platformViewsMayBeMissing`, and `systemUiNotIncluded`
warnings and must not pose as a full physical screen capture. Capture waits for `afterFrames`
Patchbay-observed Flutter frames (default 1, maximum 120) and re-checks resumed/target before the
call, after the gate `await`, and before encoding. The observer actively requests frames, so this
is the Nth observation after admission, not the App's natural frame number. The defaults cap the
shared wait at 5 seconds (maximum 30 seconds), each image at 16 MP and an 8 MiB PNG, and pixelRatio
at 3. The PNG goes only into the shared blob store, and the response returns dimensions, RGBA8888
pixel format, observed/requested frame counts, collection time, limits, SHA-256, TTL, and a blobId.

`ui.capture.diff` compares two retained Flutter capture blob IDs only when their width, height, and
decoded pixel format match. It returns `changedPixels`, `totalPixels`, and `differenceRatio` as
observations and never invents a pass/fail threshold. Both inputs obey the same 16 MP / 8 MiB
budgets and the three capture warnings remain attached to the result: platform views, textures,
system dialogs, and other OS-composited pixels are outside this evidence.

## Keep Awake (Consumer-Injected)

This is a pure Flutter package: it touches no platform channel, and it does not pull in a wakelock
dependency for the sake of one debugging switch. The protocol, the bookkeeping, and the lease live
in the framework; the one line that touches the platform comes from the app:

```dart
PatchbayFlutterBridge(
  gates: gates,
  // Android: FLAG_KEEP_SCREEN_ON; iOS: UIApplication.isIdleTimerDisabled.
  keepAwakeDelegate: (bool enabled) => myPlatformChannel.setKeepAwake(enabled),
  keepAwakeGates: const <String>{'my.debug.keepAwake'},
)
```

The delegate is called only on an actual transition, never twice in a row with the same value.
Throwing is a legitimate answer: the request is refused with `keepAwakeDelegateFailed` rather than
recorded as a hold. **Off by default** — nothing is engaged until an operator asks, because holding
the screen changes the behaviour of the app being observed, and screen-off behaviour is itself
something a consumer tests. Every engagement carries a lease (10 minutes by default, 2 hours at
most), released by the framework when it runs out; `PatchbayFlutterBridge.dispose()` gives it back
too. Neither transport gives the app a connection lifecycle, so the lease is the only honestly
observable form of "the operator is gone".

Unlike `capture` / `navigation`, the command **stays in the catalog even with nothing wired**: an
operator reaches for it exactly when the UI plane has started refusing everything, and
`commandNotRegistered` says nothing useful at that moment — so it answers `keepAwakeNotWired` and
names the missing injection point instead. The response `source` is always `appRecorded`: it states
what the app asked its host to do. This package never reads the platform back and never claims the
screen is in fact lit.

**A failed release does not commit the bookkeeping.** Recording `enabled: false` while the platform
has not let go would turn the next `off` into an `unchanged` no-op that never reaches the platform
again, stranding the screen lit with no way left to ask. So the state is committed only after the
delegate succeeds: on failure the hold stays, `enabled` remains `true`, `lastReleaseFailure` carries
the failure type, and the lease is left armed (a lease expiry whose release fails tries again one
lease later). `dispose()` is synchronous and does not join the request queue, so it can land in the
middle of an in-flight engagement — both suspended points, the gate and the delegate, re-check the
disposed state on resume. Any `set` after teardown is refused with `keepAwakeHostDisposed`, and the
case where the delegate already took the hold hands it back before refusing. **After disposal the
delegate never receives `true` again.**

## Semantic Navigation

Navigation should not be done by adding Keys to home and settings buttons and simulating taps. The
recommended approach is to inject a consumer adapter at the app's composition root, with the
protocol exposing only stable destination IDs:

```text
navigation.catalog
navigation.current
navigation.go <destination-id>
navigation.push <destination-id>
navigation.back
```

The term is destination rather than route because one consumer's destination might be a Router
route, a Shell tab, an overlay, or a dialog. That difference exists only inside the consumer
adapter; the general-purpose CLI knows nothing about paths or page implementations.

```dart
final navigation = PatchbayNavigationAdapter(
  destinations: () => <PatchbayNavigationDestination>[
    PatchbayNavigationDestination(
      id: 'settings',
      gateIds: <String>{'debug.navigation'},
      go: () => shellController.select(settingsTab),
      push: () => router.pushNamed('settings'),
    ),
  ],
  current: () => PatchbayNavigationObservation(
    revision: navigationRevision,
    destinationId: settledDestinationId,
  ),
  back: router.pop,
);
```

Low-intrusion constraints:

- only one navigation adapter is wired at the app's top level;
- each destination is registered as a single row in the central catalog, without modifying the
  target page;
- Router routes use the existing router, and Shell tabs use one injected controller;
- arbitrary route strings are not accepted, and the consumer's real paths are not exposed;
- login, privacy consent, startup redirects, and business route guards are never bypassed.

A router/controller call returning only means the navigation request was issued. Only once the
observer confirms the current destination and the next frame has completed may the result be
marked `uiObserved`. Redirects, timeouts, backgrounding, and stale revisions must be rejected
stably.

Navigation commands are serialized and carry a navigation revision, so a late `back`/`go` cannot
operate on a new page stack. Operations that need to assert "the page is displayed" should require
the app lifecycle to be `resumed`; while backgrounded or with the screen off, at most a route state
change can be reported.

`navigation.catalog` and `navigation.current` are read-only commands. `go`, `push`, and `back` must
carry the `revision` the caller has just observed, with an optional `timeoutMs` defaulting to 5000.
A consumer callback returning only means the request has been handed to the existing
router/controller; the bridge keeps observing the settled destination and returns
`outcome=arrived`, `source=uiObserved` only after re-checking on the next frame.

The consumer's observer must publish only destinations that have already settled, and must
increase the revision monotonically whenever the settled destination changes. When a business
guard rewrites the request to a different settled destination, `navigationRedirected` is returned;
the other stable rejection codes are `navigationTimeout`, `navigationLifecycleNotResumed`,
`navigationRevisionStale`, and `navigationDestinationAmbiguous`. After an `await` in a gate, the
destination callback, ambiguity, and revision are all re-resolved.

## ui.wait

`ui.wait` is a side-effect-free long-poll call with an explicit `timeoutMs`; it does not dress up
"started waiting" as completion. The current conditions are:

- `semanticsMounted` / `semanticsUnmounted` / `semanticsValue` — accept only a stable, non-empty
  Semantics `identifier`; a duplicate identifier returns `uiSemanticsTargetAmbiguous`, and obscured
  values cannot be read;
- `navigationDestination` — waits for a cataloged destination, optionally requiring the navigation
  revision to have advanced;
- `treeRevision` / `frameRevision` — waits for a revision strictly greater than the caller's
  baseline.

Successful results are uniformly `outcome=observed`, `source=uiObserved`, returning the
revision/node facts directly observable at that moment; timeouts uniformly return `uiWaitTimeout`
with an explicit timeout and current-revision summary. When the app is not resumed,
`uiWaitLifecycleNotResumed` is returned.

## Standard Operator Status

New operators use only public Flutter APIs, and the runtime catalog decides what a target actually
supports:

| Operator | Target contract | Failure policy |
|---|---|---|
| `focus` | A unique focusable target | Reject if not focusable or ambiguous |
| `action.invoke` | A unique public Semantics/Actions action | No fallback to guessing by label, type, or coordinates |
| `scroll` | A unique ScrollableState | Returns ScrollMetrics before and after |
| `wait` | Semantics identifier, destination, tree/frame revision | Timeouts and ambiguity return stable rejections |
| `capture` | Root, or a unique target RenderObject | Returns warnings, blob metadata, and sha256 |

Plain `ValueKey`s, widget copy, runtime types, and Element paths may appear in read-only summaries,
but never automatically become stable operable targets.

## Separating UI and Domain Capabilities

A UI action proves only the direct result of a Flutter callback, controller, or RenderObject. If
the action ultimately calls network, file, device SDK, or permission capabilities, the real handler
must still pass the consumer's domain gates, permits, and generations.

The Flutter bridge does not acquire the consumer's domain locks and offers no shortcut that
bypasses controllers. For complex business behavior, prefer registering a domain command; Keys are
only for verifying UI wiring and standard widget semantics.

## Release Boundary

- release does not register the Flutter service host;
- the registry, descriptors, operators, and consumer callbacks must be unreachable;
- Key types, equality, and State preservation semantics stay unchanged;
- the root bridge passes the child straight through in release;
- the on-device inspector select mode is refused with `inspectorUnavailable` on non-debug builds,
  and the binding flag is never written;
- there is no runtime configuration that re-enables Patchbay.
