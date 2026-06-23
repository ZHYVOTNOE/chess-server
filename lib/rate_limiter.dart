import 'dart:async';

class RateLimiter {
  final Map<String, List<DateTime>> _requests = {};
  final int maxRequests;
  final Duration window;
  late final Timer _cleanupTimer;

  RateLimiter({
    this.maxRequests = 10,
    this.window = const Duration(seconds: 1),
  }) {
    // ✅ Автоматическая очистка памяти каждые 5 минут
    _cleanupTimer = Timer.periodic(Duration(minutes: 5), (_) => cleanup());
  }

  bool allow(String userId) {
    final now = DateTime.now();
    _requests[userId] ??= [];
    _requests[userId]!.removeWhere((time) => now.difference(time) > window);

    if (_requests[userId]!.length >= maxRequests) {
      return false;
    }

    _requests[userId]!.add(now);
    return true;
  }

  void cleanup() {
    final now = DateTime.now();
    final toRemove = <String>[];

    for (final userId in _requests.keys) {
      _requests[userId]!.removeWhere((time) => now.difference(time) > window);
      if (_requests[userId]!.isEmpty) {
        toRemove.add(userId);
      }
    }

    for (final userId in toRemove) {
      _requests.remove(userId);
    }
  }

  void dispose() {
    _cleanupTimer.cancel();
    _requests.clear();
  }
}