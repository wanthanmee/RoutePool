/// Hardcoded ride data. Replace with Firestore (rides/{rideId}) when ready.
class RidePassenger {
  const RidePassenger(this.name, this.route, this.amount, this.status);

  final String name;
  final String route;
  final double amount;
  final String status;
}

const double rideTotalFare = 12.50;

const ridePassengers = [
  RidePassenger('You', 'Georgetown → Bayan Lepas', 4.80, 'Active'),
  RidePassenger('Sarah M.', 'Komtar → Queensbay', 5.20, 'Joined'),
  RidePassenger('James L.', 'Bayan Baru Hub → Georgetown', 2.50, 'Joined'),
];

const rideShareLink = 'rtpool.com/live/74k2';

const rideShareMessage =
    "I'm on my way! Tracking my RoutePool with Sarah M. (Tesla Model 3 - "
    'RP-2024). Follow my live trip here: $rideShareLink';

/// Where the passenger's ride is. Cancelling is only allowed before pickup.
enum PassengerRideStatus { requested, driverArriving, inProgress }

/// Hardcoded status. Replace with the ride's status field from Firestore.
const passengerRideStatus = PassengerRideStatus.driverArriving;