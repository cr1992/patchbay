import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

void main() {
  group('PatchbayTraceStore', () {
    late Directory sandbox;
    late Directory workspace;
    late PatchbayTraceStore store;

    setUp(() {
      sandbox = Directory.systemTemp.createTempSync('patchbay-trace-test-');
      workspace = Directory('${sandbox.path}/workspace')..createSync();
      store = PatchbayTraceStore('${sandbox.path}/traces', workspace);
    });

    tearDown(() {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });

    test('writes a flushed hash chain and recovers an interrupted command', () {
      final PatchbayTraceManifest trace = store.start(
        name: 'pairing',
        cliVersion: '0.4.0-test',
        activate: true,
      );
      final PatchbayTraceRecorder recorder = store.recorder(trace.traceId);
      recorder.commandStarted('exec', transport: 'vmService');

      final PatchbayTraceReadResult recovered = store.show(trace.traceId);

      expect(recovered.integrity, 'verified');
      expect(recovered.truncatedTail, isFalse);
      expect(
        recovered.events.map((PatchbayTraceEvent event) => event.type),
        containsAllInOrder(<String>[
          'trace.started',
          'command.started',
          'command.finished',
        ]),
      );
      expect(
        recovered.events.last.payload,
        containsPair('outcome', 'interrupted'),
      );
      expect(store.activeTraceId(), trace.traceId);
    });

    test(
      'serializes concurrent recorder instances without sequence loss',
      () async {
        final PatchbayTraceManifest trace = store.start(
          name: 'concurrent',
          cliVersion: 'test',
          activate: false,
        );
        await Future.wait(<Future<void>>[
          for (var index = 0; index < 20; index += 1)
            Future<void>(() {
              store
                  .recorder(trace.traceId)
                  .append(
                    'note.added',
                    observer: 'operatorStated',
                    payload: <String, Object?>{'note': '$index'},
                  );
            }),
        ]);

        final PatchbayTraceReadResult result = store.read(trace.traceId);

        expect(result.integrity, 'verified');
        expect(result.events, hasLength(21));
        expect(
          result.events.map((PatchbayTraceEvent event) => event.sequence),
          orderedEquals(List<int>.generate(21, (int index) => index + 1)),
        );
        expect(
          Directory('${store.root.path}/${trace.traceId}').listSync().where(
            (FileSystemEntity entity) => entity.path.contains('.tmp-'),
          ),
          isEmpty,
        );
      },
    );

    test('ignores and reports a tail half-line without accepting it', () {
      final PatchbayTraceManifest trace = store.start(
        name: 'tail',
        cliVersion: 'test',
        activate: false,
      );
      final File events = File(
        '${store.root.path}/${trace.traceId}/events.ndjson',
      );
      events.writeAsStringSync('{"schemaVersion":1', mode: FileMode.append);

      final PatchbayTraceReadResult result = store.read(trace.traceId);

      expect(result.truncatedTail, isTrue);
      expect(result.integrity, 'verified');
      expect(result.events, hasLength(1));
      expect(
        () => store
            .recorder(trace.traceId)
            .append(
              'note.added',
              observer: 'operatorStated',
              payload: const <String, Object?>{'note': 'after crash'},
            ),
        throwsA(
          isA<PatchbayTraceException>().having(
            (PatchbayTraceException error) => error.code,
            'code',
            'traceTruncatedTail',
          ),
        ),
      );
    });

    test('show and stop recover an open command after a torn tail', () {
      for (final String operation in <String>['show', 'stop']) {
        final PatchbayTraceManifest trace = store.start(
          name: 'torn-$operation',
          cliVersion: 'test',
          activate: false,
        );
        store
            .recorder(trace.traceId)
            .commandStarted('exec', transport: 'vmService');
        File(
          '${store.root.path}/${trace.traceId}/events.ndjson',
        ).writeAsStringSync('{"schemaVersion":1', mode: FileMode.append);

        if (operation == 'show') {
          final PatchbayTraceReadResult result = store.show(trace.traceId);
          expect(result.truncatedTail, isFalse);
        } else {
          expect(store.stop(trace.traceId).ended, isTrue);
        }

        final PatchbayTraceReadResult recovered = store.read(trace.traceId);
        expect(recovered.integrity, 'verified');
        expect(recovered.truncatedTail, isFalse);
        expect(
          recovered.events.map((PatchbayTraceEvent event) => event.type),
          containsAllInOrder(<String>[
            'command.started',
            'trace.truncated',
            'command.finished',
          ]),
        );
        expect(
          recovered.events
              .firstWhere(
                (PatchbayTraceEvent event) => event.type == 'command.finished',
              )
              .payload['outcome'],
          'interrupted',
        );
      }
    });

    test(
      'redacts sensitive values and absolute-coordinate field names recursively',
      () {
        final PatchbayTraceManifest trace = store.start(
          name: 'redaction',
          cliVersion: 'test',
          activate: false,
        );
        store
            .recorder(trace.traceId)
            .admission(
              command: 'ui.gesture.drag',
              requestId: 'request-1',
              arguments: <String, Object?>{
                'password': 'secret-value',
                'inputWasStdin': true,
                'generation': 7,
                'globalX': 812.5,
                'globalY': 400.0,
                'localX': 0.5,
                'localY': 0.25,
              },
              sensitiveParameters: const <String>{'password'},
              descriptorDigest: 'digest',
              response: <String, Object?>{
                'requestId': 'request-1',
                'admission': 'accepted',
                'payload': const <String, Object?>{},
                'schemaMode': 'validated',
              },
              includeLegacyPayload: false,
            );

        final String encoded = File(
          '${store.root.path}/${trace.traceId}/events.ndjson',
        ).readAsStringSync();
        expect(encoded, isNot(contains('secret-value')));
        expect(encoded, isNot(contains('812.5')));
        expect(encoded, isNot(contains('400.0')));
        expect(encoded, contains('"source":"stdin"'));
        expect(encoded, contains('"localX":0.5'));
      },
    );

    test('reader preserves an unknown future event type', () {
      final PatchbayTraceManifest trace = store.start(
        name: 'future',
        cliVersion: 'test',
        activate: false,
      );
      final PatchbayTraceReadResult current = store.read(trace.traceId);
      final PatchbayTraceEvent previous = current.events.last;
      final PatchbayTraceEvent future = PatchbayTraceEvent(
        traceId: trace.traceId,
        sequence: 2,
        eventId: 'ev_future',
        recordedAt: trace.createdAt.add(const Duration(milliseconds: 1)),
        elapsedMs: 1,
        type: 'permission.futureEvent',
        observer: 'driverReported',
        payload: const <String, Object?>{'future': true},
        previousEventHash: previous.hash,
      );
      File(
        '${store.root.path}/${trace.traceId}/events.ndjson',
      ).writeAsStringSync(
        '${jsonEncode(future.toJson())}\n',
        mode: FileMode.append,
      );
      final PatchbayTraceManifest updated = trace.copyWith(
        eventCount: 2,
        integrityHash: future.hash,
      );
      File(
        '${store.root.path}/${trace.traceId}/manifest.json',
      ).writeAsStringSync(jsonEncode(updated.toJson()));

      final PatchbayTraceReadResult read = store.read(trace.traceId);

      expect(read.integrity, 'verified');
      expect(read.events.last.type, 'permission.futureEvent');
      expect(read.events.last.payload, <String, Object?>{'future': true});
    });

    test('portable export re-redacts credentials and absolute paths', () {
      final PatchbayTraceManifest trace = store.start(
        name: 'portable',
        cliVersion: 'test',
        activate: false,
      );
      store
          .recorder(trace.traceId)
          .append(
            'note.added',
            observer: 'operatorStated',
            payload: <String, Object?>{
              'token': 'top-secret',
              'wsUri': 'ws://secret.example/token',
              'workspacePath': '/Users/alice/private/app',
            },
          );
      final String output = '${sandbox.path}/portable.patchbay-trace';

      store.exportDirectory(trace.traceId, output, includeArtifacts: false);

      final String bundle = File('$output/events.ndjson').readAsStringSync();
      expect(bundle, isNot(contains('top-secret')));
      expect(bundle, isNot(contains('secret.example')));
      expect(bundle, isNot(contains('/Users/alice')));
      expect(bundle, contains('<redacted:absolute-path>'));
    });

    test('content-addresses artifacts and reports a missing blob', () {
      final PatchbayTraceManifest trace = store.start(
        name: 'artifact',
        cliVersion: 'test',
        activate: false,
      );
      final List<int> bytes = utf8.encode('artifact-body');
      final String digest = sha256.convert(bytes).toString();
      final File source = File('${sandbox.path}/capture.png')
        ..writeAsBytesSync(bytes);
      store
          .recorder(trace.traceId)
          .attachArtifact(
            localPath: source.path,
            sha256Value: digest,
            length: bytes.length,
            contentType: 'image/png',
          );
      final File stored = File(
        '${store.root.path}/${trace.traceId}/artifacts/$digest',
      );
      expect(stored.readAsBytesSync(), bytes);
      stored.deleteSync();

      expect(store.read(trace.traceId).missingArtifacts, <String>[digest]);
      expect(
        () => store.exportDirectory(trace.traceId, '${sandbox.path}/bad'),
        throwsA(
          isA<PatchbayTraceException>().having(
            (PatchbayTraceException error) => error.code,
            'code',
            'traceArtifactMissing',
          ),
        ),
      );
    });

    test('golden covers start, session, command, job, artifact and stop', () {
      final PatchbayTraceManifest trace = store.start(
        name: 'golden-flow',
        cliVersion: 'test',
        activate: false,
        now: DateTime.utc(2026, 8, 18),
      );
      final PatchbayTraceRecorder recorder = store.recorder(trace.traceId);
      recorder.sessionObserved(const <String, Object?>{
        'mode': 'launcher',
        'sessionId': 'session-1',
      });
      final String runId = recorder.commandStarted(
        'exec',
        transport: 'vmService',
      );
      recorder.admission(
        command: 'pairing.start',
        requestId: 'request-1',
        arguments: const <String, Object?>{'deviceId': 'robot-1'},
        sensitiveParameters: const <String>{},
        descriptorDigest: 'descriptor-1',
        response: <String, Object?>{
          'admission': 'accepted',
          'jobId': 'job-1',
          'schemaMode': 'validated',
          'payload': <String, Object?>{
            'events': <Object?>[
              <String, Object?>{
                'sequence': 1,
                'phase': 'completed',
                'source': 'deviceReported',
                'payload': const <String, Object?>{
                  'execution': <String, Object?>{
                    'classification': 'deviceConfirmed',
                  },
                },
              },
            ],
            'execution': const <String, Object?>{
              'classification': 'deviceConfirmed',
              'factSource': 'deviceReported',
            },
          },
        },
        includeLegacyPayload: false,
      );
      final List<int> artifactBytes = utf8.encode('golden-artifact');
      final String digest = sha256.convert(artifactBytes).toString();
      final File artifact = File('${sandbox.path}/golden.png')
        ..writeAsBytesSync(artifactBytes);
      recorder.attachArtifact(
        localPath: artifact.path,
        sha256Value: digest,
        length: artifactBytes.length,
        contentType: 'image/png',
        blobId: 'blob-1',
      );
      recorder.commandFinished(runId, PatchbayExitCode.accepted);
      store.stop(trace.traceId);
      final List<Map<String, Object?>> normalized = <Map<String, Object?>>[
        for (final PatchbayTraceEvent event in store.read(trace.traceId).events)
          <String, Object?>{
            'type': event.type,
            'observer': event.observer,
            if (event.factSource != null) 'factSource': event.factSource,
            if (event.requestId != null) 'requestId': event.requestId,
            if (event.sessionRef != null) 'sessionRef': event.sessionRef,
            if (event.jobId != null) 'jobId': event.jobId,
            'payload': <String, Object?>{
              for (final MapEntry<String, Object?> entry
                  in event.payload.entries)
                if (entry.key != 'commandRunId') entry.key: entry.value,
            },
          },
      ];
      final Object? expected = jsonDecode(
        File('test/golden/trace_flow.json').readAsStringSync(),
      );

      expect(normalized, expected);
    });

    test(
      'diff pairs repeated command names by occurrence deterministically',
      () {
        String build(String name, List<String> outcomes) {
          final PatchbayTraceManifest trace = store.start(
            name: name,
            cliVersion: 'test',
            activate: false,
          );
          for (var index = 0; index < outcomes.length; index += 1) {
            store
                .recorder(trace.traceId)
                .admission(
                  command: 'pairing.start',
                  requestId: '$name-$index',
                  arguments: const <String, Object?>{},
                  sensitiveParameters: const <String>{},
                  descriptorDigest: 'same-descriptor',
                  response: <String, Object?>{
                    'admission': outcomes[index],
                    if (outcomes[index] == 'rejected')
                      'rejection': const <String, Object?>{'code': 'busy'},
                    'payload': const <String, Object?>{},
                    'schemaMode': 'validated',
                  },
                  includeLegacyPayload: false,
                );
          }
          return trace.traceId;
        }

        final String before = build('before', <String>['accepted', 'accepted']);
        final String after = build('after', <String>['accepted', 'rejected']);
        final String first = jsonEncode(store.diff(before, after));
        final String second = jsonEncode(store.diff(before, after));

        expect(first, second);
        final Map<String, Object?> decoded = Map<String, Object?>.from(
          jsonDecode(first) as Map<String, dynamic>,
        );
        expect(decoded['changed'], hasLength(1));
        expect(decoded['added'], isEmpty);
        expect(decoded['removed'], isEmpty);
      },
    );

    test('prune dry-run never removes active, recent or pinned traces', () {
      final DateTime old = DateTime.utc(2026, 1, 1);
      final PatchbayTraceManifest removable = store.start(
        name: 'old-ended',
        cliVersion: 'test',
        activate: false,
        now: old,
      );
      store.stop(removable.traceId);
      final PatchbayTracePruneResult dry = store.prune(
        dryRun: true,
        now: old.add(const Duration(days: 31)),
      );
      expect(dry.candidates, <String>[removable.traceId]);
      expect(
        Directory('${store.root.path}/${removable.traceId}').existsSync(),
        isTrue,
      );
      store.prune(dryRun: false, now: old.add(const Duration(days: 31)));
      expect(
        Directory('${store.root.path}/${removable.traceId}').existsSync(),
        isFalse,
      );
    });

    test('refuses an encoded event above the fixed event budget', () {
      final PatchbayTraceManifest trace = store.start(
        name: 'budget',
        cliVersion: 'test',
        activate: false,
      );
      expect(
        () => store
            .recorder(trace.traceId)
            .append(
              'note.added',
              observer: 'operatorStated',
              payload: <String, Object?>{
                'note': 'x' * patchbayTraceMaxEventBytes,
              },
            ),
        throwsA(
          isA<PatchbayTraceException>().having(
            (PatchbayTraceException error) => error.code,
            'code',
            'traceEventTooLarge',
          ),
        ),
      );
    });
  });

  test(
    'host audit and trace use the same execution classification projector',
    () {
      final Map<String, Object?> response = <String, Object?>{
        'payload': <String, Object?>{
          'execution': const <String, Object?>{
            'classification': 'sentUnconfirmed',
            'factSource': 'transportAck',
          },
        },
      };
      final PatchbayAuditEvent audit = patchbayProjectAuditEvent(
        command: 'pairing.start',
        requestId: 'request',
        arguments: const <String, Object?>{'value': 1},
        gateResult: 'allowed',
        response: response,
      );
      expect(audit.executionClassification, 'sentUnconfirmed');
      expect(
        audit.parameterShape,
        patchbayParameterShape(const <String, Object?>{'value': 1}),
      );
    },
  );

  group('trace CLI', () {
    late Directory sandbox;

    setUp(() {
      sandbox = Directory.systemTemp.createTempSync('patchbay-trace-cli-');
    });

    tearDown(() {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });

    test('start activate, record a command, mark, show and stop', () async {
      final String traceRoot = '${sandbox.path}/traces';
      final StringBuffer startOut = StringBuffer();
      expect(
        await runPatchbayCli(
          <String>[
            '--trace-dir',
            traceRoot,
            '--json',
            '--name',
            'cli-flow',
            '--activate',
            'trace',
            'start',
          ],
          output: startOut,
          errorOutput: StringBuffer(),
        ),
        PatchbayExitCode.accepted,
      );
      final Map<String, dynamic> started =
          jsonDecode(startOut.toString()) as Map<String, dynamic>;
      final String traceId =
          (started['trace']! as Map<String, dynamic>)['traceId']! as String;
      final FakePatchbayClient client = FakePatchbayClient(
        commands: const <Map<String, Object?>>[],
        handle: (_, _) async => fakeCommandNotRegistered(),
      );
      expect(
        await runPatchbayCli(
          <String>['--trace-dir', traceRoot, '--json', 'identity'],
          connect: (_) async => client,
          output: StringBuffer(),
          errorOutput: StringBuffer(),
        ),
        PatchbayExitCode.accepted,
      );
      await runPatchbayCli(
        <String>['--trace-dir', traceRoot, 'trace', 'mark', 'UI', 'changed'],
        output: StringBuffer(),
        errorOutput: StringBuffer(),
      );
      final StringBuffer showOut = StringBuffer();
      await runPatchbayCli(
        <String>['--trace-dir', traceRoot, '--json', 'trace', 'show', traceId],
        output: showOut,
        errorOutput: StringBuffer(),
      );
      expect(showOut.toString(), contains('command.started'));
      expect(showOut.toString(), contains('command.finished'));
      expect(showOut.toString(), contains('note.added'));
      expect(
        await runPatchbayCli(
          <String>['--trace-dir', traceRoot, 'trace', 'stop'],
          output: StringBuffer(),
          errorOutput: StringBuffer(),
        ),
        PatchbayExitCode.accepted,
      );
    });

    test(
      'records the final execution verdict instead of the raw response',
      () async {
        final PatchbayTraceStore store = PatchbayTraceStore(
          '${sandbox.path}/traces',
        );
        final PatchbayTraceManifest trace = store.start(
          name: 'validated-response',
          cliVersion: 'test',
          activate: true,
        );
        final FakePatchbayClient client = FakePatchbayClient(
          commands: const <Map<String, Object?>>[
            <String, Object?>{
              'name': 'fixture.command',
              'factSources': <String>['deviceReported'],
              'confirmationBudgetMs': 3000,
              'weakConfirmationCompletes': false,
            },
          ],
          handle: (_, _) async => fakeAccepted(const <String, Object?>{
            'execution': <String, Object?>{
              'classification': 'deviceConfirmed',
              'factSource': 'uiObserved',
              'observedAtMs': null,
              'reasonCode': null,
            },
            'password': 'must-not-reach-the-trace',
          }),
        );

        final int exitCode = await runPatchbayCli(
          <String>[
            '--trace-dir',
            store.root.path,
            '--json',
            'exec',
            'fixture.command',
          ],
          connect: (_) async => client,
          output: StringBuffer(),
          errorOutput: StringBuffer(),
        );

        expect(exitCode, PatchbayExitCode.rejected);
        final PatchbayTraceEvent admission = store
            .read(trace.traceId)
            .events
            .singleWhere(
              (PatchbayTraceEvent event) => event.type == 'command.admission',
            );
        final Map<Object?, Object?> response =
            admission.payload['response']! as Map<Object?, Object?>;
        expect(response['stableCode'], 'providerProtocolViolation');
        expect(
          File(
            '${store.root.path}/${trace.traceId}/events.ndjson',
          ).readAsStringSync(),
          isNot(contains('must-not-reach-the-trace')),
        );
      },
    );

    // Named for what it actually exercises: this process has stdin, so the CLI
    // prompts and immediately reads end of input. It used to assert the
    // non-TTY message, which passed only because both refusals shared one
    // string — the non-TTY branch was never reached here. The pure-function
    // matrix in legacy_payload_confirmation_test.dart covers the pipe case.
    test('an unanswerable prompt fails closed and says so', () async {
      final PatchbayTraceStore store = PatchbayTraceStore(
        '${sandbox.path}/traces',
      );
      final PatchbayTraceManifest trace = store.start(
        name: 'legacy',
        cliVersion: 'test',
        activate: false,
      );
      final StringBuffer error = StringBuffer();

      final int result = await runPatchbayCli(
        <String>[
          '--trace-dir',
          store.root.path,
          '--trace',
          trace.traceId,
          '--include-legacy-payload',
          'identity',
        ],
        connect: (_) async => throw StateError('must not dial'),
        output: StringBuffer(),
        errorOutput: error,
      );

      expect(result, PatchbayExitCode.usage);
      expect(
        error.toString(),
        anyOf(
          contains('reached end of input'),
          contains('must also pass --allow-non-tty-legacy-payload'),
        ),
        reason: '两条路径都必须 fail closed，且各自说清原因',
      );
    });

    // `trace start --include-legacy-payload` used to exit 0 with no notice:
    // the local trace-store branch skipped the confirmation gate entirely, so
    // the switch was accepted, never confirmed and never applied. An operator
    // reading that exit code believes later commands will store legacy values.
    test('the switch is refused where it cannot take effect', () async {
      final PatchbayTraceStore store = PatchbayTraceStore(
        '${sandbox.path}/traces',
      );
      final StringBuffer error = StringBuffer();

      final int result = await runPatchbayCli(
        <String>[
          '--trace-dir',
          store.root.path,
          '--include-legacy-payload',
          'trace',
          'start',
          '--name',
          'gate',
        ],
        connect: (_) async => throw StateError('must not dial'),
        output: StringBuffer(),
        errorOutput: error,
      );

      expect(result, PatchbayExitCode.usage);
      expect(
        error.toString(),
        contains('applies to a traced command'),
        reason: '必须说清它是按命令给的，不是在 trace start 上一次武装',
      );
    });
  });
}
