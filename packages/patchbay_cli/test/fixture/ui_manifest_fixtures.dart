import 'dart:convert';
import 'dart:io';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

import 'fake_client.dart';

Map<String, Object?> targetFixture(
  String id, {
  PatchbayUiTargetKind kind = PatchbayUiTargetKind.text,
  bool mounted = true,
  bool sensitive = false,
  bool ambiguous = false,
  int generation = 1,
}) => PatchbayUiTargetDescriptor(
  id: id,
  generation: generation,
  kind: kind,
  mounted: mounted,
  ambiguous: ambiguous,
  operations: const <PatchbayUiOperation>{},
  operationGates: const <PatchbayUiOperation, Set<String>>{},
  sensitivePolicy: sensitive
      ? PatchbaySensitivePolicy.redacted
      : PatchbaySensitivePolicy.public,
  sideEffect: PatchbaySideEffect.appState,
).toJson();

Map<String, Object?> targetWire(
  String id, {
  PatchbayUiTargetKind kind = PatchbayUiTargetKind.text,
  bool mounted = true,
  bool sensitive = false,
  bool ambiguous = false,
  int generation = 1,
}) => targetFixture(
  id,
  kind: kind,
  mounted: mounted,
  sensitive: sensitive,
  ambiguous: ambiguous,
  generation: generation,
);


Map<String, Object?> semanticsNodeFixture(
  int nodeId, {
  required int generation,
  required String identifier,
  int? parentNodeId,
  int depth = 0,
  List<int> children = const <int>[],
}) => <String, Object?>{
  'nodeId': nodeId,
  'generation': generation,
  'parentNodeId': parentNodeId,
  'depth': depth,
  'identifier': identifier,
  'label': '',
  'flags': <Object?>[],
  'actions': <Object?>[],
  'invisible': false,
  'userActionsBlocked': false,
  'rect': <String, Object?>{'left': 0, 'top': 0, 'width': 1, 'height': 1},
  'rectCoordinateSpace': 'globalLogicalPixels',
  'children': children,
};

Map<String, Object?> semanticsPayloadFixture(
  List<Map<String, Object?>> nodes, {
  int treeRevision = 1,
  bool truncated = false,
}) => <String, Object?>{
  'outcome': 'observed',
  'source': 'uiObserved',
  'treeRevision': treeRevision,
  'rootNodeId': nodes.isEmpty ? 0 : nodes.first['nodeId'],
  'truncated': truncated,
  'nodeCount': nodes.length,
  'nodes': nodes,
};

FakePatchbayClient clientFixture({
  List<Object?> uiTargets = const <Object?>[],
  String? destination,
  bool navigationCataloged = true,
  Map<String, Object?>? navigationResponse,
  Map<String, Object?>? semanticsPayload,
}) => FakePatchbayClient(
  commands: <Map<String, Object?>>[
    if (navigationCataloged)
      const <String, Object?>{'name': 'navigation.current'},
    if (semanticsPayload != null)
      const <String, Object?>{'name': 'ui.semantics.tree'},
  ],
  uiTargets: uiTargets,
  handle: (String command, Map<String, Object?> arguments) async {
    if (command == 'ui.semantics.tree' && semanticsPayload != null) {
      return fakeAccepted(semanticsPayload);
    }
    if (command != 'navigation.current' || !navigationCataloged) {
      return fakeCommandNotRegistered();
    }
    return navigationResponse ??
        fakeAccepted(<String, Object?>{
          'outcome': 'observed',
          'source': 'appRecorded',
          'navigationRevision': 3,
          'destinationId': destination,
        });
  },
);

typedef CliRun = ({int exitCode, String stdout, String stderr});

Future<CliRun> runManifestCli(
  FakePatchbayClient client,
  String manifest, {
  bool json = true,
  String extension = '.json',
}) async {
  final Directory directory = Directory.systemTemp.createTempSync(
    'patchbay-manifest',
  );
  addTearDown(() => directory.deleteSync(recursive: true));
  final File file = File('${directory.path}/targets$extension')
    ..writeAsStringSync(manifest);
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  final int exitCode = await runPatchbayCli(
    <String>[if (json) '--json', 'ui', 'verify-manifest', file.path],
    connect: (_) async => client,
    output: out,
    errorOutput: err,
  );
  return (exitCode: exitCode, stdout: out.toString(), stderr: err.toString());
}

Future<CliRun> emitManifestCli(
  FakePatchbayClient client, {
  bool json = true,
}) async {
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  final int exitCode = await runPatchbayCli(
    <String>[if (json) '--json', 'ui', 'targets', '--emit-manifest'],
    connect: (_) async => client,
    output: out,
    errorOutput: err,
  );
  return (exitCode: exitCode, stdout: out.toString(), stderr: err.toString());
}

Map<String, Object?> reportOf(CliRun run) =>
    jsonDecode(run.stdout) as Map<String, Object?>;

List<Object?> groupOf(CliRun run, String name) =>
    reportOf(run)[name]! as List<Object?>;

Map<String, Object?> statsOf(CliRun run) =>
    reportOf(run)['stats']! as Map<String, Object?>;

File exampleManifestFile() {
  Directory directory = Directory.current.absolute;
  while (true) {
    final File candidate = File(
      '${directory.path}/docs/examples/ui-targets-manifest.json',
    );
    if (candidate.existsSync()) return candidate;
    final Directory parent = directory.parent;
    if (parent.path == directory.path) {
      fail('docs/examples/ui-targets-manifest.json was not found');
    }
    directory = parent;
  }
}
