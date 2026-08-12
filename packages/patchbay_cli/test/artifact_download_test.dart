import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late List<int> bytes;
  late Map<String, Object?> metadata;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('patchbay-download-test-');
    bytes = utf8.encode(List<String>.filled(20000, 'artifact').join());
    metadata = _metadata(bytes);
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test(
    'downloads chunks and verifies length and sha256 before rename',
    () async {
      final File output = File('${directory.path}/capture.png');
      final PatchbayDownloadedArtifact result =
          await PatchbayArtifactDownloader(
            invoke: _reader(bytes, metadata),
          ).download(
            metadataJson: metadata,
            outputPath: output.path,
            force: false,
          );

      expect(output.readAsBytesSync(), bytes);
      expect(result.length, bytes.length);
      expect(result.sha256, sha256.convert(bytes).toString());
      expect(
        directory.listSync().map((entry) => entry.path),
        contains(output.path),
      );
      expect(
        directory.listSync().where(
          (entry) => entry.path.contains('.patchbay-part-'),
        ),
        isEmpty,
      );
    },
  );

  test('does not replace an existing file without force', () async {
    final File output = File('${directory.path}/logs.ndjson')
      ..writeAsStringSync('keep');
    await expectLater(
      PatchbayArtifactDownloader(
        invoke: _reader(bytes, metadata),
      ).download(metadataJson: metadata, outputPath: output.path, force: false),
      throwsA(isA<FormatException>()),
    );
    expect(output.readAsStringSync(), 'keep');
  });

  test('force replaces only after full verification', () async {
    final File output = File('${directory.path}/logs.ndjson')
      ..writeAsStringSync('old');
    await PatchbayArtifactDownloader(
      invoke: _reader(bytes, metadata),
    ).download(metadataJson: metadata, outputPath: output.path, force: true);
    expect(output.readAsBytesSync(), bytes);
  });

  test(
    'hash mismatch removes temporary file and preserves final name',
    () async {
      final File output = File('${directory.path}/capture.png');
      final Map<String, Object?> corrupt = <String, Object?>{
        ...metadata,
        'sha256': List<String>.filled(64, '0').join(),
      };
      await expectLater(
        PatchbayArtifactDownloader(invoke: _reader(bytes, corrupt)).download(
          metadataJson: corrupt,
          outputPath: output.path,
          force: false,
        ),
        throwsA(
          isA<PatchbayArtifactDownloadException>().having(
            (error) => error.code,
            'code',
            'blobIntegrityMismatch',
          ),
        ),
      );
      expect(output.existsSync(), isFalse);
      expect(directory.listSync(), isEmpty);
    },
  );

  test('rejected later chunk removes temporary file', () async {
    final File output = File('${directory.path}/logs.ndjson');
    await expectLater(
      PatchbayArtifactDownloader(
        invoke: (String command, Map<String, Object?> arguments) async {
          if ((arguments['offset'] as int) > 0) {
            return <String, Object?>{
              'admission': 'rejected',
              'rejection': <String, Object?>{'code': 'blobExpired'},
            };
          }
          return _reader(bytes, metadata)(command, arguments);
        },
      ).download(metadataJson: metadata, outputPath: output.path, force: false),
      throwsA(isA<PatchbayArtifactRejected>()),
    );
    expect(output.existsSync(), isFalse);
    expect(directory.listSync(), isEmpty);
  });

  test('rejects unbounded metadata before creating a file', () async {
    final File output = File('${directory.path}/oversized.bin');
    final Map<String, Object?> oversized = <String, Object?>{
      ...metadata,
      'length': 65 * 1024 * 1024,
    };
    await expectLater(
      PatchbayArtifactDownloader(invoke: _reader(bytes, metadata)).download(
        metadataJson: oversized,
        outputPath: output.path,
        force: false,
      ),
      throwsA(
        isA<PatchbayArtifactDownloadException>().having(
          (error) => error.code,
          'code',
          'blobLengthOutOfBounds',
        ),
      ),
    );
    expect(output.existsSync(), isFalse);
    expect(directory.listSync(), isEmpty);
  });
}

PatchbayArtifactInvoker _reader(
  List<int> bytes,
  Map<String, Object?> metadata,
) => (String command, Map<String, Object?> arguments) async {
  expect(command, 'blob.read');
  final int offset = arguments['offset']! as int;
  final int limit = arguments['limit']! as int;
  final int next = (offset + limit).clamp(0, bytes.length);
  final List<int> chunk = bytes.sublist(offset, next);
  return <String, Object?>{
    'admission': 'accepted',
    'payload': <String, Object?>{
      'metadata': metadata,
      'offset': offset,
      'length': chunk.length,
      'nextOffset': next,
      'eof': next == bytes.length,
      'dataBase64': base64Encode(chunk),
    },
  };
};

Map<String, Object?> _metadata(List<int> bytes) => <String, Object?>{
  'blobId': 'fixture-blob',
  'source': 'appRecorded',
  'kind': 'logExport',
  'contentType': 'application/octet-stream',
  'length': bytes.length,
  'sha256': sha256.convert(bytes).toString(),
  'createdAt': '2026-08-12T00:00:00.000Z',
  'expiresAt': '2026-08-12T00:05:00.000Z',
  'filename': 'fixture.bin',
};
