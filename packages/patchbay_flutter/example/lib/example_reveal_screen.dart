/// PB-050-17：`ui.reveal` 为之存在的那一屏。
///
/// 单独成文件而不是塞进 `main.dart`：组合根已经很长，而这一屏是能独立读懂的
/// 一个界面单元。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'main.dart';

/// PB-050-17: the screen `ui.reveal` exists for.
///
/// Three things are deliberate here, and each of them is something a first-page
/// walkthrough cannot cover:
///
/// - **The target starts unmounted.** [revealTargetSemanticsId] lives on a row
///   that only exists after several pages have loaded, so `ui.wait
///   semantics-mounted` on it would do nothing but time out — reveal is what
///   makes it appear.
/// - **Pages arrive after the scroll, not during it.** Reaching the end grows
///   `maxScrollExtent` one frame later, which is exactly the observation reveal
///   uses as its lazy-loading evidence (`containers[].extentGrowthSteps`).
/// - **A pinned bar covers the bottom of the viewport.** A row that lands under
///   it is mounted but not exposed, so reveal has to keep stepping instead of
///   reporting a covered row as revealed.
final class ExampleRevealScreen extends StatefulWidget {
  const ExampleRevealScreen({super.key});

  /// Index of [revealTargetSemanticsId], several pages past the first one.
  static const int targetIndex = 42;

  /// Index of the row with semantics but no pointer footprint.
  static const int semanticsOnlyIndex = 24;

  /// Rows delivered per simulated page.
  ///
  /// Large enough that the initial page cannot possibly fill a single
  /// viewport on its own — 12 fit entirely inside a tall real phone's body
  /// height (confirmed on a real device precheck run: `12 * 56` logical
  /// pixels of content did not exceed the body height), which made the list
  /// non-scrollable on first frame and `ui.reveal` correctly (and
  /// unhelpfully, for this screen's purpose) admission-reject with
  /// `uiRevealNoScrollableContainer`. `flutter_test`'s default surface is
  /// short enough that this never showed up in a widget test.
  static const int pageSize = 30;

  /// Height of the pinned bottom bar, in logical pixels.
  static const double overlayExtent = 72;

  @override
  State<ExampleRevealScreen> createState() => _ExampleRevealScreenState();
}

final class _ExampleRevealScreenState extends State<ExampleRevealScreen> {
  int _loaded = ExampleRevealScreen.pageSize;

  /// Simulated paging: a page lands one microtask after the list reports it
  /// reached the end, so the growth shows up on the step that scrolled there.
  bool _onScroll(ScrollNotification notification) {
    final ScrollMetrics metrics = notification.metrics;
    if (_loaded <= ExampleRevealScreen.targetIndex &&
        metrics.hasContentDimensions &&
        metrics.pixels >= metrics.maxScrollExtent - 1) {
      scheduleMicrotask(() {
        if (mounted) {
          setState(() => _loaded += ExampleRevealScreen.pageSize);
        }
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Reveal')),
    body: Stack(
      children: <Widget>[
        Positioned.fill(
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: Semantics(
              identifier: revealListSemanticsId,
              container: true,
              label: 'Lazy paging list',
              child: ListView.builder(
                itemExtent: 56,
                itemCount: _loaded,
                itemBuilder: _row,
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: ExampleRevealScreen.overlayExtent,
          // `Listener` rather than a `GestureDetector`: the bar must take part
          // in hit testing (that is the point) without adding a semantics node
          // that would change the rows' generations underneath it.
          child: Listener(
            behavior: HitTestBehavior.opaque,
            child: Semantics(
              identifier: revealOverlaySemanticsId,
              label: 'Pinned bar',
              child: ColoredBox(
                color: Theme.of(context).colorScheme.inverseSurface,
                child: const Center(child: Text('pinned bar')),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _row(BuildContext context, int index) {
    if (index == ExampleRevealScreen.targetIndex) {
      return Semantics(
        identifier: revealTargetSemanticsId,
        button: true,
        onTap: () {},
        child: const ExcludeSemantics(
          child: Listener(
            behavior: HitTestBehavior.opaque,
            child: ColoredBox(
              color: Color(0xFF2E7D32),
              child: Center(child: Text('far row')),
            ),
          ),
        ),
      );
    }
    if (index == ExampleRevealScreen.semanticsOnlyIndex) {
      // Semantics with no pointer footprint: a legitimate accessibility shape,
      // and the reason `reachability` has two values instead of one boolean.
      return Semantics(
        identifier: revealSemanticsOnlyRowId,
        button: true,
        onTap: () {},
        child: const SizedBox.expand(),
      );
    }
    return ListTile(dense: true, title: Text('reveal row $index'));
  }
}
