import 'dart:async';

import 'package:flutter/scheduler.dart';

/// Counts only frames explicitly observed by Patchbay operations.
final class PatchbayFrameObserver {
  int _revision = 0;

  int get revision => _revision;

  Future<bool> nextFrameBefore(DateTime deadline) async {
    final Duration remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) return false;
    SchedulerBinding.instance.scheduleFrame();
    try {
      await SchedulerBinding.instance.endOfFrame.timeout(remaining);
      _revision += 1;
      return true;
    } on TimeoutException {
      return false;
    }
  }
}
