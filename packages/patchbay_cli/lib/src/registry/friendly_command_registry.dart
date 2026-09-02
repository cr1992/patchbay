import 'package:args/args.dart';
import 'package:patchbay/patchbay.dart';

import '../sensitive_input.dart';
import 'argument_decoder.dart';
import 'canonical_ui_registry.dart';
import 'command_spec.dart';
import 'friendly_commands.dart';

/// One accepted spelling and the declared path it expands into.
final class _PathAlias {
  const _PathAlias(this.from, this.to);

  final List<String> from;
  final List<String> to;
}

abstract final class FriendlyCommandRegistryResolver {
  static PatchbayFriendlyInvocation? resolve({
    required List<PatchbayFriendlyCommandSpec> allCommands,
    required List<String> words,
    required ArgResults options,
    String Function() readSensitiveInput = readSensitiveStdinLine,
  }) {
    final List<String> path = canonicalPath(words, allCommands);
    final PatchbayFriendlyCommandSpec? spec = match(path, allCommands);
    if (spec == null) return null;
    final List<String> tail = path.sublist(spec.path.length);
    if (spec is PatchbayCanonicalUiCommandSpec) {
      return _resolveCanonicalUi(
        spec: spec,
        tail: tail,
        options: options,
        allCommands: allCommands,
        readSensitiveInput: readSensitiveInput,
      );
    }
    validateOptions(spec, options, allCommands: allCommands);
    final String? serviceCommand;
    if (spec.target == PatchbayCommandTarget.callerServiceCommand) {
      if (tail.length != 1) {
        throw const FormatException(
          'exec requires one <service-command> argument',
        );
      }
      serviceCommand = tail.single;
    } else {
      serviceCommand = spec.serviceCommand;
    }
    final Map<String, Object?> arguments;
    if (spec.protocolSyntax != null) {
      arguments = ArgumentDecoder.protocolArguments(
        spec,
        tail,
        options,
        readSensitiveInput,
      );
    } else {
      arguments = switch (spec) {
        PatchbayFriendlyCommand.identity ||
        PatchbayFriendlyCommand.catalog ||
        PatchbayFriendlyCommand.uiWidgetTree ||
        PatchbayFriendlyCommand.uiRenderTree ||
        PatchbayFriendlyCommand.uiFocusTree ||
        PatchbayFriendlyCommand.networkProfile ||
        PatchbayFriendlyCommand.repl ||
        PatchbayFriendlyCommand.doctor ||
        PatchbayFriendlyCommand.sessionsList ||
        PatchbayFriendlyCommand.sessionsPrune ||
        PatchbayFriendlyCommand.permissionCapabilities ||
        PatchbayFriendlyCommand.tracePrune =>
          ArgumentDecoder.noTail(tail, <String, Object?>{
            if (spec == PatchbayFriendlyCommand.tracePrune)
              'dryRun': options.flag('dry-run'),
          }),
        PatchbayFriendlyCommand.permissionDoctor => ArgumentDecoder.noTail(
          tail,
          const <String, Object?>{},
        ),
        PatchbayFriendlyCommand.traceStart =>
          ArgumentDecoder.noTail(tail, <String, Object?>{
            'name': options.option('name'),
            'activate': options.flag('activate'),
            'pinned': options.flag('pin'),
          }),
        PatchbayFriendlyCommand.traceMark => ArgumentDecoder.atLeastOneTail(
          tail,
          (List<String> words) => <String, Object?>{'note': words.join(' ')},
        ),
        PatchbayFriendlyCommand.traceStop => ArgumentDecoder.zeroOrOneTail(
          tail,
          (String? traceId) => <String, Object?>{'traceId': traceId},
        ),
        PatchbayFriendlyCommand.traceShow ||
        PatchbayFriendlyCommand.traceExport => ArgumentDecoder.oneTail(
          tail,
          (String traceId) => <String, Object?>{
            'traceId': traceId,
            if (spec == PatchbayFriendlyCommand.traceExport)
              'includeArtifacts': options.flag('include-artifacts'),
          },
        ),
        PatchbayFriendlyCommand.traceDiff => ArgumentDecoder.twoTail(
          tail,
          (String before, String after) => <String, Object?>{
            'before': before,
            'after': after,
          },
        ),
        PatchbayFriendlyCommand.describe => ArgumentDecoder.oneTail(
          tail,
          (String command) => <String, Object?>{'command': command},
        ),
        PatchbayFriendlyCommand.launch => <String, Object?>{
          'command': ArgumentDecoder.launchCommand(tail),
        },
        PatchbayFriendlyCommand.performanceProfile =>
          ArgumentDecoder.noTail(tail, <String, Object?>{
            'durationMs': ArgumentDecoder.positiveInt(
              options,
              'duration-ms',
              fallback: 10000,
            ),
            'sampleLimit': ArgumentDecoder.positiveInt(
              options,
              'sample-limit',
              fallback: 10000,
            ),
          }),
        PatchbayFriendlyCommand.snapshot => ArgumentDecoder.noTail(
          tail,
          <String, Object?>{
            if (options.option('path') case final String path) 'path': path,
          },
        ),
        PatchbayFriendlyCommand.snapshotWait =>
          ArgumentDecoder.snapshotWaitArguments(tail, options),
        PatchbayFriendlyCommand.snapshotDiff =>
          ArgumentDecoder.noTail(tail, <String, Object?>{
            'fromRevision':
                ArgumentDecoder.optionalPositiveInt(options, 'from') ??
                (throw const FormatException(
                  'snapshot diff requires --from <revision>',
                )),
          }),
        PatchbayFriendlyCommand.sessionUse =>
          ArgumentDecoder.sessionUseArguments(tail, options),
        PatchbayFriendlyCommand.sessionRegister =>
          ArgumentDecoder.sessionRegisterArguments(tail, options),
        PatchbayFriendlyCommand.sessionUnregister => ArgumentDecoder.oneTail(
          tail,
          (String sessionId) => <String, Object?>{'sessionId': sessionId},
        ),
        PatchbayFriendlyCommand.permissionStatus ||
        PatchbayFriendlyCommand.permissionReset => ArgumentDecoder.oneTail(
          tail,
          (String permission) => <String, Object?>{'permission': permission},
        ),
        PatchbayFriendlyCommand.permissionNormalize ||
        PatchbayFriendlyCommand.permissionFail => ArgumentDecoder.oneTail(
          tail,
          (String permission) => <String, Object?>{
            'permission': permission,
            'state': ArgumentDecoder.requiredOption(options, 'state'),
          },
        ),
        PatchbayFriendlyCommand.permissionExercise => ArgumentDecoder.oneTail(
          tail,
          (String permission) => <String, Object?>{
            'permission': permission,
            'decision': ArgumentDecoder.requiredOption(options, 'decision'),
          },
        ),
        PatchbayFriendlyCommand.exec => ArgumentDecoder.domainArguments(
          options,
          readSensitiveInput,
        ),
        PatchbayFriendlyCommand.jobGet ||
        PatchbayFriendlyCommand.jobCancel => ArgumentDecoder.oneTail(
          tail,
          (String jobId) => <String, Object?>{'jobId': jobId},
        ),
        PatchbayFriendlyCommand.uiTextSet ||
        PatchbayFriendlyCommand.uiTextEnter => ArgumentDecoder.textArguments(
          tail,
          options,
          readSensitiveInput,
        ),
        PatchbayFriendlyCommand.uiSemanticsTree => ArgumentDecoder.noTail(
          tail,
          ArgumentDecoder.domainArguments(options, readSensitiveInput),
        ),
        PatchbayFriendlyCommand.uiVerifyManifest => ArgumentDecoder.oneTail(
          tail,
          (String _) => const <String, Object?>{},
        ),
        PatchbayFriendlyCommand.uiTargets => ArgumentDecoder.noTail(
          tail,
          options.flag('emit-manifest')
              ? const <String, Object?>{}
              : throw const FormatException(
                  '--emit-manifest is required for ui targets',
                ),
        ),
        PatchbayFriendlyCommand.uiInspectOn =>
          ArgumentDecoder.noTail(tail, <String, Object?>{
            'enabled': true,
            'ttlMs': ?ArgumentDecoder.optionalPositiveInt(options, 'ttl-ms'),
          }),
        PatchbayFriendlyCommand.uiInspectOff => ArgumentDecoder.noTail(
          tail,
          const <String, Object?>{'enabled': false},
        ),
        PatchbayFriendlyCommand.uiInspectStatus => ArgumentDecoder.noTail(
          tail,
          const <String, Object?>{},
        ),
        PatchbayFriendlyCommand.uiSemanticsAction =>
          ArgumentDecoder.semanticsActionArguments(
            tail,
            options,
            readSensitiveInput,
          ),
        PatchbayFriendlyCommand.uiTap => ArgumentDecoder.oneTail(
          tail,
          (String identifier) => <String, Object?>{
            'identifier': identifier,
            'generation': ?ArgumentDecoder.optionalInt(options, 'generation'),
          },
        ),
        PatchbayFriendlyCommand.logsQuery ||
        PatchbayFriendlyCommand.logsTail ||
        PatchbayFriendlyCommand.logsExport ||
        PatchbayFriendlyCommand.captureRoot => ArgumentDecoder.noTail(
          tail,
          ArgumentDecoder.argumentsWithoutPositionals(spec, options),
        ),
        PatchbayFriendlyCommand.uiKeepAwakeOn =>
          ArgumentDecoder.noTail(tail, <String, Object?>{
            'enabled': true,
            'leaseMs': ?ArgumentDecoder.optionalPositiveInt(
              options,
              'lease-ms',
            ),
          }),
        PatchbayFriendlyCommand.uiKeepAwakeOff => ArgumentDecoder.noTail(
          tail,
          const <String, Object?>{'enabled': false},
        ),
        PatchbayFriendlyCommand.uiKeepAwakeStatus => ArgumentDecoder.noTail(
          tail,
          const <String, Object?>{},
        ),
        PatchbayFriendlyCommand.uiWaitSemanticsMounted ||
        PatchbayFriendlyCommand.uiWaitSemanticsUnmounted =>
          ArgumentDecoder.oneTail(
            tail,
            (String id) => ArgumentDecoder.waitArguments(
              options,
              condition: spec.waitCondition!,
              semanticsIdentifier: id,
            ),
          ),
        PatchbayFriendlyCommand.uiWaitSemanticsValue => ArgumentDecoder.twoTail(
          tail,
          (String id, String value) => ArgumentDecoder.waitArguments(
            options,
            condition: spec.waitCondition!,
            semanticsIdentifier: id,
            value: value,
          ),
        ),
        PatchbayFriendlyCommand.uiWaitDestination => ArgumentDecoder.oneTail(
          tail,
          (String destination) => ArgumentDecoder.waitArguments(
            options,
            condition: spec.waitCondition!,
            destinationId: destination,
            revision: ArgumentDecoder.optionalInt(options, 'revision'),
          ),
        ),
        PatchbayFriendlyCommand.uiWaitTreeRevision ||
        PatchbayFriendlyCommand.uiWaitFrameRevision => ArgumentDecoder.oneTail(
          tail,
          (String revision) => ArgumentDecoder.waitArguments(
            options,
            condition: spec.waitCondition!,
            revision: ArgumentDecoder.parseNonNegative(revision, 'revision'),
          ),
        ),
        PatchbayFriendlyCommand.captureTarget => ArgumentDecoder.twoTail(
          tail,
          (String id, String generation) => <String, Object?>{
            'targetId': id,
            'generation': ArgumentDecoder.parseNonNegative(
              generation,
              'generation',
            ),
            ...ArgumentDecoder.captureArguments(options),
          },
        ),
        PatchbayFriendlyCommand.captureDiff => ArgumentDecoder.twoTail(
          tail,
          (String beforeBlobId, String afterBlobId) => <String, Object?>{
            'beforeBlobId': beforeBlobId,
            'afterBlobId': afterBlobId,
          },
        ),
        PatchbayFriendlyCommand.blobGet ||
        PatchbayFriendlyCommand.blobMetadata => ArgumentDecoder.oneTail(
          tail,
          (String blobId) => <String, Object?>{'blobId': blobId},
        ),
        _ => throw StateError(
          'generated protocol command missed generic parser',
        ),
      };
    }
    // `renderedMember` commands accept `--output` but never require it: below
    // the inline threshold the CLI never touches disk, and above it the CLI
    // picks an auto-named path itself. `payloadBlob`/`responseBlob` commands
    // have no such fallback — the host artifact only exists at the path the
    // caller names.
    final bool requiresOutput =
        spec.artifact == PatchbayArtifactDisposition.payloadBlob ||
        spec.artifact == PatchbayArtifactDisposition.responseBlob;
    final bool allowsOutput = spec.artifact != PatchbayArtifactDisposition.none;
    final bool writesTraceExport = spec == PatchbayFriendlyCommand.traceExport;
    final String? outputPath = options.option('output');
    if ((requiresOutput || writesTraceExport) &&
        (outputPath == null || outputPath.isEmpty)) {
      throw const FormatException('--output is required for this command');
    }
    if (!allowsOutput && !writesTraceExport && outputPath != null) {
      throw const FormatException('--output is not valid for this command');
    }
    return PatchbayFriendlyInvocation(
      spec: spec,
      arguments: arguments,
      serviceCommand: serviceCommand,
      outputPath: outputPath,
      manifestPath: spec == PatchbayFriendlyCommand.uiVerifyManifest
          ? tail.single
          : null,
      force: options.flag('force'),
      plaintextArgumentKeys: ArgumentDecoder.plaintextArgumentKeys(options),
      resolvesRevision:
          spec.fencesNavigationRevision && options.option('revision') == null,
    );
  }

  static PatchbayFriendlyInvocation _resolveCanonicalUi({
    required PatchbayCanonicalUiCommandSpec spec,
    required List<String> tail,
    required ArgResults options,
    required List<PatchbayFriendlyCommandSpec> allCommands,
    required String Function() readSensitiveInput,
  }) {
    if (tail.isEmpty) {
      throw FormatException(
        '${spec.path.join(' ')} requires an explicit selector',
      );
    }
    final PatchbayCanonicalUiSelector selector =
        PatchbayCanonicalUiSelector.parse(tail.first);
    final String? via = options.option('via');
    if (spec == PatchbayCanonicalUiRegistry.tap && via == null) {
      throw const FormatException(
        'ui perform tap requires --via semantics or --via pointer',
      );
    }
    if (spec != PatchbayCanonicalUiRegistry.tap && via != null) {
      throw FormatException('--via is not valid for ${spec.path.join(' ')}');
    }
    final List<PatchbayCanonicalUiRoute> matches = spec.routes
        .where(
          (PatchbayCanonicalUiRoute route) =>
              route.selectorKind == selector.kind && route.via == via,
        )
        .toList(growable: false);
    if (matches.length != 1) {
      throw FormatException(
        '${selector.kind.name}: selector is not valid for '
        '${spec.path.join(' ')}${via == null ? '' : ' --via $via'}',
      );
    }
    final PatchbayCanonicalUiRoute route = matches.single;
    final PatchbayFriendlyCommandSpec destination = _protocolSpec(
      allCommands,
      route.serviceCommand,
    );
    final Set<String> allowed = <String>{...allowedOptions(destination)};
    final Map<String, String> boundOptionValues = <String, String>{};
    final List<String> destinationTail;
    if (route.serviceCommand == 'ui.semantics.tap') {
      if (tail.length != 2) {
        throw const FormatException(
          'ui perform tap requires <generation> after the selector',
        );
      }
      destinationTail = <String>[selector.value];
      allowed.remove('generation');
      boundOptionValues['generation'] = tail[1];
    } else {
      destinationTail = <String>[selector.value, ...tail.skip(1)];
    }
    if (spec == PatchbayCanonicalUiRegistry.tap) allowed.add('via');
    validateOptions(
      spec,
      options,
      allowedOverride: allowed,
      commandPath: spec.path,
    );
    final Map<String, Object?> arguments = ArgumentDecoder.protocolArguments(
      destination,
      destinationTail,
      options,
      readSensitiveInput,
      boundOptionValues: boundOptionValues,
    );
    return PatchbayFriendlyInvocation(
      spec: spec,
      arguments: arguments,
      serviceCommand: route.serviceCommand,
      plaintextArgumentKeys: ArgumentDecoder.plaintextArgumentKeys(options),
      localRoute: route.toLocalRoute(),
    );
  }

  static PatchbayFriendlyCommandSpec _protocolSpec(
    List<PatchbayFriendlyCommandSpec> allCommands,
    String serviceCommand,
  ) => allCommands.singleWhere(
    (PatchbayFriendlyCommandSpec command) =>
        command.protocolSyntax != null &&
        command.serviceCommand == serviceCommand,
  );

  static List<String> canonicalPath(
    List<String> words,
    List<PatchbayFriendlyCommandSpec> allCommands,
  ) {
    List<String> current = words;
    for (var pass = 0; pass < 2; pass += 1) {
      final List<String>? expanded = _expandAlias(current, allCommands);
      if (expanded == null) return current;
      current = expanded;
    }
    return current;
  }

  static List<String>? _expandAlias(
    List<String> words,
    List<PatchbayFriendlyCommandSpec> allCommands,
  ) {
    final List<_PathAlias> aliases = _buildAliases(allCommands);
    for (final _PathAlias alias in aliases) {
      if (!_startsWith(words, alias.from)) continue;
      return <String>[...alias.to, ...words.sublist(alias.from.length)];
    }
    return null;
  }

  static List<_PathAlias> _buildAliases(
    List<PatchbayFriendlyCommandSpec> allCommands,
  ) =>
      <_PathAlias>[
        for (final PatchbayFriendlyCommandSpec spec in allCommands)
          if (spec.waitCondition case final String condition)
            _PathAlias(<String>[
              ...spec.path.take(spec.path.length - 1),
              condition,
            ], spec.path),
        const _PathAlias(
          <String>['session', 'list'],
          <String>['sessions', 'list'],
        ),
        const _PathAlias(
          <String>['session', 'prune'],
          <String>['sessions', 'prune'],
        ),
        const _PathAlias(
          <String>['sessions', 'use'],
          <String>['session', 'use'],
        ),
        const _PathAlias(
          <String>['sessions', 'register'],
          <String>['session', 'register'],
        ),
        const _PathAlias(
          <String>['sessions', 'unregister'],
          <String>['session', 'unregister'],
        ),
        const _PathAlias(<String>['navigate'], <String>['navigation']),
        const _PathAlias(<String>['nav'], <String>['navigation']),
        const _PathAlias(<String>['wait'], <String>['ui', 'wait']),
        const _PathAlias(<String>['tap'], <String>['ui', 'tap']),
        const _PathAlias(<String>['keep-awake'], <String>['ui', 'keep-awake']),
        const _PathAlias(<String>['text'], <String>['ui', 'text']),
        const _PathAlias(<String>['semantics'], <String>['ui', 'semantics']),
      ]..sort(
        (_PathAlias a, _PathAlias b) => b.from.length.compareTo(a.from.length),
      );

  static bool _startsWith(List<String> words, List<String> prefix) {
    if (words.length < prefix.length) return false;
    for (var index = 0; index < prefix.length; index += 1) {
      if (words[index] != prefix[index]) return false;
    }
    return true;
  }

  static PatchbayFriendlyCommandSpec? match(
    List<String> words,
    List<PatchbayFriendlyCommandSpec> allCommands,
  ) {
    PatchbayFriendlyCommandSpec? result;
    for (final PatchbayFriendlyCommandSpec candidate in allCommands) {
      if (words.length < candidate.path.length) continue;
      bool matches = true;
      for (var index = 0; index < candidate.path.length; index += 1) {
        if (words[index] != candidate.path[index]) {
          matches = false;
          break;
        }
      }
      if (matches &&
          (result == null || candidate.path.length > result.path.length)) {
        result = candidate;
      }
    }
    return result;
  }

  static void validateOptions(
    PatchbayFriendlyCommandSpec spec,
    ArgResults options, {
    List<PatchbayFriendlyCommandSpec> allCommands =
        const <PatchbayFriendlyCommandSpec>[],
    Set<String>? allowedOverride,
    List<String>? commandPath,
  }) {
    final Set<String> allowed =
        allowedOverride ?? allowedOptions(spec, allCommands: allCommands);
    const Set<String> friendlyOptions = <String>{
      'args',
      'stdin',
      'path',
      'revision',
      'generation',
      'start',
      'gesture-path',
      'velocity',
      'duration-ms',
      'timeout-ms',
      'cursor',
      'container',
      'max-steps',
      'direction',
      'limit',
      'levels',
      'categories',
      'since',
      'until',
      'ttl-ms',
      'lease-ms',
      'pixel-ratio',
      'after-frames',
      'output',
      'force',
      'clear',
      'permission-driver',
      'device-id',
      'application-id',
      'process-id',
      'build-mode',
      'state',
      'decision',
      'confirm-system-permission',
      'emit-manifest',
      'navigate',
      'continue-on-error',
      'restore',
      'screen-timeout-ms',
      'total-timeout-ms',
      'name',
      'activate',
      'pin',
      'dry-run',
      'include-artifacts',
      'sample-limit',
      'max-inline-bytes',
      'via',
    };
    for (final String name in friendlyOptions) {
      if (options.wasParsed(name) && !allowed.contains(name)) {
        throw FormatException(
          '--$name is not valid for '
          '${(commandPath ?? spec.path).join(' ')}',
        );
      }
    }
    if (options.flag('force') && options.option('output') == null) {
      throw const FormatException('--force requires --output');
    }
    if (spec == PatchbayFriendlyCommand.uiVerifyManifest &&
        !options.flag('navigate') &&
        (options.flag('continue-on-error') ||
            options.flag('restore') ||
            options.wasParsed('screen-timeout-ms') ||
            options.wasParsed('total-timeout-ms'))) {
      throw const FormatException(
        '--continue-on-error, --restore and walkthrough timeouts require '
        '--navigate',
      );
    }
  }

  static Set<String> allowedOptions(
    PatchbayFriendlyCommandSpec spec, {
    List<PatchbayFriendlyCommandSpec> allCommands =
        const <PatchbayFriendlyCommandSpec>[],
  }) {
    if (spec is PatchbayCanonicalUiCommandSpec) {
      final Set<String> result = <String>{};
      for (final PatchbayCanonicalUiRoute route in spec.routes) {
        final PatchbayFriendlyCommandSpec destination = _protocolSpec(
          allCommands,
          route.serviceCommand,
        );
        result.addAll(allowedOptions(destination));
        if (route.serviceCommand == 'ui.semantics.tap') {
          result.remove('generation');
        }
        if (route.via != null) result.add('via');
      }
      return result;
    }
    if (spec.protocolSyntax case final PatchbayCliSyntax syntax) {
      return <String>{
        ...syntax.optionParameters.values,
        if (syntax.inputMode == PatchbayCliInputMode.mergedJsonObject) 'args',
        if (syntax.stdinParameter != null ||
            syntax.inputMode == PatchbayCliInputMode.mergedJsonObject)
          'stdin',
        // `spec.artifact`, not the wire-declared `syntax.artifactDisposition`:
        // PB-050-20's `renderedMember` override on `ui semantics tree` (see
        // `GeneratedProtocolCommand.artifact`) is a CLI-only decision the
        // descriptor never expresses, and `--output`/`--force` must become
        // legal for it the same way they did for the plain friendly
        // declarations of the other three covered commands.
        if (spec.artifact != PatchbayArtifactDisposition.none) ...<String>{
          'output',
          'force',
        },
        if (spec.artifact == PatchbayArtifactDisposition.renderedMember)
          'max-inline-bytes',
      };
    }
    return switch (spec) {
      PatchbayFriendlyCommand.identity ||
      PatchbayFriendlyCommand.catalog ||
      PatchbayFriendlyCommand.describe ||
      PatchbayFriendlyCommand.jobGet ||
      PatchbayFriendlyCommand.jobCancel ||
      PatchbayFriendlyCommand.networkProfile ||
      PatchbayFriendlyCommand.captureDiff ||
      PatchbayFriendlyCommand.uiInspectOff ||
      PatchbayFriendlyCommand.uiInspectStatus ||
      PatchbayFriendlyCommand.blobMetadata ||
      PatchbayFriendlyCommand.repl ||
      PatchbayFriendlyCommand.sessionsList ||
      PatchbayFriendlyCommand.sessionsPrune ||
      PatchbayFriendlyCommand.doctor ||
      PatchbayFriendlyCommand.uiKeepAwakeOff ||
      PatchbayFriendlyCommand.uiKeepAwakeStatus => const <String>{},
      PatchbayFriendlyCommand.uiVerifyManifest => const <String>{
        'navigate',
        'continue-on-error',
        'restore',
        'screen-timeout-ms',
        'total-timeout-ms',
      },
      PatchbayFriendlyCommand.uiTargets => const <String>{'emit-manifest'},
      PatchbayFriendlyCommand.permissionCapabilities ||
      PatchbayFriendlyCommand.permissionStatus ||
      PatchbayFriendlyCommand.permissionDoctor ||
      PatchbayFriendlyCommand.permissionReset => const <String>{
        'permission-driver',
        'device-id',
        'application-id',
        'timeout-ms',
      },
      PatchbayFriendlyCommand.permissionNormalize ||
      PatchbayFriendlyCommand.permissionFail => const <String>{
        'permission-driver',
        'device-id',
        'application-id',
        'timeout-ms',
        'state',
      },
      PatchbayFriendlyCommand.permissionExercise => const <String>{
        'permission-driver',
        'device-id',
        'application-id',
        'timeout-ms',
        'decision',
        'confirm-system-permission',
      },
      PatchbayFriendlyCommand.traceStart => const <String>{
        'name',
        'activate',
        'pin',
      },
      PatchbayFriendlyCommand.traceMark ||
      PatchbayFriendlyCommand.traceStop ||
      PatchbayFriendlyCommand.traceShow => const <String>{},
      PatchbayFriendlyCommand.traceExport => const <String>{
        'output',
        'include-artifacts',
      },
      PatchbayFriendlyCommand.traceDiff => const <String>{},
      PatchbayFriendlyCommand.tracePrune => const <String>{'dry-run'},
      PatchbayFriendlyCommand.launch => const <String>{'keep-awake'},
      PatchbayFriendlyCommand.performanceProfile => const <String>{
        'duration-ms',
        'sample-limit',
      },
      PatchbayFriendlyCommand.uiKeepAwakeOn => const <String>{'lease-ms'},
      PatchbayFriendlyCommand.snapshot => const <String>{'path'},
      PatchbayFriendlyCommand.snapshotWait => const <String>{
        'until',
        'timeout-ms',
      },
      PatchbayFriendlyCommand.snapshotDiff => const <String>{'from'},
      PatchbayFriendlyCommand.sessionUse => const <String>{'clear'},
      // `--ws-uri` is a *recorded* value here, not a dialled one: the whole
      // command is a local write to the session directory. It is deliberately
      // absent from `friendlyOptions` below, because that list is a
      // reject-everywhere-else list and `--ws-uri` is legal on every command
      // that actually connects.
      PatchbayFriendlyCommand.sessionRegister => const <String>{
        'ws-uri',
        'application-id',
        'device-id',
        'process-id',
        'build-mode',
      },
      PatchbayFriendlyCommand.sessionUnregister => const <String>{},
      // `uiSemanticsTree` is never matched (see the comment on its
      // declaration in friendly_commands.dart); `exec`'s options cover the
      // stub too so a future un-deprecation would not need to change this.
      PatchbayFriendlyCommand.exec || PatchbayFriendlyCommand.uiSemanticsTree =>
        const <String>{'args', 'stdin'},
      PatchbayFriendlyCommand.uiWidgetTree ||
      PatchbayFriendlyCommand.uiRenderTree ||
      PatchbayFriendlyCommand.uiFocusTree => const <String>{
        'output',
        'force',
        'max-inline-bytes',
      },
      PatchbayFriendlyCommand.uiTextSet ||
      PatchbayFriendlyCommand.uiTextEnter ||
      PatchbayFriendlyCommand.uiSemanticsAction => const <String>{'stdin'},
      PatchbayFriendlyCommand.uiTap => const <String>{'generation'},
      PatchbayFriendlyCommand.uiInspectOn => const <String>{'ttl-ms'},
      PatchbayFriendlyCommand.uiWaitSemanticsMounted ||
      PatchbayFriendlyCommand.uiWaitSemanticsUnmounted ||
      PatchbayFriendlyCommand.uiWaitSemanticsValue ||
      PatchbayFriendlyCommand.uiWaitTreeRevision ||
      PatchbayFriendlyCommand.uiWaitFrameRevision => const <String>{
        'timeout-ms',
      },
      PatchbayFriendlyCommand.uiWaitDestination => const <String>{
        'revision',
        'timeout-ms',
      },
      PatchbayFriendlyCommand.logsQuery => const <String>{
        'cursor',
        'direction',
        'limit',
        'levels',
        'categories',
        'since',
        'until',
      },
      PatchbayFriendlyCommand.logsTail => const <String>{
        'cursor',
        'limit',
        'levels',
        'categories',
        'timeout-ms',
      },
      PatchbayFriendlyCommand.logsExport => const <String>{
        'cursor',
        'direction',
        'limit',
        'levels',
        'categories',
        'since',
        'until',
        'ttl-ms',
        'output',
        'force',
      },
      PatchbayFriendlyCommand.captureRoot ||
      PatchbayFriendlyCommand.captureTarget => const <String>{
        'pixel-ratio',
        'after-frames',
        'timeout-ms',
        'output',
        'force',
      },
      PatchbayFriendlyCommand.blobGet => const <String>{'output', 'force'},
      _ => throw StateError('generated protocol command bypassed metadata'),
    };
  }
}
