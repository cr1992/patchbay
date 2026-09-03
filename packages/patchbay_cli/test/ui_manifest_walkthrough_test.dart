import 'dart:convert';
import 'dart:io';

import 'package:patchbay/patchbay_protocol.dart';
import 'package:patchbay_cli/src/cli.dart';
import 'package:patchbay_cli/src/manifest/manifest_models.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

typedef _Run = ({int exitCode, Map<String, Object?> response});

const String _manifest = '''
{
  "version": 2,
  "coverage": "mountedOnly",
  "destinations": [
    {"id": "screen.first", "targets": []},
    {"id": "screen.second", "targets": []},
    {"id": "screen.third", "targets": []}
  ]
}
''';

void main() {
  test('default verification stays on the current screen', () async {
    final _WalkthroughHost host = _WalkthroughHost();
    final _Run run = await _run(host.client, const <String>[]);

    expect(run.exitCode, PatchbayExitCode.accepted);
    expect(run.response['schema'], patchbayUiManifestReportSchema);
    expect(host.client.calls, isEmpty);
  });

  test('walks destinations in manifest order with closed waits', () async {
    for (final String transport in <String>['vm', 'direct']) {
      final _WalkthroughHost host = _WalkthroughHost();
      final _Run run = await _run(host.client, const <String>['--navigate']);

      expect(run.exitCode, PatchbayExitCode.accepted, reason: transport);
      expect(run.response['visited'], <String>[
        'screen.first',
        'screen.second',
        'screen.third',
      ]);
      expect(run.response['passed'], <String>[
        'screen.first',
        'screen.second',
        'screen.third',
      ]);
      final List<FakeInvocation> sideEffects = host.client.calls
          .where(
            (FakeInvocation call) =>
                call.command == 'navigation.go' || call.command == 'ui.wait',
          )
          .toList();
      expect(sideEffects.map((FakeInvocation call) => call.command), <String>[
        'navigation.go',
        'ui.wait',
        'navigation.go',
        'ui.wait',
        'navigation.go',
        'ui.wait',
      ], reason: transport);
      expect(
        sideEffects
            .where((FakeInvocation call) => call.command == 'ui.wait')
            .map((FakeInvocation call) => call.arguments['condition']),
        everyElement('navigationDestination'),
      );
    }
  });

  test('navigation rejection stops and preserves partial completion', () async {
    final _WalkthroughHost host = _WalkthroughHost(reject: 'screen.second');
    final _Run run = await _run(host.client, const <String>['--navigate']);

    expect(run.exitCode, PatchbayExitCode.rejected);
    expect(run.response['visited'], <String>['screen.first']);
    expect(run.response['passed'], <String>['screen.first']);
    expect(run.response['failed'], <String>['screen.second']);
    expect(run.response['skipped'], <String>['screen.third']);
    expect(_destination(run, 'screen.second')['reasonCode'], 'gateClosed');
    expect(
      _destination(run, 'screen.third')['reasonCode'],
      'stoppedAfterFailure',
    );
  });

  test('continue-on-error visits destinations after a rejection', () async {
    final _WalkthroughHost host = _WalkthroughHost(reject: 'screen.second');
    final _Run run = await _run(host.client, const <String>[
      '--navigate',
      '--continue-on-error',
    ]);

    expect(run.exitCode, PatchbayExitCode.rejected);
    expect(run.response['visited'], <String>['screen.first', 'screen.third']);
    expect(run.response['passed'], <String>['screen.first', 'screen.third']);
    expect(run.response['failed'], <String>['screen.second']);
    expect(run.response['skipped'], isEmpty);
  });

  test(
    'total budget keeps completed evidence and skips the remainder',
    () async {
      final _WalkthroughHost host = _WalkthroughHost(
        catalogDelay: const Duration(milliseconds: 10),
      );
      final _Run run = await _run(host.client, const <String>[
        '--navigate',
        '--total-timeout-ms',
        '1',
      ]);

      expect(run.exitCode, PatchbayExitCode.typedFailure);
      expect(run.response['visited'], isEmpty);
      expect(run.response['failed'], isEmpty);
      expect(run.response['skipped'], <String>[
        'screen.first',
        'screen.second',
        'screen.third',
      ]);
      expect(run.response['reasonCode'], 'manifestWalkthroughTotalTimeout');
    },
  );

  test(
    'per-screen budget fails one screen without an unbounded wait',
    () async {
      final _WalkthroughHost host = _WalkthroughHost(
        goDelay: const Duration(milliseconds: 100),
      );
      final _Run run = await _run(host.client, const <String>[
        '--navigate',
        '--screen-timeout-ms',
        '1',
      ]);

      expect(run.exitCode, PatchbayExitCode.typedFailure);
      expect(run.response['failed'], <String>['screen.first']);
      expect(
        _destination(run, 'screen.first')['reasonCode'],
        'manifestWalkthroughScreenTimeout',
      );
    },
  );

  test(
    'restore failure is a notice and cannot replace primary exit code',
    () async {
      final _WalkthroughHost host = _WalkthroughHost(
        initialDestination: 'screen.home',
        restoreReject: true,
        uiTargets: const <Object?>[],
        destinations: const <String>['screen.home', 'screen.first'],
      );
      const String deviating = '''
{
  "version": 2,
  "coverage": "mountedOnly",
  "destinations": [
    {"id": "screen.first", "targets": [
      {"namespace": "catalogTarget", "id": "missing", "kind": "text", "sensitive": false}
    ]}
  ]
}
''';
      final _Run run = await _run(host.client, const <String>[
        '--navigate',
        '--restore',
      ], manifest: deviating);

      expect(run.exitCode, PatchbayExitCode.verificationDeviation);
      expect(run.response['finalDestination'], 'screen.first');
      expect(run.response['restore'], <String, Object?>{
        'requested': true,
        'attempted': true,
        'reasonCode': 'restoreDenied',
      });
      expect(run.response['notices'], <Object?>[
        <String, Object?>{
          'code': 'manifestRestoreFailed',
          'reasonCode': 'restoreDenied',
        },
      ]);
    },
  );

  test(
    'restore failure also leaves a successful walkthrough at zero',
    () async {
      final _WalkthroughHost host = _WalkthroughHost(
        initialDestination: 'screen.home',
        restoreReject: true,
        destinations: const <String>['screen.home', 'screen.first'],
      );
      const String oneScreen = '''
{"version":2,"coverage":"mountedOnly","destinations":[
  {"id":"screen.first","targets":[]}
]}
''';
      final _Run run = await _run(host.client, const <String>[
        '--navigate',
        '--restore',
      ], manifest: oneScreen);

      expect(run.exitCode, PatchbayExitCode.accepted);
      expect(
        (run.response['restore']! as Map<Object?, Object?>)['reasonCode'],
        'restoreDenied',
      );
      expect(run.response['finalDestination'], 'screen.first');
    },
  );

  test(
    'missing destination capability uses current mounted verification',
    () async {
      final _WalkthroughHost host = _WalkthroughHost(includeGo: false);
      final _Run run = await _run(host.client, const <String>['--navigate']);

      expect(run.exitCode, PatchbayExitCode.accepted);
      expect(run.response['schema'], patchbayUiManifestReportSchema);
      expect(run.response['navigationMode'], 'unavailable');
      expect(run.response['missingCommands'], <String>['navigation.go']);
      expect(
        host.client.calls.where((call) => call.command == 'navigation.go'),
        isEmpty,
      );
    },
  );

  test('walkthrough-only options require explicit navigate', () async {
    final _WalkthroughHost host = _WalkthroughHost();
    final _Run run = await _run(host.client, const <String>['--restore']);

    expect(run.exitCode, PatchbayExitCode.usage);
    expect(run.response['error'], isA<Map<Object?, Object?>>());
    expect(host.client.calls, isEmpty);
  });

  test('a declaration the CLI cannot read mid-walk refuses the whole catalog, '
      'it is not interpreted row by row', () async {
    // PB-050-40: the walkthrough re-reads the catalog once per screen. Before
    // this, only the *first* read went through the declaration seam, so a host
    // that started publishing a malformed `outputProjection` after the walk
    // began got read row by row here while every other reader refused it.
    final _WalkthroughHost host = _WalkthroughHost(
      malformedProjectionAfterFirstGo: true,
    );
    final _Run run = await _run(host.client, const <String>['--navigate']);

    expect(run.exitCode, PatchbayExitCode.protocol);
    final Map<String, Object?> envelope = Map<String, Object?>.from(
      run.response['error']! as Map<Object?, Object?>,
    );
    expect(envelope['code'], 'catalogOutputProjectionInvalid');
    expect(
      (envelope['details']! as Map<Object?, Object?>)['reason'],
      contains('device.declaring'),
      reason: 'the refusal names the row that violated, not the screen',
    );
    expect(
      run.response.containsKey('visited'),
      isFalse,
      reason:
          "a provider violation is not one screen's reasonCode; the walk "
          'reports no per-destination verdicts at all',
    );
  });

  test('a clean walk still re-reads the catalog per screen', () async {
    final _WalkthroughHost host = _WalkthroughHost();
    final _Run run = await _run(host.client, const <String>['--navigate']);

    expect(run.exitCode, PatchbayExitCode.accepted);
    expect(
      host.client.catalogReads,
      greaterThan(1),
      reason: 'the per-screen re-read is the path this validation guards',
    );
  });
}

Map<String, Object?> _destination(_Run run, String id) =>
    (run.response['destinations']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .singleWhere((Map<String, Object?> row) => row['destinationId'] == id);

Future<_Run> _run(
  FakePatchbayClient client,
  List<String> options, {
  String manifest = _manifest,
}) async {
  final Directory directory = Directory.systemTemp.createTempSync(
    'patchbay-walkthrough',
  );
  addTearDown(() => directory.deleteSync(recursive: true));
  final File file = File('${directory.path}/manifest.json')
    ..writeAsStringSync(manifest);
  final StringBuffer output = StringBuffer();
  final StringBuffer error = StringBuffer();
  final int exitCode = await runPatchbayCliWithSeams(
    <String>['--json', 'ui', 'verify-manifest', file.path, ...options],
    connect: (_) async => client,
    output: output,
    errorOutput: error,
  );
  return (
    exitCode: exitCode,
    response: Map<String, Object?>.from(
      jsonDecode(output.toString())! as Map<Object?, Object?>,
    ),
  );
}

final class _WalkthroughHost {
  _WalkthroughHost({
    this.reject,
    this.restoreReject = false,
    this.initialDestination = 'screen.first',
    this.catalogDelay = Duration.zero,
    this.malformedProjectionAfterFirstGo = false,
    this.goDelay = Duration.zero,
    this.includeGo = true,
    this.uiTargets = const <Object?>[],
    this.destinations = const <String>[
      'screen.first',
      'screen.second',
      'screen.third',
    ],
  }) : current = initialDestination {
    client = FakePatchbayClient(
      commands: <Map<String, Object?>>[
        const <String, Object?>{'name': 'navigation.catalog'},
        const <String, Object?>{'name': 'navigation.current'},
        if (includeGo) const <String, Object?>{'name': 'navigation.go'},
        const <String, Object?>{'name': 'ui.wait'},
      ],
      uiTargets: uiTargets,
      handle: _handle,
    );
  }

  final String? reject;
  final bool restoreReject;
  final String initialDestination;
  final Duration catalogDelay;

  /// PB-050-40: makes the App start publishing a declaration the CLI cannot
  /// interpret half way through the walk, so the per-screen catalog re-read
  /// meets a document the initial read never contained.
  final bool malformedProjectionAfterFirstGo;
  final Duration goDelay;
  final bool includeGo;
  final List<Object?> uiTargets;
  final List<String> destinations;
  late final FakePatchbayClient client;
  late String current;
  var revision = 1;

  Future<Map<String, Object?>> _handle(
    String command,
    Map<String, Object?> arguments,
  ) async {
    switch (command) {
      case 'navigation.catalog':
        if (catalogDelay > Duration.zero) {
          await Future<void>.delayed(catalogDelay);
        }
        return fakeAccepted(
          PatchbayNavigationCatalogWire(
            outcome: 'cataloged',
            source: PatchbayFactSourceWire.appRecorded,
            navigationRevision: revision,
            destinations: <PatchbayDestinationDescriptorWire>[
              for (final String id in destinations)
                PatchbayDestinationDescriptorWire(
                  id: id,
                  summary: null,
                  operations: const <PatchbayNavigationOperationWire>[
                    PatchbayNavigationOperationWire.go,
                  ],
                  gates: const <String>['signedIn'],
                  ambiguous: false,
                ),
            ],
          ).toJson(),
        );
      case 'navigation.current':
        return fakeAccepted(
          PatchbayNavigationCurrentWire(
            outcome: 'observed',
            source: PatchbayFactSourceWire.appRecorded,
            navigationRevision: revision,
            destinationId: current,
          ).toJson(),
        );
      case 'navigation.go':
        if (goDelay > Duration.zero) await Future<void>.delayed(goDelay);
        final String destination = arguments['destinationId']! as String;
        if (destination == reject) return _rejected('gateClosed');
        if (restoreReject &&
            destination == initialDestination &&
            current != initialDestination) {
          return _rejected('restoreDenied');
        }
        current = destination;
        revision += 1;
        if (malformedProjectionAfterFirstGo) {
          client.commands.add(const <String, Object?>{
            'name': 'device.declaring',
            'outputProjection': <String, Object?>{
              'brief': <String, Object?>{
                'id': 'x',
                'omit': <String>[r'$.a'],
              },
              'formatter': 'shell',
            },
          });
        }
        return fakeAccepted(
          PatchbayNavigationResultWire(
            outcome: 'arrived',
            source: PatchbayFactSourceWire.uiObserved,
            operation: PatchbayNavigationOperationWire.go,
            requestedDestinationId: destination,
            destinationId: destination,
            beforeNavigationRevision: revision - 1,
            afterNavigationRevision: revision,
            frameRevision: revision,
          ).toJson(),
        );
      case 'ui.wait':
        return fakeAccepted(<String, Object?>{
          'outcome': 'satisfied',
          'source': 'uiObserved',
          'condition': 'navigationDestination',
          'elapsedMs': 0,
          'destinationId': current,
          'navigationRevision': revision,
          'frameRevision': revision,
        });
      default:
        return fakeCommandNotRegistered();
    }
  }
}

Map<String, Object?> _rejected(String code) => <String, Object?>{
  'admission': 'rejected',
  'rejection': <String, Object?>{'code': code},
};
