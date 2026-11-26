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

  /// Brute-force generates all permutations of a list of integers.
  static Iterable<List<int>> permutations(List<int> items) sync* {
    if (items.isEmpty) {
      yield [];
      return;
    }

    // Generate permutations by fixing each item in turn and permuting the rest
    for (var i = 0; i < items.length; i++) {
      final remaining = [...items]..removeAt(i);
      // Recursively generate permutations of the remaining items
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
    List<List<double>> durations, //matrix of driving times in seconds
    List<int> order,
  ) {
    var totalSeconds = 0.0;
    var from = 0; // Starting point index

    // Loop through the order of destinations and sum the driving times
    for (final to in order) {
      totalSeconds += durations[from][to];
      from = to;
    }

    return totalSeconds;
  }

  /// Finds the destination order with the fastest sequence.
  static List<int> findFastestOrder(
    List<List<double>> durations, // matrix of driving times in seconds
  ) {
    // If there are no destinations, return an empty list
    if (durations.isEmpty) {
      return [];
    }

    // The number of destinations is the length of the durations matrix minus one (the starting point)
    final destinationCount = durations.length - 1;

    // If there are no destinations, return an empty list
    if (destinationCount == 0) {
      return [];
    }

    // If there is only one destination, return a list with that single destination
    if (destinationCount == 1) {
      return [1];
    }

    // Initialize variables to track the fastest order and its corresponding time
    List<int>? fastest;
    var fastestSeconds = double.infinity;

    // Generate a list of destination indices (1 to destinationCount)
    final destinations = [for (var i = 1; i <= destinationCount; i++) i];

    // Iterate through all permutations of the destination indices
    for (final order in permutations(destinations)) {
      // Calculate the total driving time for the current order of destinations
      final seconds = calculateDrivingTime(durations, order);

      // If the calculated time is less than the fastest time found so far,
      //update the fastest order and time
      if (seconds < fastestSeconds) {
        fastestSeconds = seconds;
        fastest = order;
      }
    }

    return fastest ?? [];
  }
}
