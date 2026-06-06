class RateLimiter {
  final Map<String, List<DateTime>> _requests = {};
  final int maxRequests;
  final Duration window;

  RateLimiter({
    this.maxRequests = 10,
    this.window = const Duration(seconds: 1),
  });

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
    for (final userId in _requests.keys) {
      _requests[userId]!.removeWhere((time) => now.difference(time) > window);
      if (_requests[userId]!.isEmpty) {
        _requests.remove(userId);
      }
    }
  }
}
