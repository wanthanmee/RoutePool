/// Hardcoded ride data. Replace with Firestore (rides/{rideId}) when ready.
/// Holds the passenger and fare information shown in the ride UI prototypes.
class RidePassenger {
  const RidePassenger(this.name, this.route, this.amount, this.status);

  /// Passenger name displayed in the ride summary.
  final String name;

  /// Route associated with this passenger's shared ride.
  final String route;

  /// This passenger's current fare share, in currency units.
  final double amount;

  /// Human-readable membership or ride status.
  final String status;
}

/// Mock total fare used by the split-fare and ride summary screens.
const double rideTotalFare = 12.50;

/// Example passengers and fare shares shown in the prototype ride flow.
const ridePassengers = [
  RidePassenger('You', 'Georgetown → Bayan Lepas', 4.80, 'Active'),
  RidePassenger('Sarah M.', 'Komtar → Queensbay', 5.20, 'Joined'),
  RidePassenger('James L.', 'Bayan Baru Hub → Georgetown', 2.50, 'Joined'),
];

/// Mock shareable live-trip URL included in the trip-sharing UI.
const rideShareLink = 'rtpool.com/live/74k2';

/// Preformatted message displayed when a passenger shares a trip.
const rideShareMessage =
    "I'm on my way! Tracking my RoutePool with Sarah M. (Tesla Model 3 - "
    'RP-2024). Follow my live trip here: $rideShareLink';

/// Where the passenger's ride is. Cancelling is only allowed before pickup.
enum PassengerRideStatus { requested, driverArriving, inProgress }

/// Hardcoded status. Replace with the ride's status field from Firestore.
const passengerRideStatus = PassengerRideStatus.driverArriving;
