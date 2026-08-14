import 'package:flutter/widgets.dart';

/// Reads the App lifecycle state a `*LifecycleNotResumed` rejection reports.
///
/// This is a diagnostic seam, never the decision: `isAppResumed` still says
/// whether the request is admitted. Keeping them apart is what lets a consumer
/// override the decision — a headless harness, a test — without also having to
/// invent a lifecycle state for it to report.
typedef PatchbayLifecycleStateReader = AppLifecycleState? Function();

/// The default reader: whatever the widgets binding currently reports.
AppLifecycleState? patchbayBindingLifecycleState() =>
    WidgetsBinding.instance.lifecycleState;

/// The reader paired with an overridden `isAppResumed`.
///
/// A consumer that decides "resumed" for itself has, by construction, made the
/// binding's own state a different question. Reporting the binding anyway would
/// let a rejection say `resumed` while explaining that the App is not resumed;
/// `unknown` is the honest answer until that consumer supplies a reader too.
AppLifecycleState? patchbayUnknownLifecycleState() => null;

/// Pairs a lifecycle reader with the resumed decision it has to describe.
///
/// [lifecycleState] wins when the caller supplies one. Otherwise the reader
/// follows [isAppResumed]: the binding when the default decision is in use, and
/// `unknown` when the caller replaced it.
PatchbayLifecycleStateReader patchbayLifecycleReaderFor({
  required bool Function()? isAppResumed,
  required PatchbayLifecycleStateReader? lifecycleState,
}) =>
    lifecycleState ??
    (isAppResumed == null
        ? patchbayBindingLifecycleState
        : patchbayUnknownLifecycleState);

/// Rejection `details` for a request refused because the App is not resumed.
///
/// `*LifecycleNotResumed` used to travel with nothing attached, so an operator
/// learned only that the gate had closed — not whether the device was asleep,
/// the window merely unfocused, or the App on its way out. The state is the one
/// fact that separates "wake the screen", "click the window" and "the App is
/// gone", and it is engine state rather than App data, so naming it leaks
/// nothing.
Map<String, Object?> patchbayLifecycleDetails(
  PatchbayLifecycleStateReader read,
) => <String, Object?>{'lifecycleState': read()?.name ?? 'unknown'};
