import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'blob_store.dart';
import 'command_descriptor.dart';
import 'command_registry.dart';
import 'facts.dart';
import 'gates.dart';
import 'generated/core_wire.g.dart';
import 'invocation.dart';
import 'ui_descriptor.dart';

/// A log record whose public constructor enforces Patchbay's defensive
/// redaction boundary before a consumer source can return it.
///
/// This check deliberately catches only common credential shapes. It is not a
/// replacement for the consumer's own schema-aware redaction policy.
final class PatchbayRedactedLogRecord {
  PatchbayRedactedLogRecord({
    required String cursor,
    required DateTime at,
    required PatchbayLogLevelWire level,
    required String category,
    required String message,
    Map<String, Object?> fields = const <String, Object?>{},
  }) : _wire = PatchbayLogRecordWire(
         cursor: _nonEmpty(cursor, 'cursor'),
         at: at.toUtc().toIso8601String(),
         level: level,
         category: _nonEmpty(category, 'category'),
         message: _checkedText(message, r'$.message'),
         fields: _checkedFields(fields),
         redaction: PatchbayLogRedactionWire.consumerRedacted,
         source: PatchbayFactSourceWire.appRecorded,
       ) {
    _wire.toJson();
  }

  final PatchbayLogRecordWire _wire;
}

final class PatchbayLogRedactionFailure implements Exception {
  const PatchbayLogRedactionFailure(this.path);

  final String path;

  @override
  String toString() => 'PatchbayLogRedactionFailure($path)';
}

final class PatchbayLogRecordTooLarge implements Exception {
  const PatchbayLogRecordTooLarge(this.encodedBytes);

  final int encodedBytes;
}

final class PatchbayLogSourceContractFailure implements Exception {
  const PatchbayLogSourceContractFailure(this.reason);

  final String reason;
}

enum PatchbayLogPageState { records, staleCursor }

/// Consumer-owned query result. Patchbay applies its own response bounds after
/// the source returns and never subscribes to or takes ownership of the source.
final class PatchbayLogPage {
  const PatchbayLogPage.records({
    this.records = const <PatchbayRedactedLogRecord>[],
    this.nextCursor,
    this.sourceTruncated = false,
  }) : state = PatchbayLogPageState.records,
       currentCursor = null;

  const PatchbayLogPage.staleCursor({required this.currentCursor})
    : state = PatchbayLogPageState.staleCursor,
      records = const <PatchbayRedactedLogRecord>[],
      nextCursor = null,
      sourceTruncated = false;

  final PatchbayLogPageState state;
  final List<PatchbayRedactedLogRecord> records;
  final String? nextCursor;
  final String? currentCursor;
  final bool sourceTruncated;
}

final class PatchbayLogQuery {
  const PatchbayLogQuery({
    required this.direction,
    required this.limit,
    this.cursor,
    this.levels = const <PatchbayLogLevelWire>{},
    this.categories = const <String>{},
    this.since,
    this.until,
  });

  final String? cursor;
  final PatchbayLogDirectionWire direction;
  final int limit;
  final Set<PatchbayLogLevelWire> levels;
  final Set<String> categories;
  final DateTime? since;
  final DateTime? until;
}

final class PatchbayCancellationSignal {
  bool _cancelled = false;
  final Completer<void> _cancelledCompleter = Completer<void>();

  bool get isCancelled => _cancelled;
  Future<void> get cancelled => _cancelledCompleter.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelledCompleter.complete();
  }
}

/// Consumer injection seam for already-redacted structured records.
abstract interface class PatchbayLogSource {
  Future<PatchbayLogPage> query(
    PatchbayLogQuery query,
    PatchbayCancellationSignal cancellation,
  );

  /// Waits for records strictly after [PatchbayLogQuery.cursor]. The service
  /// still owns and enforces the outer timeout and cancels this signal when it
  /// expires or is disposed.
  Future<PatchbayLogPage> tail(
    PatchbayLogQuery query,
    PatchbayCancellationSignal cancellation,
  );
}

/// Explicitly injected log/blob command module shared by core and Flutter.
final class PatchbayArtifactService {
  PatchbayArtifactService({
    required this.blobs,
    required PatchbayGateEvaluator gates,
    PatchbayLogSource? logs,
    Set<String> gateIds = const <String>{},
    this.maxQueryRecords = 500,
    this.maxExportRecords = 2000,
    this.maxBatchBytes = 256 * 1024,
    this.maxTailTimeout = const Duration(seconds: 30),
    this.queryTimeout = const Duration(seconds: 2),
  }) : _gates = gates,
       _logs = logs,
       _gateIds = Set<String>.unmodifiable(gateIds) {
    if (maxQueryRecords <= 0 ||
        maxExportRecords < maxQueryRecords ||
        maxBatchBytes <= 0 ||
        maxTailTimeout <= Duration.zero ||
        queryTimeout <= Duration.zero) {
      throw ArgumentError('Artifact service limits are inconsistent.');
    }
    _registry = _buildRegistry();
  }

  final PatchbayMemoryBlobStore blobs;
  final PatchbayGateEvaluator _gates;
  final PatchbayLogSource? _logs;
  final Set<String> _gateIds;
  late final PatchbayCommandRegistry _registry;
  final int maxQueryRecords;
  final int maxExportRecords;
  final int maxBatchBytes;
  final Duration maxTailTimeout;
  final Duration queryTimeout;
  final Set<PatchbayCancellationSignal> _active =
      <PatchbayCancellationSignal>{};

  bool get logsEnabled => _logs != null;

  PatchbayCommandRegistry get registry => _registry;

  List<PatchbayCommandDescriptor> get descriptors => registry.descriptors;

  bool handles(String command) => registry.handles(command);

  Future<Map<String, Object?>> invoke(
    String command,
    Map<String, Object?> arguments,
    String requestId,
  ) => registry.dispatch(command, arguments, requestId);

  PatchbayCommandRegistry _buildRegistry() {
    final List<PatchbayCommandDescriptor> blobs = _blobDescriptors;
    final List<PatchbayCommandDescriptor> logs = _logDescriptors;
    return PatchbayCommandRegistry(<PatchbayCommandRegistration<Object?>>[
      PatchbayCommandRegistration<PatchbayBlobMetadataRequestWire>(
        descriptor: blobs[0],
        decode: PatchbayBlobMetadataRequestWire.fromJson,
        gate: _gate,
        handle: _metadata,
        onDecodeFailure: _failure,
        onExecutionFailure: _failure,
      ),
      PatchbayCommandRegistration<PatchbayBlobReadRequestWire>(
        descriptor: blobs[1],
        decode: PatchbayBlobReadRequestWire.fromJson,
        gate: _gate,
        handle: _read,
        onDecodeFailure: _failure,
        onExecutionFailure: _failure,
      ),
      if (logsEnabled) ...<PatchbayCommandRegistration<Object?>>[
        PatchbayCommandRegistration<PatchbayLogQueryRequestWire>(
          descriptor: logs[0],
          decode: PatchbayLogQueryRequestWire.fromJson,
          gate: _gate,
          handle: _query,
          onDecodeFailure: _failure,
          onExecutionFailure: _failure,
        ),
        PatchbayCommandRegistration<PatchbayLogExportRequestWire>(
          descriptor: logs[1],
          decode: PatchbayLogExportRequestWire.fromJson,
          gate: _gate,
          handle: _export,
          onDecodeFailure: _failure,
          onExecutionFailure: _failure,
        ),
        PatchbayCommandRegistration<PatchbayLogTailRequestWire>(
          descriptor: logs[2],
          decode: PatchbayLogTailRequestWire.fromJson,
          gate: _gate,
          handle: _tail,
          onDecodeFailure: _failure,
          onExecutionFailure: _failure,
        ),
      ],
    ]);
  }

  Future<Map<String, Object?>?> _gate(Object? _, String requestId) async {
    final PatchbayGateRejection? gate = await _gates.evaluate(_gateIds);
    return gate == null
        ? null
        : _rejected(
            requestId,
            gate.code,
            details: <String, Object?>{'gateId': gate.gateId},
            notice: gate.notice,
          );
  }

  Map<String, Object?> _failure(
    Object failure,
    Map<String, Object?> _,
    String requestId,
    PatchbayCommandDescriptor __,
  ) {
    if (failure case FormatException error) {
      return _rejected(
        requestId,
        'invalidArguments',
        details: <String, Object?>{'message': error.message},
      );
    }
    if (failure case PatchbayBlobFailure error) {
      return _rejected(
        requestId,
        _blobFailureCode(error.code),
        details: error.details,
      );
    }
    if (failure case PatchbayLogRedactionFailure error) {
      return _rejected(
        requestId,
        'logRedactionContractViolated',
        details: <String, Object?>{'path': error.path},
      );
    }
    if (failure case PatchbayLogRecordTooLarge error) {
      return _rejected(
        requestId,
        'logRecordTooLarge',
        details: <String, Object?>{
          'encodedBytes': error.encodedBytes,
          'maxBatchBytes': maxBatchBytes,
        },
      );
    }
    if (failure case PatchbayLogSourceContractFailure error) {
      return _rejected(
        requestId,
        'logSourceContractViolated',
        details: <String, Object?>{'reason': error.reason},
      );
    }
    if (failure is TimeoutException) {
      return _rejected(requestId, 'logQueryTimeout');
    }
    return _rejected(requestId, 'artifactSourceFailed');
  }

  void dispose() {
    for (final PatchbayCancellationSignal signal in _active.toList(
      growable: false,
    )) {
      signal.cancel();
    }
    _active.clear();
  }

  Map<String, Object?> _metadata(
    PatchbayBlobMetadataRequestWire request,
    String requestId,
  ) {
    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: blobs.metadata(request.blobId).toJson(),
    ).toJson();
  }

  Map<String, Object?> _read(
    PatchbayBlobReadRequestWire request,
    String requestId,
  ) {
    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: blobs
          .read(
            blobId: request.blobId,
            offset: request.offset,
            // The descriptor declares this default, so the wire must accept the
            // argument being absent and the host must supply the same value the
            // catalog advertises.
            limit: request.limit ?? blobs.maxChunkBytes,
          )
          .toJson(),
    ).toJson();
  }

  Future<Map<String, Object?>> _query(
    PatchbayLogQueryRequestWire request,
    String requestId,
  ) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    final PatchbayLogQuery query = _queryFromWire(
      request,
      defaultLimit: 100,
      maxLimit: maxQueryRecords,
    );
    final PatchbayLogPage page = await _withSignal(
      (PatchbayCancellationSignal signal) =>
          _logs!.query(query, signal).timeout(queryTimeout),
    );
    final PatchbayLogBatchWire result = _boundedBatch(
      page,
      limit: query.limit,
      requestCursor: query.cursor,
      elapsedMs: stopwatch.elapsedMilliseconds,
    );
    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: result.toJson(),
    ).toJson();
  }

  Future<Map<String, Object?>> _tail(
    PatchbayLogTailRequestWire request,
    String requestId,
  ) async {
    final int limit = _boundedPositive(
      request.limit ?? 100,
      maxQueryRecords,
      'limit',
    );
    final Duration timeout = Duration(
      milliseconds: _boundedPositive(
        request.timeoutMs ?? 5000,
        maxTailTimeout.inMilliseconds,
        'timeoutMs',
      ),
    );
    final PatchbayLogQuery query = PatchbayLogQuery(
      cursor: request.cursor,
      direction: PatchbayLogDirectionWire.forward,
      limit: limit,
      levels: request.levels.toSet(),
      categories: request.categories.toSet(),
    );
    final Stopwatch stopwatch = Stopwatch()..start();
    final PatchbayCancellationSignal signal = PatchbayCancellationSignal();
    final Completer<_TailTimedOut> timedOut = Completer<_TailTimedOut>();
    final Timer timeoutTimer = Timer(
      timeout,
      () => timedOut.complete(const _TailTimedOut()),
    );
    _active.add(signal);
    try {
      final Object result = await Future.any<Object>(<Future<Object>>[
        _logs!.tail(query, signal),
        signal.cancelled.then((_) => const _TailCancelled()),
        timedOut.future,
      ]);
      if (result is _TailTimedOut) {
        signal.cancel();
        return _acceptedBatch(
          requestId,
          PatchbayLogBatchWire(
            outcome: PatchbayLogBatchOutcomeWire.timedOut,
            source: PatchbayFactSourceWire.appRecorded,
            records: const <PatchbayLogRecordWire>[],
            nextCursor: request.cursor,
            currentCursor: request.cursor,
            truncated: false,
            truncation: null,
            elapsedMs: stopwatch.elapsedMilliseconds,
          ),
        );
      }
      if (result is _TailCancelled) {
        return _acceptedBatch(
          requestId,
          PatchbayLogBatchWire(
            outcome: PatchbayLogBatchOutcomeWire.cancelled,
            source: PatchbayFactSourceWire.appRecorded,
            records: const <PatchbayLogRecordWire>[],
            nextCursor: request.cursor,
            currentCursor: request.cursor,
            truncated: false,
            truncation: null,
            elapsedMs: stopwatch.elapsedMilliseconds,
          ),
        );
      }
      return _acceptedBatch(
        requestId,
        _boundedBatch(
          result as PatchbayLogPage,
          limit: limit,
          requestCursor: query.cursor,
          elapsedMs: stopwatch.elapsedMilliseconds,
        ),
      );
    } finally {
      timeoutTimer.cancel();
      signal.cancel();
      _active.remove(signal);
    }
  }

  Future<Map<String, Object?>> _export(
    PatchbayLogExportRequestWire request,
    String requestId,
  ) async {
    final DateTime? since = _date(request.since, 'since');
    final DateTime? until = _date(request.until, 'until');
    _validateRange(since, until);
    final PatchbayLogQuery query = PatchbayLogQuery(
      cursor: request.cursor,
      direction: request.direction ?? PatchbayLogDirectionWire.backward,
      limit: _boundedPositive(request.limit ?? 1000, maxExportRecords, 'limit'),
      levels: request.levels.toSet(),
      categories: request.categories.toSet(),
      since: since,
      until: until,
    );
    final PatchbayLogPage page = await _withSignal(
      (PatchbayCancellationSignal signal) =>
          _logs!.query(query, signal).timeout(queryTimeout),
    );
    final PatchbayLogBatchWire batch = _boundedBatch(
      page,
      limit: query.limit,
      requestCursor: query.cursor,
      elapsedMs: 0,
    );
    if (batch.outcome == PatchbayLogBatchOutcomeWire.staleCursor) {
      return _rejected(
        requestId,
        'logCursorStale',
        details: <String, Object?>{
          if (batch.currentCursor != null) 'currentCursor': batch.currentCursor,
        },
      );
    }
    final Uint8List bytes = Uint8List.fromList(
      utf8.encode(
        batch.records.map((record) => jsonEncode(record.toJson())).join('\n') +
            (batch.records.isEmpty ? '' : '\n'),
      ),
    );
    final Duration? ttl = request.ttlMs == null
        ? null
        : Duration(milliseconds: request.ttlMs!);
    final PatchbayBlobMetadataWire blob = blobs.put(
      bytes,
      kind: PatchbayBlobSourceWire.logExport,
      source: PatchbayFactSourceWire.appRecorded,
      contentType: 'application/x-ndjson',
      ttl: ttl,
      filename: 'patchbay-logs.ndjson',
      properties: <String, Object?>{
        'recordCount': batch.records.length,
        'truncated': batch.truncated,
      },
    );
    return PatchbayInvocation.accepted(
      requestId: requestId,
      payload: PatchbayLogExportResultWire(
        source: PatchbayFactSourceWire.appRecorded,
        blob: blob,
        recordCount: batch.records.length,
        truncated: batch.truncated,
        truncation: batch.truncation,
      ).toJson(),
    ).toJson();
  }

  Future<PatchbayLogPage> _withSignal(
    Future<PatchbayLogPage> Function(PatchbayCancellationSignal) body,
  ) async {
    final PatchbayCancellationSignal signal = PatchbayCancellationSignal();
    _active.add(signal);
    try {
      return await body(signal);
    } finally {
      signal.cancel();
      _active.remove(signal);
    }
  }

  PatchbayLogBatchWire _boundedBatch(
    PatchbayLogPage page, {
    required int limit,
    required String? requestCursor,
    required int elapsedMs,
  }) {
    if (page.state == PatchbayLogPageState.staleCursor) {
      return PatchbayLogBatchWire(
        outcome: PatchbayLogBatchOutcomeWire.staleCursor,
        source: PatchbayFactSourceWire.appRecorded,
        records: const <PatchbayLogRecordWire>[],
        nextCursor: null,
        currentCursor: page.currentCursor,
        truncated: false,
        truncation: null,
        elapsedMs: elapsedMs,
      );
    }
    final List<PatchbayLogRecordWire> records = <PatchbayLogRecordWire>[];
    final Set<String> cursors = <String>{};
    int encodedBytes = 0;
    PatchbayLogTruncationWire? truncation = page.sourceTruncated
        ? PatchbayLogTruncationWire.sourceLimit
        : null;
    if (page.records.isNotEmpty &&
        page.nextCursor != null &&
        page.nextCursor != page.records.last._wire.cursor) {
      throw const PatchbayLogSourceContractFailure(
        'log source nextCursor must equal its final record cursor',
      );
    }
    for (final PatchbayRedactedLogRecord record in page.records) {
      final PatchbayLogRecordWire wire = record._wire;
      if (wire.redaction != PatchbayLogRedactionWire.consumerRedacted) {
        throw const PatchbayLogRedactionFailure(r'$.redaction');
      }
      if (!cursors.add(wire.cursor)) {
        throw const PatchbayLogSourceContractFailure(
          'log source returned duplicate cursors',
        );
      }
      if (records.length == limit) {
        truncation = PatchbayLogTruncationWire.entryLimit;
        break;
      }
      final int nextBytes = utf8.encode(jsonEncode(wire.toJson())).length + 1;
      if (encodedBytes + nextBytes > maxBatchBytes) {
        if (records.isEmpty) throw PatchbayLogRecordTooLarge(nextBytes);
        truncation = PatchbayLogTruncationWire.byteLimit;
        break;
      }
      encodedBytes += nextBytes;
      records.add(wire);
    }
    final String? nextCursor = records.isNotEmpty
        ? records.last.cursor
        : requestCursor;
    return PatchbayLogBatchWire(
      outcome: PatchbayLogBatchOutcomeWire.records,
      source: PatchbayFactSourceWire.appRecorded,
      records: records,
      nextCursor: nextCursor,
      currentCursor: nextCursor,
      truncated: truncation != null,
      truncation: truncation,
      elapsedMs: elapsedMs,
    );
  }

  PatchbayLogQuery _queryFromWire(
    PatchbayLogQueryRequestWire request, {
    required int defaultLimit,
    required int maxLimit,
  }) {
    final DateTime? since = _date(request.since, 'since');
    final DateTime? until = _date(request.until, 'until');
    _validateRange(since, until);
    return PatchbayLogQuery(
      cursor: request.cursor,
      direction: request.direction ?? PatchbayLogDirectionWire.backward,
      limit: _boundedPositive(request.limit ?? defaultLimit, maxLimit, 'limit'),
      levels: request.levels.toSet(),
      categories: request.categories.toSet(),
      since: since,
      until: until,
    );
  }

  static int _boundedPositive(int value, int maximum, String name) {
    if (value <= 0 || value > maximum) {
      throw FormatException('$name must be between 1 and $maximum');
    }
    return value;
  }

  static DateTime? _date(String? value, String name) {
    if (value == null) return null;
    final DateTime? result = DateTime.tryParse(value);
    if (result == null) throw FormatException('$name must be ISO-8601');
    return result.toUtc();
  }

  static void _validateRange(DateTime? since, DateTime? until) {
    if (since != null && until != null && since.isAfter(until)) {
      throw const FormatException('since must not be after until');
    }
  }

  static Map<String, Object?> _acceptedBatch(
    String requestId,
    PatchbayLogBatchWire batch,
  ) => PatchbayInvocation.accepted(
    requestId: requestId,
    payload: batch.toJson(),
  ).toJson();

  static Map<String, Object?> _rejected(
    String requestId,
    String code, {
    Map<String, Object?> details = const <String, Object?>{},
    String? notice,
  }) => PatchbayInvocation.rejected(
    requestId: requestId,
    rejection: PatchbayRejection(code: code, notice: notice, details: details),
  ).toJson();

  static String _blobFailureCode(PatchbayBlobFailureCode code) =>
      switch (code) {
        PatchbayBlobFailureCode.notFound => 'blobNotFound',
        PatchbayBlobFailureCode.expired => 'blobExpired',
        PatchbayBlobFailureCode.offsetOutOfBounds => 'blobOffsetOutOfBounds',
        PatchbayBlobFailureCode.invalidChunkLimit => 'blobInvalidChunkLimit',
        PatchbayBlobFailureCode.invalidTtl => 'blobInvalidTtl',
        PatchbayBlobFailureCode.blobTooLarge => 'blobTooLarge',
        PatchbayBlobFailureCode.capacityExceeded => 'blobCapacityExceeded',
      };

  List<PatchbayCommandDescriptor> get _blobDescriptors =>
      <PatchbayCommandDescriptor>[
        PatchbayCommandDescriptor(
          name: 'blob.metadata',
          summary: 'Read metadata for one bounded Patchbay artifact.',
          plane: PatchbayPlane.domain,
          mode: PatchbayCommandMode.readOnly,
          sideEffect: PatchbaySideEffect.none,
          factSources: const <PatchbayFactSource>{
            PatchbayFactSource.appRecorded,
            PatchbayFactSource.uiObserved,
          },
          gates: _gateIds,
          parameters: const <PatchbayParameterDescriptor>[
            PatchbayParameterDescriptor(
              name: 'blobId',
              type: PatchbayParameterType.string,
              required: true,
            ),
          ],
        ),
        PatchbayCommandDescriptor(
          name: 'blob.read',
          summary: 'Read one bounded base64 chunk of a Patchbay artifact.',
          plane: PatchbayPlane.domain,
          mode: PatchbayCommandMode.readOnly,
          sideEffect: PatchbaySideEffect.none,
          factSources: const <PatchbayFactSource>{
            PatchbayFactSource.appRecorded,
            PatchbayFactSource.uiObserved,
          },
          gates: _gateIds,
          parameters: <PatchbayParameterDescriptor>[
            const PatchbayParameterDescriptor(
              name: 'blobId',
              type: PatchbayParameterType.string,
              required: true,
            ),
            const PatchbayParameterDescriptor(
              name: 'offset',
              type: PatchbayParameterType.integer,
              required: true,
            ),
            PatchbayParameterDescriptor(
              name: 'limit',
              type: PatchbayParameterType.integer,
              defaultValue: blobs.maxChunkBytes,
            ),
          ],
        ),
      ];

  List<PatchbayCommandDescriptor>
  get _logDescriptors => <PatchbayCommandDescriptor>[
    PatchbayCommandDescriptor(
      name: 'logs.query',
      summary: 'Query bounded consumer-redacted structured App logs.',
      plane: PatchbayPlane.domain,
      mode: PatchbayCommandMode.readOnly,
      sideEffect: PatchbaySideEffect.none,
      factSources: const <PatchbayFactSource>{PatchbayFactSource.appRecorded},
      gates: _gateIds,
      parameters: _logQueryParameters(export: false),
    ),
    PatchbayCommandDescriptor(
      name: 'logs.export',
      summary: 'Export consumer-redacted structured App logs to a blob.',
      plane: PatchbayPlane.domain,
      mode: PatchbayCommandMode.readOnly,
      sideEffect: PatchbaySideEffect.none,
      factSources: const <PatchbayFactSource>{PatchbayFactSource.appRecorded},
      gates: _gateIds,
      parameters: _logQueryParameters(export: true),
    ),
    PatchbayCommandDescriptor(
      name: 'logs.tail',
      summary: 'Long-poll bounded consumer-redacted logs after a cursor.',
      plane: PatchbayPlane.domain,
      mode: PatchbayCommandMode.readOnly,
      sideEffect: PatchbaySideEffect.none,
      factSources: const <PatchbayFactSource>{PatchbayFactSource.appRecorded},
      gates: _gateIds,
      parameters: <PatchbayParameterDescriptor>[
        const PatchbayParameterDescriptor(
          name: 'cursor',
          type: PatchbayParameterType.string,
        ),
        const PatchbayParameterDescriptor(
          name: 'limit',
          type: PatchbayParameterType.integer,
          defaultValue: 100,
        ),
        PatchbayParameterDescriptor(
          name: 'timeoutMs',
          type: PatchbayParameterType.integer,
          defaultValue: 5000,
          summary:
              'Bounded long-poll timeout; maximum ${maxTailTimeout.inMilliseconds}ms.',
        ),
        const PatchbayParameterDescriptor(
          name: 'levels',
          type: PatchbayParameterType.json,
        ),
        const PatchbayParameterDescriptor(
          name: 'categories',
          type: PatchbayParameterType.json,
        ),
      ],
    ),
  ];

  List<PatchbayParameterDescriptor> _logQueryParameters({
    required bool export,
  }) => <PatchbayParameterDescriptor>[
    const PatchbayParameterDescriptor(
      name: 'cursor',
      type: PatchbayParameterType.string,
    ),
    const PatchbayParameterDescriptor(
      name: 'direction',
      type: PatchbayParameterType.enumeration,
      defaultValue: 'backward',
      allowedValues: <String>['forward', 'backward'],
    ),
    PatchbayParameterDescriptor(
      name: 'limit',
      type: PatchbayParameterType.integer,
      defaultValue: export ? 1000 : 100,
    ),
    const PatchbayParameterDescriptor(
      name: 'levels',
      type: PatchbayParameterType.json,
    ),
    const PatchbayParameterDescriptor(
      name: 'categories',
      type: PatchbayParameterType.json,
    ),
    const PatchbayParameterDescriptor(
      name: 'since',
      type: PatchbayParameterType.string,
    ),
    const PatchbayParameterDescriptor(
      name: 'until',
      type: PatchbayParameterType.string,
    ),
    if (export)
      const PatchbayParameterDescriptor(
        name: 'ttlMs',
        type: PatchbayParameterType.integer,
      ),
  ];
}

final class _TailTimedOut {
  const _TailTimedOut();
}

final class _TailCancelled {
  const _TailCancelled();
}

String _nonEmpty(String value, String name) {
  if (value.isEmpty) throw FormatException('$name must not be empty');
  return value;
}

String _checkedText(String value, String path) {
  final RegExp credential = RegExp(
    r'(?:\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})',
    caseSensitive: false,
  );
  if (credential.hasMatch(value)) throw PatchbayLogRedactionFailure(path);
  return value;
}

Map<String, Object?> _checkedFields(Map<String, Object?> fields) {
  const Set<String> sensitiveKeys = <String>{
    'password',
    'passwd',
    'secret',
    'token',
    'accesstoken',
    'refreshtoken',
    'authorization',
    'cookie',
    'setcookie',
    'apikey',
    'privatekey',
  };

  Object? check(Object? value, String path) {
    if (value is String) return _checkedText(value, path);
    if (value is num || value is bool || value == null) return value;
    if (value is List) {
      return <Object?>[
        for (var index = 0; index < value.length; index += 1)
          check(value[index], '$path[$index]'),
      ];
    }
    if (value is Map) {
      final Map<String, Object?> map;
      try {
        map = Map<String, Object?>.from(value);
      } on Object {
        throw FormatException('$path must have string keys');
      }
      final Map<String, Object?> checked = <String, Object?>{};
      for (final MapEntry<String, Object?> entry in map.entries) {
        if (sensitiveKeys.contains(
          entry.key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), ''),
        )) {
          throw PatchbayLogRedactionFailure('$path.${entry.key}');
        }
        checked[entry.key] = check(entry.value, '$path.${entry.key}');
      }
      return checked;
    }
    throw FormatException('$path must be JSON-compatible');
  }

  return check(fields, r'$.fields')! as Map<String, Object?>;
}
