import 'package:patchbay/patchbay.dart';
import 'package:patchbay/patchbay_protocol.dart';

import 'command_spec.dart';

/// Identity domain carried explicitly by a canonical `ui perform` selector.
enum PatchbayUiSelectorKind { target, semantics, node }

/// CLI-local execution path reported without changing the host payload.
enum PatchbayUiExecutionPath {
  directTarget,
  semanticsAction,
  pointerGesture,
  scrollReveal,
}

/// One frozen canonical selector/channel to existing service-command route.
final class PatchbayCanonicalUiRoute {
  const PatchbayCanonicalUiRoute({
    required this.selectorKind,
    required this.executionPath,
    required this.serviceCommand,
    this.via,
  });

  final PatchbayUiSelectorKind selectorKind;
  final PatchbayUiExecutionPath executionPath;
  final String serviceCommand;
  final String? via;

  Map<String, Object?> toLocalRoute() => <String, Object?>{
    'selectorKind': selectorKind.name,
    'executionPath': executionPath.name,
    'serviceCommand': serviceCommand,
  };
}

/// One action-specific declaration in the canonical `ui perform` family.
final class PatchbayCanonicalUiCommandSpec
    implements PatchbayFriendlyCommandSpec {
  const PatchbayCanonicalUiCommandSpec({
    required this.name,
    required this.action,
    required this.summary,
    required this.usageSuffix,
    required this.routes,
  });

  @override
  final String name;
  final String action;
  @override
  final String summary;
  @override
  final String usageSuffix;
  final List<PatchbayCanonicalUiRoute> routes;

  @override
  List<String> get path => <String>['ui', 'perform', action];

  /// A single route can name its service directly in generated docs. Actions
  /// whose selector or `--via` chooses between services remain explicitly
  /// routed and therefore return `null` here.
  @override
  String? get serviceCommand {
    final Set<String> services = routes
        .map((PatchbayCanonicalUiRoute route) => route.serviceCommand)
        .toSet();
    return services.length == 1 ? services.single : null;
  }

  @override
  PatchbayArtifactDisposition get artifact => PatchbayArtifactDisposition.none;
  @override
  PatchbayCommandTarget get target =>
      PatchbayCommandTarget.routedServiceCommand;
  @override
  String? get waitCondition => null;
  @override
  bool get fencesNavigationRevision => false;
  @override
  PatchbayCommandDescriptor? get protocolDescriptor => null;
  @override
  PatchbayCliSyntax? get protocolSyntax => null;
  @override
  String? get spilledMember => null;
}

/// One 0.6.0 deprecated spelling and its exact canonical replacement.
final class PatchbayUiCommandMigration {
  const PatchbayUiCommandMigration({
    required this.legacyPath,
    required this.replacement,
  });

  final List<String> legacyPath;
  final String replacement;

  String get legacyCommand => legacyPath.join(' ');

  String get warning =>
      'deprecated: `patchbay $legacyCommand` is retained for 0.6.0 and will '
      'be removed in 1.0; use `patchbay $replacement`';

  bool matches(List<String> words) {
    if (words.length < legacyPath.length) return false;
    for (var index = 0; index < legacyPath.length; index += 1) {
      if (words[index] != legacyPath[index]) return false;
    }
    return true;
  }
}

/// The single source for canonical UI routes and old-entry migration text.
abstract final class PatchbayCanonicalUiRegistry {
  // `set-text` is deliberately absent. `ui.text.set` writes the controller
  // without running inputFormatters or onChanged, and nothing in the name
  // says so; a consumer reached for it first and watched their form stay
  // disabled. The canonical family keeps the one spelling that behaves like
  // input. The wire command and the deprecated `ui text set` remain until 1.0.
  static const PatchbayCanonicalUiCommandSpec enterText =
      PatchbayCanonicalUiCommandSpec(
        name: 'canonicalUiPerformEnterText',
        action: 'enter-text',
        summary:
            'Enter text through an explicit registered target; runs its '
            'inputFormatters and onChanged.',
        usageSuffix: 'target:<id> <generation> [text]',
        routes: <PatchbayCanonicalUiRoute>[
          PatchbayCanonicalUiRoute(
            selectorKind: PatchbayUiSelectorKind.target,
            executionPath: PatchbayUiExecutionPath.directTarget,
            serviceCommand: 'ui.text.enter',
          ),
        ],
      );
  static const PatchbayCanonicalUiCommandSpec tap =
      PatchbayCanonicalUiCommandSpec(
        name: 'canonicalUiPerformTap',
        action: 'tap',
        summary: 'Tap a Semantics target through one explicit channel.',
        usageSuffix:
            'semantics:<identifier> <generation> --via <semantics|pointer> '
            '[--start <json>]',
        routes: <PatchbayCanonicalUiRoute>[
          PatchbayCanonicalUiRoute(
            selectorKind: PatchbayUiSelectorKind.semantics,
            executionPath: PatchbayUiExecutionPath.semanticsAction,
            serviceCommand: 'ui.semantics.tap',
            via: 'semantics',
          ),
          PatchbayCanonicalUiRoute(
            selectorKind: PatchbayUiSelectorKind.semantics,
            executionPath: PatchbayUiExecutionPath.pointerGesture,
            serviceCommand: 'ui.gesture.tap',
            via: 'pointer',
          ),
        ],
      );
  static const PatchbayCanonicalUiCommandSpec action =
      PatchbayCanonicalUiCommandSpec(
        name: 'canonicalUiPerformAction',
        action: 'action',
        summary: 'Dispatch an action through an explicit Semantics identity.',
        usageSuffix:
            '<semantics:<identifier>|node:<node-id>> <generation> <action> '
            '[text]',
        routes: <PatchbayCanonicalUiRoute>[
          PatchbayCanonicalUiRoute(
            selectorKind: PatchbayUiSelectorKind.semantics,
            executionPath: PatchbayUiExecutionPath.semanticsAction,
            serviceCommand: 'ui.semantics.actionByIdentifier',
          ),
          PatchbayCanonicalUiRoute(
            selectorKind: PatchbayUiSelectorKind.node,
            executionPath: PatchbayUiExecutionPath.semanticsAction,
            serviceCommand: 'ui.semantics.action',
          ),
        ],
      );
  static const PatchbayCanonicalUiCommandSpec pressHold =
      PatchbayCanonicalUiCommandSpec(
        name: 'canonicalUiPerformPressHold',
        action: 'press-hold',
        summary: 'Press and hold an explicit Semantics target.',
        usageSuffix:
            'semantics:<identifier> <generation> --start <json> '
            '[--duration-ms <ms>]',
        routes: <PatchbayCanonicalUiRoute>[
          PatchbayCanonicalUiRoute(
            selectorKind: PatchbayUiSelectorKind.semantics,
            executionPath: PatchbayUiExecutionPath.pointerGesture,
            serviceCommand: 'ui.gesture.pressHold',
          ),
        ],
      );
  static const PatchbayCanonicalUiCommandSpec drag =
      PatchbayCanonicalUiCommandSpec(
        name: 'canonicalUiPerformDrag',
        action: 'drag',
        summary: 'Drag through an explicit Semantics target-local path.',
        usageSuffix:
            'semantics:<identifier> <generation> --start <json> '
            '--gesture-path <json> [--duration-ms <ms>]',
        routes: <PatchbayCanonicalUiRoute>[
          PatchbayCanonicalUiRoute(
            selectorKind: PatchbayUiSelectorKind.semantics,
            executionPath: PatchbayUiExecutionPath.pointerGesture,
            serviceCommand: 'ui.gesture.drag',
          ),
        ],
      );
  static const PatchbayCanonicalUiCommandSpec fling =
      PatchbayCanonicalUiCommandSpec(
        name: 'canonicalUiPerformFling',
        action: 'fling',
        summary: 'Fling from an explicit Semantics target-local point.',
        usageSuffix:
            'semantics:<identifier> <generation> --start <json> '
            '--velocity <json> [--duration-ms <ms>]',
        routes: <PatchbayCanonicalUiRoute>[
          PatchbayCanonicalUiRoute(
            selectorKind: PatchbayUiSelectorKind.semantics,
            executionPath: PatchbayUiExecutionPath.pointerGesture,
            serviceCommand: 'ui.gesture.fling',
          ),
        ],
      );
  static const PatchbayCanonicalUiCommandSpec reveal =
      PatchbayCanonicalUiCommandSpec(
        name: 'canonicalUiPerformReveal',
        action: 'reveal',
        summary: 'Reveal an explicit Semantics target without hiding a task.',
        usageSuffix:
            'semantics:<identifier> [--container <identifier>] '
            '[--direction <forward|backward|both>] [--max-steps <n>] '
            '[--timeout-ms <ms>]',
        routes: <PatchbayCanonicalUiRoute>[
          PatchbayCanonicalUiRoute(
            selectorKind: PatchbayUiSelectorKind.semantics,
            executionPath: PatchbayUiExecutionPath.scrollReveal,
            serviceCommand: 'ui.reveal',
          ),
        ],
      );

  static const List<PatchbayCanonicalUiCommandSpec> commands =
      <PatchbayCanonicalUiCommandSpec>[
        enterText,
        tap,
        action,
        pressHold,
        drag,
        fling,
        reveal,
      ];

  static const List<PatchbayUiCommandMigration> migrations =
      <PatchbayUiCommandMigration>[
        // Points at enter-text on purpose: that is the write a caller almost
        // always meant. The controller-only write keeps its deprecated
        // spelling until 1.0 and has no canonical entry.
        PatchbayUiCommandMigration(
          legacyPath: <String>['ui', 'text', 'set'],
          replacement: 'ui perform enter-text target:<id> <generation> [text]',
        ),
        PatchbayUiCommandMigration(
          legacyPath: <String>['ui', 'text', 'enter'],
          replacement: 'ui perform enter-text target:<id> <generation> [text]',
        ),
        PatchbayUiCommandMigration(
          legacyPath: <String>['ui', 'tap'],
          replacement:
              'ui perform tap semantics:<identifier> <generation> '
              '--via semantics',
        ),
        PatchbayUiCommandMigration(
          legacyPath: <String>['ui', 'action'],
          replacement:
              'ui perform action semantics:<identifier> <generation> '
              '<action> [text]',
        ),
        PatchbayUiCommandMigration(
          legacyPath: <String>['ui', 'semantics', 'action'],
          replacement:
              'ui perform action node:<node-id> <generation> <action> [text]',
        ),
        PatchbayUiCommandMigration(
          legacyPath: <String>['ui', 'gesture', 'tap'],
          replacement:
              'ui perform tap semantics:<identifier> <generation> '
              '--via pointer [--start <json>]',
        ),
        PatchbayUiCommandMigration(
          legacyPath: <String>['ui', 'gesture', 'press-hold'],
          replacement:
              'ui perform press-hold semantics:<identifier> <generation> '
              '--start <json> [--duration-ms <ms>]',
        ),
        PatchbayUiCommandMigration(
          legacyPath: <String>['ui', 'gesture', 'drag'],
          replacement:
              'ui perform drag semantics:<identifier> <generation> '
              '--start <json> --gesture-path <json> [--duration-ms <ms>]',
        ),
        PatchbayUiCommandMigration(
          legacyPath: <String>['ui', 'gesture', 'fling'],
          replacement:
              'ui perform fling semantics:<identifier> <generation> '
              '--start <json> --velocity <json> [--duration-ms <ms>]',
        ),
        PatchbayUiCommandMigration(
          legacyPath: <String>['ui', 'reveal'],
          replacement:
              'ui perform reveal semantics:<identifier> '
              '[--container <identifier>] '
              '[--direction <forward|backward|both>] [--max-steps <n>] '
              '[--timeout-ms <ms>]',
        ),
      ];

  static PatchbayUiCommandMigration? migrationFor(List<String> words) {
    for (final PatchbayUiCommandMigration migration in migrations) {
      if (migration.matches(words)) return migration;
    }
    return null;
  }
}

/// Parsed selector whose first colon alone separates kind from identity.
final class PatchbayCanonicalUiSelector {
  const PatchbayCanonicalUiSelector(this.kind, this.value);

  final PatchbayUiSelectorKind kind;
  final String value;

  static PatchbayCanonicalUiSelector parse(String raw) {
    final int separator = raw.indexOf(':');
    if (separator <= 0 || separator == raw.length - 1) {
      throw const FormatException(
        'selector must be target:<id>, semantics:<identifier>, or '
        'node:<non-negative-int>',
      );
    }
    final String prefix = raw.substring(0, separator);
    final String value = raw.substring(separator + 1);
    final PatchbayUiSelectorKind kind = switch (prefix) {
      'target' => PatchbayUiSelectorKind.target,
      'semantics' => PatchbayUiSelectorKind.semantics,
      'node' => PatchbayUiSelectorKind.node,
      _ => throw const FormatException(
        'selector must be target:<id>, semantics:<identifier>, or '
        'node:<non-negative-int>',
      ),
    };
    if (kind == PatchbayUiSelectorKind.node) {
      final int? nodeId = int.tryParse(value);
      if (nodeId == null || nodeId < 0) {
        throw const FormatException('node selector must be non-negative');
      }
    }
    return PatchbayCanonicalUiSelector(kind, value);
  }
}
