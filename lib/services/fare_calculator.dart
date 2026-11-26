import 'dart:math' as math;

/// Fare calculation rules for RoutePool.
///
/// All monetary values are stored in sen.
/// RM1.00 = 100 sen.
///
/// IMPORTANT:
/// Keep these pricing rules consistent with functions/index.js.
///
/// The Flutter application calculates estimated fares.
/// Firebase Cloud Functions calculates the final authoritative fares.
class FareCalculator {
  // ============================================================
  // BASE FARE CONSTANTS
  // ============================================================

  /// Base fare: RM3.00
  static const int baseFareSen = 300;

  /// Distance rate: RM1.20 per kilometre
  static const int perKmSen = 120;

  /// Minimum normal solo fare: RM6.00
  static const int minimumFareSen = 600;

  /// Roads are generally longer than straight-line distances.
  /// This factor provides an approximate driving distance.
  static const double roadFactor = 1.3;

  // ============================================================
  // PASSENGER PRICING CONSTANTS
  // ============================================================

  /// Maximum number of passengers allowed in one booking.
  static const int maxPassengersPerBooking = 12;

  /// Each additional passenger contributes 50% of the solo fare.
  static const double additionalPassengerRate = 0.50;

  /// Separate bookings matched into a shared ride receive
  /// a 20% discount on their booking fares.
  static const double matchedBookingDiscount = 0.20;

  // ============================================================
  // DISTANCE CALCULATION
  // ============================================================

  /// Estimate the road distance between two coordinates.
  ///
  /// Uses the Haversine formula to calculate straight-line
  /// distance, then multiplies it by the road correction factor.
  ///
  /// Returns the estimated distance in kilometres.
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

  // ============================================================
  // NORMAL SOLO FARE
  // ============================================================

  /// Calculate the normal fare for one passenger.
  ///
  /// Formula:
  /// Solo Fare = max(RM6, RM3 + RM1.20 × distance)
  ///
  /// Rounded to the nearest RM0.10.
  ///
  /// This is the base fare used for calculating booking prices.
  static int soloFareSen(double distanceKm) {
    final raw = baseFareSen + perKmSen * distanceKm;

    final rounded = (raw / 10).round() * 10;

    return math.max(minimumFareSen, rounded);
  }

  // ============================================================
  // MULTIPLE PASSENGERS IN ONE BOOKING
  // ============================================================

  /// Calculate the total fare for one booking.
  ///
  /// The first passenger contributes 100% of the solo fare.
  /// Each additional passenger contributes 50%.
  ///
  /// Formula:
  /// Booking Fare = Solo Fare × [1 + 0.5 × (passengerCount - 1)]
  ///
  /// Example:
  /// Solo fare = RM6.00
  ///
  /// 1 passenger = RM6.00
  /// 2 passengers = RM9.00
  /// 3 passengers = RM12.00
  /// 4 passengers = RM15.00
  ///
  /// This is the total booking fare before any matching discount.
  static int bookingFareSen(int soloFare, int passengerCount) {
    if (passengerCount < 1 || passengerCount > maxPassengersPerBooking) {
      throw ArgumentError(
        'Passenger count must be between 1 and '
        '$maxPassengersPerBooking.',
      );
    }

    final multiplier = 1 + (passengerCount - 1) * additionalPassengerRate;

    final rawFare = soloFare * multiplier;

    // Round to the nearest RM0.10.
    return (rawFare / 10).round() * 10;
  }

  // ============================================================
  // MATCHED BOOKING DISCOUNT
  // ============================================================

  /// Apply the 20% shared-ride discount.
  ///
  /// This discount is only applied when at least two
  /// separate bookings are successfully matched.
  ///
  /// Formula:
  /// Matched Fare = Booking Fare × 0.80
  ///
  /// Example:
  /// Booking fare = RM12.00
  /// Discount = 20%
  /// Final matched fare = RM9.60
  ///
  /// Rounded to the nearest RM0.10.
  static int matchedBookingFareSen(int bookingFare) {
    final discountedFare = bookingFare * (1 - matchedBookingDiscount);

    return (discountedFare / 10).round() * 10;
  }

  // ============================================================
  // FINAL BOOKING FARE
  // ============================================================

  /// Calculate the estimated final booking fare.
  ///
  /// [distanceKm] is the estimated road distance.
  /// [passengerCount] is the number of passengers in this booking.
  /// [isMatched] indicates whether the booking has been matched
  /// with at least one other separate booking.
  ///
  /// If matched, apply the 20% discount.
  /// Otherwise, charge the normal booking fare.
  static int calculateFareSen({
    required double distanceKm,
    required int passengerCount,
    bool isMatched = false,
  }) {
    final soloFare = soloFareSen(distanceKm);

    final bookingFare = bookingFareSen(soloFare, passengerCount);

    if (isMatched) {
      return matchedBookingFareSen(bookingFare);
    }

    return bookingFare;
  }

  // ============================================================
  // PER-PASSENGER FARE
  // ============================================================

  /// Calculate the average amount per passenger.
  ///
  /// The booking fare is shared equally among all passengers
  /// within the same booking.
  ///
  /// Returns the average in RM.
  ///
  /// Note:
  /// Some fares may not divide evenly into whole sen.
  /// The booking's total fare remains authoritative.
  static double farePerPassenger(int bookingFare, int passengerCount) {
    if (passengerCount < 1 || passengerCount > maxPassengersPerBooking) {
      throw ArgumentError(
        'Passenger count must be between 1 and '
        '$maxPassengersPerBooking.',
      );
    }

    return bookingFare / passengerCount / 100;
  }

  // ============================================================
  // CURRENCY FORMATTING
  // ============================================================

  /// Format sen into Malaysian Ringgit.
  ///
  /// Example:
  /// 1250 -> RM12.50
  /// 600  -> RM6.00
  /// 480  -> RM4.80
  static String format(int sen) {
    return 'RM${(sen / 100).toStringAsFixed(2)}';
  }

  // ============================================================
  // HELPER METHODS
  // ============================================================

  /// Convert degrees into radians.
  static double _rad(double deg) {
    return deg * math.pi / 180;
  }
}
