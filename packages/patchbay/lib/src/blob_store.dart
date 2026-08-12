import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'generated/core_wire.g.dart';

enum PatchbayBlobFailureCode {
  notFound,
  expired,
  offsetOutOfBounds,
  invalidChunkLimit,
  invalidTtl,
  blobTooLarge,
  capacityExceeded,
}

final class PatchbayBlobFailure implements Exception {
  const PatchbayBlobFailure(this.code, {this.details = const {}});

  final PatchbayBlobFailureCode code;
  final Map<String, Object?> details;

  @override
  String toString() => 'PatchbayBlobFailure(${code.name})';
}

/// Bounded, process-local storage for binary artifacts.
///
/// Bytes are copied on admission and never returned whole through the service
/// protocol. Expiration is lazy and capacity failures are explicit: the store
/// does not evict a live artifact behind a client's cursor.
final class PatchbayMemoryBlobStore {
  PatchbayMemoryBlobStore({
    this.capacityBytes = 16 * 1024 * 1024,
    this.maxChunkBytes = 64 * 1024,
    this.defaultTtl = const Duration(minutes: 5),
    this.maxTtl = const Duration(minutes: 15),
    DateTime Function()? now,
    String Function()? idFactory,
  }) : _now = now ?? DateTime.now,
       _idFactory = idFactory ?? _randomId {
    if (capacityBytes <= 0 || maxChunkBytes <= 0) {
      throw ArgumentError('Blob capacity and chunk limits must be positive.');
    }
    if (defaultTtl <= Duration.zero ||
        maxTtl <= Duration.zero ||
        defaultTtl > maxTtl) {
      throw ArgumentError('Blob TTL limits are inconsistent.');
    }
  }

  final int capacityBytes;
  final int maxChunkBytes;
  final Duration defaultTtl;
  final Duration maxTtl;
  final DateTime Function() _now;
  final String Function() _idFactory;
  final Map<String, _BlobEntry> _entries = <String, _BlobEntry>{};
  final LinkedHashMap<String, DateTime> _expired =
      LinkedHashMap<String, DateTime>();
  int _storedBytes = 0;

  int get storedBytes {
    _pruneExpired();
    return _storedBytes;
  }

  PatchbayBlobMetadataWire put(
    Uint8List bytes, {
    required PatchbayBlobSourceWire kind,
    required PatchbayFactSourceWire source,
    required String contentType,
    Duration? ttl,
    String? filename,
    Map<String, Object?> properties = const <String, Object?>{},
  }) {
    final Duration effectiveTtl = ttl ?? defaultTtl;
    if (effectiveTtl <= Duration.zero || effectiveTtl > maxTtl) {
      throw PatchbayBlobFailure(
        PatchbayBlobFailureCode.invalidTtl,
        details: <String, Object?>{'maxTtlMs': maxTtl.inMilliseconds},
      );
    }
    if (bytes.length > capacityBytes) {
      throw PatchbayBlobFailure(
        PatchbayBlobFailureCode.blobTooLarge,
        details: <String, Object?>{
          'length': bytes.length,
          'capacityBytes': capacityBytes,
        },
      );
    }
    _pruneExpired();
    if (_storedBytes + bytes.length > capacityBytes) {
      throw PatchbayBlobFailure(
        PatchbayBlobFailureCode.capacityExceeded,
        details: <String, Object?>{
          'requestedBytes': bytes.length,
          'storedBytes': _storedBytes,
          'capacityBytes': capacityBytes,
        },
      );
    }
    final DateTime createdAt = _now().toUtc();
    final Uint8List copy = Uint8List.fromList(bytes);
    String blobId;
    do {
      blobId = _idFactory();
    } while (_entries.containsKey(blobId));
    final PatchbayBlobMetadataWire candidate = PatchbayBlobMetadataWire(
      blobId: blobId,
      source: source,
      kind: kind,
      contentType: contentType,
      length: copy.length,
      sha256: crypto.sha256.convert(copy).toString(),
      createdAt: createdAt.toIso8601String(),
      expiresAt: createdAt.add(effectiveTtl).toIso8601String(),
      filename: filename,
      properties: properties,
    );
    // Round-trip through the generated codec to validate and deep-copy
    // caller-owned JSON metadata before retaining it.
    final PatchbayBlobMetadataWire metadata = PatchbayBlobMetadataWire.fromJson(
      candidate.toJson(),
    );
    _entries[blobId] = _BlobEntry(
      bytes: copy,
      metadata: metadata,
      expiresAt: createdAt.add(effectiveTtl),
    );
    _storedBytes += copy.length;
    return metadata;
  }

  PatchbayBlobMetadataWire metadata(String blobId) =>
      _metadataCopy(_entry(blobId).metadata);

  PatchbayBlobChunkWire read({
    required String blobId,
    required int offset,
    required int limit,
  }) {
    if (limit <= 0 || limit > maxChunkBytes) {
      throw PatchbayBlobFailure(
        PatchbayBlobFailureCode.invalidChunkLimit,
        details: <String, Object?>{'maxChunkBytes': maxChunkBytes},
      );
    }
    final _BlobEntry entry = _entry(blobId);
    if (offset < 0 || offset > entry.bytes.length) {
      throw PatchbayBlobFailure(
        PatchbayBlobFailureCode.offsetOutOfBounds,
        details: <String, Object?>{
          'offset': offset,
          'length': entry.bytes.length,
        },
      );
    }
    final int end = min(offset + limit, entry.bytes.length);
    return PatchbayBlobChunkWire(
      metadata: _metadataCopy(entry.metadata),
      offset: offset,
      length: end - offset,
      nextOffset: end,
      eof: end == entry.bytes.length,
      dataBase64: base64Encode(entry.bytes.sublist(offset, end)),
    );
  }

  static PatchbayBlobMetadataWire _metadataCopy(
    PatchbayBlobMetadataWire metadata,
  ) => PatchbayBlobMetadataWire.fromJson(metadata.toJson());

  _BlobEntry _entry(String blobId) {
    final _BlobEntry? entry = _entries[blobId];
    if (entry != null && !_isExpired(entry)) return entry;
    if (entry != null) _expire(blobId, entry);
    if (_expired.containsKey(blobId)) {
      throw const PatchbayBlobFailure(PatchbayBlobFailureCode.expired);
    }
    throw const PatchbayBlobFailure(PatchbayBlobFailureCode.notFound);
  }

  void _pruneExpired() {
    for (final MapEntry<String, _BlobEntry> entry in _entries.entries.toList(
      growable: false,
    )) {
      if (_isExpired(entry.value)) _expire(entry.key, entry.value);
    }
  }

  bool _isExpired(_BlobEntry entry) =>
      !_now().toUtc().isBefore(entry.expiresAt);

  void _expire(String blobId, _BlobEntry entry) {
    if (_entries.remove(blobId) == null) return;
    _storedBytes -= entry.bytes.length;
    _expired[blobId] = _now().toUtc();
    while (_expired.length > 1024) {
      _expired.remove(_expired.keys.first);
    }
  }

  static String _randomId() {
    final Random random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((int byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}

final class _BlobEntry {
  const _BlobEntry({
    required this.bytes,
    required this.metadata,
    required this.expiresAt,
  });

  final Uint8List bytes;
  final PatchbayBlobMetadataWire metadata;
  final DateTime expiresAt;
}
