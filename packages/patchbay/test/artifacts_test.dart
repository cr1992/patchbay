import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:patchbay/patchbay.dart';
import 'package:test/test.dart';

void main() {
  group('PatchbayMemoryBlobStore', () {
    test('returns metadata and bounded chunks with sha256', () {
      final PatchbayMemoryBlobStore blobs = PatchbayMemoryBlobStore(
        capacityBytes: 32,
        maxChunkBytes: 4,
        idFactory: () => 'blob-1',
      );
      final metadata = blobs.put(
        Uint8List.fromList(utf8.encode('hello')),
        kind: PatchbayBlobSourceWire.logExport,
        source: PatchbayFactSourceWire.appRecorded,
        contentType: 'text/plain',
      );

      expect(metadata.length, 5);
      expect(
        metadata.sha256,
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
      );
      expect(blobs.read(blobId: 'blob-1', offset: 0, limit: 4).eof, isFalse);
      expect(
        base64Decode(
          blobs.read(blobId: 'blob-1', offset: 4, limit: 4).dataBase64,
        ),
        utf8.encode('o'),
      );
    });

    test('types expiry, offset, ttl and capacity failures', () {
      DateTime now = DateTime.utc(2026, 8, 12);
      var next = 0;
      final PatchbayMemoryBlobStore blobs = PatchbayMemoryBlobStore(
        capacityBytes: 4,
        maxChunkBytes: 2,
        defaultTtl: const Duration(seconds: 1),
        maxTtl: const Duration(seconds: 2),
        now: () => now,
        idFactory: () => 'blob-${++next}',
      );
      blobs.put(
        Uint8List.fromList(<int>[1, 2, 3]),
        kind: PatchbayBlobSourceWire.logExport,
        source: PatchbayFactSourceWire.appRecorded,
        contentType: 'application/octet-stream',
      );

      expect(
        () => blobs.put(
          Uint8List.fromList(<int>[4, 5]),
          kind: PatchbayBlobSourceWire.logExport,
          source: PatchbayFactSourceWire.appRecorded,
          contentType: 'application/octet-stream',
        ),
        throwsA(
          isA<PatchbayBlobFailure>().having(
            (failure) => failure.code,
            'code',
            PatchbayBlobFailureCode.capacityExceeded,
          ),
        ),
      );
      expect(
        () => blobs.read(blobId: 'blob-1', offset: 4, limit: 1),
        throwsA(
          isA<PatchbayBlobFailure>().having(
            (failure) => failure.code,
            'code',
            PatchbayBlobFailureCode.offsetOutOfBounds,
          ),
        ),
      );
      now = now.add(const Duration(seconds: 1));
      expect(
        () => blobs.metadata('blob-1'),
        throwsA(
          isA<PatchbayBlobFailure>().having(
            (failure) => failure.code,
            'code',
            PatchbayBlobFailureCode.expired,
          ),
        ),
      );
      expect(
        () => blobs.put(
          Uint8List(0),
          kind: PatchbayBlobSourceWire.logExport,
          source: PatchbayFactSourceWire.appRecorded,
          contentType: 'application/octet-stream',
          ttl: const Duration(seconds: 3),
        ),
        throwsA(
          isA<PatchbayBlobFailure>().having(
            (failure) => failure.code,
            'code',
            PatchbayBlobFailureCode.invalidTtl,
          ),
        ),
      );
    });
  });

  group('structured logs', () {
    test('redacted type rejects common sensitive keys and credentials', () {
      expect(
        () => PatchbayRedactedLogRecord(
          cursor: '1',
          at: DateTime.utc(2026),
          level: PatchbayLogLevelWire.info,
          category: 'auth',
          message: 'ready',
          fields: const <String, Object?>{'access_token': 'secret'},
        ),
        throwsA(isA<PatchbayLogRedactionFailure>()),
      );
      expect(
        () => PatchbayRedactedLogRecord(
          cursor: '1',
          at: DateTime.utc(2026),
          level: PatchbayLogLevelWire.info,
          category: 'auth',
          message: 'Authorization: Bearer abcdefghijklmnop',
        ),
        throwsA(isA<PatchbayLogRedactionFailure>()),
      );
    });

    test('query keeps the last delivered cursor when byte-truncated', () async {
      final _FakeLogSource source = _FakeLogSource(
        page: PatchbayLogPage.records(
          records: <PatchbayRedactedLogRecord>[
            _record('1', 'a'),
            _record('2', 'x' * 200),
          ],
          nextCursor: '2',
        ),
      );
      final PatchbayArtifactService service = _service(
        source,
        maxBatchBytes: 180,
      );

      final Map<String, Object?> response = await service.invoke(
        'logs.query',
        <String, Object?>{'cursor': '0'},
        'query-1',
      );
      final Map<String, Object?> payload = _payload(response);
      expect(payload['truncation'], 'byteLimit');
      expect(payload['nextCursor'], '1');
      expect((payload['records']! as List<Object?>).length, 1);
    });

    test('oversized first record fails without advancing cursor', () async {
      final PatchbayArtifactService service = _service(
        _FakeLogSource(
          page: PatchbayLogPage.records(
            records: <PatchbayRedactedLogRecord>[_record('1', 'x' * 200)],
            nextCursor: '1',
          ),
        ),
        maxBatchBytes: 64,
      );

      final Map<String, Object?> response = await service.invoke(
        'logs.query',
        <String, Object?>{'cursor': '0'},
        'query-large',
      );
      expect(_rejectionCode(response), 'logRecordTooLarge');
      expect(jsonEncode(response), isNot(contains('nextCursor')));
    });

    test('stale cursor and contradictory source cursor are typed', () async {
      PatchbayArtifactService service = _service(
        const _FakeLogSource(
          page: PatchbayLogPage.staleCursor(currentCursor: 'latest'),
        ),
      );
      expect(
        _payload(
          await service.invoke('logs.query', <String, Object?>{
            'cursor': 'old',
          }, 'stale'),
        )['outcome'],
        'staleCursor',
      );

      service = _service(
        _FakeLogSource(
          page: PatchbayLogPage.records(
            records: <PatchbayRedactedLogRecord>[_record('1', 'a')],
            nextCursor: '2',
          ),
        ),
      );
      expect(
        _rejectionCode(
          await service.invoke('logs.query', const <String, Object?>{}, 'bad'),
        ),
        'logSourceContractViolated',
      );
    });

    test('tail times out and cancels the consumer operation', () async {
      final _FakeLogSource source = _FakeLogSource(
        page: const PatchbayLogPage.records(),
        tailCompleter: Completer<PatchbayLogPage>(),
      );
      final PatchbayArtifactService service = _service(source);

      final Map<String, Object?> response = await service.invoke(
        'logs.tail',
        const <String, Object?>{'timeoutMs': 1},
        'tail-1',
      );
      expect(_payload(response)['outcome'], 'timedOut');
      expect(source.tailSignal?.isCancelled, isTrue);
    });

    test('dispose cancels an active long poll', () async {
      final _FakeLogSource source = _FakeLogSource(
        page: const PatchbayLogPage.records(),
        tailCompleter: Completer<PatchbayLogPage>(),
      );
      final PatchbayArtifactService service = _service(source);
      final Future<Map<String, Object?>> pending = service.invoke(
        'logs.tail',
        const <String, Object?>{'timeoutMs': 30000},
        'tail-dispose',
      );
      await Future<void>.delayed(Duration.zero);

      service.dispose();

      expect(_payload(await pending)['outcome'], 'cancelled');
      expect(source.tailSignal?.isCancelled, isTrue);
    });

    test('query validates time range and bounds', () async {
      final PatchbayArtifactService service = _service(
        const _FakeLogSource(page: PatchbayLogPage.records()),
      );
      expect(
        _rejectionCode(
          await service.invoke('logs.query', <String, Object?>{
            'since': '2026-08-13T00:00:00Z',
            'until': '2026-08-12T00:00:00Z',
          }, 'range'),
        ),
        'invalidArguments',
      );
      expect(
        _rejectionCode(
          await service.invoke('logs.query', const <String, Object?>{
            'limit': 501,
          }, 'limit'),
        ),
        'invalidArguments',
      );
    });

    test('export uses the shared chunked blob store', () async {
      final PatchbayArtifactService service = _service(
        _FakeLogSource(
          page: PatchbayLogPage.records(
            records: <PatchbayRedactedLogRecord>[_record('1', 'safe')],
            nextCursor: '1',
          ),
        ),
      );
      final Map<String, Object?> export = _payload(
        await service.invoke(
          'logs.export',
          const <String, Object?>{},
          'export-1',
        ),
      );
      final String blobId =
          (export['blob']! as Map<String, Object?>)['blobId']! as String;
      final Map<String, Object?> chunk = _payload(
        await service.invoke('blob.read', <String, Object?>{
          'blobId': blobId,
          'offset': 0,
          'limit': 1024,
        }, 'read-1'),
      );
      expect(chunk['eof'], isTrue);
      expect(
        utf8.decode(base64Decode(chunk['dataBase64']! as String)),
        contains('"redaction":"consumerRedacted"'),
      );
    });

    test(
      'blob.read applies the limit default the descriptor advertises',
      () async {
        final PatchbayArtifactService service = _service(
          const _FakeLogSource(page: PatchbayLogPage.records()),
        );
        final PatchbayParameterDescriptor limit = service.descriptors
            .firstWhere((descriptor) => descriptor.name == 'blob.read')
            .parameters
            .firstWhere((parameter) => parameter.name == 'limit');
        expect(limit.required, isFalse);
        expect(limit.defaultValue, service.blobs.maxChunkBytes);

        final PatchbayBlobMetadataWire blob = service.blobs.put(
          Uint8List.fromList(utf8.encode('x' * 3000)),
          kind: PatchbayBlobSourceWire.logExport,
          source: PatchbayFactSourceWire.appRecorded,
          contentType: 'text/plain',
        );
        final Map<String, Object?> chunk = _payload(
          await service.invoke('blob.read', <String, Object?>{
            'blobId': blob.blobId,
            'offset': 0,
          }, 'read-default'),
        );

        // The advertised default is a chunk bound, not "read everything".
        expect(chunk['length'], service.blobs.maxChunkBytes);
        expect(chunk['nextOffset'], service.blobs.maxChunkBytes);
        expect(chunk['eof'], isFalse);
      },
    );

    test('catalog and dispatch expose only explicitly injected capability', () {
      final PatchbayArtifactService blobsOnly = PatchbayArtifactService(
        blobs: PatchbayMemoryBlobStore(),
        gates: _gates,
      );
      expect(
        blobsOnly.descriptors.map((descriptor) => descriptor.name),
        <String>['blob.metadata', 'blob.read'],
      );
      final PatchbayArtifactService logs = _service(
        const _FakeLogSource(page: PatchbayLogPage.records()),
      );
      final Set<String> descriptors = logs.descriptors
          .map((descriptor) => descriptor.name)
          .toSet();
      expect(descriptors, <String>{
        'blob.metadata',
        'blob.read',
        'logs.query',
        'logs.export',
        'logs.tail',
      });
      expect(descriptors.every(logs.handles), isTrue);
      expect(logs.handles('logs.tail.cancel'), isFalse);
    });
  });
}

final PatchbayGateEvaluator _gates = PatchbayGateEvaluator(
  baseGate: () => const PatchbayGateDecision.allow(),
  consumerGate: (_) => const PatchbayGateDecision.allow(),
);

PatchbayArtifactService _service(
  PatchbayLogSource source, {
  int maxBatchBytes = 256 * 1024,
}) => PatchbayArtifactService(
  blobs: PatchbayMemoryBlobStore(maxChunkBytes: 1024),
  gates: _gates,
  logs: source,
  maxBatchBytes: maxBatchBytes,
);

PatchbayRedactedLogRecord _record(String cursor, String message) =>
    PatchbayRedactedLogRecord(
      cursor: cursor,
      at: DateTime.utc(2026, 8, 12),
      level: PatchbayLogLevelWire.info,
      category: 'test',
      message: message,
    );

Map<String, Object?> _payload(Map<String, Object?> response) =>
    response['payload']! as Map<String, Object?>;

String? _rejectionCode(Map<String, Object?> response) =>
    (response['rejection'] as Map<String, Object?>?)?['code'] as String?;

final class _FakeLogSource implements PatchbayLogSource {
  const _FakeLogSource({required this.page, this.tailCompleter});

  final PatchbayLogPage page;
  final Completer<PatchbayLogPage>? tailCompleter;
  static PatchbayCancellationSignal? _lastTailSignal;

  PatchbayCancellationSignal? get tailSignal => _lastTailSignal;

  @override
  Future<PatchbayLogPage> query(
    PatchbayLogQuery query,
    PatchbayCancellationSignal cancellation,
  ) async => page;

  @override
  Future<PatchbayLogPage> tail(
    PatchbayLogQuery query,
    PatchbayCancellationSignal cancellation,
  ) {
    _lastTailSignal = cancellation;
    return tailCompleter?.future ?? Future<PatchbayLogPage>.value(page);
  }
}
