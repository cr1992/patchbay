/// 跨版本兼容用例：新 CLI ↔ 老 host、老 CLI ↔ 新 host。
///
/// 本仓的 CLI 和 host 是**分开部署**的：CLI 从终端装，host 跟着某个接入方发布的 App 走。
/// 已经有两个接入方，各自 pin 在不同 tag 上，所以「两边同版本」从来不是可依赖的前提。
///
/// 这份用例钉的就是那两个方向：
///
/// - **新 CLI ↔ 老 host**：拿 `test/golden/legacy_host_v0_2_0/` 里冻结的 0.2.0 语料喂给
///   当前 CLI。那些语料缺 `serverVersion` / `features` / `catalogDigest` / lifecycle
///   details，当前 CLI 必须照常给出完整诊断，并且把「读不到」说成 host 不上报，而不是
///   说成 App 状态未知。
/// - **老 CLI ↔ 新 host**：在这里**复刻** 0.2.0 客户端的读法（逐键读、多余键忽略、
///   `schemaVersion` 必须是 1），拿它去读当前 host 真的吐出来的东西。复刻而不是 import，
///   是因为要测的正是「当年那份代码」的行为，而当年那份代码已经不在树里了。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/src/artifact_download.dart';
import 'package:patchbay_cli/src/cli.dart';
import 'package:patchbay_cli/src/client.dart';
import 'package:patchbay_cli/src/doctor/doctor_checks.dart';
import 'package:patchbay_cli/src/doctor/doctor_models.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:patchbay_cli/src/session/session_models.dart';
import 'package:patchbay_cli/src/session/session_store.dart';
import 'package:patchbay_cli/src/session/workspace_identity.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

const String _legacyCorpus = 'test/golden/legacy_host_v0_2_0';
const String _compatibilityCorpusRoot = 'test/golden';

Map<String, Object?> _legacy(String name) =>
    jsonDecode(File('$_legacyCorpus/$name.json').readAsStringSync())
        as Map<String, Object?>;

List<Directory> _versionedCorpora() =>
    Directory(_compatibilityCorpusRoot)
        .listSync()
        .whereType<Directory>()
        .where((directory) {
          final String path = directory.path;
          return path
                  .split(Platform.pathSeparator)
                  .last
                  .startsWith('legacy_host_v') &&
              File('$path/identity.json').existsSync() &&
              File('$path/catalog.json').existsSync();
        })
        .toList(growable: false)
      ..sort((left, right) => left.path.compareTo(right.path));

/// 当前 host 真的吐出来的东西——不是手抄的一份「应该长这样」。
PatchbayServiceHost _currentHost() => PatchbayServiceHost(
  applicationId: 'dev.patchbay.current',
  appInstanceId: 'current-instance',
  registrar: (_, _) {},
  catalog: () async => <String, Object?>{
    'commands': <Object?>[
      <String, Object?>{'name': 'ui.semantics.tree', 'summary': 'tree'},
    ],
    'uiTargets': const <Object?>[],
  },
  snapshot: () async => const <String, Object?>{},
  invoke: (_, _, requestId) async => PatchbayInvocation.rejected(
    requestId: requestId,
    rejection: const PatchbayRejection(code: 'notRegistered'),
  ).toJson(),
  features: const <PatchbayFeature>{PatchbayFeature.lifecycleState},
);

/// 0.2.0 客户端读 identity 的方式：只认这四个键，其余一律不看。
///
/// 复刻自当年的 `PatchbayRuntimeIdentity.fromJson` 与
/// `PatchbayDirectClient._readIdentity`——两者都是逐键读，谁都没有用生成的严格解码器。
/// 这正是今天能往 identity 上加字段的全部依据。
({int schemaVersion, String applicationId, String appInstanceId})?
_readIdentityTheOldWay(Map<String, Object?> json) {
  final Object? schemaVersion = json['schemaVersion'];
  final Object? applicationId = json['applicationId'];
  final Object? appInstanceId = json['appInstanceId'];
  if (schemaVersion is! int ||
      applicationId is! String ||
      applicationId.isEmpty ||
      appInstanceId is! String ||
      appInstanceId.isEmpty) {
    return null;
  }
  return (
    schemaVersion: schemaVersion,
    applicationId: applicationId,
    appInstanceId: appInstanceId,
  );
}

/// 0.2.0 客户端每次 RPC 后的握手校验：`schemaVersion` 必须恰好是 1。
bool _acceptedByOldSchemaCheck(Map<String, Object?> response) =>
    response['schemaVersion'] == 1;

({String admission, Map<Object?, Object?> payload})? _readInvocationTheOldWay(
  Map<String, Object?> response,
) {
  final Object? admission = response['admission'];
  final Object? payload = response['payload'];
  if (response['schemaVersion'] != 1 ||
      admission is! String ||
      payload is! Map<Object?, Object?>) {
    return null;
  }
  return (admission: admission, payload: payload);
}

String _oldCanonicalJson(Object? value) {
  Object? canonical(Object? item) {
    if (item is Map<Object?, Object?>) {
      final List<MapEntry<String, Object?>> entries =
          <MapEntry<String, Object?>>[
            for (final MapEntry<Object?, Object?> entry in item.entries)
              MapEntry<String, Object?>('${entry.key}', canonical(entry.value)),
          ]..sort((a, b) => a.key.compareTo(b.key));
      return Map<String, Object?>.fromEntries(entries);
    }
    if (item is List<Object?>) {
      return <Object?>[for (final Object? child in item) canonical(child)];
    }
    return item;
  }

  return jsonEncode(canonical(value));
}

String _oldCommandsDigest(Object? commands) {
  final List<String> rows = <String>[
    if (commands is List<Object?>)
      for (final Object? row in commands) _oldCanonicalJson(row),
  ]..sort();
  return crypto.sha256.convert(utf8.encode('[${rows.join(',')}]')).toString();
}

String _oldDigestVerdict(Map<String, Object?> catalog) {
  final Object? raw = catalog['catalogDigest'];
  if (raw is! Map<Object?, Object?> ||
      raw['algorithm'] != 'sha256' ||
      raw['covers'] is! List<Object?>) {
    return 'unsupported';
  }
  final List<Object?> covers = raw['covers']! as List<Object?>;
  if (covers.length != 1 || covers.single != 'commands') return 'unsupported';
  return raw['value'] == _oldCommandsDigest(catalog['commands'])
      ? 'verified'
      : 'mismatched';
}

/// 0.2.0 客户端读 catalog 命令表的方式。
List<String> _readCommandsTheOldWay(Map<String, Object?> catalog) {
  final Object? rows = catalog['commands'];
  if (rows is! List<Object?>) return const <String>[];
  return <String>[
    for (final Object? row in rows)
      if (row is Map<Object?, Object?> && row['name'] is String)
        row['name']! as String,
  ];
}

final class _Run {
  const _Run(this.exitCode, this.out);

  final int exitCode;
  final String out;

  Map<String, Object?> get doctor =>
      (jsonDecode(out) as Map<String, Object?>)['doctor']!
          as Map<String, Object?>;

  List<Map<String, Object?>> get checks => <Map<String, Object?>>[
    for (final Object? check in doctor['checks']! as List<Object?>)
      check! as Map<String, Object?>,
  ];

  Map<String, Object?> check(String name) =>
      checks.firstWhere((Map<String, Object?> check) => check['check'] == name);

  Map<String, Object?> details(String name) =>
      (check(name)['details'] ?? const <String, Object?>{})
          as Map<String, Object?>;

  List<Map<String, Object?>> get warnings => <Map<String, Object?>>[
    for (final Object? warning in doctor['warnings']! as List<Object?>)
      warning! as Map<String, Object?>,
  ];
}

final PatchbayWorkspaceIdentity _workspace =
    PatchbayWorkspaceIdentity.current()!;

void main() {
  late Directory directory;
  late PatchbaySessionStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('patchbay-compat-');
    store = PatchbaySessionStore(directory.path);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<_Run> runDoctor(PatchbayClient client) async {
    final StringBuffer out = StringBuffer();
    final StringBuffer err = StringBuffer();
    final int exitCode = await runPatchbayCliWithSeams(
      <String>['--session-dir', directory.path, '--json', 'doctor'],
      connect: (ArgResults _) async => client,
      output: out,
      errorOutput: err,
    );
    return _Run(exitCode, out.toString());
  }

  PatchbaySessionRecord record() => PatchbaySessionRecord(
    sessionId: 'compat',
    applicationId: 'dev.patchbay.fixture',
    appInstanceId: null,
    isolateId: null,
    // 唯一能确定还活着的 PID 就是当前进程。
    processId: pid,
    wsUri: 'ws://127.0.0.1:1234/token=/ws',
    buildMode: 'debug',
    createdAt: DateTime.utc(2026, 8, 14),
    // doctor 走真 CLI，会话归属按 CLI 自己的 workspace 探测判定（PB-050-14），
    // 因此这条记录必须落在当前 checkout 内，否则本组测的是"选不出会话"而不是兼容性。
    workspacePath: _workspace.canonicalRoot,
    deviceId: 'device-1',
  ).withWorkspace(_workspace);

  group('新 CLI ↔ 老 host（冻结的 v0.2.0 语料）', () {
    FakePatchbayClient legacyClient() => FakePatchbayClient(
      identityData: _legacy('identity'),
      commands: <Map<String, Object?>>[
        for (final Object? row
            in _legacy('catalog')['commands']! as List<Object?>)
          Map<String, Object?>.from(row! as Map<Object?, Object?>),
      ],
      handle: (String command, _) async => _legacy('lifecycle_rejection'),
    );

    test('四项诊断照常跑完，没有一项因为缺字段而变成 skipped', () async {
      store.write(record());

      final _Run result = await runDoctor(legacyClient());

      expect(
        result.checks.map((Map<String, Object?> check) => check['check']),
        <String>['session', 'connection', 'catalog', 'lifecycle'],
      );
      expect(
        result.checks.map((Map<String, Object?> check) => check['verdict']),
        isNot(contains('skipped')),
      );
    });

    test('连接项照常通过，并说明这个 host 不报自己的版本', () async {
      store.write(record());

      final _Run result = await runDoctor(legacyClient());

      expect(result.check('connection')['verdict'], 'ok');
      expect(
        result.check('connection')['observed'],
        contains('does not report'),
      );
      expect(
        result.details('connection').containsKey('serverVersion'),
        isFalse,
      );
      // 没声明 ≠ 声明为空：老 host 这里必须是「键都没有」，不是空数组。
      expect(result.details('connection').containsKey('features'), isFalse);
    });

    test('lifecycle 缺 state 时说的是 host 不上报，而不是 App 状态未知', () async {
      store.write(record());

      final _Run result = await runDoctor(legacyClient());

      expect(result.check('lifecycle')['verdict'], 'failed');
      expect(
        result.details('lifecycle')['lifecycleStateSource'],
        patchbayLifecycleStateFeatureUndeclared,
      );
      expect(
        result.check('lifecycle')['observed'],
        contains('declares no lifecycle reporting'),
      );
      // 分平台解法照旧给全——降级只改措辞，不减诊断。
      expect(result.check('lifecycle')['action'], contains('KEYCODE_WAKEUP'));
    });

    test('catalog 没有摘要不算问题，也不生造一个', () async {
      store.write(record());

      final _Run result = await runDoctor(legacyClient());

      expect(result.check('catalog')['verdict'], 'ok');
      expect(result.details('catalog').containsKey('catalogDigest'), isFalse);
      expect(
        result.warnings.map((Map<String, Object?> w) => w['kind']),
        isNot(contains(patchbayCapabilityNotHonouredWarningKind)),
      );
    });
  });

  group('版本化兼容语料可被当前 CLI 读取', () {
    final List<Directory> corpora = _versionedCorpora();
    test('至少保留一个真实历史版本', () {
      expect(corpora, isNotEmpty);
    });
    for (final Directory corpus in corpora) {
      final String name = corpus.path.split(Platform.pathSeparator).last;
      test(name, () async {
        final Map<String, Object?> identity =
            jsonDecode(File('${corpus.path}/identity.json').readAsStringSync())
                as Map<String, Object?>;
        final Map<String, Object?> catalog =
            jsonDecode(File('${corpus.path}/catalog.json').readAsStringSync())
                as Map<String, Object?>;
        final List<Map<String, Object?>> commands = <Map<String, Object?>>[
          for (final Object? row in catalog['commands']! as List<Object?>)
            Map<String, Object?>.from(row! as Map<Object?, Object?>),
        ];
        final Map<String, Object?> extras = <String, Object?>{...catalog}
          ..remove('commands')
          ..remove('uiTargets');
        store.write(record());

        final _Run result = await runDoctor(
          FakePatchbayClient(
            identityData: identity,
            commands: commands,
            uiTargets:
                (catalog['uiTargets'] as List<Object?>?) ?? const <Object?>[],
            catalogExtras: extras,
            handle: (_, _) async => fakeCommandNotRegistered(),
          ),
        );

        expect(
          result.details('connection')['code'],
          isNot('identityValidationFailed'),
        );
        expect(result.check('catalog')['verdict'], isNot('failed'));
      });
    }
  });

  group('老 CLI ↔ 新 host（复刻 0.2.0 读法）', () {
    test('老读法仍然读得出 identity，多出来的字段被忽略', () {
      final Map<String, Object?> identity = _currentHost().identityResponse();

      expect(identity.keys, contains('serverVersion'));
      expect(identity.keys, contains('features'));

      final read = _readIdentityTheOldWay(identity);
      expect(read, isNotNull);
      expect(read!.applicationId, 'dev.patchbay.current');
      expect(read.appInstanceId, 'current-instance');
    });

    test('老 CLI 的 schemaVersion 握手校验仍然通过——加字段不是版本跳跃', () async {
      final PatchbayServiceHost host = _currentHost();

      expect(_acceptedByOldSchemaCheck(host.identityResponse()), isTrue);
      expect(_acceptedByOldSchemaCheck(await host.dispatchCatalog()), isTrue);
      expect(_acceptedByOldSchemaCheck(await host.dispatchSnapshot()), isTrue);
    });

    test('老读法读新 catalog 的命令表不受 catalogDigest 影响', () async {
      final Map<String, Object?> catalog = await _currentHost()
          .dispatchCatalog();

      expect(catalog.keys, contains('catalogDigest'));
      expect(_readCommandsTheOldWay(catalog), <String>['ui.semantics.tree']);
    });

    test('catalog digest coverage remains exactly commands', () async {
      final Map<String, Object?> catalog = await _currentHost()
          .dispatchCatalog();
      final Map<Object?, Object?> digest =
          catalog['catalogDigest']! as Map<Object?, Object?>;

      expect(digest['covers'], <String>['commands']);
    });

    test('old digest recursion includes unknown nested command fields', () {
      final List<Object?> commands = <Object?>[
        <String, Object?>{
          'name': 'fixture.command',
          'future': <String, Object?>{
            'nested': <Object?>[
              true,
              <String, Object?>{'answer': 42},
            ],
          },
        },
      ];

      expect(
        _oldCommandsDigest(commands),
        PatchbayCatalogDigest.ofCommands(commands).value,
      );
    });

    test('0.3 digest reader verifies 0.4 nested command contracts', () {
      final List<Object?> commands = <Object?>[
        <String, Object?>{
          'name': 'fixture.command',
          'responseSchema': <String, Object?>{
            'accepted': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'session': <String, Object?>{
                  'type': 'string',
                  'nullable': true,
                },
              },
              'required': <String>['session'],
              'additionalProperties': false,
            },
          },
          'retryPolicy': <String, Object?>{'maxAttempts': 2, 'backoffMs': 100},
        },
      ];
      final Map<String, Object?> catalog = <String, Object?>{
        'commands': commands,
        'catalogDigest': PatchbayCatalogDigest.ofCommands(commands).toJson(),
      };

      expect(_oldDigestVerdict(catalog), 'verified');
    });

    test('0.3 digest reader rejects an expanded covers list', () {
      const List<Object?> commands = <Object?>[];
      final Map<String, Object?> catalog = <String, Object?>{
        'commands': commands,
        'catalogDigest': <String, Object?>{
          ...PatchbayCatalogDigest.ofCommands(commands).toJson(),
          'covers': <String>['commands', 'responseSchemas'],
        },
      };

      expect(_oldDigestVerdict(catalog), 'unsupported');
    });

    test('0.3 digest reader transparently covers execution policy fields', () {
      const List<Object?> commands = <Object?>[
        <String, Object?>{
          'name': 'fixture.command',
          'factSources': <String>['deviceReported'],
          'confirmationBudgetMs': 5000,
          'unchangedEvidenceMaxAgeMs': 30000,
          'weakConfirmationCompletes': false,
        },
      ];
      final Map<String, Object?> catalog = <String, Object?>{
        'commands': commands,
        'catalogDigest': PatchbayCatalogDigest.ofCommands(commands).toJson(),
      };

      expect(_oldDigestVerdict(catalog), 'verified');
      expect(
        (catalog['catalogDigest']! as Map<Object?, Object?>)['covers'],
        <String>['commands'],
      );
    });

    test('0.3 invocation reader ignores the new schemaMode sibling', () async {
      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'dev.patchbay.schema-compat',
        catalog: () async => <String, Object?>{
          'commands': <Object?>[
            <String, Object?>{
              'name': 'fixture.typed',
              'responseSchema': <String, Object?>{
                'accepted': <String, Object?>{
                  'type': 'object',
                  'properties': <String, Object?>{
                    'ok': <String, Object?>{'type': 'boolean'},
                  },
                  'required': <String>['ok'],
                  'additionalProperties': false,
                },
              },
            },
          ],
        },
        snapshot: () async => const <String, Object?>{},
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          payload: const <String, Object?>{'ok': true},
        ).toJson(),
      );
      await host.dispatchCatalog();

      final Map<String, Object?> response = await host.dispatchInvoke(
        'fixture.typed',
        const <String, Object?>{},
        'compat-request',
      );

      expect(response['schemaMode'], 'validated');
      expect(_readInvocationTheOldWay(response)?.admission, 'accepted');
      expect(_readInvocationTheOldWay(response)?.payload, <String, Object?>{
        'ok': true,
      });
    });
  });

  group('0.4.1 reader ↔ 含 ui.reveal 的新 catalog 与新 payload（PB-050-17）', () {
    // reveal 是 0.5.0 才新增的顶层命令，0.4.1 的读法完全不认识它——这条锁的
    // 正是「不认识」不等于「读不下去」：catalog 的命令表逐键读，多一行不影响
    // 老读法认出既有命令；invocation 只逐键取 admission / payload 两个顶层
    // 键，payload 内部再冒出 containers / reachability 这类新字段一样被忽略。
    test('老读法从新 catalog 里也能读出 ui.reveal，既有命令不受影响', () async {
      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'dev.patchbay.reveal-compat',
        registrar: (_, _) {},
        catalog: () async => <String, Object?>{
          'commands': <Object?>[
            <String, Object?>{'name': 'ui.semantics.tree', 'summary': 'tree'},
            <String, Object?>{
              'name': 'ui.reveal',
              'summary': 'identifier 锚定的 scroll-to-reveal',
            },
          ],
          'uiTargets': const <Object?>[],
        },
        snapshot: () async => const <String, Object?>{},
        invoke: (_, _, requestId) async => PatchbayInvocation.rejected(
          requestId: requestId,
          rejection: const PatchbayRejection(code: 'notRegistered'),
        ).toJson(),
      );

      final Map<String, Object?> catalog = await host.dispatchCatalog();

      expect(_readCommandsTheOldWay(catalog), <String>[
        'ui.semantics.tree',
        'ui.reveal',
      ]);
    });

    Map<String, Object?> revealResponse(PatchbayRevealResultWire payload) =>
        PatchbayInvocation.accepted(
          requestId: 'reveal-compat',
          payload: payload.toJson(),
        ).toJson();

    test('老读法读 revealed payload：拿到 admission/payload，多出来的 '
        'containers/reachability 等新字段被忽略、不报错', () {
      final Map<String, Object?> response = revealResponse(
        const PatchbayRevealResultWire(
          outcome: 'revealed',
          source: PatchbayFactSourceWire.uiObserved,
          identifier: 'row.42',
          steps: 3,
          elapsedMs: 120,
          containers: <PatchbayRevealContainerWire>[
            PatchbayRevealContainerWire(
              nodeId: 7,
              generation: 1,
              steps: 3,
              direction: PatchbayRevealDirectionWire.forward,
              extentGrowthSteps: 0,
            ),
          ],
          nodeId: 42,
          generation: 2,
          reachability: PatchbayRevealReachabilityWire.pointer,
          beforeTreeRevision: 1,
          afterTreeRevision: 2,
          reason: null,
          failureType: null,
          gateId: null,
          gateCode: null,
        ),
      );

      final read = _readInvocationTheOldWay(response);
      expect(read, isNotNull);
      expect(read!.admission, 'accepted');
      expect(read.payload['outcome'], 'revealed');
      expect(read.payload['steps'], 3);
      expect(
        read.payload.containsKey('containers'),
        isTrue,
        reason: '老 reader 逐键取值时看得见这个键，只是不认识、用不上它',
      );
    });

    test('老 CLI 对 reveal 的 outcome: failed 得 typedFailure 退出码', () {
      final Map<String, Object?> response = revealResponse(
        const PatchbayRevealResultWire(
          outcome: 'failed',
          source: PatchbayFactSourceWire.uiObserved,
          identifier: 'row.42',
          steps: 40,
          elapsedMs: 900,
          containers: <PatchbayRevealContainerWire>[
            PatchbayRevealContainerWire(
              nodeId: 7,
              generation: 1,
              steps: 40,
              direction: PatchbayRevealDirectionWire.forward,
              extentGrowthSteps: 0,
            ),
          ],
          nodeId: null,
          generation: null,
          reachability: null,
          beforeTreeRevision: 1,
          afterTreeRevision: 3,
          reason: 'scrollExhausted',
          failureType: null,
          gateId: null,
          gateCode: null,
        ),
      );

      // patchbayExitCodeFor 是通用分类器：它按字段名走，不认命令名，所以老
      // CLI 未经任何改动就正确分类了一个它从未见过的命令的失败态。
      expect(patchbayExitCodeFor(response), PatchbayExitCode.typedFailure);
      expect(_readInvocationTheOldWay(response)?.payload['outcome'], 'failed');
    });

    test('rejected 的 reveal（如 uiRevealNoScrollableContainer）走既有 '
        'rejected 分支，不落进 typedFailure', () {
      final Map<String, Object?> response = PatchbayInvocation.rejected(
        requestId: 'reveal-compat-rejected',
        rejection: const PatchbayRejection(
          code: 'uiRevealNoScrollableContainer',
          details: <String, Object?>{'identifier': 'row.42'},
        ),
      ).toJson();

      expect(patchbayExitCodeFor(response), PatchbayExitCode.rejected);
    });

    test('PB-050-35 新增的两个 reveal 准入码同样落在既有 rejected 分支', () {
      // 拆码是收紧且 additive：分类器按信封形状走，不认码值，所以老 CLI 见到
      // 一个它从未听说过的 code 仍然正确分类，退出码不变。反过来，新 CLI 面对
      // 老 host 仍会收到合并后的 `uiRevealNoScrollableContainer`——那是 legacy
      // ambiguous，CLI 不转换码、也不自行猜测遮挡。
      for (final String code in <String>[
        'uiRevealTargetNotFound',
        'uiRevealTargetObscured',
      ]) {
        final Map<String, Object?> response = PatchbayInvocation.rejected(
          requestId: 'reveal-compat-$code',
          rejection: PatchbayRejection(
            code: code,
            details: const <String, Object?>{'identifier': 'row.42'},
          ),
        ).toJson();

        expect(
          patchbayExitCodeFor(response),
          PatchbayExitCode.rejected,
          reason: code,
        );
      }
    });
  });

  group('0.4.1 reader ↔ 带 origin 的新 localArtifact 回执', () {
    // PB-050-20 给回执加了 `origin`，并且**对既有 blob 路径同样写入**——
    // `capture` / `blob get` / `logs export` 的回执从此多一个键。多加一个键
    // 是不是 additive，取决于当年那份 reader 会不会因为看见没见过的键而失败；
    // 这里按仓内惯例**复刻**当年的读法，而不是 import 今天的实现。
    //
    // 0.4.1 的读法有两处：`patchbayResponseSummary` 逐键取 `path` / `length`
    // 并把 `verified` 当常量印出来；机器消费方按 `--json` 逐键取自己要的那几个。
    // 两者都不做键集合校验，这正是 additive 成立的全部依据。
    ({String path, int length, String sha256, String? blobId})?
    readLocalArtifactThe041Way(Map<String, Object?> response) {
      final Object? artifact = response['localArtifact'];
      if (artifact is! Map<Object?, Object?>) return null;
      final Object? path = artifact['path'];
      final Object? length = artifact['length'];
      final Object? digest = artifact['sha256'];
      if (path is! String || length is! int || digest is! String) return null;
      return (
        path: path,
        length: length,
        sha256: digest,
        blobId: artifact['blobId'] as String?,
      );
    }

    String summariseThe041Way(Map<String, Object?> response) {
      final Object? artifact = response['localArtifact'];
      if (artifact is! Map<Object?, Object?>) return '';
      return 'artifact=${artifact['path']} length=${artifact['length']} '
          'verified=true';
    }

    Map<String, Object?> responseWith(Map<String, Object?> receipt) =>
        <String, Object?>{
          'schemaVersion': 1,
          'requestId': 'compat-request',
          'admission': 'accepted',
          'payload': <String, Object?>{
            'blob': <String, Object?>{'blobId': 'blob-1'},
          },
          'localArtifact': receipt,
        };

    const String digestA =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const String digestB =
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const String digestC =
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

    test('老读法读今天的 hostBlob 回执：新增的 origin 键被忽略', () {
      final Map<String, Object?> response = responseWith(
        const PatchbayDownloadedArtifact(
          path: '/tmp/capture.png',
          blobId: 'blob-1',
          length: 12,
          sha256: digestA,
          contentType: 'image/png',
          origin: 'hostBlob',
        ).toJson(),
      );

      expect(
        (response['localArtifact']! as Map<String, Object?>).keys,
        contains('origin'),
        reason: '前提：新回执确实带上了这个老 reader 没见过的键',
      );
      final read = readLocalArtifactThe041Way(response);
      expect(read, isNotNull);
      expect(read!.path, '/tmp/capture.png');
      expect(read.length, 12);
      expect(read.blobId, 'blob-1');
      expect(
        summariseThe041Way(response),
        'artifact=/tmp/capture.png length=12 verified=true',
        reason: '0.4.1 的人读行逐字不变',
      );
    });

    test('老读法读 cliRendered 回执：没有 blobId 也不炸，只是读不到 blob', () {
      // 老 reader 没有 `cliRendered` 这个概念，但它对回执的用法是「按路径取
      // 文件」，而这条路径同样是本机绝对路径、同样已按 sha256 校验过。缺
      // `blobId` 只影响「回头再向 host 要一次」这类用法，那是 blob 路径独有的；
      // 树类载荷本来就没有 host blob 可要——不编造一个正是这条的用意。
      final Map<String, Object?> response = responseWith(
        const PatchbayDownloadedArtifact(
          path: '/tmp/ui-semantics-tree.json',
          blobId: null,
          length: 812345,
          sha256: digestB,
          contentType: 'application/json',
          origin: 'cliRendered',
        ).toJson(),
      );

      final read = readLocalArtifactThe041Way(response);
      expect(read, isNotNull);
      expect(read!.path, '/tmp/ui-semantics-tree.json');
      expect(read.length, 812345);
      expect(read.blobId, isNull);
      expect(
        summariseThe041Way(response),
        'artifact=/tmp/ui-semantics-tree.json length=812345 verified=true',
      );
    });

    test('additive 的另一半：既有键的值一个都没被改动', () {
      const PatchbayDownloadedArtifact artifact = PatchbayDownloadedArtifact(
        path: '/tmp/logs.ndjson',
        blobId: 'blob-2',
        length: 7,
        sha256: digestC,
        contentType: 'application/x-ndjson',
        origin: 'hostBlob',
      );
      final Map<String, Object?> withoutOrigin = <String, Object?>{
        ...artifact.toJson(),
      }..remove('origin');

      expect(withoutOrigin, <String, Object?>{
        'path': '/tmp/logs.ndjson',
        'blobId': 'blob-2',
        'length': 7,
        'sha256': digestC,
        'contentType': 'application/x-ndjson',
        'verified': true,
      }, reason: '去掉 origin 之后必须与 0.4.1 的回执逐键相同');
    });
  });

  group('更新的 host ↔ 当前 CLI', () {
    Map<String, Object?> modernIdentity({
      List<String> features = const <String>['catalogDigest', 'lifecycleState'],
      String serverVersion = '9.9.9',
    }) => <String, Object?>{
      ..._legacy('identity'),
      'serverVersion': serverVersion,
      'features': features,
    };

    test('报出 host 版本与它声明的能力', () async {
      store.write(record());

      final _Run result = await runDoctor(
        FakePatchbayClient(
          identityData: modernIdentity(),
          commands: const <Map<String, Object?>>[],
          handle: (_, _) async => fakeCommandNotRegistered(),
          catalogExtras: <String, Object?>{
            'catalogDigest': PatchbayCatalogDigest.ofCommands(
              const <Object?>[],
            ).toJson(),
          },
        ),
      );

      expect(
        result.check('connection')['observed'],
        contains('patchbay 9.9.9'),
      );
      expect(result.details('connection')['serverVersion'], '9.9.9');
      expect(result.details('connection')['features'], <String>[
        'catalogDigest',
        'lifecycleState',
      ]);
    });

    test('没见过的能力名不炸，如实转述', () async {
      store.write(record());

      final _Run result = await runDoctor(
        FakePatchbayClient(
          identityData: modernIdentity(
            features: const <String>['catalogDigest', 'timeTravel'],
          ),
          commands: const <Map<String, Object?>>[],
          handle: (_, _) async => fakeCommandNotRegistered(),
          catalogExtras: <String, Object?>{
            'catalogDigest': PatchbayCatalogDigest.ofCommands(
              const <Object?>[],
            ).toJson(),
          },
        ),
      );

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(result.details('connection')['features'], contains('timeTravel'));
    });

    test('摘要与内容对得上时标 verified', () async {
      store.write(record());
      const List<Map<String, Object?>> commands = <Map<String, Object?>>[
        <String, Object?>{'name': 'domain.ping', 'summary': 'ping'},
      ];

      final _Run result = await runDoctor(
        FakePatchbayClient(
          identityData: modernIdentity(),
          commands: commands,
          handle: (_, _) async => fakeCommandNotRegistered(),
          catalogExtras: <String, Object?>{
            'catalogDigest': PatchbayCatalogDigest.ofCommands(
              commands,
            ).toJson(),
          },
        ),
      );

      expect(result.details('catalog')['catalogDigestCheck'], 'verified');
    });

    test('摘要与内容对不上时标 mismatched——不照抄 host 的说法', () async {
      store.write(record());

      final _Run result = await runDoctor(
        FakePatchbayClient(
          identityData: modernIdentity(),
          commands: const <Map<String, Object?>>[
            <String, Object?>{'name': 'domain.ping', 'summary': 'ping'},
          ],
          handle: (_, _) async => fakeCommandNotRegistered(),
          catalogExtras: <String, Object?>{
            'catalogDigest': PatchbayCatalogDigest.ofCommands(
              const <Object?>[],
            ).toJson(),
          },
        ),
      );

      expect(result.details('catalog')['catalogDigestCheck'], 'mismatched');
      expect(
        result.details('catalog')['catalogDigestRecomputed'],
        isA<String>(),
      );
    });

    test('算法或覆盖范围超出本版认知时标 unsupported，而不是 mismatched', () async {
      store.write(record());

      final _Run result = await runDoctor(
        FakePatchbayClient(
          identityData: modernIdentity(),
          commands: const <Map<String, Object?>>[],
          handle: (_, _) async => fakeCommandNotRegistered(),
          catalogExtras: const <String, Object?>{
            'catalogDigest': <String, Object?>{
              'algorithm': 'blake3',
              'covers': <String>['commands', 'uiTargets'],
              'value': '00',
            },
          },
        ),
      );

      expect(result.details('catalog')['catalogDigestCheck'], 'unsupported');
      expect(result.details('catalog')['catalogDigestAlgorithm'], 'blake3');
    });

    test('covers 混进非字符串时报 unsupported，不因为「算出来一样」就说 verified', () async {
      store.write(record());
      const List<Map<String, Object?>> commands = <Map<String, Object?>>[
        <String, Object?>{'name': 'domain.ping', 'summary': 'ping'},
      ];

      final _Run result = await runDoctor(
        FakePatchbayClient(
          identityData: modernIdentity(),
          commands: commands,
          handle: (_, _) async => fakeCommandNotRegistered(),
          catalogExtras: <String, Object?>{
            'catalogDigest': <String, Object?>{
              'algorithm': patchbayDigestAlgorithmSha256,
              // 这个 host 的覆盖面比本版认得的多一项，且那一项本版根本读不懂。
              'covers': <Object?>[patchbayCatalogDigestScopeCommands, 42],
              // 值恰好等于「只对 commands」算出来的那个。所以一旦把读不懂的那项
              // 悄悄丢掉，CLI 会算出一模一样的数，然后自信地说 verified——
              // 「让客户端相信 host 没说过的话」正是这套东西要防的那一件事。
              'value': PatchbayCatalogDigest.ofCommands(commands).value,
            },
          },
        ),
      );

      expect(result.details('catalog')['catalogDigestCheck'], 'unsupported');
      // 摘要是「验不了」而不是「没有」，所以不能顺手报成能力失约。
      expect(
        result.warnings.map((Map<String, Object?> w) => w['kind']),
        isNot(contains(patchbayCapabilityNotHonouredWarningKind)),
      );
    });

    test('声明了 catalogDigest 却不带，报「能力失约」', () async {
      store.write(record());

      final _Run result = await runDoctor(
        FakePatchbayClient(
          identityData: modernIdentity(),
          commands: const <Map<String, Object?>>[],
          handle: (_, _) async => fakeCommandNotRegistered(),
        ),
      );

      // 失约是要归档的 host bug，不是停止调试的理由：退出码仍是 0。
      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(
        result.warnings.map((Map<String, Object?> w) => w['kind']),
        contains(patchbayCapabilityNotHonouredWarningKind),
      );
    });

    test('声明了 lifecycleState 却不带，说的是 host 失约而不是老 host', () {
      final PatchbayDoctorFinding finding = patchbayLifecycleFinding(
        _legacy('lifecycle_rejection'),
        identity: modernIdentity(),
      );

      expect(
        finding.details['lifecycleStateSource'],
        patchbayLifecycleStateNotHonoured,
      );
      expect(finding.observed, contains('host bug'));
    });

    test('protocol-owned 字段类型不对时点名，而不是当成「没上报」', () {
      final PatchbayDoctorFinding finding = patchbayIdentityFinding(
        <String, Object?>{..._legacy('identity'), 'serverVersion': 7},
      );

      expect(finding.verdict, PatchbayCheckVerdict.warning);
      expect(finding.details['code'], 'identityValidationFailed');
    });
  });
}
