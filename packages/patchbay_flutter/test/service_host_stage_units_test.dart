// PB-050-38：拆出来的每个单元各自的失败注入。
//
// 表征测试证明的是「整台 host 对外没变」；这份文件证明拆分真的拆开了——七个单元逐个
// 脱离 `PatchbayFlutterServiceHost` 单独构造、单独注入失败、给出类型化结论。
//
// 注入点按单元分：声明表注入运行期覆写，解码器注入未知键与类型不符，拒绝投影注入
// 失败对象与严格度，装配原语两端各注入一次数量失配，命令族注入「descriptor 不够」
// 与「桥没接线」，catalog 注入一个会抛的 provider，host 装配注入四种源头组合。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patchbay_flutter/patchbay_flutter_host.dart';
import 'package:patchbay_flutter/src/flutter_host_assembly.dart';
import 'package:patchbay_flutter/src/flutter_ui_argument_decoders.dart';
import 'package:patchbay_flutter/src/flutter_ui_catalog.dart';
import 'package:patchbay_flutter/src/flutter_ui_command_bindings.dart';
import 'package:patchbay_flutter/src/flutter_ui_command_descriptors.dart';
import 'package:patchbay_flutter/src/flutter_ui_registration.dart';
import 'package:patchbay_flutter/src/flutter_ui_rejection.dart';

final PatchbayGateEvaluator _gates = PatchbayGateEvaluator(
  baseGate: () => const PatchbayGateDecision.allow(),
  consumerGate: (_) => const PatchbayGateDecision.allow(),
);

/// 一个名字任意、参数为空的 descriptor：位置约定不看名字，测试也不该看。
PatchbayCommandDescriptor _stub(String name) => PatchbayCommandDescriptor(
  name: name,
  summary: 'stub',
  plane: PatchbayPlane.flutterUi,
  mode: PatchbayCommandMode.readOnly,
  sideEffect: PatchbaySideEffect.none,
  factSources: const <PatchbayFactSource>{PatchbayFactSource.uiObserved},
  parameters: const <PatchbayParameterDescriptor>[],
);

List<PatchbayCommandDescriptor> _stubs(int count) =>
    <PatchbayCommandDescriptor>[
      for (int i = 0; i < count; i += 1) _stub('stub.c$i'),
    ];

PatchbayFlutterBridge _bridge({
  bool artifacts = false,
  bool navigation = false,
  bool inspect = false,
  bool gesture = false,
  bool reveal = false,
  bool semanticsActions = false,
}) => PatchbayFlutterBridge(
  registry: PatchbayUiRegistry(),
  gates: _gates,
  isAppResumed: () => true,
  semanticsActionPolicy: semanticsActions
      ? (_, _) => const PatchbaySemanticsActionDecision.allow()
      : null,
  gesturePolicy: gesture
      ? (_, _) => const PatchbayGestureDecision.allow()
      : null,
  revealPolicy: reveal ? (_, _) => const PatchbayRevealDecision.allow() : null,
  navigationAdapter: navigation
      ? PatchbayNavigationAdapter(
          destinations: () => <PatchbayNavigationDestination>[
            PatchbayNavigationDestination(id: 'home', go: () {}),
          ],
          current: () =>
              PatchbayNavigationObservation(revision: 1, destinationId: 'home'),
        )
      : null,
  inspectPolicy: inspect ? const PatchbayInspectPolicy() : null,
  artifacts: artifacts
      ? PatchbayArtifactService(blobs: PatchbayMemoryBlobStore(), gates: _gates)
      : null,
);

/// 一个只会抛的 domain provider，用来注入 catalog 那层的失败。
final class _ThrowingCatalogProvider implements PatchbayCatalogProvider {
  int reads = 0;

  @override
  int get commandsRevision => 9;

  @override
  Future<PatchbayCatalogSample> readCatalog() async {
    reads += 1;
    throw StateError('domain catalog unavailable');
  }
}

final class _CountingCatalogProvider implements PatchbayCatalogProvider {
  int reads = 0;

  @override
  int get commandsRevision => 42;

  @override
  Future<PatchbayCatalogSample> readCatalog() async {
    reads += 1;
    return const PatchbayCatalogSample(
      commandsRevision: 42,
      catalog: <String, Object?>{'uiTargets': 'domain wins nothing', 'a': 1},
    );
  }
}

void main() {
  group('声明表：运行期覆写只改门与缺省', () {
    test('注入的三组覆写原样出现，参数的名字/必填/类型不动', () {
      final List<PatchbayCommandDescriptor> plain =
          patchbayFlutterUiCommandDescriptors(
            captureGates: const <String>{},
            keepAwakeGates: const <String>{},
            inspectPolicy: const PatchbayInspectPolicy(),
          );
      final List<PatchbayCommandDescriptor> overridden =
          patchbayFlutterUiCommandDescriptors(
            captureGates: const <String>{'app.shot'},
            keepAwakeGates: const <String>{'app.awake'},
            inspectPolicy: const PatchbayInspectPolicy(
              gates: <String>{'app.inspect'},
              defaultLease: Duration(seconds: 7),
            ),
          );

      expect(
        overridden.map((PatchbayCommandDescriptor d) => d.name),
        plain.map((PatchbayCommandDescriptor d) => d.name),
      );
      PatchbayCommandDescriptor at(
        List<PatchbayCommandDescriptor> list,
        String name,
      ) => list.singleWhere((PatchbayCommandDescriptor d) => d.name == name);

      expect(at(overridden, 'ui.capture').gates, <String>{'app.shot'});
      expect(at(overridden, 'ui.capture.diff').gates, <String>{'app.shot'});
      expect(at(overridden, 'ui.keepAwake.set').gates, <String>{'app.awake'});
      expect(at(overridden, 'ui.inspect.select').gates, <String>{
        'app.inspect',
      });
      expect(at(plain, 'ui.capture').gates, isEmpty);

      // 覆写不碰参数的三件事：名字、必填、类型。
      for (final PatchbayCommandDescriptor before in plain) {
        final PatchbayCommandDescriptor after = at(overridden, before.name);
        expect(
          after.parameters.map(
            (PatchbayParameterDescriptor p) =>
                '${p.name}/${p.required}/${p.type.name}',
          ),
          before.parameters.map(
            (PatchbayParameterDescriptor p) =>
                '${p.name}/${p.required}/${p.type.name}',
          ),
          reason: before.name,
        );
      }
    });

    test('声明表的次序就是注册次序，命令名不重复', () {
      final List<String> names = patchbayFlutterUiCommandDescriptors(
        captureGates: const <String>{},
        keepAwakeGates: const <String>{},
        inspectPolicy: const PatchbayInspectPolicy(),
      ).map((PatchbayCommandDescriptor d) => d.name).toList();

      expect(names.toSet().length, names.length);
      expect(names.first, 'ui.text.set');
      expect(names.last, 'navigation.back');
      expect(names, hasLength(23));
    });
  });

  group('解码器：注入未知键与类型不符', () {
    test('严格键的命令当场拒绝未声明的键', () {
      for (final Map<String, Object?> Function(Map<String, Object?>) decode
          in <Map<String, Object?> Function(Map<String, Object?>)>[
            patchbayDecodeUiSemanticsTap,
            patchbayDecodeUiSemanticsIdentifierAction,
            patchbayDecodeNavigationDestination,
            patchbayDecodeNavigationBack,
            patchbayDecodeNoUiArguments,
          ]) {
        expect(
          () => decode(const <String, Object?>{'zeta': 1}),
          throwsA(
            isA<FormatException>().having(
              (FormatException e) => e.message,
              'message',
              'unexpected argument',
            ),
          ),
        );
      }
    });

    test('exec 式的两条不拒绝未声明的键', () {
      // `--args` 整包转发的命令刻意不调用 `patchbayRejectUnexpectedUiKeys`。
      expect(
        patchbayDecodeUiText(const <String, Object?>{
          'id': 'a',
          'generation': 1,
          'text': 't',
          'note': 'anything',
        })['note'],
        'anything',
      );
      expect(
        patchbayDecodeUiSemanticsTree(const <String, Object?>{
          'note': 'anything',
        })['note'],
        'anything',
      );
    });

    test('gesture 的键集按 kind 分叉，tap 没有 durationMs', () {
      const Map<String, Object?> base = <String, Object?>{
        'identifier': 'a',
        'generation': 1,
        'start': <String, Object?>{'x': 0.5, 'y': 0.5},
      };
      expect(
        () => patchbayDecodeUiGesture(<String, Object?>{
          ...base,
          'durationMs': 10,
        }, PatchbayGestureKind.tap),
        throwsFormatException,
      );
      expect(
        patchbayDecodeUiGesture(<String, Object?>{
          ...base,
          'durationMs': 10,
        }, PatchbayGestureKind.pressHold)['durationMs'],
        10,
      );
      // drag 要 path，fling 要 velocity，互换即拒。
      expect(
        () => patchbayDecodeUiGesture(<String, Object?>{
          ...base,
          'velocity': <String, Object?>{'x': 0, 'y': -1},
        }, PatchbayGestureKind.drag),
        throwsFormatException,
      );
      expect(
        () => patchbayDecodeUiGesture(<String, Object?>{
          ...base,
          'path': <Object?>[],
        }, PatchbayGestureKind.fling),
        throwsFormatException,
      );
      // tap 的 start 可省，家族里其余三条不可省。
      expect(
        patchbayDecodeUiGesture(const <String, Object?>{
          'identifier': 'a',
          'generation': 1,
        }, PatchbayGestureKind.tap),
        isNotNull,
      );
      expect(
        () => patchbayDecodeUiGesture(const <String, Object?>{
          'identifier': 'a',
          'generation': 1,
        }, PatchbayGestureKind.pressHold),
        throwsFormatException,
      );
    });

    test('两条 action 解码器的 action 词表不同', () {
      // nodeId 版走内部词表，identifier 版只收 descriptor 声明的取值——
      // `longPress` 是前者有、后者没有的那个。
      expect(
        patchbayDecodeUiSemanticsAction(const <String, Object?>{
          'nodeId': 1,
          'generation': 1,
          'action': 'longPress',
        })['decodedAction'],
        isA<PatchbaySemanticsAction>(),
      );
      expect(
        () => patchbayDecodeUiSemanticsIdentifierAction(const <String, Object?>{
          'identifier': 'a',
          'generation': 1,
          'action': 'longPress',
        }),
        throwsFormatException,
      );
    });
  });

  group('拒绝投影：注入失败对象与严格度', () {
    test('strictKeys 决定 unexpected 是否出现，其余不变', () {
      const Map<String, Object?> arguments = <String, Object?>{
        'identifier': 'a',
        'zeta': 1,
      };
      expect(
        patchbayInvalidUiArguments(
              'r',
              'ui.semantics.tap',
              arguments,
            )['rejection']!
            as Map<String, Object?>,
        <String, Object?>{
          'code': 'invalidUiArguments',
          'details': <String, Object?>{'command': 'ui.semantics.tap'},
        },
      );
      expect(
        ((patchbayInvalidUiArguments(
                  'r',
                  'ui.semantics.tap',
                  arguments,
                  strictKeys: true,
                )['rejection']!
                as Map<String, Object?>)['details']!
            as Map<String, Object?>)['unexpected'],
        <String>['zeta'],
      );
    });

    test('未知命令名降级成只报 command，不抛', () {
      expect(
        patchbayInvalidUiArguments(
              'r',
              'not.a.command',
              const <String, Object?>{'x': 1},
            )['rejection']!
            as Map<String, Object?>,
        <String, Object?>{
          'code': 'invalidUiArguments',
          'details': <String, Object?>{'command': 'not.a.command'},
        },
      );
    });

    test('reason 的三个分支：句子 / 字段名 / 类型名', () {
      expect(
        patchbayUiDecodeFailureReason(const FormatException('a sentence')),
        'a sentence',
      );
      expect(
        patchbayUiDecodeFailureReason(ArgumentError.value(1, 'timeout')),
        'timeout is out of the accepted range',
      );
      // 没有 String name 的 ArgumentError 不能落到上一分支，否则会把值带出去。
      expect(
        patchbayUiDecodeFailureReason(ArgumentError('99999 is too large')),
        isNot(contains('99999')),
      );
      expect(patchbayUiDecodeFailureReason(StateError('x')), 'StateError');
    });

    test('声明表单独构造：三类指名各自有序', () {
      final PatchbayUiArgumentShape shape = PatchbayUiArgumentShape(
        const <PatchbayParameterDescriptor>[
          PatchbayParameterDescriptor(
            name: 'zulu',
            type: PatchbayParameterType.string,
            required: true,
          ),
          PatchbayParameterDescriptor(
            name: 'alpha',
            type: PatchbayParameterType.integer,
            required: true,
          ),
          PatchbayParameterDescriptor(
            name: 'mode',
            type: PatchbayParameterType.enumeration,
            allowedValues: <String>['on', 'off'],
          ),
          PatchbayParameterDescriptor(
            name: 'blob',
            type: PatchbayParameterType.json,
          ),
        ],
      );

      expect(shape.missing(const <String, Object?>{}), <String>[
        'alpha',
        'zulu',
      ]);
      // 显式 null 与缺席同义。
      expect(shape.missing(const <String, Object?>{'zulu': null}), <String>[
        'alpha',
        'zulu',
      ]);
      expect(
        shape.unexpected(const <String, Object?>{'yankee': 1, 'bravo': 2}),
        <String>['bravo', 'yankee'],
      );
      expect(
        shape.invalid(const <String, Object?>{
          'zulu': 1,
          'alpha': 'x',
          'mode': 'sideways',
        }),
        <String>['alpha', 'mode', 'zulu'],
      );
      // json 不声明形状，任何取值都不与它矛盾。
      expect(
        shape.invalid(const <String, Object?>{'blob': 'anything'}),
        isEmpty,
      );
    });
  });

  group('装配原语：两端各守一道数量', () {
    test('descriptor 用完还要 bind 就报', () {
      final PatchbayUiRegistrationBuilder builder =
          PatchbayUiRegistrationBuilder(_stubs(1));
      builder.bind<Map<String, Object?>>(
        (a) => a,
        (_, _) async => const <String, Object?>{},
      );

      expect(
        () => builder.bind<Map<String, Object?>>(
          (a) => a,
          (_, _) async => const <String, Object?>{},
        ),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            'UI command descriptor/handler count mismatch',
          ),
        ),
      );
    });

    test('handler 配完还剩 descriptor，seal 就报', () {
      final PatchbayUiRegistrationBuilder builder =
          PatchbayUiRegistrationBuilder(_stubs(2));
      builder.bind<Map<String, Object?>>(
        (a) => a,
        (_, _) async => const <String, Object?>{},
      );

      expect(builder.seal, throwsStateError);
    });

    test('数量刚好时按位置成表，名字不参与配对', () {
      final PatchbayUiRegistrationBuilder builder =
          PatchbayUiRegistrationBuilder(<PatchbayCommandDescriptor>[
            _stub('second.first'),
            _stub('first.second'),
          ]);
      builder.bind<Map<String, Object?>>(
        (a) => a,
        (_, _) async => const <String, Object?>{'which': 'a'},
      );
      builder.bind<Map<String, Object?>>(
        (a) => a,
        (_, _) async => const <String, Object?>{'which': 'b'},
        available: false,
      );
      final PatchbayCommandRegistry registry = builder.seal();

      expect(registry.handles('second.first'), isTrue);
      expect(registry.handles('first.second'), isTrue);
      // `available: false` 的那条不进目录，但注册表仍然认得它。
      expect(
        registry.descriptors.map((PatchbayCommandDescriptor d) => d.name),
        <String>['second.first'],
      );
    });

    test('解码失败走投影，执行失败原样抛出', () async {
      final PatchbayUiRegistrationBuilder builder =
          PatchbayUiRegistrationBuilder(<PatchbayCommandDescriptor>[
            _stub('ui.semantics.tap'),
            _stub('boom.now'),
          ]);
      builder.bind<Map<String, Object?>>(
        (_) => throw const FormatException('nope'),
        (_, _) async => const <String, Object?>{},
        strictKeys: true,
        includeReason: true,
      );
      builder.bind<Map<String, Object?>>(
        (a) => a,
        (_, _) async => throw StateError('bridge exploded'),
      );
      final PatchbayCommandRegistry registry = builder.seal();

      final Map<String, Object?> decoded = await registry.dispatch(
        'ui.semantics.tap',
        const <String, Object?>{'zeta': 1},
        'r',
      );
      expect(decoded['rejection'], <String, Object?>{
        'code': 'invalidUiArguments',
        'details': <String, Object?>{
          'command': 'ui.semantics.tap',
          'missing': <String>['identifier'],
          'unexpected': <String>['zeta'],
          'reason': 'nope',
        },
      });
      // 执行阶段没有 recover：桥抛出的东西不该被伪装成一次拒绝。
      await expectLater(
        registry.dispatch('boom.now', const <String, Object?>{}, 'r'),
        throwsStateError,
      );
    });
  });

  group('命令族：每族消费固定条数，available 跟着接线走', () {
    // 每族消费的条数是位置约定的关键量：多一条少一条都会让后面所有命令错位。
    const List<(String, int)> families = <(String, int)>[
      ('text', 2),
      ('semantics', 4),
      ('gesture', 4),
      ('revealWait', 2),
      ('keepAwake', 2),
      ('capture', 2),
      ('inspect', 2),
      ('navigation', 5),
    ];

    void bindFamily(
      String family,
      PatchbayUiRegistrationBuilder builder,
      PatchbayFlutterBridge bridge,
    ) => switch (family) {
      'text' => patchbayBindUiTextCommands(builder, bridge),
      'semantics' => patchbayBindUiSemanticsCommands(builder, bridge),
      'gesture' => patchbayBindUiGestureCommands(builder, bridge),
      'revealWait' => patchbayBindUiRevealAndWaitCommands(builder, bridge),
      'keepAwake' => patchbayBindUiKeepAwakeCommands(builder, bridge),
      'capture' => patchbayBindUiCaptureCommands(builder, bridge),
      'inspect' => patchbayBindUiInspectCommands(builder, bridge),
      'navigation' => patchbayBindNavigationCommands(builder, bridge),
      _ => throw StateError(family),
    };

    test('少一条那一族当场报，多一条 seal 报，刚好通过', () {
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      for (final (String family, int consumes) in families) {
        final PatchbayUiRegistrationBuilder exact =
            PatchbayUiRegistrationBuilder(_stubs(consumes));
        bindFamily(family, exact, bridge);
        expect(exact.seal, returnsNormally, reason: family);

        final PatchbayUiRegistrationBuilder short =
            PatchbayUiRegistrationBuilder(_stubs(consumes - 1));
        expect(
          () => bindFamily(family, short, bridge),
          throwsStateError,
          reason: family,
        );

        final PatchbayUiRegistrationBuilder long =
            PatchbayUiRegistrationBuilder(_stubs(consumes + 1));
        bindFamily(family, long, bridge);
        expect(long.seal, throwsStateError, reason: family);
      }
    });

    test('桥没接线的族整族 available: false', () {
      final PatchbayFlutterBridge bare = _bridge();
      addTearDown(bare.dispose);

      for (final (String family, int consumes) in <(String, int)>[
        ('gesture', 4),
        ('capture', 2),
        ('inspect', 2),
        ('navigation', 5),
      ]) {
        final PatchbayUiRegistrationBuilder builder =
            PatchbayUiRegistrationBuilder(_stubs(consumes));
        bindFamily(family, builder, bare);
        expect(builder.seal().descriptors, isEmpty, reason: family);
      }
    });

    test('接线之后同一族整族出现', () {
      final PatchbayFlutterBridge wired = _bridge(
        artifacts: true,
        navigation: true,
        inspect: true,
        gesture: true,
      );
      addTearDown(wired.dispose);

      for (final (String family, int consumes) in <(String, int)>[
        ('gesture', 4),
        ('capture', 2),
        ('inspect', 2),
        ('navigation', 5),
      ]) {
        final PatchbayUiRegistrationBuilder builder =
            PatchbayUiRegistrationBuilder(_stubs(consumes));
        bindFamily(family, builder, wired);
        expect(builder.seal().descriptors, hasLength(consumes), reason: family);
      }
    });

    test('整表装配吃掉的正好是声明表那 23 条', () {
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      // seal 的正面用例：八个族加起来必须**正好**吃完，多一条少一条都会抛。
      final PatchbayCommandRegistry registry = patchbayFlutterUiCommandRegistry(
        bridge,
      );
      expect(registry.handles('ui.reveal'), isTrue);
      expect(registry.handles('navigation.back'), isTrue);
    });
  });

  group('catalog 投影：注入一个会抛的 provider', () {
    testWidgets('domain 的键在前，uiTargets 覆盖同名键', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      final Map<String, Object?> merged = patchbayWithUiTargets(
        const <String, Object?>{'a': 1, 'uiTargets': 'domain wrote this'},
        bridge,
      );

      expect(merged.keys.join(','), 'a,uiTargets');
      expect(merged['uiTargets'], isEmpty);
    });

    testWidgets('provider 抛出时原样传出，读取只发生一次', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final _ThrowingCatalogProvider domain = _ThrowingCatalogProvider();
      final PatchbayFlutterCatalogProvider wrapped =
          PatchbayFlutterCatalogProvider(domain, bridge);

      // commandsRevision 不读 catalog，所以抛出的 provider 也答得出来。
      expect(wrapped.commandsRevision, 9);
      await expectLater(wrapped.readCatalog(), throwsStateError);
      expect(domain.reads, 1);
    });

    testWidgets('commandsRevision 透传的是 sample 的那个', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);
      final _CountingCatalogProvider domain = _CountingCatalogProvider();

      final PatchbayCatalogSample sample = await PatchbayFlutterCatalogProvider(
        domain,
        bridge,
      ).readCatalog();

      expect(sample.commandsRevision, 42);
      expect(sample.catalog['a'], 1);
      expect(sample.catalog['uiTargets'], isEmpty);
      expect(domain.reads, 1);
    });
  });

  group('host 装配：注入四种源头组合', () {
    testWidgets('两条 invoke 都没给才装 commandNotRegistered 兜底', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      final PatchbayServiceHost fallback = patchbayBuildFlutterServiceHost(
        applicationId: 'dev.patchbay.units',
        bridge: bridge,
        auditQueueCapacity: 8,
        maxConcurrentInvocations: 2,
        cancellationConfirmationTimeout: const Duration(seconds: 1),
      );
      expect(
        (await fallback.dispatchInvoke(
          'example.nope',
          const <String, Object?>{},
          'r',
        ))['rejection'],
        <String, Object?>{
          'code': 'commandNotRegistered',
          'details': <String, Object?>{'command': 'example.nope'},
        },
      );

      // 只给了 contextAware 的 App 不该被兜底抢走请求。
      var reached = false;
      final PatchbayServiceHost contextual = patchbayBuildFlutterServiceHost(
        applicationId: 'dev.patchbay.units',
        bridge: bridge,
        domainInvokeWithContext: (command, arguments, requestId, _) async {
          reached = true;
          return PatchbayInvocation.accepted(
            requestId: requestId,
            payload: const <String, Object?>{'outcome': 'applied'},
          ).toJson();
        },
        auditQueueCapacity: 8,
        maxConcurrentInvocations: 2,
        cancellationConfirmationTimeout: const Duration(seconds: 1),
      );
      await contextual.dispatchInvoke(
        'example.write',
        const <String, Object?>{},
        'r',
      );
      expect(reached, isTrue);
    });

    testWidgets('features 里的 captureAfterFrames 跟着 artifacts', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final PatchbayFlutterBridge bare = _bridge();
      final PatchbayFlutterBridge wired = _bridge(artifacts: true);
      addTearDown(bare.dispose);
      addTearDown(wired.dispose);

      PatchbayServiceHost host(PatchbayFlutterBridge bridge) =>
          patchbayBuildFlutterServiceHost(
            applicationId: 'dev.patchbay.units',
            bridge: bridge,
            auditQueueCapacity: 8,
            maxConcurrentInvocations: 2,
            cancellationConfirmationTimeout: const Duration(seconds: 1),
          );

      expect(
        host(bare).features.contains(PatchbayFeature.captureAfterFrames),
        isFalse,
      );
      expect(
        host(wired).features.contains(PatchbayFeature.captureAfterFrames),
        isTrue,
      );
      expect(
        host(bare).features.contains(PatchbayFeature.lifecycleState),
        isTrue,
      );
    });

    testWidgets('缺省 snapshot 是空 map，artifacts 的 blob 命令并进同一张表', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final PatchbayFlutterBridge bridge = _bridge(artifacts: true);
      addTearDown(bridge.dispose);

      final PatchbayServiceHost host = patchbayBuildFlutterServiceHost(
        applicationId: 'dev.patchbay.units',
        bridge: bridge,
        auditQueueCapacity: 8,
        maxConcurrentInvocations: 2,
        cancellationConfirmationTimeout: const Duration(seconds: 1),
      );

      expect((await host.dispatchSnapshot())['snapshotBytes'], 2);
      final List<Object?> commands =
          (await host.dispatchCatalog())['commands']! as List<Object?>;
      final List<String> names = <String>[
        for (final Object? command in commands)
          (command! as Map<String, Object?>)['name']! as String,
      ];
      expect(names, contains('blob.read'));
      expect(names, contains('ui.text.set'));
    });

    testWidgets('两种 catalog 源头至多给一个', (WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final PatchbayFlutterBridge bridge = _bridge();
      addTearDown(bridge.dispose);

      expect(
        () => patchbayBuildFlutterServiceHost(
          applicationId: 'dev.patchbay.units',
          bridge: bridge,
          domainCatalog: () async => const <String, Object?>{},
          domainCatalogProvider: _CountingCatalogProvider(),
          auditQueueCapacity: 8,
          maxConcurrentInvocations: 2,
          cancellationConfirmationTimeout: const Duration(seconds: 1),
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
