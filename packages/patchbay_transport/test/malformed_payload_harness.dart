// PB-060-06: shared malformed-payload harness for the direct transport's
// decode boundary.
//
// Why a shared harness instead of per-feature cases: 0.6.0 extends
// descriptor/wire fields, and a Proposal that only fuzzes its own new field
// re-derives the generators every time while still proving nothing about the
// operations it did not touch. This file owns three things instead:
//
//   1. a closed registry of every wire operation the transport decodes, kept
//      honest against the source by `hostOperationsInSource` /
//      `clientOperationsInSource` (a new operation that skips the registry
//      turns the closure test red);
//   2. deterministic generators for the three malformation classes the version
//      plan names — byte truncation, field type substitution and bounded
//      oversized strings;
//   3. the closed sets a rejection must land in, so "typed rejection" is a
//      machine-checked claim rather than a review note.
//
// Reproducibility: every generator draws from a seeded [Random]. The seed is
// fixed by default and overridable through `PATCHBAY_MALFORMED_SEED`, so a
// failing case can be replayed byte for byte.
//
// Boundaries this harness deliberately does not cross:
//   - it never mutates *inside* a forwarded object (`snapshot.request`,
//     `invoke.arguments`). What a selector may contain is the protocol
//     package's rule; a transport test that asserted a shape there would be
//     the second decoder `protocol.dart` explicitly refuses to grow.
//   - it never generates unbounded input. Oversized strings are capped by
//     [maxGeneratedStringBytes], and the single over-limit case is capped by
//     [overLimitBodyBytes].
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:patchbay_transport/patchbay_transport.dart';

/// Default seed. `0x50424D50` is ASCII `PBMP` (patchbay malformed payload).
const int defaultMalformedSeed = 0x50424D50;

/// Marker woven into every string-bearing malformation.
///
/// A rejection is allowed to say *which* typed code it is; it is not allowed to
/// quote the payload back. Asserting on one improbable marker is enough to
/// catch an echo, and unlike a length heuristic it cannot pass by accident.
const String payloadSentinel = 'pb-malformed-sentinel-4f21c8';

/// Upper bound for a generated oversized string, in bytes.
///
/// Chosen to stay under the host's default 64 KiB request cap so the case
/// exercises the *field* decoder rather than the body limiter.
const int maxGeneratedStringBytes = 32 * 1024;

/// Lower bound for a generated oversized string, in bytes.
const int minGeneratedStringBytes = 1024;

/// A body deliberately past the host's default request cap.
const int overLimitBodyBytes = 96 * 1024;

/// Sentinel status for "the host closed before answering".
///
/// Not an error condition to paper over — it is the **second legitimate
/// fail-closed outcome** of an over-limit upload, and the harness has to name it
/// to keep the strong assertions honest.
///
/// `PatchbayDirectHost` refuses on the declared `Content-Length` *before*
/// reading the body (`direct_host.dart` `_readBoundedBody`), which is the right
/// call: reading 96 KiB just to refuse it would be the resource exhaustion the
/// cap exists to prevent. But that means the host writes `413` and closes while
/// the client is still uploading, so the client legitimately races and may see
/// the socket close instead of the answer. Measured here: ~2 in 30 runs, on
/// whichever operation happened to lose the race (BUG-20260831-01).
///
/// What this outcome does **not** excuse: the payload must still never be
/// accepted and no application handler may run. Those invariants stay
/// unconditional; only the observability of the typed answer is racy.
const int closedBeforeAnswer = -1;

/// Truncation offsets drawn per operation.
const int truncationsPerOperation = 6;

/// Identity pinned by the harness host.
const PatchbayDirectIdentity harnessIdentity = PatchbayDirectIdentity(
  schemaVersion: 1,
  applicationId: 'com.example.harness',
  appInstanceId: 'harness-instance-0001',
);

/// A syntactically valid owner token: 22 chars of `[A-Za-z0-9_-]`.
const String validOwnerToken = 'AAAAAAAAAAAAAAAAAAAAAA';

/// Non-ASCII payload used so byte-level truncation can split a UTF-8 sequence.
///
/// Without it, truncation would only ever produce invalid JSON; with it the
/// same generator also reaches the `utf8.decode` failure path.
const String multiByteMarker = '边界哨兵';

/// HTTP statuses the host is allowed to answer a malformed payload with.
///
/// Deliberately tighter than "every status the host can emit": a payload that
/// carries valid credentials and no browser Origin must be classified at the
/// decode boundary, so `401` / `403` / `429` are as much a failure here as a
/// `500` would be. Measured against the current generators the host only ever
/// answers `400`, `409` and `413`.
const Set<int> closedRejectionStatuses = <int>{
  HttpStatus.badRequest,
  HttpStatus.conflict,
  HttpStatus.requestEntityTooLarge,
};

/// Error codes a malformed payload may produce.
///
/// `internalError`, `timeout` and `responseTooLarge` are intentionally absent:
/// a malformed request must be classified at the decode boundary, not escalate
/// into a handler fault or a hang.
final Set<String> closedRejectionCodes = <String>{
  PatchbayDirectErrorCode.protocolError.name,
  PatchbayDirectErrorCode.identityMismatch.name,
  PatchbayDirectErrorCode.bodyTooLarge.name,
};

/// Client-side codes a malformed *response* may produce.
final Set<String> closedClientRejectionCodes = <String>{
  'protocolError',
  'identityMismatch',
  'transportError',
  'responseTooLarge',
  'requestIdMismatch',
  'timeout',
};

/// How the transport treats one field it decodes itself.
enum DecodedFieldKind {
  /// Integer compared against the pinned identity.
  identitySchemaVersion,

  /// String compared against the pinned identity.
  identityString,

  /// Required non-empty string whose vocabulary the transport does not own.
  ///
  /// Length is bounded by the request cap, not by the field decoder, so an
  /// oversized value here is forwarded rather than rejected.
  opaqueRequiredString,

  /// Fully validated fixed-shape token (charset and exact length).
  boundedToken,

  /// Same as [boundedToken], but absent or `null` means "not supplied".
  optionalBoundedToken,

  /// Required JSON object, forwarded verbatim.
  requiredObject,

  /// Optional JSON object; absent or `null` both mean "none".
  optionalObject,
}

/// One field of one operation, plus what the transport must reject in it.
final class DecodedField {
  const DecodedField(this.name, this.kind);

  final String name;
  final DecodedFieldKind kind;

  /// Values the transport must refuse. Exhaustive over a closed set on purpose:
  /// the interesting axis here is JSON type coverage, not sampling.
  List<Object?> get invalidSubstitutions => switch (kind) {
    DecodedFieldKind.identitySchemaVersion => <Object?>[
      '1',
      true,
      null,
      1.5,
      999,
      <Object?>[1],
      <String, Object?>{'value': 1},
    ],
    DecodedFieldKind.identityString => <Object?>[
      1,
      true,
      null,
      <Object?>['x'],
      <String, Object?>{'value': 'x'},
      'other-$payloadSentinel',
    ],
    DecodedFieldKind.opaqueRequiredString => <Object?>[
      1,
      true,
      null,
      '',
      <Object?>['x'],
      <String, Object?>{'value': 'x'},
    ],
    DecodedFieldKind.boundedToken => <Object?>[
      1,
      true,
      null,
      '',
      'too-short',
      '${validOwnerToken}X',
      'AAAAAAAAAAAAAAAAAAAA+/',
      <Object?>[validOwnerToken],
    ],
    DecodedFieldKind.optionalBoundedToken => <Object?>[
      1,
      true,
      '',
      'too-short',
      '${validOwnerToken}X',
      'AAAAAAAAAAAAAAAAAAAA+/',
      <Object?>[validOwnerToken],
    ],
    DecodedFieldKind.requiredObject => <Object?>[
      1,
      true,
      null,
      '',
      payloadSentinel,
      <Object?>[<String, Object?>{}],
    ],
    DecodedFieldKind.optionalObject => <Object?>[
      1,
      true,
      payloadSentinel,
      <Object?>[<String, Object?>{}],
    ],
  };

  /// Whether the transport itself bounds this field's length.
  ///
  /// `false` means an oversized value is the *consumer's* vocabulary, not a
  /// protocol violation: the transport only owes boundedness (the request cap)
  /// and no payload echo.
  bool get rejectsOversizedString => switch (kind) {
    DecodedFieldKind.identitySchemaVersion => true,
    DecodedFieldKind.identityString => true,
    DecodedFieldKind.boundedToken => true,
    DecodedFieldKind.optionalBoundedToken => true,
    DecodedFieldKind.opaqueRequiredString => false,
    DecodedFieldKind.requiredObject => false,
    DecodedFieldKind.optionalObject => false,
  };

  /// Whether an oversized *string* is even type-legal for this field.
  bool get acceptsStringValue =>
      kind != DecodedFieldKind.requiredObject &&
      kind != DecodedFieldKind.optionalObject &&
      kind != DecodedFieldKind.identitySchemaVersion;
}

/// Identity fields every operation carries.
const List<DecodedField> _identityFields = <DecodedField>[
  DecodedField('schemaVersion', DecodedFieldKind.identitySchemaVersion),
  DecodedField('applicationId', DecodedFieldKind.identityString),
  DecodedField('appInstanceId', DecodedFieldKind.identityString),
];

/// One decodable wire operation.
final class WireOperation {
  const WireOperation({
    required this.name,
    required this.operationFields,
    required this.extraBody,
    required this.settlesThroughHandler,
  });

  /// Path segment under `PatchbayDirectHost.protocolPathPrefix`.
  final String name;

  /// Fields beyond the shared identity triple.
  final List<DecodedField> operationFields;

  /// Valid values for [operationFields], plus any forwarded payload.
  final Map<String, Object?> extraBody;

  /// Whether a *successful* request reaches an application handler.
  ///
  /// `identity` is served from the pinned runtime read, so it has none; the
  /// side-effect invariant is asserted against the others.
  final bool settlesThroughHandler;

  List<DecodedField> get decodedFields => <DecodedField>[
    ..._identityFields,
    ...operationFields,
  ];

  Map<String, Object?> validBody() => <String, Object?>{
    ...harnessIdentity.toJson(),
    ...extraBody,
  };
}

/// The closed registry. Kept honest by [hostOperationsInSource].
final List<WireOperation> wireOperations = <WireOperation>[
  const WireOperation(
    name: 'identity',
    operationFields: <DecodedField>[],
    extraBody: <String, Object?>{},
    settlesThroughHandler: false,
  ),
  const WireOperation(
    name: 'catalog',
    operationFields: <DecodedField>[],
    extraBody: <String, Object?>{},
    settlesThroughHandler: true,
  ),
  const WireOperation(
    name: 'snapshot',
    operationFields: <DecodedField>[
      DecodedField('request', DecodedFieldKind.optionalObject),
    ],
    extraBody: <String, Object?>{
      'request': <String, Object?>{
        'path': 'state.ready',
        'note': multiByteMarker,
      },
    },
    settlesThroughHandler: true,
  ),
  const WireOperation(
    name: 'invoke',
    operationFields: <DecodedField>[
      DecodedField('command', DecodedFieldKind.opaqueRequiredString),
      DecodedField('arguments', DecodedFieldKind.requiredObject),
      DecodedField('requestId', DecodedFieldKind.opaqueRequiredString),
      DecodedField('ownerToken', DecodedFieldKind.optionalBoundedToken),
    ],
    extraBody: <String, Object?>{
      'command': 'probe.read',
      'arguments': <String, Object?>{'note': multiByteMarker},
      'requestId': 'req-0001',
      'ownerToken': validOwnerToken,
    },
    settlesThroughHandler: true,
  ),
  const WireOperation(
    name: 'cancel-invocation',
    operationFields: <DecodedField>[
      DecodedField('command', DecodedFieldKind.opaqueRequiredString),
      DecodedField('requestId', DecodedFieldKind.opaqueRequiredString),
      DecodedField('ownerToken', DecodedFieldKind.boundedToken),
    ],
    extraBody: <String, Object?>{
      'command': 'probe.read',
      'requestId': 'req-0001',
      'ownerToken': validOwnerToken,
    },
    settlesThroughHandler: true,
  ),
];

/// Which malformation produced a case.
enum MalformationClass {
  byteTruncation,
  fieldTypeSubstitution,
  boundedOversizedString,
  overLimitBody,
}

/// One reproducible malformed request.
final class MalformedCase {
  const MalformedCase({
    required this.operation,
    required this.malformation,
    required this.label,
    required this.bytes,
    required this.mustBeRejected,
  });

  final String operation;
  final MalformationClass malformation;

  /// Human-readable identity of the case, stable across runs for a given seed.
  final String label;
  final List<int> bytes;

  /// `false` marks a payload the transport is allowed to forward (an oversized
  /// value in a field whose vocabulary it does not own). Those cases still owe
  /// boundedness, liveness and no payload echo.
  final bool mustBeRejected;

  @override
  String toString() => '${malformation.name}/$operation/$label';
}

/// Deterministic generator for one seed.
final class MalformedPayloadGenerator {
  MalformedPayloadGenerator({int? seed})
    : this._(seed ?? resolveMalformedSeed());

  MalformedPayloadGenerator._(this.seed) : _random = Random(seed);

  final int seed;
  final Random _random;

  /// Every case for every registered operation, in a stable order.
  List<MalformedCase> generate() => <MalformedCase>[
    for (final WireOperation operation in wireOperations) ...<MalformedCase>[
      ..._truncations(operation),
      ..._typeSubstitutions(operation),
      ..._oversizedStrings(operation),
    ],
    ..._overLimitBodies(),
  ];

  /// Byte-level truncation. Offsets are drawn from the seeded [Random] and
  /// de-duplicated, so the case count is stable but the offsets vary per seed.
  List<MalformedCase> _truncations(WireOperation operation) {
    final List<int> encoded = utf8.encode(jsonEncode(operation.validBody()));
    final Set<int> offsets = <int>{};
    while (offsets.length < truncationsPerOperation) {
      offsets.add(_random.nextInt(encoded.length));
    }
    final List<int> ordered = offsets.toList()..sort();
    return <MalformedCase>[
      for (final int offset in ordered)
        MalformedCase(
          operation: operation.name,
          malformation: MalformationClass.byteTruncation,
          label: 'truncated-at-$offset-of-${encoded.length}',
          bytes: encoded.sublist(0, offset),
          mustBeRejected: true,
        ),
    ];
  }

  /// Exhaustive JSON-type substitution over the closed invalid set.
  List<MalformedCase> _typeSubstitutions(WireOperation operation) =>
      <MalformedCase>[
        for (final DecodedField field in operation.decodedFields)
          for (final Object? value in field.invalidSubstitutions)
            MalformedCase(
              operation: operation.name,
              malformation: MalformationClass.fieldTypeSubstitution,
              label: '${field.name}=${_describe(value)}',
              bytes: utf8.encode(
                jsonEncode(<String, Object?>{
                  ...operation.validBody(),
                  field.name: value,
                }),
              ),
              mustBeRejected: true,
            ),
      ];

  /// Bounded oversized strings. Lengths are drawn from the seeded [Random]
  /// within `[minGeneratedStringBytes, maxGeneratedStringBytes]`.
  List<MalformedCase> _oversizedStrings(WireOperation operation) =>
      <MalformedCase>[
        for (final DecodedField field in operation.decodedFields)
          if (field.acceptsStringValue)
            MalformedCase(
              operation: operation.name,
              malformation: MalformationClass.boundedOversizedString,
              label: '${field.name}=oversized',
              bytes: utf8.encode(
                jsonEncode(<String, Object?>{
                  ...operation.validBody(),
                  field.name: _oversizedString(),
                }),
              ),
              mustBeRejected: field.rejectsOversizedString,
            ),
      ];

  /// One over-limit body per operation, to prove the cap answers before any
  /// field decoder runs.
  List<MalformedCase> _overLimitBodies() => <MalformedCase>[
    for (final WireOperation operation in wireOperations)
      MalformedCase(
        operation: operation.name,
        malformation: MalformationClass.overLimitBody,
        label: 'body-$overLimitBodyBytes-bytes',
        bytes: utf8.encode(
          jsonEncode(<String, Object?>{
            ...operation.validBody(),
            'padding': _repeatToBytes(overLimitBodyBytes),
          }),
        ),
        mustBeRejected: true,
      ),
  ];

  String _oversizedString() => _repeatToBytes(
    minGeneratedStringBytes +
        _random.nextInt(maxGeneratedStringBytes - minGeneratedStringBytes),
  );

  static String _repeatToBytes(int bytes) {
    final StringBuffer buffer = StringBuffer();
    while (buffer.length < bytes) {
      buffer.write(payloadSentinel);
    }
    return buffer.toString().substring(0, bytes);
  }

  /// Stable rendering used in case labels; never includes the whole payload.
  static String _describe(Object? value) => switch (value) {
    null => 'null',
    final String text when text.isEmpty => 'empty-string',
    final String text when text.length > 24 => 'string(${text.length})',
    final String text => 'string:$text',
    final bool flag => 'bool:$flag',
    final int number => 'int:$number',
    final double number => 'double:$number',
    final List<Object?> list => 'list(${list.length})',
    final Map<String, Object?> map => 'map(${map.length})',
    _ => 'other',
  };
}

/// Seed actually in force, honouring `PATCHBAY_MALFORMED_SEED`.
int resolveMalformedSeed() {
  final String? raw = Platform.environment['PATCHBAY_MALFORMED_SEED'];
  if (raw == null) return defaultMalformedSeed;
  return int.tryParse(raw) ?? defaultMalformedSeed;
}

/// Operation names the host actually serves, read from its source.
///
/// This is the ratchet half of the registry: a new operation added to
/// `direct_host.dart` without a [wireOperations] entry fails the closure test
/// instead of silently shipping an unfuzzed decoder.
Set<String> hostOperationsInSource() => _operationsIn(
  File('lib/src/direct_host.dart'),
  RegExp(r"\$protocolPathPrefix/([a-z][a-z-]*)'"),
);

/// Operation names the client actually calls, read from its source.
Set<String> clientOperationsInSource() => _operationsIn(
  File('lib/src/direct_client.dart'),
  RegExp(r"_call\(\s*'([a-z][a-z-]*)'"),
);

Set<String> _operationsIn(File source, RegExp pattern) {
  if (!source.existsSync()) {
    throw StateError(
      'malformed-payload harness must run from the package root; '
      'missing ${source.path}',
    );
  }
  return pattern
      .allMatches(source.readAsStringSync())
      .map((RegExpMatch match) => match.group(1)!)
      .toSet();
}
