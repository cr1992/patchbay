import 'generated/core_wire.g.dart';

/// Closed vocabulary of snapshot-domain wait conditions.
///
/// It is deliberately not an expression language. A predicate the host has to
/// interpret would put a second, untested evaluator between the operator and
/// the App, and every debugging answer it produced would be one more thing to
/// doubt. Three conditions cover what a wait is actually for — the field turned
/// up, the field went away, the field reached a value — and anything else is a
/// full `snapshot` read the caller inspects themselves.
enum PatchbaySnapshotCondition {
  /// The path resolves to a non-null value.
  exists,

  /// The path resolves to nothing: the key is missing or its value is null.
  ///
  /// A path that runs into a non-object ([PatchbaySnapshotMiss.notAnObject])
  /// deliberately does *not* satisfy this. "The field is not there" and "this
  /// path contradicts the shape of the snapshot" are different answers, and
  /// collapsing them would let a mistyped path report success.
  absent,

  /// The path resolves to a value deeply equal to the declared one.
  equals;

  PatchbaySnapshotConditionWire get wire => switch (this) {
    PatchbaySnapshotCondition.exists => PatchbaySnapshotConditionWire.exists,
    PatchbaySnapshotCondition.absent => PatchbaySnapshotConditionWire.absent,
    PatchbaySnapshotCondition.equals => PatchbaySnapshotConditionWire.equals,
  };

  static PatchbaySnapshotCondition fromWire(
    PatchbaySnapshotConditionWire wire,
  ) => switch (wire) {
    PatchbaySnapshotConditionWire.exists => exists,
    PatchbaySnapshotConditionWire.absent => absent,
    PatchbaySnapshotConditionWire.equals => equals,
  };
}

/// Why a path resolved to nothing.
///
/// A bare `found: false` cannot tell a field that has not appeared yet from a
/// path that can never resolve against this snapshot, which is exactly the
/// difference between "wait longer" and "fix the path".
enum PatchbaySnapshotMiss {
  /// A segment names a key the object at that level does not have.
  missingKey,

  /// A segment resolved to JSON null.
  nullValue,

  /// A segment before the last resolved to a present, non-null non-object, so
  /// the remaining segments have nothing to index into.
  notAnObject;

  PatchbaySnapshotMissWire get wire => switch (this) {
    PatchbaySnapshotMiss.missingKey => PatchbaySnapshotMissWire.missingKey,
    PatchbaySnapshotMiss.nullValue => PatchbaySnapshotMissWire.nullValue,
    PatchbaySnapshotMiss.notAnObject => PatchbaySnapshotMissWire.notAnObject,
  };

  static PatchbaySnapshotMiss fromWire(PatchbaySnapshotMissWire wire) =>
      switch (wire) {
        PatchbaySnapshotMissWire.missingKey => missingKey,
        PatchbaySnapshotMissWire.nullValue => nullValue,
        PatchbaySnapshotMissWire.notAnObject => notAnObject,
      };
}

/// Longest wait the host will accept, matching the `ui.wait` family.
const Duration patchbaySnapshotWaitCeiling = Duration(minutes: 2);

/// How often the host re-reads the consumer snapshot while waiting.
///
/// The snapshot source is a pull-only callback: unlike the Flutter UI plane
/// there is no frame or change signal to advance on, so the host polls it. The
/// polling stays *inside* one request — that is the whole point of the feature.
/// A client that polled instead would pay a full round trip per probe, and on
/// the VM Service path each of those is a WebSocket exchange with an App the
/// operator is usually debugging over a cable.
const Duration patchbaySnapshotPollInterval = Duration(milliseconds: 100);

/// Validated request for one snapshot field selection, optionally waited on.
final class PatchbaySnapshotRequest {
  PatchbaySnapshotRequest({
    required this.path,
    this.until,
    this.value,
    this.timeout,
  }) {
    if (!_path.hasMatch(path)) {
      throw FormatException(
        'path must be dot-separated segments matching ${_path.pattern}',
      );
    }
    if (until == null) {
      if (value != null) {
        throw const FormatException('value requires until: equals');
      }
      if (timeout != null) {
        throw const FormatException('timeoutMs requires until');
      }
      return;
    }
    if (timeout == null) {
      throw const FormatException('a wait requires timeoutMs');
    }
    if (timeout! <= Duration.zero || timeout! > patchbaySnapshotWaitCeiling) {
      throw FormatException(
        'timeoutMs must be greater than zero and at most '
        '${patchbaySnapshotWaitCeiling.inMilliseconds}',
      );
    }
    if ((until == PatchbaySnapshotCondition.equals) != (value != null)) {
      throw const FormatException(
        'until: equals requires value, and value is accepted only with it',
      );
    }
  }

  /// Decodes one wire request.
  ///
  /// Every failure is a [FormatException] — including the range check the
  /// `ui.wait` decoder expresses as an `ArgumentError` — so a caller has one
  /// exception type to translate into one rejection, and no malformed request
  /// can escape as an error class the host does not answer.
  factory PatchbaySnapshotRequest.fromWire(PatchbaySnapshotRequestWire wire) =>
      PatchbaySnapshotRequest(
        path: wire.path,
        until: wire.until == null
            ? null
            : PatchbaySnapshotCondition.fromWire(wire.until!),
        value: wire.value,
        timeout: wire.timeoutMs == null
            ? null
            : Duration(milliseconds: wire.timeoutMs!),
      );

  /// Dot path into the served snapshot object.
  final String path;

  /// The condition to wait for, or null for a plain selection.
  final PatchbaySnapshotCondition? until;

  /// The JSON literal [PatchbaySnapshotCondition.equals] compares against.
  final Object? value;

  /// Wait budget; null for a plain selection.
  final Duration? timeout;

  /// Whether this request asks the host to wait rather than answer at once.
  bool get isWait => until != null;

  PatchbaySnapshotRequestWire toWire() => PatchbaySnapshotRequestWire(
    path: path,
    until: until?.wire,
    value: value,
    timeoutMs: timeout?.inMilliseconds,
  );

  /// Accepted path syntax, deliberately the same charset as a stable
  /// destination id: dot-separated `[A-Za-z0-9_-]` segments.
  ///
  /// A snapshot is consumer-shaped JSON and may legitimately hold keys outside
  /// this charset — including keys containing a dot, which no dot path could
  /// address unambiguously. Those stay reachable through a full `snapshot`
  /// read; refusing them here is what keeps one path string from having two
  /// readings.
  static final RegExp _path = RegExp(r'^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$');
}

/// One resolution of a [PatchbaySnapshotRequest.path] against a snapshot.
final class PatchbaySnapshotSelection {
  const PatchbaySnapshotSelection.found(this.path, this.value) : miss = null;

  const PatchbaySnapshotSelection.missing(
    this.path,
    PatchbaySnapshotMiss this.miss,
  ) : value = null;

  /// Resolves [path] against [snapshot], segment by segment.
  ///
  /// The value is returned verbatim, including whole subtrees. It is a slice of
  /// what the snapshot RPC already serves, never a re-derived or summarised
  /// view: a debugging read that reshapes what it read is a read nobody can
  /// reason about.
  factory PatchbaySnapshotSelection.resolve(
    Map<String, Object?> snapshot,
    String path,
  ) {
    Object? current = snapshot;
    final List<String> segments = path.split('.');
    for (var index = 0; index < segments.length; index += 1) {
      if (current == null) {
        return PatchbaySnapshotSelection.missing(
          path,
          PatchbaySnapshotMiss.nullValue,
        );
      }
      if (current is! Map<Object?, Object?>) {
        return PatchbaySnapshotSelection.missing(
          path,
          PatchbaySnapshotMiss.notAnObject,
        );
      }
      final String segment = segments[index];
      if (!current.containsKey(segment)) {
        return PatchbaySnapshotSelection.missing(
          path,
          PatchbaySnapshotMiss.missingKey,
        );
      }
      current = current[segment];
    }
    return current == null
        ? PatchbaySnapshotSelection.missing(
            path,
            PatchbaySnapshotMiss.nullValue,
          )
        : PatchbaySnapshotSelection.found(path, current);
  }

  final String path;

  /// The resolved value, or null when this is a miss.
  final Object? value;

  /// Why the path resolved to nothing, or null when it resolved.
  final PatchbaySnapshotMiss? miss;

  bool get found => miss == null;

  /// Whether [condition] holds for this resolution.
  bool satisfies(PatchbaySnapshotCondition condition, Object? expected) =>
      switch (condition) {
        PatchbaySnapshotCondition.exists => found,
        // `notAnObject` is a path that contradicts the snapshot, not a field
        // that is absent; see [PatchbaySnapshotCondition.absent].
        PatchbaySnapshotCondition.absent =>
          miss == PatchbaySnapshotMiss.missingKey ||
              miss == PatchbaySnapshotMiss.nullValue,
        PatchbaySnapshotCondition.equals =>
          found && patchbayJsonEquals(value, expected),
      };

  PatchbaySnapshotSelectionWire toWire() => PatchbaySnapshotSelectionWire(
    path: path,
    found: found,
    value: value,
    miss: miss?.wire,
  );

  Map<String, Object?> toJson() => toWire().toJson();
}

/// Structural equality for two decoded JSON values.
///
/// `==` on maps and lists is identity in Dart, so a declared `{"a": 1}` would
/// never match an equal object the App just built. Numbers compare by value, so
/// a JSON `1` matches a `1.0` the consumer computed — the wire cannot tell an
/// operator which one they typed.
bool patchbayJsonEquals(Object? left, Object? right) {
  if (left is Map<Object?, Object?>) {
    if (right is! Map<Object?, Object?> || left.length != right.length) {
      return false;
    }
    for (final Object? key in left.keys) {
      if (!right.containsKey(key)) return false;
      if (!patchbayJsonEquals(left[key], right[key])) return false;
    }
    return true;
  }
  if (left is List<Object?>) {
    if (right is! List<Object?> || left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (!patchbayJsonEquals(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}
