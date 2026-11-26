import 'package:test/test.dart';
import 'package:route_optimizer_tests/route_optimizer.dart';

void main() {
  group('Route Optimization Algorithm Testing', () {
    // TEST 1: Single Destination
    test('Test 1: Single Destination', () {
      final durations = [
        [0.0, 300.0],
        [300.0, 0.0],
      ];

      final result = RouteOptimizer.findFastestOrder(durations);

      expect(result, [1]);
    });

    // TEST 2: Multiple Destinations
    test('Test 2: Multiple Destinations', () {
      final durations = [
        [0.0, 300.0, 600.0, 900.0],
        [300.0, 0.0, 200.0, 500.0],
        [600.0, 200.0, 0.0, 100.0],
        [900.0, 500.0, 100.0, 0.0],
      ];

      final result = RouteOptimizer.findFastestOrder(durations);

      expect(result, [1, 2, 3]);
    });

    // TEST 3: Duplicate Destinations
    test('Test 3: Duplicate Destinations', () {
      final durations = [
        [0.0, 300.0, 300.0],
        [300.0, 0.0, 0.0],
        [300.0, 0.0, 0.0],
      ];

      final result = RouteOptimizer.findFastestOrder(durations);

      expect(result.length, 2);
      expect(result.toSet(), {1, 2});
    });

    // TEST 4: Invalid Coordinates
    test('Test 4: Invalid Coordinates', () {
      expect(RouteOptimizer.isValidCoordinate(100.0, 200.0), false);

      expect(RouteOptimizer.isValidCoordinate(5.4141, 100.3288), true);
    });

    // TEST 5: Driving Time Comparison
    test('Test 5: Driving Time Comparison', () {
      final durations = [
        [0.0, 300.0, 600.0],
        [300.0, 0.0, 200.0],
        [600.0, 200.0, 0.0],
      ];

      final time1 = RouteOptimizer.calculateDrivingTime(durations, [1, 2]);

      final time2 = RouteOptimizer.calculateDrivingTime(durations, [2, 1]);

      expect(time1, 500.0);
      expect(time2, 800.0);

      expect(time1 < time2, true);
    });
  });
}
