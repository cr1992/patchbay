import 'dart:convert';
import 'dart:math';

import '../artifact_download.dart';
import '../command_registry.dart';
import '../support/catalog_descriptor.dart';
import '../result.dart';

/// Request for downloading an artifact from command output.
final class ArtifactRequest {
  const ArtifactRequest({
    required this.disposition,
    required this.outputPath,
    required this.force,
  });

  final PatchbayArtifactDisposition disposition;
  final String outputPath;
  final bool force;
}

/// Execution outcome for one dispatch.
final class ExecutionResult {
  const ExecutionResult(
    this.response, {
    this.catalog,
    this.artifact,
    this.exitCode,
    this.summary,
  });

  final Map<String, Object?> response;
  final Map<String, Object?>? catalog;
  final ArtifactRequest? artifact;

  /// Set only when the CLI itself decided the outcome, so the classification of
  /// an App response stays in one place.
  final int? exitCode;
  final String? summary;
}

/// Final outcome of a CLI execution.
final class Outcome {
  const Outcome(this.response, this.exitCode, {this.summary, this.catalog});

  final Map<String, Object?> response;
  final int exitCode;

  /// PB-050-40: the host catalog this dispatch ran against, carried to the
  /// render seam so the projection can be resolved from the host's own
  /// declaration. `null` for a command that never reads a catalog — the
  /// CLI-local declaration and the frozen fallback still answer for those.
  final Map<String, Object?>? catalog;

  /// Human rendering for the one-shot path, when one line cannot carry the
  /// result. `null` keeps the shared per-response summary.
  final String? summary;
}

/// Output formatting and artifact helper utilities.
abstract final class OutputFormatter {
  static void writeOutput(
    StringSink out,
    Map<String, Object?> output, {
    required bool json,
    String? summary,
  }) {
    out.writeln(
      json
          ? const JsonEncoder.withIndent('  ').convert(output)
          : summary ?? patchbayResponseSummary(output),
    );
  }

  static Map<String, Object?> artifactMetadata(
    Map<String, Object?> response,
    PatchbayArtifactDisposition disposition,
  ) {
    final Object? payload = response['payload'];
    if (payload is! Map<String, Object?>) {
      throw const PatchbayArtifactDownloadException(
        'artifactPayloadContractViolated',
      );
    }
    final Object? metadata = switch (disposition) {
      PatchbayArtifactDisposition.responseBlob => payload,
      PatchbayArtifactDisposition.payloadBlob => payload['blob'],
      PatchbayArtifactDisposition.none => null,
      // `renderedMember` never reaches `PatchbayArtifactDownloader`: there is
      // no host blob to fetch, so it never calls this helper. Reached only
      // if that invariant breaks.
      PatchbayArtifactDisposition.renderedMember => throw StateError(
        'renderedMember commands do not use artifactMetadata',
      ),
    };
    if (metadata is! Map<String, Object?>) {
      throw const PatchbayArtifactDownloadException(
        'artifactMetadataContractViolated',
      );
    }
    return metadata;
  }

  /// The `blob.read` chunk size this host will actually accept.
  static int blobChunkBytes(Map<String, Object?> catalog) {
    final int? declared = CatalogCommandDescriptor.find(
      catalog,
      'blob.read',
    )?.positiveIntegerDefault('limit');
    if (declared == null) return PatchbayArtifactDownloader.defaultChunkBytes;
    return min(declared, PatchbayArtifactDownloader.defaultChunkBytes);
  }
}
