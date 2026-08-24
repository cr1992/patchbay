import 'package:patchbay/patchbay.dart';

import '../client.dart';

/// Stable code for "this App is too old to understand a snapshot selector".
const String patchbaySnapshotSelectorUnsupportedCode =
    'snapshotSelectionUnsupportedByHost';

/// Runner responsible for snapshot selection, degradation, and revision diffing.
abstract final class SnapshotRunner {
  /// Fetches a selected snapshot, gracefully degrading with typed rejection if host does not support selectors.
  static Future<Map<String, Object?>> selectedSnapshot(
    PatchbayClient connection,
    PatchbaySnapshotRequest request,
  ) async {
    final Set<String>? features = patchbayDeclaredFeatures(
      await connection.identity(),
    );
    if (!(features?.contains(PatchbayFeature.snapshotSelectors.name) ??
        false)) {
      return snapshotSelectorUnsupported();
    }
    return connection.snapshot(request: request);
  }

  /// Fetches snapshot diff against [fromRevision], falling back to full snapshot on older hosts.
  static Future<Map<String, Object?>> snapshotDiff(
    PatchbayClient connection,
    int fromRevision,
  ) async {
    final Set<String>? features = patchbayDeclaredFeatures(
      await connection.identity(),
    );
    if (!(features?.contains(PatchbayFeature.snapshotRevisionDiff.name) ??
        false)) {
      final Map<String, Object?> snapshot = await connection.snapshot();
      return <String, Object?>{
        ...snapshot,
        'snapshotMode': 'legacyFull',
        'notice':
            'This App does not declare snapshot revision diff support; returned '
            'the full snapshot without sending a diff request.',
      };
    }
    if (connection is! PatchbaySnapshotDiffClient) {
      throw const PatchbayProtocolException('snapshotDiffClientUnavailable');
    }
    return (connection as PatchbaySnapshotDiffClient).snapshotDiff(
      fromRevision: fromRevision,
    );
  }

  /// Rejection payload when snapshot selector is unsupported by host.
  static Map<String, Object?> snapshotSelectorUnsupported() {
    const String notice =
        'This App does not support snapshot field selection or waits. Run '
        '`patchbay snapshot` for the whole snapshot, or update the App to a '
        'Patchbay version that serves selectors.';
    return <String, Object?>{
      'schemaVersion': PatchbayServiceHost.schemaVersion,
      'admission': 'rejected',
      'notice': notice,
      'rejection': PatchbayRejection(
        code: patchbaySnapshotSelectorUnsupportedCode,
        notice: notice,
      ).toJson(),
    };
  }
}
