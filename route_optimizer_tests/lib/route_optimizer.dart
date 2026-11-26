class RouteOptimizer {
  /// Checks whether coordinates are valid.
  static bool isValidCoordinate(double lat, double lon) {
    return lat.isFinite &&
        lon.isFinite &&
        lat >= -90 &&
        lat <= 90 &&
        lon >= -180 &&
        lon <= 180;
  }

  /// Generates all possible destination sequences.
  static Iterable<List<int>> permutations(List<int> items) sync* {
    if (items.isEmpty) {
      yield [];
      return;
    }

    for (var i = 0; i < items.length; i++) {
      final remaining = [...items]..removeAt(i);

      for (final rest in permutations(remaining)) {
        yield [items[i], ...rest];
      }
    }
  }

  /// Calculates total driving time for a sequence.
  ///
  /// Matrix index 0 represents the starting point.
  /// Matrix indices 1..N represent destinations.
  static double calculateDrivingTime(
    List<List<double>> durations,
    List<int> order,
  ) {
    var totalSeconds = 0.0;
    var from = 0;

    for (final to in order) {
      totalSeconds += durations[from][to];
      from = to;
    }

    return totalSeconds;
  }

  /// Finds the destination order with the lowest driving time.
  static List<int> findFastestOrder(
    List<List<double>> durations,
  ) {
    if (durations.isEmpty) {
      return [];
    }

    final destinationCount = durations.length - 1;

    if (destinationCount == 0) {
      return [];
    }

    if (destinationCount == 1) {
      return [1];
    }

    List<int>? fastest;
    var fastestSeconds = double.infinity;

    final destinations = [
      for (var i = 1; i <= destinationCount; i++) i,
    ];

    for (final order in permutations(destinations)) {
      final seconds = calculateDrivingTime(
        durations,
        order,
      );

      if (seconds < fastestSeconds) {
        fastestSeconds = seconds;
        fastest = order;
      }
    }

    return fastest ?? [];
  }
}