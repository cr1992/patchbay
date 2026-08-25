import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:patchbay_cli/src/output/local_artifact.dart';
import 'package:test/test.dart';

/// A minimal [PatchbayFriendlyCommandSpec] the test controls directly,
/// rather than resolving one through the registry — these tests are about
/// the spill mechanics themselves, not path resolution (that is covered
/// end to end in `tree_artifact_output_test.dart`).
final class _FakeSpec implements PatchbayFriendlyCommandSpec {
  const _FakeSpec({
    this.artifact = PatchbayArtifactDisposition.renderedMember,
    this.spilledMember = 'payload.nodes',
  });

  @override
  final PatchbayArtifactDisposition artifact;
  @override
  final String? spilledMember;
  @override
  List<String> get path => const <String>['fake', 'tree'];

  @override
  String get name => 'fakeTree';
  @override
  String? get serviceCommand => null;
  @override
  String get summary => 'fake';
  @override
  String get usageSuffix => '';
  @override
  PatchbayCommandTarget get target =>
      PatchbayCommandTarget.declaredServiceCommand;
  @override
  String? get waitCondition => null;
  @override
  bool get fencesNavigationRevision => false;
  @override
  PatchbayCommandDescriptor? get protocolDescriptor => null;
  @override
  PatchbayCliSyntax? get protocolSyntax => null;
}

void main() {
  group('PatchbayLocalArtifactWriter', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('patchbay-outputs-test-');
    });
    tearDown(() => directory.deleteSync(recursive: true));

    test(
      'explicit --output writes, verifies and reports cliRendered',
      () async {
        final File output = File('${directory.path}/tree.json');
        final List<int> bytes = utf8.encode('{"a":1}');
        final PatchbayDownloadedArtifact result =
            await PatchbayLocalArtifactWriter().write(
              bytes: bytes,
              contentType: 'application/json',
              extension: 'json',
              commandSlug: 'ui-semantics-tree',
              outputPath: output.path,
            );

        expect(output.readAsBytesSync(), bytes);
        expect(result.origin, 'cliRendered');
        expect(result.blobId, isNull);
        expect(result.length, bytes.length);
        expect(result.sha256, sha256.convert(bytes).toString());
        expect(result.toJson().containsKey('blobId'), isFalse);
        expect(
          directory.listSync().where(
            (FileSystemEntity e) => e.path.contains('.patchbay-part-'),
          ),
          isEmpty,
        );
      },
    );

    test(
      'explicit --output without --force refuses an existing file',
      () async {
        final File output = File('${directory.path}/tree.json')
          ..writeAsStringSync('keep');
        await expectLater(
          PatchbayLocalArtifactWriter().write(
            bytes: utf8.encode('new'),
            contentType: 'text/plain; charset=utf-8',
            extension: 'txt',
            commandSlug: 'ui-widget-tree',
            outputPath: output.path,
          ),
          throwsA(isA<FormatException>()),
        );
        expect(output.readAsStringSync(), 'keep');
      },
    );

    test('explicit --output --force replaces after verification', () async {
      final File output = File('${directory.path}/tree.json')
        ..writeAsStringSync('old');
      await PatchbayLocalArtifactWriter().write(
        bytes: utf8.encode('new'),
        contentType: 'text/plain; charset=utf-8',
        extension: 'txt',
        commandSlug: 'ui-widget-tree',
        outputPath: output.path,
        force: true,
      );
      expect(output.readAsStringSync(), 'new');
    });

    test(
      'explicit --output with a missing parent directory fails closed',
      () async {
        await expectLater(
          PatchbayLocalArtifactWriter().write(
            bytes: utf8.encode('x'),
            contentType: 'text/plain; charset=utf-8',
            extension: 'txt',
            commandSlug: 'ui-widget-tree',
            outputPath: '${directory.path}/does-not-exist/tree.txt',
          ),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('auto path: PATCHBAY_OUTPUT_DIR is honoured and the filename shape is '
        'time-pid-slug-digest', () async {
      final List<int> bytes = utf8.encode('["node"]');
      final PatchbayDownloadedArtifact result =
          await PatchbayLocalArtifactWriter().write(
            bytes: bytes,
            contentType: 'application/json',
            extension: 'json',
            commandSlug: 'ui-semantics-tree',
            environment: <String, String>{
              'PATCHBAY_OUTPUT_DIR': directory.path,
            },
          );

      expect(result.path, startsWith(directory.path));
      final String fileName = result.path.split(Platform.pathSeparator).last;
      expect(
        fileName,
        matches(
          RegExp(r'^\d{8}T\d{6}Z-\d+-ui-semantics-tree-[0-9a-f]{16}\.json$'),
        ),
      );
      expect(File(result.path).readAsBytesSync(), bytes);
    });

    test('auto path with neither PATCHBAY_OUTPUT_DIR nor HOME set fails closed '
        'as localArtifactWriteFailed', () async {
      await expectLater(
        PatchbayLocalArtifactWriter().write(
          bytes: utf8.encode('x'),
          contentType: 'application/json',
          extension: 'json',
          commandSlug: 'ui-semantics-tree',
          environment: const <String, String>{},
        ),
        throwsA(
          isA<PatchbayArtifactDownloadException>().having(
            (PatchbayArtifactDownloadException e) => e.code,
            'code',
            'localArtifactWriteFailed',
          ),
        ),
      );
    });

    test('a member over the hard cap fails closed as localArtifactTooLarge '
        'without writing anything', () async {
      await expectLater(
        PatchbayLocalArtifactWriter().write(
          bytes: List<int>.filled(patchbayMaxLocalArtifactBytes + 1, 65),
          contentType: 'application/json',
          extension: 'json',
          commandSlug: 'ui-semantics-tree',
          environment: <String, String>{'PATCHBAY_OUTPUT_DIR': directory.path},
        ),
        throwsA(
          isA<PatchbayArtifactDownloadException>().having(
            (PatchbayArtifactDownloadException e) => e.code,
            'code',
            'localArtifactTooLarge',
          ),
        ),
      );
      expect(directory.listSync(), isEmpty);
    });

    test('opportunistic eviction ages out old files but keeps this run\'s '
        'writes', () async {
      final File stale = File('${directory.path}/stale.json')
        ..writeAsStringSync('old');
      final DateTime longAgo = DateTime.now().subtract(
        patchbayOutputRetentionAge + const Duration(days: 1),
      );
      stale.setLastModifiedSync(longAgo);

      final PatchbayLocalArtifactWriter writer = PatchbayLocalArtifactWriter();
      final PatchbayDownloadedArtifact first = await writer.write(
        bytes: utf8.encode('first'),
        contentType: 'text/plain; charset=utf-8',
        extension: 'txt',
        commandSlug: 'ui-widget-tree',
        environment: <String, String>{'PATCHBAY_OUTPUT_DIR': directory.path},
      );
      // A second write in the same run must not evict the first one, even
      // though nothing else protects it once it is no longer "new".
      await writer.write(
        bytes: utf8.encode('second'),
        contentType: 'text/plain; charset=utf-8',
        extension: 'txt',
        commandSlug: 'ui-render-tree',
        environment: <String, String>{'PATCHBAY_OUTPUT_DIR': directory.path},
      );

      expect(stale.existsSync(), isFalse);
      expect(File(first.path).existsSync(), isTrue);
    });

    test('opportunistic eviction trims oldest-first once the directory exceeds '
        'the byte cap, but never a path this run wrote', () async {
      final Map<String, String> environment = <String, String>{
        'PATCHBAY_OUTPUT_DIR': directory.path,
      };
      // Two old, unprotected files that together exceed the cap once a new
      // write needs room.
      final File oldest = File(
        '${directory.path}/oldest.json',
      )..writeAsBytesSync(List<int>.filled(patchbayOutputRetentionMaxBytes, 1));
      oldest.setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 2)),
      );
      final File newerStale = File('${directory.path}/newer.json')
        ..writeAsBytesSync(utf8.encode('small'));
      newerStale.setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 1)),
      );

      await PatchbayLocalArtifactWriter().write(
        bytes: utf8.encode('fresh'),
        contentType: 'application/json',
        extension: 'json',
        commandSlug: 'ui-semantics-tree',
        environment: environment,
      );

      // The oldest, largest file is the one eviction should reach for
      // first to get back under the cap.
      expect(oldest.existsSync(), isFalse);
    });
  });

  group('maybeSpillRenderedMember', () {
    late Directory directory;
    late PatchbayLocalArtifactWriter writer;
    late Map<String, String> environment;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('patchbay-spill-test-');
      writer = PatchbayLocalArtifactWriter();
      environment = <String, String>{'PATCHBAY_OUTPUT_DIR': directory.path};
    });
    tearDown(() => directory.deleteSync(recursive: true));

    Map<String, Object?> _responseWithNodeCount(int nodeCount) =>
        <String, Object?>{
          'admission': 'accepted',
          'payload': <String, Object?>{
            'outcome': 'observed',
            'treeRevision': 1,
            'nodeCount': nodeCount,
            'nodes': <Object?>[
              for (var i = 0; i < nodeCount; i += 1)
                <String, Object?>{'nodeId': i, 'identifier': 'node-$i-padding'},
            ],
          },
        };

    String _prettyJson(Map<String, Object?> response) =>
        const JsonEncoder.withIndent('  ').convert(response);

    test('non-renderedMember spec is always identity', () async {
      final Map<String, Object?> response = _responseWithNodeCount(1);
      final PatchbayRenderedMemberSpillResult result =
          await maybeSpillRenderedMember(
            writer: writer,
            spec: const _FakeSpec(artifact: PatchbayArtifactDisposition.none),
            response: response,
            exitCode: PatchbayExitCode.accepted,
            explicitOutputPath: null,
            force: false,
            maxInlineBytes: 1,
            renderDocument: _prettyJson,
            environment: environment,
          );
      expect(identical(result.response, response), isTrue);
      expect(result.artifact, isNull);
    });

    test('a missing spilledMember path renders inline without error', () async {
      final Map<String, Object?> response = <String, Object?>{
        'admission': 'accepted',
        'payload': <String, Object?>{'outcome': 'observed'},
      };
      final PatchbayRenderedMemberSpillResult result =
          await maybeSpillRenderedMember(
            writer: writer,
            spec: const _FakeSpec(),
            response: response,
            exitCode: PatchbayExitCode.accepted,
            explicitOutputPath: null,
            force: false,
            maxInlineBytes: 1,
            renderDocument: _prettyJson,
            environment: environment,
          );
      expect(result.response, response);
      expect(result.artifact, isNull);
    });

    test(
      'a non-accepted exit code never spills, however large the document',
      () async {
        final Map<String, Object?> response = _responseWithNodeCount(5000);
        final PatchbayRenderedMemberSpillResult result =
            await maybeSpillRenderedMember(
              writer: writer,
              spec: const _FakeSpec(),
              response: response,
              exitCode: PatchbayExitCode.typedFailure,
              explicitOutputPath: null,
              force: false,
              maxInlineBytes: 1,
              renderDocument: _prettyJson,
              environment: environment,
            );
        expect(identical(result.response, response), isTrue);
      },
    );

    test('--max-inline-bytes 0 disables spilling entirely', () async {
      final Map<String, Object?> response = _responseWithNodeCount(5000);
      final PatchbayRenderedMemberSpillResult result =
          await maybeSpillRenderedMember(
            writer: writer,
            spec: const _FakeSpec(),
            response: response,
            exitCode: PatchbayExitCode.accepted,
            explicitOutputPath: null,
            force: false,
            maxInlineBytes: 0,
            renderDocument: _prettyJson,
            environment: environment,
          );
      expect(identical(result.response, response), isTrue);
    });

    test('threshold boundary: exactly at the ceiling stays inline, one byte '
        'over spills', () async {
      // The ceiling is derived from the document's own measured length,
      // so this pins the exact `<=` boundary byte-for-byte rather than
      // hoping a coarse-grained node count happens to land on it.
      final Map<String, Object?> response = _responseWithNodeCount(37);
      final int exactSize = utf8.encode(_prettyJson(response)).length;

      final PatchbayRenderedMemberSpillResult atCeiling =
          await maybeSpillRenderedMember(
            writer: writer,
            spec: const _FakeSpec(),
            response: response,
            exitCode: PatchbayExitCode.accepted,
            explicitOutputPath: null,
            force: false,
            maxInlineBytes: exactSize,
            renderDocument: _prettyJson,
            environment: environment,
          );
      expect(
        atCeiling.artifact,
        isNull,
        reason: 'documentBytes == ceiling must stay inline',
      );
      expect(
        (atCeiling.response['payload']! as Map<String, Object?>)['nodes'],
        isA<List<Object?>>(),
      );

      final PatchbayRenderedMemberSpillResult overCeiling =
          await maybeSpillRenderedMember(
            writer: writer,
            spec: const _FakeSpec(),
            response: response,
            exitCode: PatchbayExitCode.accepted,
            explicitOutputPath: null,
            force: false,
            maxInlineBytes: exactSize - 1,
            renderDocument: _prettyJson,
            environment: environment,
          );
      expect(
        overCeiling.artifact,
        isNotNull,
        reason: 'documentBytes == ceiling + 1 must spill',
      );
      final Object? nodesAfterSpill =
          (overCeiling.response['payload']! as Map<String, Object?>)['nodes'];
      expect(nodesAfterSpill, isA<Map<String, Object?>>());
      // Bounded facts a caller needs to decide the next step stay inline.
      expect(
        (overCeiling.response['payload']!
            as Map<String, Object?>)['treeRevision'],
        1,
      );
    });

    test('a spilled JSON member is byte-identical to its would-be inline '
        'rendering, and the receipt sha256 matches the file on disk', () async {
      final Map<String, Object?> response = _responseWithNodeCount(5000);
      final List<Object?> nodes =
          (response['payload']! as Map<String, Object?>)['nodes']!
              as List<Object?>;
      final PatchbayRenderedMemberSpillResult result =
          await maybeSpillRenderedMember(
            writer: writer,
            spec: const _FakeSpec(),
            response: response,
            exitCode: PatchbayExitCode.accepted,
            explicitOutputPath: null,
            force: false,
            maxInlineBytes: 1,
            renderDocument: _prettyJson,
            environment: environment,
          );
      final PatchbayDownloadedArtifact artifact = result.artifact!;
      final List<int> onDisk = File(artifact.path).readAsBytesSync();
      expect(
        utf8.decode(onDisk),
        const JsonEncoder.withIndent('  ').convert(nodes),
      );
      expect(sha256.convert(onDisk).toString(), artifact.sha256);
      expect(artifact.contentType, 'application/json');
    });

    test(
      'a spilled text member is written as decoded text, not a JSON string',
      () async {
        const String dump = 'FocusManager\n  focus: rootScope\n    child: x\n';
        final Map<String, Object?> response = <String, Object?>{
          'source': 'uiObserved',
          'plane': 'flutterDiagnostic',
          'data': dump * 5000,
        };
        final PatchbayRenderedMemberSpillResult result =
            await maybeSpillRenderedMember(
              writer: writer,
              spec: const _FakeSpec(spilledMember: 'data'),
              response: response,
              exitCode: PatchbayExitCode.accepted,
              explicitOutputPath: null,
              force: false,
              maxInlineBytes: 1,
              renderDocument: (Map<String, Object?> r) =>
                  const JsonEncoder.withIndent('  ').convert(r),
              environment: environment,
            );
        final PatchbayDownloadedArtifact artifact = result.artifact!;
        expect(artifact.contentType, 'text/plain; charset=utf-8');
        expect(File(artifact.path).readAsStringSync(), dump * 5000);
        // Never JSON-quoted: no leading/trailing `"` and no `\n` escapes.
        final String onDisk = File(artifact.path).readAsStringSync();
        expect(onDisk.startsWith('"'), isFalse);
        expect(onDisk, contains('\n'));
      },
    );

    test('the top-level localArtifact and the in-place receipt are the same '
        'object', () async {
      final Map<String, Object?> response = _responseWithNodeCount(5000);
      final PatchbayRenderedMemberSpillResult result =
          await maybeSpillRenderedMember(
            writer: writer,
            spec: const _FakeSpec(),
            response: response,
            exitCode: PatchbayExitCode.accepted,
            explicitOutputPath: null,
            force: false,
            maxInlineBytes: 1,
            renderDocument: _prettyJson,
            environment: environment,
          );
      final Object? inPlace =
          (result.response['payload']! as Map<String, Object?>)['nodes'];
      expect(identical(result.response['localArtifact'], inPlace), isTrue);
    });

    test(
      'an explicit --output always spills, even under the inline ceiling',
      () async {
        final File output = File('${directory.path}/explicit.json');
        final Map<String, Object?> response = _responseWithNodeCount(1);
        final PatchbayRenderedMemberSpillResult result =
            await maybeSpillRenderedMember(
              writer: writer,
              spec: const _FakeSpec(),
              response: response,
              exitCode: PatchbayExitCode.accepted,
              explicitOutputPath: output.path,
              force: false,
              maxInlineBytes: patchbayDefaultMaxInlineBytes,
              renderDocument: _prettyJson,
              environment: environment,
            );
        expect(result.artifact!.path, output.path);
        expect(output.existsSync(), isTrue);
      },
    );
  });
}
