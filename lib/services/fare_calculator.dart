import 'dart:math' as math;

/// Fare rules for RoutePool. Money is stored in sen (RM 1.00 = 100 sen).
///
/// IMPORTANT: keep these numbers in sync with the constants at the top of
/// functions/index.js. The Cloud Function recalculates the fare on the server,
/// so the app only uses this class for the estimate shown while booking.
class FareCalculator {
  static const int baseFareSen = 300; // RM 3.00
  static const int perKmSen = 120; // RM 1.20 per km
  static const int minimumFareSen = 600; // RM 6.00

  /// Roads are longer than a straight line; this is a rough correction.
  static const double roadFactor = 1.3;

  /// Estimated road distance between two points.
  static double roadDistanceKm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadiusKm = 6371.0;
    final dLat = _rad(lat2 - lat1);
    final dLon = _rad(lon2 - lon1);
    final a =
        math.pow(math.sin(dLat / 2), 2) +
        math.cos(_rad(lat1)) *
            math.cos(_rad(lat2)) *
            math.pow(math.sin(dLon / 2), 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusKm * c * roadFactor;
  }

  /// Price of the trip if the passenger rides alone (before sharing).
  static int soloFareSen(double distanceKm) {
    final raw = baseFareSen + perKmSen * distanceKm;
    final rounded = (raw / 10).round() * 10; // nearest 10 sen
    return math.max(minimumFareSen, rounded);
  }

  /// 1250 -> "RM12.50"
  static String format(int sen) => 'RM${(sen / 100).toStringAsFixed(2)}';

  static double _rad(double deg) => deg * math.pi / 180;
}