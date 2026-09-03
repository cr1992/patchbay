import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay/patchbay_protocol.dart';
import 'package:patchbay_cli/src/artifact_download.dart';
import 'package:patchbay_cli/src/cli.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

/// A host whose blob store accepts chunks no larger than [maxChunkBytes].
///
/// The store is the real one, so `blobInvalidChunkLimit` comes from the same
/// code a consumer's App runs — a fake that merely echoed bytes back would
/// never have shown the mismatch this test exists for.
FakePatchbayClient _client({
  required int maxChunkBytes,
  bool declareLimit = true,
}) {
  final PatchbayMemoryBlobStore blobs = PatchbayMemoryBlobStore(
    maxChunkBytes: maxChunkBytes,
    idFactory: () => 'fixture-blob',
  );
  final PatchbayBlobMetadataWire metadata = blobs.put(
    Uint8List.fromList(utf8.encode(List<String>.filled(400, 'chunk').join())),
    kind: PatchbayBlobSourceWire.logExport,
    source: PatchbayFactSourceWire.appRecorded,
    contentType: 'application/octet-stream',
    filename: 'fixture.bin',
  );
  return FakePatchbayClient(
    commands: <Map<String, Object?>>[
      <String, Object?>{'name': 'blob.metadata'},
      <String, Object?>{
        'name': 'blob.read',
        'parameters': <Object?>[
          <String, Object?>{
            'name': 'blobId',
            'type': 'string',
            'required': true,
          },
          <String, Object?>{
            'name': 'offset',
            'type': 'integer',
            'required': true,
          },
          <String, Object?>{
            'name': 'limit',
            'type': 'integer',
            if (declareLimit) 'defaultValue': maxChunkBytes,
          },
        ],
      },
    ],
    handle: (String command, Map<String, Object?> arguments) async {
      try {
        return switch (command) {
          'blob.metadata' => fakeAccepted(metadata.toJson()),
          'blob.read' => fakeAccepted(
            blobs
                .read(
                  blobId: arguments['blobId']! as String,
                  offset: arguments['offset']! as int,
                  limit: arguments['limit']! as int,
                )
                .toJson(),
          ),
          _ => fakeCommandNotRegistered(),
        };
      } on PatchbayBlobFailure catch (failure) {
        return <String, Object?>{
          'admission': 'rejected',
          'rejection': <String, Object?>{
            'code': 'blobInvalidChunkLimit',
            'details': <String, Object?>{'failure': failure.code.name},
          },
        };
      }
    },
  );
}

Future<({int exitCode, FakePatchbayClient client, String err})> _download(
  FakePatchbayClient client,
  String outputPath,
) async {
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  final int exitCode = await runPatchbayCliWithSeams(
    <String>['--json', '--output', outputPath, 'blob', 'get', 'fixture-blob'],
    connect: (_) async => client,
    output: out,
    errorOutput: err,
  );
  return (exitCode: exitCode, client: client, err: err.toString());
}

void main() {
  late Directory directory;

  setUp(
    () => directory = Directory.systemTemp.createTempSync('patchbay-chunk-'),
  );
  tearDown(() => directory.deleteSync(recursive: true));

  test('a host with a smaller chunk ceiling can still be downloaded', () async {
    // 4 KiB is a perfectly legal `maxChunkBytes`; the CLI used to ask for a
    // hardcoded 64 KiB and have every chunk refused.
    final result = await _download(
      _client(maxChunkBytes: 4096),
      '${directory.path}/artifact.bin',
    );

    expect(result.exitCode, PatchbayExitCode.accepted, reason: result.err);
    expect(File('${directory.path}/artifact.bin').lengthSync(), 2000);
    final Iterable<Object?> limits = result.client.calls
        .where((FakeInvocation call) => call.command == 'blob.read')
        .map((FakeInvocation call) => call.arguments['limit']);
    expect(limits, isNotEmpty);
    expect(limits, everyElement(4096));
  });

  test('a host that declares no limit keeps the CLI default', () async {
    final result = await _download(
      _client(maxChunkBytes: 64 * 1024, declareLimit: false),
      '${directory.path}/artifact.bin',
    );

    expect(result.exitCode, PatchbayExitCode.accepted, reason: result.err);
    expect(
      result.client.calls
          .where((FakeInvocation call) => call.command == 'blob.read')
          .map((FakeInvocation call) => call.arguments['limit']),
      everyElement(PatchbayArtifactDownloader.defaultChunkBytes),
    );
  });

  test('a larger declared ceiling does not enlarge the request', () async {
    final result = await _download(
      _client(maxChunkBytes: 1024 * 1024),
      '${directory.path}/artifact.bin',
    );

    expect(result.exitCode, PatchbayExitCode.accepted, reason: result.err);
    expect(
      result.client.calls
          .where((FakeInvocation call) => call.command == 'blob.read')
          .map((FakeInvocation call) => call.arguments['limit']),
      everyElement(PatchbayArtifactDownloader.defaultChunkBytes),
    );
  });
}
