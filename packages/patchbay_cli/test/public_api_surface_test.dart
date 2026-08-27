// PB-050-13 / DG-050-07 的公共 API 契约测试。
//
// 这是包内唯一允许 import 两个公开 library 的测试文件（另一个允许方是 pub 的
// `example/`，它就是给使用者看的公共面示例）。正向部分靠**自身能编译**证明清单
// 里的符号都在；负向部分把源码写进 `.dart_tool/`（包自身的 analyze 不扫那里）再
// 单独跑一次 `dart analyze`，证明清单外的符号确实不存在——不是"应该不在"，是
// 编译器拒绝。
import 'dart:io';

import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:patchbay_cli/patchbay_client.dart';
import 'package:test/test.dart';

/// canonical library 的正向 fixture：整个入口就是这两个符号。
///
/// 静态类型写死是这里的重点：`runPatchbayCli` 收窄成一元函数后，任何把 0.4.1 的
/// `connect` / `output` / `replInput` seam 加回去的改动都会让这一行不再赋值成功。
const Future<int> Function(List<String> arguments) _entryPoint = runPatchbayCli;

const int _acceptedExitCode = PatchbayExitCode.accepted;

/// client library 的正向 fixture：8 个符号逐个被构造或引用。
final class _FixtureClient
    implements PatchbayClient, PatchbaySnapshotDiffClient {
  @override
  Future<Map<String, Object?>> identity() async => const <String, Object?>{};
  @override
  Future<Map<String, Object?>> catalog() async => const <String, Object?>{};
  @override
  Future<Map<String, Object?>> snapshot({
    PatchbaySnapshotRequest? request,
  }) async => <String, Object?>{'path': request?.path};
  @override
  Future<Map<String, Object?>> snapshotDiff({
    required int fromRevision,
  }) async => <String, Object?>{'from': fromRevision};
  @override
  Future<Map<String, Object?>> invoke({
    required String command,
    required Map<String, Object?> arguments,
    String? requestId,
    Duration? deadline,
  }) async => <String, Object?>{'command': command};
  @override
  Future<Map<String, Object?>> widgetTree() async => const <String, Object?>{};
  @override
  Future<Map<String, Object?>> renderTree() async => const <String, Object?>{};
  @override
  Future<Map<String, Object?>> focusTree() async => const <String, Object?>{};
  @override
  Future<void> close() async {}
}

void main() {
  test('canonical library exposes exactly the entry point and its codes', () {
    expect(_entryPoint, isNotNull);
    expect(_acceptedExitCode, 0);
    // The other frozen codes, referenced so a removal is a compile failure
    // rather than a silently narrower contract.
    expect(
      <int>[
        PatchbayExitCode.transport,
        PatchbayExitCode.protocol,
        PatchbayExitCode.rejected,
        PatchbayExitCode.typedFailure,
        PatchbayExitCode.verificationDeviation,
        PatchbayExitCode.usage,
      ],
      <int>[3, 4, 5, 6, 7, 64],
    );
  });

  test(
    'client library constructs or references each of its eight symbols',
    () async {
      // 1 + 2: the two client interfaces are implementable from outside.
      final PatchbayClient client = _FixtureClient();
      expect(client, isA<PatchbaySnapshotDiffClient>());

      // 3: the identity type a caller compares a handshake against.
      const PatchbayRuntimeIdentity identity = PatchbayRuntimeIdentity(
        schemaVersion: 1,
        applicationId: 'com.example.app',
        appInstanceId: 'instance-1',
        isolateId: 'isolates/1',
      );
      expect(identity.applicationId, 'com.example.app');

      // 4 + 5: the two failure classes a caller has to catch by type.
      expect(
        const PatchbayProtocolException('identityValidationFailed').code,
        'identityValidationFailed',
      );
      expect(
        const PatchbayTransportException('appUnresponsive').code,
        'appUnresponsive',
      );

      // 6: re-exported from `patchbay`, and it must arrive through *this*
      // library — a caller of the client surface may not be forced to add a
      // second dependency just to name a request.
      final PatchbaySnapshotRequest request = PatchbaySnapshotRequest(
        path: 'call.session',
      );
      expect((await client.snapshot(request: request))['path'], 'call.session');

      // 7: the direct factory really constructs, without dialling anything.
      final PatchbayClient direct = connectPatchbayDirect(
        endpoint: Uri.parse('http://127.0.0.1:1/patchbay/direct/v1'),
        bearerToken: 'fixture-token',
        schemaVersion: 1,
        applicationId: 'com.example.app',
        appInstanceId: 'instance-1',
      );
      expect(direct, isA<PatchbaySnapshotDiffClient>());
      await direct.close();

      // 8: referenced with its exact static type; calling it would dial a VM.
      const Future<PatchbayClient> Function(
        Uri serviceUri, {
        PatchbayRuntimeIdentity? expectedIdentity,
      })
      vmService = connectPatchbayVmService;
      expect(vmService, isNotNull);
    },
  );

  test('removed root symbols are gone, not forwarded or aliased', () async {
    final _Analysis analysis = await _analyzeFixture('canonical_negative', '''
import 'package:patchbay_cli/patchbay_cli.dart';

Future<void> main() async {
  // Executable internals that used to ride the root barrel.
  PatchbaySessionStore('/tmp');
  PatchbayLauncherSupervisor(store: null);
  PatchbayTraceStore('/tmp');
  PatchbayCommandHelp.usageLine();
  PatchbayFriendlyCommandRegistry.commands;
  patchbayCliParser();
  // The client surface deliberately does not live here either.
  PatchbayClient c;
  PatchbayConnection.connect(Uri.parse('ws://127.0.0.1:1/ws'));
  // And the 0.4.1 test seams are no longer part of the function.
  await runPatchbayCli(const <String>['--help'], output: null);
}
''');

    expect(analysis.exitCode, isNot(0));
    for (final String symbol in const <String>[
      'PatchbaySessionStore',
      'PatchbayLauncherSupervisor',
      'PatchbayTraceStore',
      'PatchbayCommandHelp',
      'PatchbayFriendlyCommandRegistry',
      'patchbayCliParser',
      'PatchbayClient',
      'PatchbayConnection',
      'output',
    ]) {
      expect(
        analysis.output,
        contains(symbol),
        reason: '$symbol must fail to resolve through the canonical library',
      );
    }
  });

  test('the client library refuses a ninth symbol', () async {
    final _Analysis analysis = await _analyzeFixture('client_negative', '''
import 'package:patchbay_cli/patchbay_client.dart';

void main() {
  // Connection classes, the timeout wrapper, the cancellation and profiling
  // seams: every one of them is what the two factories exist to hide.
  PatchbayConnection.connect(Uri.parse('ws://127.0.0.1:1/ws'));
  PatchbayDirectConnection(
    endpoint: Uri.parse('http://127.0.0.1:1/patchbay/direct/v1'),
    bearerToken: 't',
    schemaVersion: 1,
    applicationId: 'a',
    appInstanceId: 'i',
  );
  PatchbayTimeoutClient(null, rpcTimeout: Duration.zero);
  PatchbayCancelableInvocationClient c;
  PatchbayProfilingClient p;
  patchbayCliRequestId('vm');
}
''');

    expect(analysis.exitCode, isNot(0));
    for (final String symbol in const <String>[
      'PatchbayConnection',
      'PatchbayDirectConnection',
      'PatchbayTimeoutClient',
      'PatchbayCancelableInvocationClient',
      'PatchbayProfilingClient',
      'patchbayCliRequestId',
    ]) {
      expect(
        analysis.output,
        contains(symbol),
        reason: '$symbol must stay inside src/',
      );
    }
  });

  test('nothing but the public-API consumers imports a public library', () {
    // `example/` is the pub.dev entry a reader is shown as "how to use this
    // package", so it must demonstrate the public library rather than `src/`.
    // Everything else in the package imports what it actually needs.
    const Set<String> allowed = <String>{
      'example/patchbay_cli_example.dart',
      'test/public_api_surface_test.dart',
    };
    final List<String> offenders = <String>[];
    for (final FileSystemEntity entity in Directory.current.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String relative = entity.path
          .substring(Directory.current.path.length + 1)
          .replaceAll(r'\', '/');
      if (relative.startsWith('.dart_tool/')) continue;
      final String text = entity.readAsStringSync();
      final bool imports =
          text.contains("import 'package:patchbay_cli/patchbay_cli.dart'") ||
          text.contains("import 'package:patchbay_cli/patchbay_client.dart'");
      if (imports && !allowed.contains(relative)) offenders.add(relative);
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'the public libraries are a compatibility promise, not a shortcut '
          'for reaching this package\'s own implementation',
    );
  });
}

final class _Analysis {
  const _Analysis(this.exitCode, this.output);

  final int exitCode;
  final String output;
}

/// Analyzes [source] as a standalone file that may only see the public
/// libraries.
///
/// It is written under `.dart_tool/` on purpose: package resolution still finds
/// `package:patchbay_cli/…` (the analyzer walks up to this package's own
/// `package_config.json`), while the package's own `dart analyze` never
/// descends into it — so a fixture that must not compile cannot turn the
/// repository's analyze gate red.
Future<_Analysis> _analyzeFixture(String name, String source) async {
  final Directory root = Directory(
    '${Directory.current.path}/.dart_tool/patchbay_public_api/$name',
  )..createSync(recursive: true);
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  final File file = File('${root.path}/fixture.dart')
    ..writeAsStringSync(source);
  final ProcessResult result = await Process.run(
    Platform.resolvedExecutable,
    <String>['analyze', file.path],
    workingDirectory: Directory.current.path,
  );
  return _Analysis(result.exitCode, '${result.stdout}\n${result.stderr}');
}
