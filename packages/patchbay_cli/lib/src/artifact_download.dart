import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:patchbay/patchbay.dart';

final class PatchbayArtifactDownloadException implements Exception {
  const PatchbayArtifactDownloadException(this.code);

  final String code;
}

final class PatchbayArtifactRejected implements Exception {
  const PatchbayArtifactRejected(this.response);

  final Map<String, Object?> response;
}

final class PatchbayDownloadedArtifact {
  const PatchbayDownloadedArtifact({
    required this.path,
    required this.blobId,
    required this.length,
    required this.sha256,
    required this.contentType,
  });

  final String path;
  final String blobId;
  final int length;
  final String sha256;
  final String contentType;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'blobId': blobId,
    'length': length,
    'sha256': sha256,
    'contentType': contentType,
    'verified': true,
  };
}

typedef PatchbayArtifactInvoker =
    Future<Map<String, Object?>> Function(
      String command,
      Map<String, Object?> arguments,
    );

final class PatchbayArtifactDownloader {
  PatchbayArtifactDownloader({
    required PatchbayArtifactInvoker invoke,
    this.maxArtifactBytes = 64 * 1024 * 1024,
    this.chunkBytes = defaultChunkBytes,
  }) : _invoke = invoke {
    if (maxArtifactBytes <= 0) {
      throw ArgumentError.value(maxArtifactBytes, 'maxArtifactBytes');
    }
    if (chunkBytes <= 0) {
      throw ArgumentError.value(chunkBytes, 'chunkBytes');
    }
  }

  /// Chunk size used when the host declares no limit of its own.
  static const int defaultChunkBytes = 64 * 1024;

  final PatchbayArtifactInvoker _invoke;
  final int maxArtifactBytes;

  /// Bytes requested per `blob.read`.
  ///
  /// The host publishes its own ceiling as the `limit` parameter default and
  /// rejects anything above it, so this is the App's number, not the CLI's: a
  /// hardcoded constant is right only by coincidence, and a consumer that
  /// lowered the ceiling would see every artifact download refused with
  /// `blobInvalidChunkLimit`.
  final int chunkBytes;

  Future<PatchbayDownloadedArtifact> download({
    required Map<String, Object?> metadataJson,
    required String outputPath,
    required bool force,
  }) async {
    final PatchbayBlobMetadataWire metadata = _metadata(metadataJson);
    if (metadata.length < 0 || metadata.length > maxArtifactBytes) {
      throw const PatchbayArtifactDownloadException('blobLengthOutOfBounds');
    }
    final File output = File(outputPath).absolute;
    final Directory parent = output.parent;
    if (!await parent.exists()) {
      throw const FormatException('--output parent directory does not exist');
    }
    if (!force && await output.exists()) {
      throw const FormatException('--output already exists; use --force');
    }

    final File temporary = File(
      '${output.path}.patchbay-part-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    IOSink? fileSink;
    ByteConversionSink? hashSink;
    final _DigestSink digestSink = _DigestSink();
    var completed = false;
    try {
      await temporary.create(exclusive: true);
      fileSink = temporary.openWrite();
      hashSink = sha256.startChunkedConversion(digestSink);
      var offset = 0;
      var eof = false;
      do {
        final Map<String, Object?> response = await _invoke(
          'blob.read',
          <String, Object?>{
            'blobId': metadata.blobId,
            'offset': offset,
            'limit': chunkBytes,
          },
        );
        final Map<String, Object?> payload = _acceptedPayload(response);
        final PatchbayBlobChunkWire chunk;
        try {
          chunk = PatchbayBlobChunkWire.fromJson(payload);
        } on Object {
          throw const PatchbayArtifactDownloadException(
            'blobChunkContractViolated',
          );
        }
        final List<int> bytes;
        try {
          bytes = base64Decode(chunk.dataBase64);
        } on FormatException {
          throw const PatchbayArtifactDownloadException('blobBase64Invalid');
        }
        if (chunk.metadata.blobId != metadata.blobId ||
            chunk.metadata.length != metadata.length ||
            chunk.metadata.sha256 != metadata.sha256 ||
            chunk.offset != offset ||
            chunk.length != bytes.length ||
            chunk.nextOffset != offset + bytes.length ||
            chunk.nextOffset > metadata.length ||
            chunk.eof != (chunk.nextOffset == metadata.length) ||
            !chunk.eof && bytes.isEmpty) {
          throw const PatchbayArtifactDownloadException(
            'blobChunkContractViolated',
          );
        }
        fileSink.add(bytes);
        hashSink.add(bytes);
        offset = chunk.nextOffset;
        eof = chunk.eof;
      } while (!eof);
      await fileSink.flush();
      await fileSink.close();
      fileSink = null;
      hashSink.close();
      hashSink = null;
      if (offset != metadata.length ||
          digestSink.value?.toString() != metadata.sha256) {
        throw const PatchbayArtifactDownloadException('blobIntegrityMismatch');
      }
      await temporary.rename(output.path);
      completed = true;
      return PatchbayDownloadedArtifact(
        path: output.path,
        blobId: metadata.blobId,
        length: metadata.length,
        sha256: metadata.sha256,
        contentType: metadata.contentType,
      );
    } finally {
      if (fileSink != null) await fileSink.close();
      hashSink?.close();
      if (!completed && await temporary.exists()) await temporary.delete();
    }
  }

  static PatchbayBlobMetadataWire _metadata(Map<String, Object?> json) {
    try {
      return PatchbayBlobMetadataWire.fromJson(json);
    } on Object {
      throw const PatchbayArtifactDownloadException(
        'blobMetadataContractViolated',
      );
    }
  }

  static Map<String, Object?> _acceptedPayload(Map<String, Object?> response) {
    if (response['admission'] == 'rejected') {
      throw PatchbayArtifactRejected(response);
    }
    final Object? payload = response['payload'];
    if (payload is! Map<String, Object?>) {
      throw const PatchbayArtifactDownloadException(
        'blobPayloadContractViolated',
      );
    }
    return payload;
  }
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
