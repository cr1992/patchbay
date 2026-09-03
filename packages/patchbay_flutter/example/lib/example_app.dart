/// 示例 App 的 widget 层（PB-060-02）。
///
/// 这个文件存在的理由就是 import 行本身：它只 import
/// `package:patchbay_flutter/patchbay_flutter.dart`，也就是 0.6.0 的默认
/// Flutter 面。widget 需要的 Patchbay 词汇只有 `PatchbayKey` 与 `PatchbayRoot`；
/// service host、bridge、policy 与 raw wire 都在 `main.dart` 那个组合根里，从这里
/// **看不见**——把它们搬回来会立刻编译失败，而不是悄悄可用。
library;

import 'package:flutter/material.dart';
import 'package:patchbay_flutter/patchbay_flutter.dart';

import 'example_reveal_screen.dart';
import 'main.dart';

final class PatchbayExampleApp extends StatefulWidget {
  const PatchbayExampleApp({
    required this.model,
    required this.noteKey,
    required this.cardCaptureKey,
    required this.router,
    super.key,
  });

  final ExampleCounterModel model;
  final PatchbayKey noteKey;
  final PatchbayKey cardCaptureKey;
  final ExampleRouter router;

  @override
  State<PatchbayExampleApp> createState() => _PatchbayExampleAppState();
}

final class _PatchbayExampleAppState extends State<PatchbayExampleApp> {
  final TextEditingController _noteController = TextEditingController();

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PatchbayRoot(
    child: MaterialApp(
      navigatorKey: widget.router.navigatorKey,
      initialRoute: homeDestinationId,
      routes: <String, WidgetBuilder>{
        homeDestinationId: (BuildContext context) => _ExampleHomeScreen(
          model: widget.model,
          noteKey: widget.noteKey,
          cardCaptureKey: widget.cardCaptureKey,
          noteController: _noteController,
        ),
        detailsDestinationId: (BuildContext context) =>
            const _ExampleDetailsScreen(),
        revealDestinationId: (BuildContext context) =>
            const ExampleRevealScreen(),
      },
    ),
  );
}

final class _ExampleHomeScreen extends StatelessWidget {
  const _ExampleHomeScreen({
    required this.model,
    required this.noteKey,
    required this.cardCaptureKey,
    required this.noteController,
  });

  final ExampleCounterModel model;
  final PatchbayKey noteKey;
  final PatchbayKey cardCaptureKey;
  final TextEditingController noteController;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Patchbay example')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ValueListenableBuilder<int>(
            valueListenable: model,
            builder: (BuildContext context, int count, Widget? child) =>
                Semantics(
                  identifier: counterSemanticsId,
                  label: 'Counter value',
                  value: '$count',
                  liveRegion: true,
                  child: Text('Count: $count'),
                ),
          ),
          const SizedBox(height: 16),
          // identifier 与 tap 动作必须落在同一个语义节点上，而且该 identifier 只能命中
          // 一个节点：
          // - 只包一层 Semantics(identifier:) 时，按钮自己的节点才带 tap 动作，
          //   identifier 命中的那个节点 actions 为空 → uiSemanticsActionUnavailable；
          // - 用 MergeSemantics 合并时，identifier 会同时出现在合并节点和子节点上，
          //   活体清单核对报 manifestSemanticsIdentifierAmbiguous（matchCount 2）。
          // 所以由外层节点自己声明动作，并排除子树语义。两条路径都是真机预检发现的。
          Semantics(
            identifier: incrementSemanticsId,
            button: true,
            onTap: model.increment,
            child: ExcludeSemantics(
              child: ElevatedButton(
                onPressed: model.increment,
                child: const Text('Increment'),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Semantics(
            identifier: identifierActionSemanticsId,
            focusable: true,
            onFocus: () {},
            onScrollDown: () {},
            onSetText: (_) {},
            child: const SizedBox(width: 1, height: 1),
          ),
          TextField(
            key: noteKey,
            controller: noteController,
            decoration: const InputDecoration(labelText: 'Debug note'),
          ),
          const SizedBox(height: 16),
          RepaintBoundary(
            key: cardCaptureKey,
            child: const _ExampleGestureSurface(),
          ),
          const SizedBox(height: 16),
          const Expanded(child: _ExampleGestureList()),
        ],
      ),
    ),
  );
}

/// Press-hold / drag target. It reports what it observed so a CLI-driven
/// gesture can be verified from the App side instead of from a screenshot.
final class _ExampleGestureSurface extends StatefulWidget {
  const _ExampleGestureSurface();

  @override
  State<_ExampleGestureSurface> createState() => _ExampleGestureSurfaceState();
}

final class _ExampleGestureSurfaceState extends State<_ExampleGestureSurface> {
  String _observed = 'none';

  @override
  Widget build(BuildContext context) => Stack(
    children: <Widget>[
      Semantics(
        identifier: gestureSurfaceSemanticsId,
        label: 'Gesture surface',
        value: _observed,
        child: GestureDetector(
          onTap: () => setState(() => _observed = 'tap'),
          onLongPress: () => setState(() => _observed = 'longPress'),
          onPanUpdate: (DragUpdateDetails details) =>
              setState(() => _observed = 'pan'),
          child: Container(
            height: 96,
            alignment: Alignment.center,
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Text('gesture surface: $_observed'),
          ),
        ),
      ),
      // 被遮挡的 tap 探针：嵌在手势面右上角，不改变任何既有布局。上层是
      // 不透明、非模态的装饰块（吸收 hit-test，但不用 BlockSemantics），
      // 预检据此断言 `ui.gesture.tap` 对它如实拒绝而不是隔着装饰点下去。
      Positioned(
        right: 8,
        top: 8,
        width: 40,
        height: 40,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Semantics(
              identifier: gestureCoveredSemanticsId,
              container: true,
              label: 'Covered tap probe',
              child: const Listener(
                behavior: HitTestBehavior.opaque,
                child: ColoredBox(color: Color(0xFF335577)),
              ),
            ),
            const Listener(
              behavior: HitTestBehavior.opaque,
              child: ColoredBox(color: Color(0xFF222222)),
            ),
          ],
        ),
      ),
    ],
  );
}

/// Scrollable list for fling and multi-segment drag paths, including a nested
/// horizontal scrollable for nested gesture isolation testing.
final class _ExampleGestureList extends StatelessWidget {
  const _ExampleGestureList();

  @override
  Widget build(BuildContext context) => Semantics(
    identifier: gestureListSemanticsId,
    label: 'Gesture list',
    child: ListView.builder(
      itemCount: 60,
      itemBuilder: (BuildContext context, int index) {
        if (index == 2) {
          return SizedBox(
            height: 96,
            child: Semantics(
              identifier: gestureNestedListSemanticsId,
              container: true,
              label: 'Nested horizontal list',
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: 20,
                itemBuilder: (BuildContext context, int hIndex) => Container(
                  width: 96,
                  margin: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Text('item $hIndex'),
                ),
              ),
            ),
          );
        }
        return ListTile(dense: true, title: Text('row $index'));
      },
    ),
  );
}

final class _ExampleDetailsScreen extends StatelessWidget {
  const _ExampleDetailsScreen();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Details')),
    body: Center(
      child: Semantics(
        identifier: 'example.details.body',
        child: Text('Second destination'),
      ),
    ),
  );
}
