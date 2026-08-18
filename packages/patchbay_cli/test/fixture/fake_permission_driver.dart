import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final String? line = await stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .firstOrNull;
  if (line == null) exit(2);
  final Map<String, Object?> request = Map<String, Object?>.from(
    jsonDecode(line) as Map,
  );
  final String mode = Platform.environment['FAKE_PERMISSION_MODE'] ?? 'normal';
  if (mode == 'timeout') {
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  stderr.writeln('fake driver diagnostic: $mode');
  final String protocolVersion = mode == 'major-mismatch' ? '2.0' : '1.0';
  final String requestId = request['requestId']! as String;
  final String operation = request['operation']! as String;
  if (operation == 'capabilities') {
    stdout.writeln(
      jsonEncode(<String, Object?>{
        'protocolVersion': protocolVersion,
        'requestId': requestId,
        'admission': 'accepted',
        if (mode != 'missing-capabilities')
          'capabilities': <String, Object?>{
            'platform': 'fixture',
            'driver': 'fixture.permission',
            'driverVersion': '9',
            'permissions': <String, Object?>{
              'camera': <String, Object?>{
                'actions': <String>[
                  'status',
                  'grant',
                  'revoke',
                  'reset',
                  'exercise',
                ],
                'decisions': <String>['allow', 'deny', 'allowOnce'],
              },
            },
          },
        'evidence': const <Object?>[],
      }),
    );
    return;
  }
  // `fail` is a CLI policy. A runner that sends it to the companion has
  // violated the contract; make that regression unmistakable.
  if (operation == 'fail') exit(23);
  final String permission = request['permission']! as String;
  final String? statePath = Platform.environment['FAKE_PERMISSION_STATE_FILE'];
  final File? stateFile = statePath == null ? null : File(statePath);
  final String state = switch (operation) {
    'normalize' => request['state']! as String,
    'exercise' => switch (request['decision']) {
      'allow' => 'granted',
      'allowOnce' => 'allowOnce',
      _ => 'denied',
    },
    _ =>
      mode == 'unknown-state'
          ? 'vendorFutureState'
          : stateFile?.existsSync() == true
          ? stateFile!.readAsStringSync().trim()
          : 'granted',
  };
  if (operation == 'normalize' || operation == 'exercise') {
    stateFile?.writeAsStringSync(state);
  }
  stdout.writeln(
    jsonEncode(<String, Object?>{
      'protocolVersion': protocolVersion,
      'requestId': requestId,
      'admission': 'accepted',
      if (mode != 'missing-status')
        'after': <String, Object?>{
          'permission': permission,
          'platformPermission': 'fixture.$permission',
          'state': state,
          'platformState': state,
          'factSource': 'deviceReported',
          'driver': 'fixture.permission',
          'driverVersion': '9',
          'supportedActions': <String>['status'],
          'requiresRestart': false,
          'requiresSettings': false,
          'systemUiExpected': operation == 'exercise',
        },
      'evidence': <Object?>[
        <String, Object?>{
          'factSource': 'deviceReported',
          'kind': 'fixtureState',
          'details': <String, Object?>{'operation': operation},
        },
      ],
    }),
  );
}

extension<T> on Stream<T> {
  Future<T?> get firstOrNull async {
    await for (final T value in this) {
      return value;
    }
    return null;
  }
}
