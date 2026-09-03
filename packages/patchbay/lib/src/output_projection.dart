/// PB-050-40: the declarative output projection a command descriptor carries.
///
/// `docs/proposals/0.6.0/descriptor-output-projection.md` is the contract this
/// file implements. One command declares at most one `brief` deny-list and at
/// most one artifact; the CLI's single interpreter turns that declaration into
/// the `--view brief` projection and the local-artifact spill it used to
/// hard-code per command family.
///
/// Two invariants shape the types below.
///
/// **Declarations must be `const`.** The CLI-local command registry is a Dart
/// `enum`, so every declaration it carries has to be constructible in a const
/// context. That rules out parsing or validating inside the constructor, so
/// the declaration holds the *literal* path strings and [PatchbayOutputProjection.validate]
/// is the one place that checks them. Provider-supplied declarations are
/// validated on decode ([PatchbayOutputProjection.fromJson]); repo-authored
/// ones are validated by a test that walks every compiled-in declaration.
///
/// **Invalid means the whole catalog is unusable.** A malformed declaration is
/// a provider protocol violation, not a field to drop: dropping it would let
/// two clients disagree about what the same command publishes. Decoding throws
/// [FormatException] and the caller is expected to fail the catalog as a
/// whole, never to continue with the remaining rows.
library;

/// Maximum bytes one restricted path literal may occupy.
const int patchbayOutputProjectionMaxPathBytes = 256;

/// Maximum number of `omit` rules one brief declaration may carry.
const int patchbayOutputProjectionMaxOmitRules = 32;

/// Maximum length of a brief projection id.
const int patchbayOutputProjectionMaxIdLength = 64;

/// Media type paired with [PatchbayOutputArtifactEncoding.json].
const String patchbayOutputProjectionJsonMediaType = 'application/json';

/// Media type paired with [PatchbayOutputArtifactEncoding.utf8Text].
const String patchbayOutputProjectionTextMediaType =
    'text/plain; charset=utf-8';

/// File extension paired with [PatchbayOutputArtifactEncoding.json].
const String patchbayOutputProjectionJsonExtension = 'json';

/// File extension paired with [PatchbayOutputArtifactEncoding.utf8Text].
const String patchbayOutputProjectionTextExtension = 'txt';

/// Brief projection ids.
///
/// The proposal writes this class as "ASCII lowercase letters, digits, dots or
/// hyphens". It is widened here by exactly one character class — uppercase
/// ASCII letters — because 0.5.0 froze `diagnosticTree` as a `localView.projection`
/// value in `test/golden/view_brief/diagnostic_tree.brief.json`, and that
/// document is stable JSON whose bytes this change must not move. Narrowing to
/// the literal proposal text would have meant renaming a frozen id, which the
/// same proposal forbids outright; widening keeps every property the bound
/// exists for (bounded length, no separators, no runtime-derived text).
final RegExp _idPattern = RegExp(r'^[A-Za-z0-9.\-]+$');

final RegExp _fieldPattern = RegExp(r'^[A-Za-z][A-Za-z0-9_]*$');

/// Where an artifact's bytes come from. A closed set: a declaration may not
/// name a path, a template, a formatter or a second artifact.
enum PatchbayOutputArtifactKind {
  /// One member of the accepted response, rendered by the CLI.
  renderedMember,

  /// Host blob metadata at `$.payload.blob`.
  payloadBlob,

  /// Host blob metadata at `$.payload`.
  responseBlob,
}

/// How a [PatchbayOutputArtifactKind.renderedMember] member becomes bytes.
///
/// The first two values are the closed wire set the proposal fixes: a provider
/// may declare `json` or `utf8Text` and nothing else, and each pins one media
/// type and one extension. [jsonOrDecodedText] is **not** part of that set —
/// see its own comment.
enum PatchbayOutputArtifactEncoding {
  /// The member is JSON-encodable and written as JSON.
  json,

  /// The member is a String and written as UTF-8 text.
  utf8Text,

  /// PB-050-40 open point: the frozen 0.5.0 rule for the three Flutter
  /// diagnostic-tree passthroughs, which pick their encoding from the *runtime
  /// shape* of `data` rather than from a static declaration.
  ///
  /// `docs/proposals/0.5.0/tree-artifact-output.md` rules that one and the same
  /// `ui widget-tree` writes `application/json` / `.json` when the inspector
  /// answered with a JSON value and `text/plain; charset=utf-8` / `.txt` when
  /// `debugDumpApp` answered with a text dump — and that the second rule "is
  /// not optional polish": a text dump stored as a quoted JSON string is
  /// useless to a human and to `grep`, i.e. a fake artifact. Neither `json` nor
  /// `utf8Text` can express that, so declaring either would silently reverse an
  /// accepted 0.5.0 ruling.
  ///
  /// This value is therefore confined to the CLI-local side of the same
  /// declaration type, exactly where those three commands live: they are SDK
  /// service-extension passthroughs, never cataloged commands, so their
  /// declaration is never serialized and never decoded from a provider.
  /// [PatchbayOutputArtifactProjection.fromJson] refuses it and
  /// [PatchbayOutputArtifactProjection.toJson] throws on it, so the **wire**
  /// vocabulary a provider may use stays byte-for-byte the closed set the
  /// 0.6.0 proposal fixed. Widening the wire set, or changing what those three
  /// commands write, is a ruling this implementation deliberately does not
  /// make on its own.
  jsonOrDecodedText;

  /// Whether a provider may declare this encoding on the catalog wire.
  bool get isWireDeclarable =>
      this != PatchbayOutputArtifactEncoding.jsonOrDecodedText;

  /// The one media type this encoding is allowed to declare, or `null` when the
  /// member's runtime shape decides.
  String? get mediaType => switch (this) {
    PatchbayOutputArtifactEncoding.json =>
      patchbayOutputProjectionJsonMediaType,
    PatchbayOutputArtifactEncoding.utf8Text =>
      patchbayOutputProjectionTextMediaType,
    PatchbayOutputArtifactEncoding.jsonOrDecodedText => null,
  };

  /// The one file extension this encoding is allowed to declare, or `null` when
  /// the member's runtime shape decides.
  String? get extension => switch (this) {
    PatchbayOutputArtifactEncoding.json =>
      patchbayOutputProjectionJsonExtension,
    PatchbayOutputArtifactEncoding.utf8Text =>
      patchbayOutputProjectionTextExtension,
    PatchbayOutputArtifactEncoding.jsonOrDecodedText => null,
  };

  /// The media type and extension for one concrete member.
  (String, String) resolveFor({required bool memberIsString}) => switch (this) {
    PatchbayOutputArtifactEncoding.json => (
      patchbayOutputProjectionJsonMediaType,
      patchbayOutputProjectionJsonExtension,
    ),
    PatchbayOutputArtifactEncoding.utf8Text => (
      patchbayOutputProjectionTextMediaType,
      patchbayOutputProjectionTextExtension,
    ),
    PatchbayOutputArtifactEncoding.jsonOrDecodedText =>
      memberIsString
          ? (
              patchbayOutputProjectionTextMediaType,
              patchbayOutputProjectionTextExtension,
            )
          : (
              patchbayOutputProjectionJsonMediaType,
              patchbayOutputProjectionJsonExtension,
            ),
  };
}

/// One `.field` (optionally `[]`) step of a restricted projection path.
final class PatchbayOutputProjectionPathSegment {
  const PatchbayOutputProjectionPathSegment(
    this.field, {
    this.traversesList = false,
  });

  final String field;

  /// Whether this step reads a list and continues into every map element of
  /// it. Only a non-final segment may traverse.
  final bool traversesList;
}

/// A parsed restricted path: `$` followed by one or more `.field`, where any
/// non-final field may carry `[]` to traverse the maps of a list.
///
/// Nothing else is accepted. There are no wildcards, no indices, no filters and
/// no escapes, so a declaration can neither address a member it was not written
/// to address nor smuggle runtime text into `localView.omitted`.
final class PatchbayOutputProjectionPath {
  const PatchbayOutputProjectionPath._(this.pattern, this.segments);

  /// Parses [pattern], throwing [FormatException] when it is not a restricted
  /// path. [allowListTraversal] is `false` for an artifact `member`, which the
  /// proposal restricts to exactly one member and therefore forbids `[]` in.
  factory PatchbayOutputProjectionPath.parse(
    String pattern, {
    bool allowListTraversal = true,
    String path = r'$',
  }) {
    if (pattern.isEmpty) {
      throw FormatException('$path must not be empty');
    }
    if (pattern.codeUnits.length > patchbayOutputProjectionMaxPathBytes) {
      throw FormatException(
        '$path exceeds $patchbayOutputProjectionMaxPathBytes bytes',
      );
    }
    final List<String> parts = pattern.split('.');
    if (parts.first != r'$' || parts.length < 2) {
      throw FormatException(
        r'$path must start with "$" and name at least one field',
      );
    }
    final List<PatchbayOutputProjectionPathSegment> segments =
        <PatchbayOutputProjectionPathSegment>[];
    for (var index = 1; index < parts.length; index += 1) {
      final String raw = parts[index];
      final bool traverses = raw.endsWith('[]');
      final String field = traverses ? raw.substring(0, raw.length - 2) : raw;
      if (!_fieldPattern.hasMatch(field)) {
        throw FormatException('$path has an invalid field segment "$raw"');
      }
      if (traverses && !allowListTraversal) {
        throw FormatException('$path must name one member, without "[]"');
      }
      if (traverses && index == parts.length - 1) {
        throw FormatException('$path must not end with "[]"');
      }
      segments.add(
        PatchbayOutputProjectionPathSegment(field, traversesList: traverses),
      );
    }
    return PatchbayOutputProjectionPath._(pattern, segments);
  }

  /// The literal declaration text. This — never a value derived from the
  /// instance being projected — is what `localView.omitted` echoes.
  final String pattern;

  final List<PatchbayOutputProjectionPathSegment> segments;

  /// Every step above the leaf.
  List<PatchbayOutputProjectionPathSegment> get containerSegments =>
      segments.sublist(0, segments.length - 1);

  /// The key the rule deletes, or the member the artifact renders.
  String get leafKey => segments.last.field;

  @override
  String toString() => pattern;
}

/// The `brief` half of a declaration: a stable id plus a deny-list.
final class PatchbayOutputBriefProjection {
  const PatchbayOutputBriefProjection({required this.id, required this.omit});

  /// Decodes a provider-supplied `brief` object, fail-closed.
  factory PatchbayOutputBriefProjection.fromJson(
    Object? value, {
    String path = r'$.brief',
  }) {
    if (value is! Map<Object?, Object?>) {
      throw FormatException('$path must be an object');
    }
    _rejectUnknownKeys(value, const <String>{'id', 'omit'}, path);
    final Object? id = value['id'];
    if (id is! String) {
      throw FormatException('$path.id must be a string');
    }
    final Object? omit = value['omit'];
    if (omit is! List<Object?>) {
      throw FormatException('$path.omit must be a list');
    }
    final List<String> patterns = <String>[];
    for (var index = 0; index < omit.length; index += 1) {
      final Object? entry = omit[index];
      if (entry is! String) {
        throw FormatException('$path.omit[$index] must be a string');
      }
      patterns.add(entry);
    }
    final PatchbayOutputBriefProjection decoded = PatchbayOutputBriefProjection(
      id: id,
      omit: patterns,
    );
    decoded.validate(path: path);
    return decoded;
  }

  /// The stable projection name reported as `localView.projection`.
  final String id;

  /// Literal restricted paths this projection may delete, in declaration
  /// order. `localView.omitted` reports the ones that actually removed
  /// something, in this order, which is what makes 0.5.0's frozen output
  /// reproducible from a declaration.
  final List<String> omit;

  /// Parses [omit]. Call [validate] first, or be ready for [FormatException].
  List<PatchbayOutputProjectionPath> get paths =>
      <PatchbayOutputProjectionPath>[
        for (final String pattern in omit)
          PatchbayOutputProjectionPath.parse(pattern),
      ];

  /// Throws [FormatException] unless this declaration is within every bound
  /// the proposal fixes.
  void validate({String path = r'$.brief'}) {
    if (id.isEmpty || id.length > patchbayOutputProjectionMaxIdLength) {
      throw FormatException(
        '$path.id must be 1..$patchbayOutputProjectionMaxIdLength characters',
      );
    }
    if (!_idPattern.hasMatch(id)) {
      throw FormatException('$path.id has a character outside the id class');
    }
    if (omit.isEmpty || omit.length > patchbayOutputProjectionMaxOmitRules) {
      throw FormatException(
        '$path.omit must carry 1..$patchbayOutputProjectionMaxOmitRules rules',
      );
    }
    final Set<String> seen = <String>{};
    for (var index = 0; index < omit.length; index += 1) {
      final String pattern = omit[index];
      if (!seen.add(pattern)) {
        throw FormatException('$path.omit[$index] repeats "$pattern"');
      }
      PatchbayOutputProjectionPath.parse(pattern, path: '$path.omit[$index]');
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'omit': List<String>.unmodifiable(omit),
  };
}

/// The `artifact` half of a declaration: at most one artifact per command.
final class PatchbayOutputArtifactProjection {
  /// One response member the CLI renders and writes locally.
  const PatchbayOutputArtifactProjection.renderedMember({
    required String member,
    required PatchbayOutputArtifactEncoding encoding,
  }) : kind = PatchbayOutputArtifactKind.renderedMember,
       member = member,
       encoding = encoding;

  /// Host blob metadata at `$.payload.blob`.
  const PatchbayOutputArtifactProjection.payloadBlob()
    : kind = PatchbayOutputArtifactKind.payloadBlob,
      member = null,
      encoding = null;

  /// Host blob metadata at `$.payload`.
  const PatchbayOutputArtifactProjection.responseBlob()
    : kind = PatchbayOutputArtifactKind.responseBlob,
      member = null,
      encoding = null;

  const PatchbayOutputArtifactProjection._({
    required this.kind,
    required this.member,
    required this.encoding,
  });

  /// Decodes a provider-supplied `artifact` object, fail-closed.
  factory PatchbayOutputArtifactProjection.fromJson(
    Object? value, {
    String path = r'$.artifact',
  }) {
    if (value is! Map<Object?, Object?>) {
      throw FormatException('$path must be an object');
    }
    final Object? rawKind = value['kind'];
    if (rawKind is! String) {
      throw FormatException('$path.kind must be a string');
    }
    final PatchbayOutputArtifactKind kind = switch (rawKind) {
      'renderedMember' => PatchbayOutputArtifactKind.renderedMember,
      'payloadBlob' => PatchbayOutputArtifactKind.payloadBlob,
      'responseBlob' => PatchbayOutputArtifactKind.responseBlob,
      _ => throw FormatException('$path.kind "$rawKind" is not a known kind'),
    };
    if (kind != PatchbayOutputArtifactKind.renderedMember) {
      // The blob kinds read a fixed host location. Any additional field is a
      // declaration the interpreter would silently ignore, so it is refused.
      _rejectUnknownKeys(value, const <String>{'kind'}, path);
      return PatchbayOutputArtifactProjection._(
        kind: kind,
        member: null,
        encoding: null,
      );
    }
    _rejectUnknownKeys(value, const <String>{
      'kind',
      'member',
      'encoding',
      'mediaType',
      'extension',
      'automaticSpill',
    }, path);
    final Object? member = value['member'];
    if (member is! String) {
      throw FormatException('$path.member must be a string');
    }
    final Object? rawEncoding = value['encoding'];
    // Closed on purpose, and closed here rather than by `EnumName.values`:
    // `jsonOrDecodedText` exists for the CLI-local declarations only and must
    // never become something a provider can put on the wire.
    final PatchbayOutputArtifactEncoding encoding = switch (rawEncoding) {
      'json' => PatchbayOutputArtifactEncoding.json,
      'utf8Text' => PatchbayOutputArtifactEncoding.utf8Text,
      _ => throw FormatException('$path.encoding must be json or utf8Text'),
    };
    if (value['mediaType'] != encoding.mediaType) {
      throw FormatException('$path.mediaType does not match $path.encoding');
    }
    if (value['extension'] != encoding.extension) {
      throw FormatException('$path.extension does not match $path.encoding');
    }
    if (value['automaticSpill'] != true) {
      throw FormatException(
        '$path.automaticSpill must be true in this version',
      );
    }
    final PatchbayOutputArtifactProjection decoded =
        PatchbayOutputArtifactProjection.renderedMember(
          member: member,
          encoding: encoding,
        );
    decoded.validate(path: path);
    return decoded;
  }

  final PatchbayOutputArtifactKind kind;

  /// Literal restricted path of the rendered member; `null` for a blob kind.
  final String? member;

  final PatchbayOutputArtifactEncoding? encoding;

  /// Always the media type [encoding] fixes; `null` for a blob kind.
  String? get mediaType => encoding?.mediaType;

  /// Always the extension [encoding] fixes; `null` for a blob kind.
  String? get extension => encoding?.extension;

  /// Whether the CLI may spill without an explicit `--output`.
  ///
  /// `true` for every [PatchbayOutputArtifactKind.renderedMember] declaration
  /// in this version — the proposal fixes the value and keeps its meaning at
  /// "the rendered document grew past the local threshold". A blob kind never
  /// downloads without an explicit `--output`.
  bool get automaticSpill => kind == PatchbayOutputArtifactKind.renderedMember;

  /// The parsed member path; `null` for a blob kind.
  PatchbayOutputProjectionPath? get memberPath => member == null
      ? null
      : PatchbayOutputProjectionPath.parse(member!, allowListTraversal: false);

  /// Throws [FormatException] unless this declaration is internally consistent.
  void validate({String path = r'$.artifact'}) {
    switch (kind) {
      case PatchbayOutputArtifactKind.renderedMember:
        if (member == null || encoding == null) {
          throw FormatException('$path.renderedMember needs member+encoding');
        }
        PatchbayOutputProjectionPath.parse(
          member!,
          allowListTraversal: false,
          path: '$path.member',
        );
      case PatchbayOutputArtifactKind.payloadBlob:
      case PatchbayOutputArtifactKind.responseBlob:
        if (member != null || encoding != null) {
          throw FormatException('$path.$name declares no additional field');
        }
    }
  }

  String get name => kind.name;

  Map<String, Object?> toJson() {
    if (kind != PatchbayOutputArtifactKind.renderedMember) {
      return <String, Object?>{'kind': kind.name};
    }
    final PatchbayOutputArtifactEncoding declared = encoding!;
    if (!declared.isWireDeclarable) {
      throw StateError(
        'encoding ${declared.name} is a CLI-local declaration and must never '
        'be published in a catalog row',
      );
    }
    return <String, Object?>{
      'kind': kind.name,
      'member': member,
      'encoding': declared.name,
      'mediaType': declared.mediaType,
      'extension': declared.extension,
      'automaticSpill': true,
    };
  }
}

/// One command's whole machine-output declaration.
///
/// `full` is the identity projection and is therefore not declared: it is what
/// happens when nothing is applied. A command that declares nothing at all is
/// descriptor-less, which is *not* the same as declaring an empty projection —
/// hence the invariant that at least one half is present.
final class PatchbayOutputProjection {
  const PatchbayOutputProjection({this.brief, this.artifact})
    : assert(
        brief != null || artifact != null,
        'an outputProjection declares brief, artifact or both; a command with '
        'neither simply omits the field',
      );

  /// Decodes a provider-supplied declaration, fail-closed.
  factory PatchbayOutputProjection.fromJson(
    Object? value, {
    String path = r'$.outputProjection',
  }) {
    if (value is! Map<Object?, Object?>) {
      throw FormatException('$path must be an object');
    }
    _rejectUnknownKeys(value, const <String>{'brief', 'artifact'}, path);
    if (!value.containsKey('brief') && !value.containsKey('artifact')) {
      throw FormatException('$path must declare brief, artifact or both');
    }
    final PatchbayOutputBriefProjection? brief = value.containsKey('brief')
        ? PatchbayOutputBriefProjection.fromJson(
            value['brief'],
            path: '$path.brief',
          )
        : null;
    final PatchbayOutputArtifactProjection? artifact =
        value.containsKey('artifact')
        ? PatchbayOutputArtifactProjection.fromJson(
            value['artifact'],
            path: '$path.artifact',
          )
        : null;
    return PatchbayOutputProjection(brief: brief, artifact: artifact);
  }

  /// Reads the optional `outputProjection` sibling off one catalog row.
  ///
  /// Returns `null` when the row carries no declaration — a 0.5.x host, or a
  /// command whose output needs no projection. Throws [FormatException] when
  /// the row carries a malformed one; the caller must then fail the whole
  /// catalog rather than continue with the remaining rows.
  static PatchbayOutputProjection? fromCatalogRow(
    Map<Object?, Object?> row, {
    String path = r'$',
  }) {
    if (!row.containsKey('outputProjection')) return null;
    return PatchbayOutputProjection.fromJson(
      row['outputProjection'],
      path: '$path.outputProjection',
    );
  }

  final PatchbayOutputBriefProjection? brief;
  final PatchbayOutputArtifactProjection? artifact;

  /// Throws [FormatException] unless every half is within its bounds. Decoded
  /// declarations are already validated; this exists for the compiled-in ones,
  /// which are `const` and therefore cannot validate in their constructor.
  void validate({String path = r'$.outputProjection'}) {
    if (brief == null && artifact == null) {
      throw FormatException('$path must declare brief, artifact or both');
    }
    brief?.validate(path: '$path.brief');
    artifact?.validate(path: '$path.artifact');
  }

  Map<String, Object?> toJson() => <String, Object?>{
    if (brief case final PatchbayOutputBriefProjection value)
      'brief': value.toJson(),
    if (artifact case final PatchbayOutputArtifactProjection value)
      'artifact': value.toJson(),
  };
}

/// Decodes every `outputProjection` a catalog document carries, so one
/// malformed declaration fails the catalog as a whole.
///
/// The proposal's reason for the all-or-nothing rule: a provider that ships a
/// declaration no client can agree on must not be able to make each client
/// guess a different projection of the same command. Callers translate the
/// [FormatException] into their own typed catalog failure.
Map<String, PatchbayOutputProjection> patchbayDecodeCatalogOutputProjections(
  Map<String, Object?> catalog,
) {
  final Object? rows = catalog['commands'];
  if (rows is! List<Object?>) return const <String, PatchbayOutputProjection>{};
  final Map<String, PatchbayOutputProjection> decoded =
      <String, PatchbayOutputProjection>{};
  for (final Object? row in rows) {
    if (row is! Map<Object?, Object?>) continue;
    final Object? name = row['name'];
    final String command = name is String ? name : '<unnamed>';
    final PatchbayOutputProjection? projection;
    try {
      projection = PatchbayOutputProjection.fromCatalogRow(row);
    } on FormatException catch (failure) {
      throw FormatException('$command: ${failure.message}');
    }
    if (projection != null && name is String) decoded[name] = projection;
  }
  return decoded;
}

void _rejectUnknownKeys(
  Map<Object?, Object?> value,
  Set<String> allowed,
  String path,
) {
  final List<String> unknown =
      value.keys
          .map((Object? key) => '$key')
          .where((String key) => !allowed.contains(key))
          .toList(growable: false)
        ..sort();
  if (unknown.isNotEmpty) {
    throw FormatException('$path has unknown fields: ${unknown.join(',')}');
  }
}
