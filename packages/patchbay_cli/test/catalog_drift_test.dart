import 'dart:convert';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/src/cli.dart';
import 'package:patchbay_cli/src/client.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:test/test.dart';

/// The rejection envelope a host serves in place of a catalog it refuses.
///
/// Copied from the shape `PatchbayServiceHost` produces for an invalid command
/// name: it deliberately has no `commands` key, which is why the CLI cannot
/// find the command it was asked to run.
Map<String, Object?> _violatedCatalog() => <String, Object?>{
  'schemaVersion': 1,
  'admission': 'rejected',
  'rejection': <String, Object?>{
    'code': 'providerProtocolViolation',
    'details': _violation(),
  },
};

Map<String, Object?> _violation() => <String, Object?>{
  'reason': 'invalidCatalogCommands',
  'commandNamePattern': r'^[a-z][A-Za-z0-9]*(?:\.[a-z][A-Za-z0-9]*)+$',
  'violations': <Object?>[
    <String, Object?>{
      'index': 0,
      'name': 'auth.switch-tenant',
      'reason': 'invalidCommandName',
    },
  ],
};

/// A client whose catalog is refused and whose invoke answers the same way the
/// host does for a request it could not police.
final class _ViolatedCatalogClient implements PatchbayClient {
  _ViolatedCatalogClient({required this.repeatsViolationInInvoke});

  final bool repeatsViolationInInvoke;

  @override
  Future<Map<String, Object?>> catalog() async => _violatedCatalog();

  @override
  Future<Map<String, Object?>> invoke({
    required String command,
    required Map<String, Object?> arguments,
    String? requestId,
    Duration? deadline,
  }) async => <String, Object?>{
    'schemaVersion': 1,
    'requestId': requestId ?? 'drift-request',
    'admission': 'rejected',
    'rejection': <String, Object?>{
      'code': 'providerProtocolViolation',
      'details': <String, Object?>{
        'reason': 'catalogUnavailable',
        if (repeatsViolationInInvoke) 'catalog': _violation(),
      },
    },
  };

  @override
  Future<Map<String, Object?>> identity() async => <String, Object?>{};

  @override
  Future<Map<String, Object?>> snapshot({
    PatchbaySnapshotRequest? request,
  }) async => <String, Object?>{};

  @override
  Future<Map<String, Object?>> widgetTree() async => <String, Object?>{};

  @override
  Future<Map<String, Object?>> renderTree() async => <String, Object?>{};

  @override
  Future<Map<String, Object?>> focusTree() async => <String, Object?>{};

  @override
  Future<void> close() async {}
}

Future<Map<String, Object?>> _runExec(PatchbayClient client) async {
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  final int exitCode = await runPatchbayCliWithSeams(
    <String>['--json', 'exec', 'auth.tenant.switch'],
    connect: (_) async => client,
    output: out,
    errorOutput: err,
  );
  expect(exitCode, PatchbayExitCode.protocol, reason: err.toString());
  return (jsonDecode(out.toString()) as Map<String, Object?>)['error']!
      as Map<String, Object?>;
}

void main() {
  test('catalogInvocationDrift carries the host catalog violation', () async {
    final Map<String, Object?> error = await _runExec(
      _ViolatedCatalogClient(repeatsViolationInInvoke: true),
    );

    expect(error['code'], 'catalogInvocationDrift');
    final Map<String, Object?> details =
        error['details']! as Map<String, Object?>;
    expect(details['command'], 'auth.tenant.switch');
    expect(details['rejection'], 'providerProtocolViolation');
    expect(details['reason'], 'catalogUnavailable');
    // The whole point: the name the host refused reaches the operator without
    // a second round trip to `patchbay catalog`.
    final Map<String, Object?> catalog =
        details['catalog']! as Map<String, Object?>;
    expect(catalog['reason'], 'invalidCatalogCommands');
    expect(jsonEncode(catalog['violations']), contains('auth.switch-tenant'));
  });

  test(
    'falls back to the catalog read when invoke does not repeat it',
    () async {
      final Map<String, Object?> error = await _runExec(
        _ViolatedCatalogClient(repeatsViolationInInvoke: false),
      );

      final Map<String, Object?> details =
          error['details']! as Map<String, Object?>;
      final Map<String, Object?> catalog =
          details['catalog']! as Map<String, Object?>;
      expect(catalog['reason'], 'invalidCatalogCommands');
    },
  );
}
