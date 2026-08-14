import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

void main() {
  test(
    'connects to a real VM Service extension host',
    () async {
      final Process host =
          await Process.start(Platform.resolvedExecutable, <String>[
            '--enable-vm-service=0',
            '--disable-service-auth-codes',
            'test/fixture/host.dart',
          ], workingDirectory: Directory.current.path);
      addTearDown(() async {
        host.kill();
        await host.exitCode;
      });

      final Completer<Uri> serviceUri = Completer<Uri>();
      void observe(String line) {
        final RegExpMatch? match = RegExp(
          r'(https?://[^\s]+)',
        ).firstMatch(line);
        if (match != null && !serviceUri.isCompleted) {
          serviceUri.complete(Uri.parse(match.group(1)!));
        }
      }

      final StreamSubscription<String> stdout = host.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(observe);
      final StreamSubscription<String> stderr = host.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(observe);
      addTearDown(stdout.cancel);
      addTearDown(stderr.cancel);

      final Uri uri = await serviceUri.future.timeout(
        const Duration(seconds: 15),
      );
      final Directory sessions = Directory.systemTemp.createTempSync(
        'patchbay-cross-process-sessions-',
      );
      addTearDown(() => sessions.deleteSync(recursive: true));
      final PatchbaySessionStore sessionStore = PatchbaySessionStore(
        sessions.path,
      );
      sessionStore.write(
        PatchbaySessionRecord(
          sessionId: 'fixture-current',
          applicationId: 'dev.patchbay.fixture',
          appInstanceId: null,
          isolateId: null,
          processId: host.pid,
          wsUri: uri.toString(),
          buildMode: 'debug',
          createdAt: DateTime.now().toUtc(),
          workspacePath: Directory.current.path,
          deviceId: 'local-vm',
        ),
      );
      final PatchbayConnection connection = await PatchbayConnection.connect(
        uri,
      );
      addTearDown(connection.close);

      final Map<String, Object?> identity = await connection.identity();
      expect(identity['applicationId'], 'dev.patchbay.fixture');
      expect(identity['appInstanceId'], 'fixture-instance');

      final Map<String, Object?> snapshot = await connection.snapshot();
      expect(snapshot['source'], PatchbayFactSource.appRecorded.name);

      final ProcessResult cli = await Process.run(
        Platform.resolvedExecutable,
        <String>[
          'run',
          'bin/patchbay.dart',
          '--ws-uri',
          uri.toString(),
          '--json',
          'snapshot',
        ],
        workingDirectory: Directory.current.path,
      );
      expect(cli.exitCode, 0, reason: cli.stderr.toString());
      expect(
        (jsonDecode(cli.stdout.toString()) as Map<String, Object?>)['source'],
        PatchbayFactSource.appRecorded.name,
      );

      final ProcessResult discoveredCli = await Process.run(
        Platform.resolvedExecutable,
        <String>[
          'run',
          'bin/patchbay.dart',
          '--session-dir',
          sessions.path,
          '--json',
          'snapshot',
        ],
        workingDirectory: Directory.current.path,
      );
      expect(
        discoveredCli.exitCode,
        0,
        reason: discoveredCli.stderr.toString(),
      );
      expect(sessionStore.readAll().single.appInstanceId, 'fixture-instance');

      sessionStore.write(
        PatchbaySessionRecord(
          sessionId: 'fixture-other-worktree',
          applicationId: 'dev.patchbay.fixture',
          appInstanceId: null,
          isolateId: null,
          processId: host.pid,
          wsUri: uri.toString(),
          buildMode: 'debug',
          createdAt: DateTime.now().toUtc(),
          workspacePath: '${Directory.current.path}/other-worktree',
          deviceId: 'local-vm',
        ),
      );
      final ProcessResult ambiguousCli = await Process.run(
        Platform.resolvedExecutable,
        <String>[
          'run',
          'bin/patchbay.dart',
          '--session-dir',
          sessions.path,
          'identity',
        ],
        workingDirectory: Directory.current.path,
      );
      expect(ambiguousCli.exitCode, PatchbayExitCode.transport);
      expect(ambiguousCli.stderr.toString(), contains('sessionAmbiguous'));
      expect(ambiguousCli.stderr.toString(), contains('fixture-current'));
      expect(ambiguousCli.stderr.toString(), isNot(contains(uri.toString())));
      // The refusal names the command that settles it, and that command runs
      // without dialling anything.
      expect(ambiguousCli.stderr.toString(), contains('session use'));

      // Pin one, then run a command with no --session at all: this is the
      // whole point of the feature, and the only place it is exercised against
      // a real VM Service rather than an injected resolver.
      final ProcessResult pinCli =
          await Process.run(Platform.resolvedExecutable, <String>[
            'run',
            'bin/patchbay.dart',
            '--session-dir',
            sessions.path,
            'session',
            'use',
            'fixture-current',
          ], workingDirectory: Directory.current.path);
      expect(pinCli.exitCode, 0, reason: pinCli.stderr.toString());
      expect(pinCli.stdout.toString(), isNot(contains(uri.toString())));
      final ProcessResult stickyCli = await Process.run(
        Platform.resolvedExecutable,
        <String>[
          'run',
          'bin/patchbay.dart',
          '--session-dir',
          sessions.path,
          '--json',
          'identity',
        ],
        workingDirectory: Directory.current.path,
      );
      expect(stickyCli.exitCode, 0, reason: stickyCli.stderr.toString());
      expect(
        (jsonDecode(stickyCli.stdout.toString())
            as Map<String, Object?>)['applicationId'],
        'dev.patchbay.fixture',
      );
      // Unpin so the assertions below still describe an unpinned directory.
      final ProcessResult unpinCli =
          await Process.run(Platform.resolvedExecutable, <String>[
            'run',
            'bin/patchbay.dart',
            '--session-dir',
            sessions.path,
            'session',
            'use',
            '--clear',
          ], workingDirectory: Directory.current.path);
      expect(unpinCli.exitCode, 0, reason: unpinCli.stderr.toString());

      final ProcessResult selectedCli =
          await Process.run(Platform.resolvedExecutable, <String>[
            'run',
            'bin/patchbay.dart',
            '--session-dir',
            sessions.path,
            '--session',
            'fixture-current',
            '--json',
            'identity',
          ], workingDirectory: Directory.current.path);
      expect(selectedCli.exitCode, 0, reason: selectedCli.stderr.toString());

      final Directory emptySessions = Directory.systemTemp.createTempSync(
        'patchbay-cross-process-empty-',
      );
      addTearDown(() => emptySessions.deleteSync(recursive: true));
      final ProcessResult emptyCli = await Process.run(
        Platform.resolvedExecutable,
        <String>[
          'run',
          'bin/patchbay.dart',
          '--session-dir',
          emptySessions.path,
          'identity',
        ],
        workingDirectory: Directory.current.path,
      );
      expect(emptyCli.exitCode, PatchbayExitCode.transport);
      expect(emptyCli.stderr.toString(), contains('sessionDirectoryEmpty'));

      final Directory staleSessions = Directory.systemTemp.createTempSync(
        'patchbay-cross-process-stale-',
      );
      addTearDown(() => staleSessions.deleteSync(recursive: true));
      final staleStore = PatchbaySessionStore(staleSessions.path);
      staleStore.write(
        PatchbaySessionRecord(
          sessionId: 'stale-secret',
          applicationId: 'dev.patchbay.fixture',
          appInstanceId: null,
          isolateId: null,
          processId: 2147483647,
          wsUri: 'ws://127.0.0.1:1/authentication-secret/ws',
          buildMode: 'debug',
          createdAt: DateTime.now().toUtc(),
          workspacePath: Directory.current.path,
          deviceId: 'local-vm',
        ),
      );
      final ProcessResult staleCli = await Process.run(
        Platform.resolvedExecutable,
        <String>[
          'run',
          'bin/patchbay.dart',
          '--session-dir',
          staleSessions.path,
          'identity',
        ],
        workingDirectory: Directory.current.path,
      );
      expect(staleCli.exitCode, PatchbayExitCode.transport);
      expect(staleCli.stderr.toString(), contains('sessionStaleProcess'));
      expect(
        staleCli.stderr.toString(),
        isNot(contains('authentication-secret')),
      );
      expect(staleStore.readAll(), isEmpty);

      final Directory mismatchedSessions = Directory.systemTemp.createTempSync(
        'patchbay-cross-process-mismatch-',
      );
      addTearDown(() => mismatchedSessions.deleteSync(recursive: true));
      final mismatchStore = PatchbaySessionStore(mismatchedSessions.path);
      mismatchStore.write(
        PatchbaySessionRecord(
          sessionId: 'foreign-application',
          applicationId: 'dev.patchbay.other',
          appInstanceId: 'old-instance',
          isolateId: 'isolates/old',
          processId: host.pid,
          wsUri: uri.toString(),
          buildMode: 'debug',
          createdAt: DateTime.now().toUtc(),
          workspacePath: Directory.current.path,
          deviceId: 'local-vm',
        ),
      );
      final ProcessResult mismatchedCli =
          await Process.run(Platform.resolvedExecutable, <String>[
            'run',
            'bin/patchbay.dart',
            '--session-dir',
            mismatchedSessions.path,
            'identity',
          ], workingDirectory: Directory.current.path);
      expect(mismatchedCli.exitCode, PatchbayExitCode.protocol);
      expect(
        mismatchedCli.stderr.toString(),
        contains('sessionIdentityMismatch'),
      );
      expect(mismatchStore.readAll(), isEmpty);

      // Same application, stale instance and isolate: a hot restart must be
      // re-pinned against the live runtime, not discarded.
      final Directory restartedSessions = Directory.systemTemp.createTempSync(
        'patchbay-cross-process-restart-',
      );
      addTearDown(() => restartedSessions.deleteSync(recursive: true));
      final restartStore = PatchbaySessionStore(restartedSessions.path);
      restartStore.write(
        PatchbaySessionRecord(
          sessionId: 'before-hot-restart',
          applicationId: 'dev.patchbay.fixture',
          appInstanceId: 'old-instance',
          isolateId: 'isolates/old',
          processId: host.pid,
          wsUri: uri.toString(),
          buildMode: 'debug',
          createdAt: DateTime.now().toUtc(),
          workspacePath: Directory.current.path,
          deviceId: 'local-vm',
        ),
      );
      final ProcessResult restartedCli = await Process.run(
        Platform.resolvedExecutable,
        <String>[
          'run',
          'bin/patchbay.dart',
          '--session-dir',
          restartedSessions.path,
          'identity',
        ],
        workingDirectory: Directory.current.path,
      );
      expect(restartedCli.exitCode, PatchbayExitCode.accepted);
      expect(
        restartStore.readAll().single.appInstanceId,
        isNot('old-instance'),
      );

      final ProcessResult missingCommand =
          await Process.run(Platform.resolvedExecutable, <String>[
            'run',
            'bin/patchbay.dart',
            '--ws-uri',
            uri.toString(),
            '--json',
            'exec',
            'fixture.missing',
          ], workingDirectory: Directory.current.path);
      expect(missingCommand.exitCode, PatchbayExitCode.protocol);

      final ProcessResult typedFailure =
          await Process.run(Platform.resolvedExecutable, <String>[
            'run',
            'bin/patchbay.dart',
            '--ws-uri',
            uri.toString(),
            '--json',
            'exec',
            'fixture.typedFailure',
          ], workingDirectory: Directory.current.path);
      expect(typedFailure.exitCode, PatchbayExitCode.typedFailure);

      final ProcessResult failedJob =
          await Process.run(Platform.resolvedExecutable, <String>[
            'run',
            'bin/patchbay.dart',
            '--ws-uri',
            uri.toString(),
            '--json',
            '--wait',
            'exec',
            'fixture.failedJob',
          ], workingDirectory: Directory.current.path);
      expect(failedJob.exitCode, PatchbayExitCode.typedFailure);
      final Map<String, Object?> failedJobOutput =
          jsonDecode(failedJob.stdout.toString()) as Map<String, Object?>;
      expect(failedJobOutput['waitMode'], 'serverLongPoll');
      // One place to read the id in both outputs: the admission envelope put
      // `jobId` at the top level, and so does the terminal `--wait` result. The
      // fixture's snapshot deliberately carries a different id, which is what
      // proves the top-level value is the admitted job rather than an echo of
      // whatever the host's snapshot happened to name.
      expect(failedJobOutput['jobId'], 'fixture-job');
      expect(
        (failedJobOutput['payload']! as Map<String, Object?>)['jobId'],
        'job-1',
      );

      final ProcessResult navigationCatalog = await _runCli(uri, <String>[
        'navigation',
        'catalog',
      ]);
      expect(navigationCatalog.exitCode, 0, reason: navigationCatalog.stderr);
      expect(
        ((jsonDecode(navigationCatalog.stdout.toString())
                as Map<String, Object?>)['payload']!
            as Map<String, Object?>)['navigationRevision'],
        7,
      );

      final ProcessResult navigationGo = await _runCli(uri, <String>[
        '--revision',
        '7',
        'navigation',
        'go',
        'settings',
      ]);
      expect(navigationGo.exitCode, 0, reason: navigationGo.stderr);
      expect(
        (((jsonDecode(navigationGo.stdout.toString())
                    as Map<String, Object?>)['payload']!
                as Map<String, Object?>)['arguments']!
            as Map<String, Object?>)['destinationId'],
        'settings',
      );

      final ProcessResult uiWait = await _runCli(uri, <String>[
        '--timeout-ms',
        '250',
        'ui',
        'wait',
        'semantics-mounted',
        'example.settings.screen',
      ]);
      expect(uiWait.exitCode, 0, reason: uiWait.stderr);
      expect(
        ((jsonDecode(uiWait.stdout.toString())
                as Map<String, Object?>)['payload']!
            as Map<String, Object?>)['condition'],
        'semanticsMounted',
      );

      final ProcessResult logsQuery = await _runCli(uri, <String>[
        '--limit',
        '10',
        'logs',
        'query',
      ]);
      expect(logsQuery.exitCode, 0, reason: logsQuery.stderr);
      expect(
        ((jsonDecode(logsQuery.stdout.toString())
                    as Map<String, Object?>)['payload']!
                as Map<String, Object?>)['records']
            as List<Object?>,
        hasLength(1),
      );

      final ProcessResult logsTail = await _runCli(uri, <String>[
        '--timeout-ms',
        '5',
        'logs',
        'tail',
      ]);
      expect(logsTail.exitCode, 0, reason: logsTail.stderr);
      expect(
        ((jsonDecode(logsTail.stdout.toString())
                as Map<String, Object?>)['payload']!
            as Map<String, Object?>)['outcome'],
        'timedOut',
      );

      final Directory artifacts = Directory.systemTemp.createTempSync(
        'patchbay-cli-artifacts-',
      );
      addTearDown(() => artifacts.deleteSync(recursive: true));
      final String logsPath = '${artifacts.path}/logs.ndjson';
      final ProcessResult logsExport = await _runCli(uri, <String>[
        '--output',
        logsPath,
        'logs',
        'export',
      ]);
      expect(logsExport.exitCode, 0, reason: logsExport.stderr);
      expect(File(logsPath).readAsStringSync(), 'fixture artifact\n');
      expect(
        (jsonDecode(logsExport.stdout.toString())
            as Map<String, Object?>)['localArtifact'],
        isA<Map<String, Object?>>(),
      );

      final String capturePath = '${artifacts.path}/capture.png';
      final ProcessResult capture = await _runCli(uri, <String>[
        '--output',
        capturePath,
        'capture',
        'root',
      ]);
      expect(capture.exitCode, 0, reason: capture.stderr);
      expect(File(capturePath).readAsStringSync(), 'fixture artifact\n');

      final String corruptPath = '${artifacts.path}/corrupt.png';
      final ProcessResult corruptCapture = await _runCli(uri, <String>[
        '--pixel-ratio',
        '3',
        '--output',
        corruptPath,
        'capture',
        'root',
      ]);
      expect(corruptCapture.exitCode, PatchbayExitCode.protocol);
      expect(File(corruptPath).existsSync(), isFalse);
      expect(
        artifacts.listSync().where(
          (entry) => entry.path.contains('.patchbay-part-'),
        ),
        isEmpty,
      );

      final String blobPath = '${artifacts.path}/blob.bin';
      final ProcessResult blob = await _runCli(uri, <String>[
        '--output',
        blobPath,
        'blob',
        'get',
        'fixture-blob',
      ]);
      expect(blob.exitCode, 0, reason: blob.stderr);
      expect(File(blobPath).readAsStringSync(), 'fixture artifact\n');

      final ProcessResult refusesOverwrite = await _runCli(uri, <String>[
        '--output',
        blobPath,
        'blob',
        'get',
        'fixture-blob',
      ]);
      expect(refusesOverwrite.exitCode, PatchbayExitCode.usage);
      expect(refusesOverwrite.stderr.toString(), contains('--force'));

      final ProcessResult semanticsTree =
          await Process.run(Platform.resolvedExecutable, <String>[
            'run',
            'bin/patchbay.dart',
            '--ws-uri',
            uri.toString(),
            '--json',
            'ui',
            'semantics',
            'tree',
          ], workingDirectory: Directory.current.path);
      expect(
        semanticsTree.exitCode,
        0,
        reason: semanticsTree.stderr.toString(),
      );
      expect(
        ((jsonDecode(semanticsTree.stdout.toString())
                as Map<String, Object?>)['payload']!
            as Map<String, Object?>)['outcome'],
        'observed',
      );

      final ProcessResult semanticsTap =
          await Process.run(Platform.resolvedExecutable, <String>[
            'run',
            'bin/patchbay.dart',
            '--ws-uri',
            uri.toString(),
            '--json',
            'ui',
            'semantics',
            'action',
            '42',
            '7',
            'tap',
          ], workingDirectory: Directory.current.path);
      expect(semanticsTap.exitCode, 0, reason: semanticsTap.stderr.toString());
      final Map<String, Object?> tapPayload =
          (jsonDecode(semanticsTap.stdout.toString())
                  as Map<String, Object?>)['payload']!
              as Map<String, Object?>;
      expect(tapPayload['outcome'], 'dispatched');
      expect((tapPayload['arguments']! as Map<String, Object?>)['nodeId'], 42);

      final ProcessResult identifierTap = await _runCli(uri, <String>[
        '--generation',
        '7',
        'ui',
        'tap',
        'fixture.tap',
      ]);
      expect(identifierTap.exitCode, 0, reason: identifierTap.stderr);
      final Map<String, Object?> identifierTapArguments =
          ((jsonDecode(identifierTap.stdout.toString())
                      as Map<String, Object?>)['payload']!
                  as Map<String, Object?>)['arguments']!
              as Map<String, Object?>;
      expect(identifierTapArguments['identifier'], 'fixture.tap');
      expect(identifierTapArguments['generation'], 7);
      expect(identifierTapArguments, isNot(contains('nodeId')));

      // A rejection has to reach the operator with its details intact; an
      // empty `rejected` would push them back to the two-hop tree read.
      final ProcessResult missingIdentifier = await _runCli(uri, <String>[
        'ui',
        'tap',
        'fixture.absent',
      ]);
      expect(missingIdentifier.exitCode, PatchbayExitCode.rejected);
      final Map<String, Object?> tapRejection =
          (jsonDecode(missingIdentifier.stdout.toString())
                  as Map<String, Object?>)['rejection']!
              as Map<String, Object?>;
      expect(tapRejection['code'], 'uiSemanticsIdentifierNotFound');
      expect(
        (tapRejection['details']!
            as Map<String, Object?>)['mountedIdentifiers'],
        contains('fixture.tap'),
      );

      final ProcessResult unavailableFlutterTree =
          await Process.run(Platform.resolvedExecutable, <String>[
            'run',
            'bin/patchbay.dart',
            '--ws-uri',
            uri.toString(),
            '--json',
            'ui',
            'widget-tree',
          ], workingDirectory: Directory.current.path);
      expect(
        unavailableFlutterTree.exitCode,
        PatchbayExitCode.protocol,
        reason: unavailableFlutterTree.stderr.toString(),
      );
      expect(
        unavailableFlutterTree.stderr.toString(),
        contains('flutterDiagnosticUnavailable'),
      );

      // One process, one connection, four typed commands. The exact
      // connection count is asserted in repl_test.dart against an injected
      // client; what this proves is that the same loop works over a real VM
      // Service and still exits cleanly when stdin closes.
      final Process replProcess = await Process.start(
        Platform.resolvedExecutable,
        <String>[
          'run',
          'bin/patchbay.dart',
          '--ws-uri',
          uri.toString(),
          '--json',
          'repl',
        ],
        workingDirectory: Directory.current.path,
      );
      final Future<String> replOut = replProcess.stdout
          .transform(utf8.decoder)
          .join();
      replProcess.stdin
        ..writeln('identity')
        ..writeln('snapshot')
        ..writeln('ui semantics tree')
        ..writeln('ui tap fixture.tap')
        ..writeln('ui tap fixture.absent');
      await replProcess.stdin.close();
      final int replExit = await replProcess.exitCode;
      final List<Map<String, Object?>> replLines = const LineSplitter()
          .convert(await replOut)
          .where((String line) => line.isNotEmpty)
          .map((String line) => jsonDecode(line) as Map<String, Object?>)
          .toList(growable: false);

      expect(replExit, PatchbayExitCode.accepted);
      expect(replLines, hasLength(5));
      expect(
        replLines.map((Map<String, Object?> row) => row['exitCode']),
        <int>[0, 0, 0, 0, PatchbayExitCode.rejected],
      );
      expect(replLines[3]['command'], <String>['ui', 'tap', 'fixture.tap']);
      expect(
        (((replLines[3]['response']! as Map<String, Object?>)['payload']!
                as Map<String, Object?>)['arguments']!
            as Map<String, Object?>)['identifier'],
        'fixture.tap',
      );

      final Map<String, Object?> invocation = await connection.invoke(
        command: 'device.list',
        arguments: const <String, Object?>{},
      );
      expect(invocation['requestId'], startsWith('patchbay-cli-vm-'));
      expect(invocation['admission'], 'rejected');
      expect(
        (invocation['rejection']! as Map<String, Object?>)['code'],
        'commandNotRegistered',
      );
      await expectLater(
        connection.invoke(
          command: 'device.list',
          arguments: const <String, Object?>{},
          requestId: '',
        ),
        throwsA(
          isA<PatchbayProtocolException>().having(
            (PatchbayProtocolException error) => error.code,
            'code',
            'requestIdValidationFailed',
          ),
        ),
      );
    },
    // GH 共享 runner 冷启时真实 VM Service 拉起可超 30s（main 首跑实测翻车）。
    // 显式标注会压过 dart test --timeout 的默认值，上限必须写在这里。
    timeout: const Timeout(Duration(seconds: 120)),
  );
}

Future<ProcessResult> _runCli(Uri uri, List<String> arguments) =>
    Process.run(Platform.resolvedExecutable, <String>[
      'run',
      'bin/patchbay.dart',
      '--ws-uri',
      uri.toString(),
      '--json',
      ...arguments,
    ], workingDirectory: Directory.current.path);
