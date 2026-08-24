import 'dart:async';

import 'package:args/args.dart';
import 'package:patchbay/patchbay.dart';

import '../client.dart';
import '../result.dart';
import '../ui_manifest.dart';

const String manifestWalkthroughSchema = 'uiManifestWalkthroughReport';
const Duration defaultManifestScreenBudget = Duration(seconds: 5);
const Duration maximumManifestScreenBudget = Duration(minutes: 2);
const Duration defaultManifestTotalBudget = Duration(minutes: 2);
const Duration maximumManifestTotalBudget = Duration(minutes: 10);

/// Result of a manifest walkthrough execution containing response payload, exit code, and human summary.
final class ManifestWalkthroughResult {
  const ManifestWalkthroughResult({
    required this.response,
    required this.exitCode,
    required this.summary,
  });

  final Map<String, Object?> response;
  final int exitCode;
  final String? summary;
}

/// Encapsulates the manifest walkthrough audit execution.
abstract final class ManifestWalkthroughRunner {
  /// Runs the explicitly side-effecting, destination-ordered manifest audit.
  static Future<ManifestWalkthroughResult> walkUiManifest({
    required PatchbayClient connection,
    required Map<String, Object?> initialCatalog,
    required PatchbayUiManifest manifest,
    required ArgResults parsed,
    required bool Function(Map<String, Object?> catalog, String command)
    hasCatalogCommand,
    required Future<Map<String, Object?>> Function(
      PatchbayClient connection,
      Map<String, Object?> catalog,
      String command,
      Map<String, Object?> arguments, {
      Duration? deadline,
    })
    invokeAgainstCatalog,
    required String? Function(Map<String, Object?> response)
    getNavigationDestination,
    required int? Function(Map<String, Object?> response) getNavigationRevision,
    required PatchbayUiManifestSemanticsRuntime Function(
      Map<String, Object?> response,
    )
    getManifestSemanticsRuntime,
    required Map<String, Object?> Function(
      Map<String, Object?> response,
      String key,
    )
    withSource,
  }) async {
    final Duration screenBudget = manifestWalkthroughBudget(
      parsed,
      'screen-timeout-ms',
      fallback: defaultManifestScreenBudget,
      maximum: maximumManifestScreenBudget,
    );
    final Duration totalBudget = manifestWalkthroughBudget(
      parsed,
      'total-timeout-ms',
      fallback: defaultManifestTotalBudget,
      maximum: maximumManifestTotalBudget,
    );
    final bool continueOnError = parsed.flag('continue-on-error');
    final bool restoreRequested = parsed.flag('restore');
    const Set<String> requiredCommands = <String>{
      'navigation.catalog',
      'navigation.current',
      'navigation.go',
      'ui.wait',
    };
    final Set<String> missingCommands = <String>{
      for (final String command in requiredCommands)
        if (!hasCatalogCommand(initialCatalog, command)) command,
    };

    if (missingCommands.isNotEmpty || manifest.destinations.isEmpty) {
      if (hasCatalogCommand(initialCatalog, 'navigation.current') ||
          !manifest.usesDestinations) {
        final ManifestWalkthroughResult current = await verifyManifestCurrent(
          connection: connection,
          catalog: initialCatalog,
          manifest: manifest,
          hasCatalogCommand: hasCatalogCommand,
          invokeAgainstCatalog: invokeAgainstCatalog,
          getNavigationDestination: getNavigationDestination,
          getManifestSemanticsRuntime: getManifestSemanticsRuntime,
          withSource: withSource,
        );
        return ManifestWalkthroughResult(
          response: <String, Object?>{
            ...current.response,
            'navigationMode': 'unavailable',
            'navigationUnavailableReason': manifest.destinations.isEmpty
                ? 'manifestDestinationsUnavailable'
                : 'navigationCapabilityUnavailable',
            if (missingCommands.isNotEmpty)
              'missingCommands': missingCommands.toList()..sort(),
          },
          exitCode: current.exitCode,
          summary:
              'navigation unavailable; ${current.summary ?? 'current-screen verification only'}',
        );
      }
      return ManifestWalkthroughResult(
        response: <String, Object?>{
          'schema': manifestWalkthroughSchema,
          'navigationMode': 'unavailable',
          'reasonCode': 'navigationCapabilityUnavailable',
          'missingCommands': missingCommands.toList()..sort(),
          'visited': const <String>[],
          'passed': const <String>[],
          'failed': const <String>[],
          'skipped': manifest.destinations,
          'destinations': <Map<String, Object?>>[
            for (final String destination in manifest.destinations)
              <String, Object?>{
                'destinationId': destination,
                'status': 'skipped',
                'reasonCode': 'navigationCapabilityUnavailable',
              },
          ],
          'restore': <String, Object?>{
            'requested': restoreRequested,
            'attempted': false,
          },
          'finalDestination': null,
        },
        exitCode: PatchbayExitCode.typedFailure,
        summary:
            'navigation unavailable; no destination-scoped verdict emitted',
      );
    }

    final Stopwatch total = Stopwatch()..start();
    final List<String> visited = <String>[];
    final List<String> passed = <String>[];
    final List<String> failed = <String>[];
    final List<String> skipped = <String>[];
    final List<Map<String, Object?>> destinations = <Map<String, Object?>>[];
    final List<Map<String, Object?>> notices = <Map<String, Object?>>[];
    int primaryExitCode = PatchbayExitCode.accepted;

    final Map<String, Object?> navigationCatalogResponse =
        await invokeWalkthroughWait(
          connection,
          initialCatalog,
          'navigation.catalog',
          const <String, Object?>{},
          deadline: totalBudget - total.elapsed,
          total: total,
          totalBudget: totalBudget,
          timeoutCode: 'manifestWalkthroughTotalTimeout',
          invokeAgainstCatalog: invokeAgainstCatalog,
        );
    if (patchbayExitCodeFor(navigationCatalogResponse) !=
        PatchbayExitCode.accepted) {
      return walkthroughPreludeRejected(
        manifest,
        restoreRequested,
        navigationCatalogResponse,
        'navigationCatalogRejected',
      );
    }
    final PatchbayNavigationCatalogWire navigationCatalog =
        decodeNavigationCatalog(navigationCatalogResponse);
    final Map<String, PatchbayDestinationDescriptorWire> descriptors =
        <String, PatchbayDestinationDescriptorWire>{
          for (final PatchbayDestinationDescriptorWire descriptor
              in navigationCatalog.destinations)
            descriptor.id: descriptor,
        };

    final Map<String, Object?> initialCurrent = await invokeWalkthroughWait(
      connection,
      initialCatalog,
      'navigation.current',
      const <String, Object?>{},
      deadline: totalBudget - total.elapsed,
      total: total,
      totalBudget: totalBudget,
      timeoutCode: 'manifestWalkthroughTotalTimeout',
      invokeAgainstCatalog: invokeAgainstCatalog,
    );
    if (patchbayExitCodeFor(initialCurrent) != PatchbayExitCode.accepted) {
      return walkthroughPreludeRejected(
        manifest,
        restoreRequested,
        initialCurrent,
        'navigationCurrentRejected',
      );
    }
    final String? initialDestination = getNavigationDestination(initialCurrent);

    var stopped = false;
    for (var index = 0; index < manifest.destinations.length; index += 1) {
      final String destination = manifest.destinations[index];
      if (stopped) {
        skipped.add(destination);
        destinations.add(<String, Object?>{
          'destinationId': destination,
          'status': 'skipped',
          'reasonCode': 'stoppedAfterFailure',
        });
        continue;
      }
      if (total.elapsed >= totalBudget) {
        failed.add(destination);
        destinations.add(<String, Object?>{
          'destinationId': destination,
          'status': 'failed',
          'reasonCode': 'manifestWalkthroughTotalTimeout',
        });
        primaryExitCode = firstFailure(
          primaryExitCode,
          PatchbayExitCode.typedFailure,
        );
        stopped = true;
        continue;
      }

      final PatchbayDestinationDescriptorWire? descriptor =
          descriptors[destination];
      final String? descriptorFailure = descriptor == null
          ? 'manifestDestinationNotDeclared'
          : descriptor.ambiguous
          ? 'navigationDestinationAmbiguous'
          : !descriptor.operations.contains(PatchbayNavigationOperationWire.go)
          ? 'navigationGoUnsupported'
          : null;
      if (descriptorFailure != null) {
        failed.add(destination);
        destinations.add(<String, Object?>{
          'destinationId': destination,
          'status': 'failed',
          'reasonCode': descriptorFailure,
          if (descriptor != null) 'descriptorGates': descriptor.gates,
        });
        primaryExitCode = firstFailure(
          primaryExitCode,
          PatchbayExitCode.rejected,
        );
        stopped = !continueOnError;
        continue;
      }

      final Stopwatch screen = Stopwatch()..start();
      final Duration currentTimeout = remainingWalkthroughBudget(
        screenBudget,
        screen.elapsed,
        totalBudget,
        total.elapsed,
      );
      final Map<String, Object?> current = await invokeWalkthroughWait(
        connection,
        initialCatalog,
        'navigation.current',
        const <String, Object?>{},
        deadline: currentTimeout,
        total: total,
        totalBudget: totalBudget,
        invokeAgainstCatalog: invokeAgainstCatalog,
      );
      Map<String, Object?>? failure;
      if (patchbayExitCodeFor(current) != PatchbayExitCode.accepted) {
        failure = current;
      } else {
        final Duration navigationTimeout = remainingWalkthroughBudget(
          screenBudget,
          screen.elapsed,
          totalBudget,
          total.elapsed,
        );
        if (navigationTimeout <= Duration.zero) {
          failure = localWalkthroughFailure('manifestWalkthroughScreenTimeout');
        } else {
          final Map<String, Object?> navigation = await invokeWalkthroughWait(
            connection,
            initialCatalog,
            'navigation.go',
            <String, Object?>{
              'destinationId': destination,
              'revision': getNavigationRevision(current),
              'timeoutMs': navigationTimeout.inMilliseconds,
            },
            deadline: navigationTimeout,
            total: total,
            totalBudget: totalBudget,
            invokeAgainstCatalog: invokeAgainstCatalog,
          );
          if (patchbayExitCodeFor(navigation) != PatchbayExitCode.accepted) {
            failure = navigation;
          } else {
            final Duration stableTimeout = remainingWalkthroughBudget(
              screenBudget,
              screen.elapsed,
              totalBudget,
              total.elapsed,
            );
            if (stableTimeout <= Duration.zero) {
              failure = localWalkthroughFailure(
                'manifestWalkthroughScreenTimeout',
              );
            } else {
              final Map<String, Object?> stable = await invokeWalkthroughWait(
                connection,
                initialCatalog,
                'ui.wait',
                <String, Object?>{
                  'condition': 'navigationDestination',
                  'timeoutMs': stableTimeout.inMilliseconds,
                  'destinationId': destination,
                },
                deadline: stableTimeout,
                total: total,
                totalBudget: totalBudget,
                invokeAgainstCatalog: invokeAgainstCatalog,
              );
              if (patchbayExitCodeFor(stable) != PatchbayExitCode.accepted) {
                failure = stable;
              }
            }
          }
        }
      }

      if (failure == null && total.elapsed >= totalBudget) {
        failure = localWalkthroughFailure('manifestWalkthroughTotalTimeout');
      } else if (failure == null && screen.elapsed >= screenBudget) {
        failure = localWalkthroughFailure('manifestWalkthroughScreenTimeout');
      }

      if (failure != null) {
        final String reason = walkthroughFailureCode(failure);
        failed.add(destination);
        destinations.add(<String, Object?>{
          'destinationId': destination,
          'status': 'failed',
          'reasonCode': reason,
          'descriptorGates': descriptor!.gates,
        });
        primaryExitCode = firstFailure(
          primaryExitCode,
          patchbayExitCodeFor(failure),
        );
        stopped =
            reason == 'manifestWalkthroughTotalTimeout' || !continueOnError;
        continue;
      }

      visited.add(destination);
      PatchbayUiManifestSemanticsRuntime? semantics;
      Map<String, Object?>? verificationFailure;
      Map<String, Object?>? screenCatalog;
      final Duration catalogTimeout = remainingWalkthroughBudget(
        screenBudget,
        screen.elapsed,
        totalBudget,
        total.elapsed,
      );
      if (catalogTimeout.inMilliseconds < 1) {
        verificationFailure = localWalkthroughFailure(
          total.elapsed >= totalBudget
              ? 'manifestWalkthroughTotalTimeout'
              : 'manifestWalkthroughScreenTimeout',
        );
      } else {
        try {
          screenCatalog = await connection.catalog().timeout(catalogTimeout);
        } on TimeoutException {
          verificationFailure = localWalkthroughFailure(
            total.elapsed >= totalBudget
                ? 'manifestWalkthroughTotalTimeout'
                : 'manifestWalkthroughScreenTimeout',
          );
        }
      }
      if (verificationFailure == null &&
          manifest.requiresSemanticsAt(destination)) {
        if (!hasCatalogCommand(screenCatalog!, 'ui.semantics.tree')) {
          verificationFailure = localWalkthroughFailure(
            'manifestSemanticsUnavailable',
          );
        } else {
          final Duration semanticsTimeout = remainingWalkthroughBudget(
            screenBudget,
            screen.elapsed,
            totalBudget,
            total.elapsed,
          );
          final Map<String, Object?> observed = await invokeWalkthroughWait(
            connection,
            screenCatalog,
            'ui.semantics.tree',
            const <String, Object?>{},
            deadline: semanticsTimeout,
            total: total,
            totalBudget: totalBudget,
            invokeAgainstCatalog: invokeAgainstCatalog,
          );
          if (patchbayExitCodeFor(observed) != PatchbayExitCode.accepted) {
            verificationFailure = observed;
          } else {
            semantics = getManifestSemanticsRuntime(observed);
          }
        }
      }
      if (verificationFailure != null) {
        final String reason = walkthroughFailureCode(verificationFailure);
        failed.add(destination);
        destinations.add(<String, Object?>{
          'destinationId': destination,
          'status': 'failed',
          'reasonCode': reason,
          'descriptorGates': descriptor!.gates,
        });
        primaryExitCode = firstFailure(
          primaryExitCode,
          patchbayExitCodeFor(verificationFailure),
        );
        stopped =
            reason == 'manifestWalkthroughTotalTimeout' || !continueOnError;
        continue;
      }
      final PatchbayUiManifestReport report = verifyPatchbayUiManifest(
        manifest: manifest,
        runtime: decodePatchbayCatalogUiTargets(screenCatalog!),
        currentDestination: destination,
        semantics: semantics,
      );
      if (report.hasDeviation) {
        failed.add(destination);
        primaryExitCode = firstFailure(
          primaryExitCode,
          PatchbayExitCode.verificationDeviation,
        );
        stopped = !continueOnError;
      } else {
        passed.add(destination);
      }
      destinations.add(<String, Object?>{
        'destinationId': destination,
        'status': report.hasDeviation ? 'failed' : 'passed',
        'reasonCode': report.hasDeviation ? 'manifestDeviation' : 'verified',
        'descriptorGates': descriptor!.gates,
        'report': report.toJson(),
      });
    }

    final Map<String, Object?> restore = <String, Object?>{
      'requested': restoreRequested,
      'attempted': false,
    };
    String? finalDestination;
    Map<String, Object?>? finalCurrent;
    try {
      finalCurrent = await invokeWalkthroughWait(
        connection,
        initialCatalog,
        'navigation.current',
        const <String, Object?>{},
        deadline: totalBudget - total.elapsed,
        total: total,
        totalBudget: totalBudget,
        invokeAgainstCatalog: invokeAgainstCatalog,
      );
      if (patchbayExitCodeFor(finalCurrent) == PatchbayExitCode.accepted) {
        finalDestination = getNavigationDestination(finalCurrent);
      }
    } on Object {
      // Primary walkthrough result remains authoritative.
    }
    if (restoreRequested &&
        initialDestination != null &&
        finalDestination != initialDestination) {
      final Duration remaining = remainingWalkthroughBudget(
        screenBudget,
        Duration.zero,
        totalBudget,
        total.elapsed,
      );
      if (remaining.inMilliseconds < 1 ||
          finalCurrent == null ||
          patchbayExitCodeFor(finalCurrent) != PatchbayExitCode.accepted) {
        restore['reasonCode'] = 'manifestRestoreBudgetUnavailable';
        notices.add(const <String, Object?>{
          'code': 'manifestRestoreFailed',
          'reasonCode': 'manifestRestoreBudgetUnavailable',
        });
      } else {
        restore['attempted'] = true;
        final Map<String, Object?> response = await invokeWalkthroughWait(
          connection,
          initialCatalog,
          'navigation.go',
          <String, Object?>{
            'destinationId': initialDestination,
            'revision': getNavigationRevision(finalCurrent),
            'timeoutMs': remaining.inMilliseconds,
          },
          deadline: remaining,
          total: total,
          totalBudget: totalBudget,
          invokeAgainstCatalog: invokeAgainstCatalog,
        );
        if (patchbayExitCodeFor(response) != PatchbayExitCode.accepted) {
          final String reason = walkthroughFailureCode(response);
          restore['reasonCode'] = reason;
          notices.add(<String, Object?>{
            'code': 'manifestRestoreFailed',
            'reasonCode': reason,
          });
        } else {
          restore['outcome'] = 'restored';
          finalDestination = initialDestination;
        }
        final Map<String, Object?> observed = await invokeWalkthroughWait(
          connection,
          initialCatalog,
          'navigation.current',
          const <String, Object?>{},
          deadline: totalBudget - total.elapsed,
          total: total,
          totalBudget: totalBudget,
          invokeAgainstCatalog: invokeAgainstCatalog,
        );
        if (patchbayExitCodeFor(observed) == PatchbayExitCode.accepted) {
          finalDestination = getNavigationDestination(observed);
        }
      }
    }

    final Map<String, Object?> response = <String, Object?>{
      'schema': manifestWalkthroughSchema,
      'navigationMode': 'walkthrough',
      'visited': visited,
      'passed': passed,
      'failed': failed,
      'skipped': skipped,
      'destinations': destinations,
      'initialDestination': initialDestination,
      'finalDestination': finalDestination,
      'restore': restore,
      if (notices.isNotEmpty) 'notices': notices,
    };
    return ManifestWalkthroughResult(
      response: response,
      exitCode: primaryExitCode,
      summary:
          'visited=${visited.length} passed=${passed.length} '
          'failed=${failed.length} skipped=${skipped.length} '
          'finalDestination=${finalDestination ?? 'none'}',
    );
  }

  static Future<ManifestWalkthroughResult> verifyManifestCurrent({
    required PatchbayClient connection,
    required Map<String, Object?> catalog,
    required PatchbayUiManifest manifest,
    required bool Function(Map<String, Object?> catalog, String command)
    hasCatalogCommand,
    required Future<Map<String, Object?>> Function(
      PatchbayClient connection,
      Map<String, Object?> catalog,
      String command,
      Map<String, Object?> arguments,
    )
    invokeAgainstCatalog,
    required String? Function(Map<String, Object?> response)
    getNavigationDestination,
    required PatchbayUiManifestSemanticsRuntime Function(
      Map<String, Object?> response,
    )
    getManifestSemanticsRuntime,
    required Map<String, Object?> Function(
      Map<String, Object?> response,
      String key,
    )
    withSource,
  }) async {
    String? destination;
    if (manifest.usesDestinations) {
      final Map<String, Object?> current = await invokeAgainstCatalog(
        connection,
        catalog,
        'navigation.current',
        const <String, Object?>{},
      );
      if (current['admission'] == 'rejected') {
        return ManifestWalkthroughResult(
          response: withSource(current, 'destinationSource'),
          exitCode: patchbayExitCodeFor(current),
          summary: null,
        );
      }
      destination = getNavigationDestination(current);
    }
    PatchbayUiManifestSemanticsRuntime? semantics;
    if (manifest.requiresSemanticsAt(destination)) {
      if (!hasCatalogCommand(catalog, 'ui.semantics.tree')) {
        throw const PatchbayProtocolException('manifestSemanticsUnavailable');
      }
      final Map<String, Object?> observed = await invokeAgainstCatalog(
        connection,
        catalog,
        'ui.semantics.tree',
        const <String, Object?>{},
      );
      if (observed['admission'] == 'rejected') {
        return ManifestWalkthroughResult(
          response: withSource(observed, 'semanticsSource'),
          exitCode: patchbayExitCodeFor(observed),
          summary: null,
        );
      }
      semantics = getManifestSemanticsRuntime(observed);
    }
    final PatchbayUiManifestReport report = verifyPatchbayUiManifest(
      manifest: manifest,
      runtime: decodePatchbayCatalogUiTargets(catalog),
      currentDestination: destination,
      semantics: semantics,
    );
    return ManifestWalkthroughResult(
      response: report.toJson(),
      exitCode: report.hasDeviation
          ? PatchbayExitCode.verificationDeviation
          : PatchbayExitCode.accepted,
      summary: report.humanReport,
    );
  }

  static Duration manifestWalkthroughBudget(
    ArgResults parsed,
    String name, {
    required Duration fallback,
    required Duration maximum,
  }) {
    final String? raw = parsed.option(name);
    if (raw == null) return fallback;
    final int? milliseconds = int.tryParse(raw);
    if (milliseconds == null ||
        milliseconds <= 0 ||
        milliseconds > maximum.inMilliseconds) {
      throw FormatException(
        '--$name must be an integer from 1 to ${maximum.inMilliseconds}',
      );
    }
    return Duration(milliseconds: milliseconds);
  }

  static Duration remainingWalkthroughBudget(
    Duration screenBudget,
    Duration screenElapsed,
    Duration totalBudget,
    Duration totalElapsed,
  ) {
    final Duration screenRemaining = screenBudget - screenElapsed;
    final Duration totalRemaining = totalBudget - totalElapsed;
    return screenRemaining < totalRemaining ? screenRemaining : totalRemaining;
  }

  static int firstFailure(int current, int next) =>
      current == PatchbayExitCode.accepted ? next : current;

  static Map<String, Object?> localWalkthroughFailure(String code) =>
      <String, Object?>{
        'outcome': 'failed',
        'failure': <String, Object?>{'code': code},
      };

  static Future<Map<String, Object?>> invokeWalkthroughWait(
    PatchbayClient connection,
    Map<String, Object?> catalog,
    String command,
    Map<String, Object?> arguments, {
    required Duration deadline,
    required Stopwatch total,
    required Duration totalBudget,
    String? timeoutCode,
    required Future<Map<String, Object?>> Function(
      PatchbayClient connection,
      Map<String, Object?> catalog,
      String command,
      Map<String, Object?> arguments, {
      Duration? deadline,
    })
    invokeAgainstCatalog,
  }) async {
    if (deadline.inMilliseconds < 1) {
      return localWalkthroughFailure(
        timeoutCode ??
            (total.elapsed >= totalBudget
                ? 'manifestWalkthroughTotalTimeout'
                : 'manifestWalkthroughScreenTimeout'),
      );
    }
    try {
      return await invokeAgainstCatalog(
        connection,
        catalog,
        command,
        arguments,
        deadline: deadline,
      ).timeout(deadline);
    } on TimeoutException {
      return localWalkthroughFailure(
        timeoutCode ??
            (total.elapsed >= totalBudget
                ? 'manifestWalkthroughTotalTimeout'
                : 'manifestWalkthroughScreenTimeout'),
      );
    }
  }

  static String walkthroughFailureCode(Map<String, Object?> response) {
    final Object? rejection = response['rejection'];
    if (rejection is Map<Object?, Object?> && rejection['code'] is String) {
      return rejection['code']! as String;
    }
    final Object? failure = response['failure'];
    if (failure is Map<Object?, Object?> && failure['code'] is String) {
      return failure['code']! as String;
    }
    return 'manifestWalkthroughFailed';
  }

  static PatchbayNavigationCatalogWire decodeNavigationCatalog(
    Map<String, Object?> response,
  ) {
    final Object? payload = response['payload'];
    if (payload is! Map<String, Object?>) {
      throw const PatchbayProtocolException(
        'navigationCatalogContractViolated',
      );
    }
    try {
      return PatchbayNavigationCatalogWire.fromJson(payload);
    } on FormatException catch (failure) {
      throw PatchbayProtocolException(
        'navigationCatalogContractViolated',
        details: <String, Object?>{'reason': failure.message},
      );
    }
  }

  static ManifestWalkthroughResult walkthroughPreludeRejected(
    PatchbayUiManifest manifest,
    bool restoreRequested,
    Map<String, Object?> rejection,
    String fallbackCode,
  ) {
    final String code =
        walkthroughFailureCode(rejection) == 'manifestWalkthroughFailed'
        ? fallbackCode
        : walkthroughFailureCode(rejection);
    return ManifestWalkthroughResult(
      response: <String, Object?>{
        'schema': manifestWalkthroughSchema,
        'navigationMode': 'walkthrough',
        'reasonCode': code,
        'visited': const <String>[],
        'passed': const <String>[],
        'failed': const <String>[],
        'skipped': manifest.destinations,
        'destinations': <Map<String, Object?>>[
          for (final String destination in manifest.destinations)
            <String, Object?>{
              'destinationId': destination,
              'status': 'skipped',
              'reasonCode': code,
            },
        ],
        'restore': <String, Object?>{
          'requested': restoreRequested,
          'attempted': false,
        },
        'finalDestination': null,
      },
      exitCode: patchbayExitCodeFor(rejection),
      summary: 'walkthrough refused: $code',
    );
  }
}
