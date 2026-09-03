import 'dart:async';

import 'package:patchbay_flutter/patchbay_flutter_host.dart';

/// One example-authored log line, kept in the shape the example can filter on.
///
/// `PatchbayRedactedLogRecord` intentionally exposes no getters — it is a
/// write-only envelope so a consumer cannot read a record back out of the
/// protocol layer and re-derive text it already redacted. The example
/// therefore keeps its own struct and builds the protocol record only when a
/// page is served.
final class ExampleLogEntry {
  ExampleLogEntry({
    required this.cursor,
    required this.at,
    required this.level,
    required this.category,
    required this.message,
    this.fields = const <String, Object?>{},
  });

  final String cursor;
  final DateTime at;
  final PatchbayLogLevelWire level;
  final String category;
  final String message;
  final Map<String, Object?> fields;

  PatchbayRedactedLogRecord toRecord() => PatchbayRedactedLogRecord(
    cursor: cursor,
    at: at,
    level: level,
    category: category,
    message: message,
    fields: fields,
  );
}

/// A bounded, already-redacted log source for the example app.
///
/// Redaction is the consumer's job, not the transport's: every record here is
/// written by the example itself. Nothing forwards real framework or app log
/// output — a debug channel that did would ship whatever the app happened to
/// log, which is exactly what the protocol refuses to promise on the app's
/// behalf.
final class ExampleLogSource implements PatchbayLogSource {
  ExampleLogSource({this.capacity = 200});

  final int capacity;
  final List<ExampleLogEntry> _entries = <ExampleLogEntry>[];
  final List<void Function()> _waiters = <void Function()>[];
  int _sequence = 0;

  int get length => _entries.length;

  void write({
    required String category,
    required String message,
    PatchbayLogLevelWire level = PatchbayLogLevelWire.info,
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    _sequence += 1;
    _entries.add(
      ExampleLogEntry(
        cursor: _sequence.toString().padLeft(9, '0'),
        at: DateTime.now(),
        level: level,
        category: category,
        message: message,
        fields: fields,
      ),
    );
    while (_entries.length > capacity) {
      _entries.removeAt(0);
    }
    final List<void Function()> waiting = List<void Function()>.of(_waiters);
    _waiters.clear();
    for (final void Function() waiter in waiting) {
      waiter();
    }
  }

  @override
  Future<PatchbayLogPage> query(
    PatchbayLogQuery query,
    PatchbayCancellationSignal cancellation,
  ) async => _page(query);

  @override
  Future<PatchbayLogPage> tail(
    PatchbayLogQuery query,
    PatchbayCancellationSignal cancellation,
  ) async {
    final PatchbayLogPage immediate = _page(query);
    if (immediate.records.isNotEmpty ||
        immediate.state != PatchbayLogPageState.records) {
      return immediate;
    }

    // The service owns the outer timeout and cancels this signal when it
    // expires or is disposed, so waiting here cannot outlive the caller.
    final Completer<void> arrival = Completer<void>();
    void wake() {
      if (!arrival.isCompleted) arrival.complete();
    }

    _waiters.add(wake);
    unawaited(cancellation.cancelled.then((_) => wake()));
    await arrival.future;
    _waiters.remove(wake);
    return _page(query);
  }

  PatchbayLogPage _page(PatchbayLogQuery query) {
    final String? cursor = query.cursor;
    if (cursor != null &&
        _entries.isNotEmpty &&
        cursor.compareTo(_entries.first.cursor) < 0) {
      // The caller's cursor fell out of the retained window. Say so instead of
      // silently restarting from the oldest record still held — a scripted
      // tail would otherwise re-read history it already processed.
      return PatchbayLogPage.staleCursor(currentCursor: _entries.first.cursor);
    }
    Iterable<ExampleLogEntry> selected = _entries;
    if (cursor != null) {
      selected = selected.where(
        (ExampleLogEntry entry) => entry.cursor.compareTo(cursor) > 0,
      );
    }
    if (query.levels.isNotEmpty) {
      selected = selected.where(
        (ExampleLogEntry entry) => query.levels.contains(entry.level),
      );
    }
    if (query.categories.isNotEmpty) {
      selected = selected.where(
        (ExampleLogEntry entry) => query.categories.contains(entry.category),
      );
    }
    final List<ExampleLogEntry> page = selected
        .take(query.limit)
        .toList(growable: false);
    return PatchbayLogPage.records(
      records: page
          .map((ExampleLogEntry entry) => entry.toRecord())
          .toList(growable: false),
      nextCursor: page.isEmpty ? cursor : page.last.cursor,
    );
  }
}
