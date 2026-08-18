import 'dart:async';

import 'package:flutter/scheduler.dart';

/// Counts only frames explicitly observed by Patchbay operations.
final class PatchbayFrameObserver {
  int _revision = 0;

  int get revision => _revision;

  /// Requests and observes up to [count] frames before one shared deadline.
  ///
  /// The returned number is deliberately explicit: callers can report a
  /// partial observation when the deadline expires instead of collapsing
  /// "saw 0" and "saw N - 1" into the same timeout.
  Future<int> framesBefore(DateTime deadline, int count) async {
    var observed = 0;
    while (observed < count && await nextFrameBefore(deadline)) {
      observed += 1;
    }
    return observed;
  }

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
