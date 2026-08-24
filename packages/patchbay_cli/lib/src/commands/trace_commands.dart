import 'package:args/args.dart';
import 'package:patchbay/patchbay.dart';

import '../command_registry.dart';
import '../trace.dart';
import 'session_commands.dart';

/// Handler for local trace-store commands (`trace start/mark/stop/show/export/diff/prune`).
abstract final class LocalTraceCommandHandler {
  /// Runs one local trace command.
  static LocalOutcome runLocalTraceCommand(ArgResults parsed) {
    validateLocalTraceShape(parsed);
    final PatchbayFriendlyInvocation friendly =
        PatchbayFriendlyCommandRegistry.resolve(parsed.rest, parsed)!;
    final PatchbayTraceStore traces = PatchbayTraceStore(
      parsed.option('trace-dir'),
    );
    final String? explicit = parsed.option('trace');
    switch (friendly.spec) {
      case PatchbayFriendlyCommand.traceStart:
        if (explicit != null) {
          throw const FormatException('trace start does not accept --trace');
        }
        final Object? name = friendly.arguments['name'];
        if (name is! String || name.trim().isEmpty) {
          throw const FormatException('trace start requires --name <name>');
        }
        final PatchbayTraceManifest manifest = traces.start(
          name: name,
          cliVersion: patchbayPackageVersion,
          activate: friendly.arguments['activate'] == true,
          pinned: friendly.arguments['pinned'] == true,
        );
        return LocalOutcome(<String, Object?>{
          'trace': manifest.toJson(),
          'active': friendly.arguments['activate'] == true,
        }, 'traceId: ${manifest.traceId}');
      case PatchbayFriendlyCommand.traceMark:
        final PatchbayTraceManifest manifest = traces.mark(
          explicit,
          friendly.arguments['note']! as String,
        );
        return LocalOutcome(<String, Object?>{
          'trace': manifest.toJson(),
          'marked': true,
        }, 'marked ${manifest.traceId}');
      case PatchbayFriendlyCommand.traceStop:
        final String? positional = friendly.arguments['traceId'] as String?;
        if (positional != null && explicit != null && positional != explicit) {
          throw const FormatException(
            'trace stop positional id and --trace must match',
          );
        }
        final PatchbayTraceManifest manifest = traces.stop(
          positional ?? explicit,
        );
        return LocalOutcome(<String, Object?>{
          'trace': manifest.toJson(),
          'stopped': true,
        }, 'stopped ${manifest.traceId}');
      case PatchbayFriendlyCommand.traceShow:
        final PatchbayTraceReadResult result = traces.show(
          friendly.arguments['traceId']! as String,
        );
        return LocalOutcome(result.toJson(), traceTimeline(result));
      case PatchbayFriendlyCommand.traceExport:
        final Map<String, Object?> result = traces.exportDirectory(
          friendly.arguments['traceId']! as String,
          friendly.outputPath!,
          includeArtifacts: friendly.arguments['includeArtifacts'] == true,
        );
        return LocalOutcome(
          result,
          'exported ${result['traceId']} to ${result['output']}',
        );
      case PatchbayFriendlyCommand.traceDiff:
        final Map<String, Object?> result = traces.diff(
          friendly.arguments['before']! as String,
          friendly.arguments['after']! as String,
        );
        final int changes =
            (result['added']! as List<Object?>).length +
            (result['removed']! as List<Object?>).length +
            (result['changed']! as List<Object?>).length;
        return LocalOutcome(result, 'trace diff: $changes change(s)');
      case PatchbayFriendlyCommand.tracePrune:
        final PatchbayTracePruneResult result = traces.prune(
          dryRun: friendly.arguments['dryRun'] == true,
        );
        return LocalOutcome(
          result.toJson(),
          result.dryRun
              ? 'would prune ${result.candidates.length} trace(s)'
              : 'pruned ${result.candidates.length} trace(s)',
        );
      default:
        throw StateError(
          'unexpected local trace command ${friendly.spec.name}',
        );
    }
  }

  static void validateLocalTraceShape(ArgResults parsed) {
    for (final String name in const <String>[
      'ws-uri',
      'session',
      'direct-endpoint',
      'direct-token-stdin',
    ]) {
      if (!parsed.wasParsed(name)) continue;
      throw FormatException(
        '--$name does not apply to a local trace-store command',
      );
    }
  }

  static String traceTimeline(PatchbayTraceReadResult result) {
    final List<String> lines = <String>[
      '${result.manifest.traceId} ${result.manifest.name} '
          '${result.manifest.ended ? 'finished' : 'active'} '
          'integrity=${result.integrity}',
      for (final PatchbayTraceEvent event in result.events)
        '${event.sequence.toString().padLeft(4)} '
            '+${event.elapsedMs}ms ${event.type}'
            '${event.requestId == null ? '' : ' request=${event.requestId}'}'
            '${event.jobId == null ? '' : ' job=${event.jobId}'}',
      if (result.truncatedTail) 'warning: truncatedTail',
      for (final String digest in result.missingArtifacts)
        'warning: missing artifact $digest',
    ];
    return lines.join('\n');
  }
}
