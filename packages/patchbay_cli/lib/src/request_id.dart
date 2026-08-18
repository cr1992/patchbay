import 'dart:math';

final Random _requestRandom = Random.secure();
var _requestSequence = 0;

/// One process-unique request identity suitable for host-side de-duplication.
///
/// The counter preserves ordering inside a process; wall time plus a secure
/// nonce prevents separate short-lived CLI processes from restarting at the
/// same ID and being mistaken for a retry by a long-lived App host.
String patchbayCliRequestId(String channel) {
  final String nonce = _requestRandom.nextInt(0x100000000).toRadixString(16);
  return 'patchbay-cli-$channel-'
      '${DateTime.now().microsecondsSinceEpoch}-$nonce-${++_requestSequence}';
}
