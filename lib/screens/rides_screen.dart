import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'ride_matching_screen.dart';
import 'cancel_ride_screen.dart';
import 'driver_ride_screen.dart';
import 'form_widgets.dart' show rpAppBar;
import 'gps_view_screen.dart';
import 'passenger_home.dart' show RPColors;
import 'trip_eta_card.dart';

/// Passenger Rides tab, with a read-only live optimized drop-off route.
class RidesScreen extends StatelessWidget {
  const RidesScreen({
    super.key,
    required this.isDriver,
    this.requestId,
    this.onOpenHubs,
  });

  final bool isDriver;
  final String? requestId;
  final VoidCallback? onOpenHubs;

  Future<void> _openCancel(BuildContext context, String activeRequestId) async {
    if (activeRequestId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No active ride request was found to cancel.'),
        ),
      );
      return;
    }
    final cancelled = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            CancelRideScreen(isDriver: false, requestId: activeRequestId),
      ),
    );
    if (cancelled == true && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Ride cancelled')));
    }
  }

  void _openMatching(BuildContext context, String id) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => RideMatchingScreen(requestId: id)),
    );
  }

  void _openMap(BuildContext context, String tripId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GpsViewScreen(tripId: tripId, isDriver: false),
      ),
    );
  }

  Widget _activeRideRequestCard(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      initialData: FirebaseAuth.instance.currentUser,
      builder: (context, authSnapshot) {
        final user = authSnapshot.data;
        if (user == null) {
          return _whiteCard(
            child: const Text('Please log in to view your rides.'),
          );
        }
        return _activeRideRequestCardForUser(context, user);
      },
    );
  }

  Widget _activeRideRequestCardForUser(BuildContext context, User user) {
    const activeStatuses = {
      'searching',
      'awaiting_choice',
      'solo_requested',
      'matching_driver',
      'driver_arrived',
      'driver_assigned',
      'in_progress',
    };

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('ride_requests')
          .where('passengerId', isEqualTo: user.uid)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _whiteCard(
            child: const Text('Unable to load your active ride.'),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final requests = snapshot.data!.docs.where((doc) {
          return activeStatuses.contains(doc.data()['status']);
        }).toList();

        requests.sort((a, b) {
          final aTime = a.data()['createdAt'];
          final bTime = b.data()['createdAt'];
          final aDate = aTime is Timestamp
              ? aTime.toDate()
              : DateTime.fromMillisecondsSinceEpoch(0);
          final bDate = bTime is Timestamp
              ? bTime.toDate()
              : DateTime.fromMillisecondsSinceEpoch(0);
          return bDate.compareTo(aDate);
        });

        if (requests.isEmpty) {
          return _whiteCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.directions_car_outlined,
                  color: RPColors.teal,
                  size: 32,
                ),
                const SizedBox(height: 8),
                const Text(
                  'No active ride',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: RPColors.teal,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Your current ride requests will appear here while matching or travelling.',
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: onOpenHubs,
                  icon: const Icon(Icons.add),
                  label: const Text('Book a Ride'),
                ),
              ],
            ),
          );
        }

        // Keep the existing behavior: display the newest active request.
        final doc = requests.first;
        final data = doc.data();
        final pickup = _nonEmpty(
          data['pickupName'],
          fallback: _nonEmpty(data['pickupAddress'], fallback: 'Pickup hub'),
        );
        final dropoff = _nonEmpty(
          data['dropoffAddress'],
          fallback: _nonEmpty(data['dropoffName'], fallback: 'Destination'),
        );
        final status = data['status']?.toString() ?? 'searching';
        final tripId = data['groupId'] as String?;
        const cancellableStatuses = {
          'searching',
          'awaiting_choice',
          'solo_requested',
          'matching_driver',
          'driver_assigned',
        };
        final canCancel = cancellableStatuses.contains(status);
        final hasDriver =
            status == 'driver_assigned' ||
            status == 'driver_arrived' ||
            status == 'in_progress';

        final statusLabel = switch (status) {
          'searching' => 'Finding passengers',
          'awaiting_choice' => 'Action needed: choose your ride',
          'solo_requested' => 'Finding a solo driver',
          'matching_driver' => 'Finding a driver',
          'driver_assigned' => 'Driver assigned',
          'driver_arrived' => 'Your driver has arrived',
          'in_progress' => 'Ride in progress',
          _ => 'Ride active',
        };

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _whiteCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionHeading(
                    icon: Icons.route,
                    label: 'YOUR ACTIVE RIDE',
                  ),
                  const SizedBox(height: 14),
                  Text(
                    pickup,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: RPColors.textDark,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 5),
                    child: Icon(
                      Icons.arrow_downward,
                      size: 18,
                      color: RPColors.textGrey,
                    ),
                  ),
                  Text(dropoff),
                  const SizedBox(height: 12),
                  _StatusPill(text: statusLabel, color: RPColors.teal),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        if (hasDriver) {
                          if (tripId == null || tripId.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'The shared trip could not be found. Please refresh.',
                                ),
                              ),
                            );
                            return;
                          }
                          _openMap(context, tripId);
                        } else {
                          _openMatching(context, doc.id);
                        }
                      },
                      icon: Icon(
                        hasDriver ? Icons.map_outlined : Icons.open_in_new,
                      ),
                      label: Text(
                        hasDriver ? 'View Live Map' : 'View Matching Status',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: RPColors.teal,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(46),
                      ),
                    ),
                  ),
                  if (canCancel) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => _openCancel(context, doc.id),
                        icon: const Icon(Icons.cancel_outlined),
                        label: const Text('Cancel Ride'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red.shade700,
                          side: BorderSide(color: Colors.red.shade700),
                          minimumSize: const Size.fromHeight(46),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (hasDriver && tripId != null && tripId.isNotEmpty)
              _assignedTripDetails(context, data, tripId, ownRequestId: doc.id),
          ],
        );
      },
    );
  }

  Widget _assignedTripDetails(
    BuildContext context,
    Map<String, dynamic> requestData,
    String tripId, {
    required String ownRequestId,
  }) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('trips')
          .doc(tripId)
          .snapshots(),
      builder: (context, tripSnapshot) {
        if (tripSnapshot.hasError) {
          return const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Text('Unable to load trip details.'),
          );
        }
        if (!tripSnapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final tripData = tripSnapshot.data!.data();
        if (tripData == null) {
          return const Text('Trip details could not be found.');
        }

        final requestDriverId = requestData['driverId'] as String?;
        final tripDriverId = tripData['driverId'] as String?;
        final driverId = requestDriverId != null && requestDriverId.isNotEmpty
            ? requestDriverId
            : tripDriverId;

        // The route is separate from driver/vehicle loading, so it remains
        // visible even if a driver profile or vehicle document is unavailable.
        return TripEtaEstimates(
          tripId: tripId,
          tripData: tripData,
          builder: (context, estimates) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (driverId == null || driverId.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: _whiteCard(
                    child: const Text('Waiting for driver information.'),
                  ),
                )
              else
                _driverAndSummaryCard(
                  driverId: driverId,
                  requestData: requestData,
                  tripData: tripData,
                ),
              const SizedBox(height: 20),
              const _SectionHeading(
                icon: Icons.alt_route,
                label: 'OPTIMIZED DROP-OFF ROUTE',
              ),
              const SizedBox(height: 6),
              const Text(
                'Follow every passenger stop in the driver\'s optimized route.',
                style: TextStyle(fontSize: 12, color: RPColors.textGrey),
              ),
              const SizedBox(height: 12),
              _PassengerRouteCards(
                tripData: tripData,
                ownRequestId: ownRequestId,
                estimates: estimates,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _driverAndSummaryCard({
    required String driverId,
    required Map<String, dynamic> requestData,
    required Map<String, dynamic> tripData,
  }) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(driverId)
          .snapshots(),
      builder: (context, driverSnapshot) {
        if (driverSnapshot.hasError) {
          return const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Text('Unable to load driver information.'),
          );
        }
        if (!driverSnapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final driver = driverSnapshot.data!.data() ?? <String, dynamic>{};

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('vehicles')
              .where('driverId', isEqualTo: driverId)
              .where('isActive', isEqualTo: true)
              .snapshots(),
          builder: (context, vehicleSnapshot) {
            final vehicles = vehicleSnapshot.data?.docs ?? [];
            final vehicle = vehicles.isNotEmpty
                ? vehicles.first.data()
                : <String, dynamic>{};
            final name = _nonEmpty(driver['name'], fallback: 'Assigned driver');
            final photo = driver['profilePic'] as String?;
            final make = _nonEmpty(vehicle['vehicleMake']);
            final model = _nonEmpty(vehicle['vehicleModel']);
            final color = _nonEmpty(vehicle['vehicleColor']);
            final plate = _nonEmpty(vehicle['plateNumber']);

            return Padding(
              padding: const EdgeInsets.only(top: 16),
              child: _whiteCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _SectionHeading(
                      icon: Icons.person_outline,
                      label: 'YOUR DRIVER',
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 25,
                          backgroundImage: photo != null && photo.isNotEmpty
                              ? NetworkImage(photo)
                              : null,
                          child: photo == null || photo.isEmpty
                              ? const Icon(Icons.person)
                              : null,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            name,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: RPColors.textDark,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 28),
                    const _SectionHeading(
                      icon: Icons.directions_car_outlined,
                      label: 'VEHICLE DETAILS',
                    ),
                    const SizedBox(height: 8),
                    _DetailRow('Vehicle', '$make $model'.trim()),
                    _DetailRow('Color', color),
                    _DetailRow('Plate number', plate),
                    const Divider(height: 28),
                    const _SectionHeading(
                      icon: Icons.receipt_long_outlined,
                      label: 'TRIP SUMMARY',
                    ),
                    const SizedBox(height: 8),
                    _DetailRow(
                      'Passengers',
                      tripData['totalPassengers']?.toString() ??
                          'Not available',
                    ),
                    _DetailRow(
                      'Your fare share',
                      _formatFare(requestData['fareShareSen']),
                    ),
                    _DetailRow(
                      'Total trip fare',
                      _formatFare(tripData['totalFareSen']),
                    ),
                    if (vehicleSnapshot.hasError)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'Unable to load vehicle information.',
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isDriver) return DriverRideScreen(requestId: requestId);

    return Scaffold(
      backgroundColor: RPColors.bg,
      appBar: rpAppBar('Ride Details'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [_activeRideRequestCard(context)],
      ),
    );
  }
}

/// Read-only passenger route. The driver alone can confirm drop-offs.
/// Each stop listens to its own ride request, so there is no whereIn limit.
class _PassengerRouteCards extends StatelessWidget {
  const _PassengerRouteCards({
    required this.tripData,
    required this.ownRequestId,
    required this.estimates,
  });

  final Map<String, dynamic> tripData;
  final String ownRequestId;
  final TripEtaResult estimates;

  @override
  Widget build(BuildContext context) {
    final requestIds = _stringIds(tripData['requestIds']);
    final optimized = _stringIds(tripData['optimizedDropoffOrder']);
    final order = <String>{
      ...optimized.where(requestIds.contains),
      ...requestIds.where((id) => !optimized.contains(id)),
    }.toList();
    final tripStatus = tripData['status']?.toString() ?? '';

    if (order.isEmpty) {
      return _whiteCard(child: const Text('No passenger stops available yet.'));
    }

    // A single stream per request is combined using nested StreamBuilders.
    // This ensures the next-stop label changes when ANY stop is confirmed.
    return _RouteStatusListener(
      order: order,
      index: 0,
      loaded: const {},
      builder: (statuses) {
        final nextId = order.cast<String?>().firstWhere((id) {
          final status = statuses[id]?['status']?.toString();
          return status != 'drop_off_confirmed' &&
              status != 'completed' &&
              status != 'cancelled';
        }, orElse: () => null);
        return Column(
          children: [
            for (var i = 0; i < order.length; i++)
              _PassengerRouteCard(
                stopNumber: i + 1,
                data: statuses[order[i]],
                isOwnStop: order[i] == ownRequestId,
                isNextStop: order[i] == nextId && tripStatus == 'in_progress',
                tripStatus: tripStatus,
                estimate:
                    estimates.stopEtas[order[i]] ??
                    (order[i] == nextId ? estimates.message : null),
                driverEta:
                    estimates.pickupEta ??
                    (order[i] == ownRequestId ? estimates.message : null),
              ),
          ],
        );
      },
    );
  }
}

/// Sequential listeners avoid Firestore whereIn limits and allow every stop
/// to update the whole ordered route in real time.
class _RouteStatusListener extends StatelessWidget {
  const _RouteStatusListener({
    required this.order,
    required this.index,
    required this.loaded,
    required this.builder,
  });

  final List<String> order;
  final int index;
  final Map<String, Map<String, dynamic>?> loaded;
  final Widget Function(Map<String, Map<String, dynamic>?>) builder;

  @override
  Widget build(BuildContext context) {
    if (index >= order.length) return builder(loaded);
    final id = order[index];
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('ride_requests')
          .doc(id)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _whiteCard(
            child: Text(
              'Unable to load route stop ${index + 1}. Check read permissions.',
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return _RouteStatusListener(
          order: order,
          index: index + 1,
          loaded: {...loaded, id: snapshot.data!.data()},
          builder: builder,
        );
      },
    );
  }
}

class _PassengerRouteCard extends StatelessWidget {
  const _PassengerRouteCard({
    required this.stopNumber,
    required this.data,
    required this.isOwnStop,
    required this.isNextStop,
    required this.tripStatus,
    required this.estimate,
    required this.driverEta,
  });

  final int stopNumber;
  final Map<String, dynamic>? data;
  final bool isOwnStop;
  final bool isNextStop;
  final String tripStatus;
  final String? estimate;
  final String? driverEta;

  @override
  Widget build(BuildContext context) {
    if (data == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _whiteCard(child: Text('Stop $stopNumber is unavailable.')),
      );
    }

    final status = data!['status']?.toString() ?? '';
    final droppedOff = status == 'drop_off_confirmed' || status == 'completed';
    final cancelled = status == 'cancelled';
    final pickup = _nonEmpty(
      data!['pickupName'],
      fallback: _nonEmpty(data!['pickupAddress'], fallback: 'Pickup location'),
    );
    final destination = _nonEmpty(
      data!['dropoffAddress'],
      fallback: _nonEmpty(data!['dropoffName'], fallback: 'Destination'),
    );
    final passengerCount =
        data!['passengerCount'] ?? data!['totalPassengers'] ?? 1;

    final progressLabel = droppedOff
        ? 'DROPPED OFF'
        : cancelled
        ? 'CANCELLED'
        : isNextStop
        ? 'NEXT STOP'
        : tripStatus == 'in_progress'
        ? 'PENDING'
        : 'AWAITING DEPARTURE';
    final progressColor = droppedOff
        ? Colors.green.shade700
        : cancelled
        ? Colors.red.shade700
        : RPColors.teal;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        margin: EdgeInsets.zero,
        color: isOwnStop ? RPColors.teal.withValues(alpha: 0.07) : Colors.white,
        elevation: isOwnStop ? 2 : 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: isOwnStop
                ? RPColors.teal
                : progressColor.withValues(alpha: 0.25),
            width: isOwnStop ? 1.6 : 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: RPColors.teal.withValues(alpha: 0.12),
                    child: Text(
                      '$stopNumber',
                      style: const TextStyle(
                        color: RPColors.teal,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'PASSENGER $stopNumber',
                      style: const TextStyle(
                        color: RPColors.teal,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  if (isOwnStop)
                    _StatusPill(text: 'YOUR STOP', color: RPColors.teal),
                ],
              ),
              const Divider(height: 24),
              _DetailRow('Pickup', pickup),
              _DetailRow('Destination', destination),
              _DetailRow('Passengers', '$passengerCount'),
              if (isOwnStop && tripStatus == 'driver_assigned')
                _DetailRow('Driver arrival', driverEta ?? 'Calculating…'),
              if (!droppedOff &&
                  !cancelled &&
                  const {'driver_arrived', 'in_progress'}.contains(tripStatus))
                _DetailRow('Estimated drop-off', estimate ?? 'Calculating…'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    droppedOff
                        ? Icons.check_circle
                        : cancelled
                        ? Icons.cancel
                        : isNextStop
                        ? Icons.directions_car
                        : Icons.schedule,
                    size: 18,
                    color: progressColor,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      progressLabel,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: progressColor,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, color: RPColors.teal, size: 20),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          label,
          style: const TextStyle(
            color: RPColors.teal,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ),
    ],
  );
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: Text(
            label,
            style: const TextStyle(color: RPColors.textGrey, fontSize: 13),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 3,
          child: Text(
            value.isEmpty ? 'Not available' : value,
            textAlign: TextAlign.end,
            style: const TextStyle(
              color: RPColors.textDark,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
      ],
    ),
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 11),
    ),
  );
}

Widget _whiteCard({required Widget child}) => Card(
  margin: EdgeInsets.zero,
  color: Colors.white,
  elevation: 1,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(16),
    side: BorderSide(color: RPColors.teal.withValues(alpha: 0.12)),
  ),
  child: Padding(padding: const EdgeInsets.all(16), child: child),
);

String _nonEmpty(dynamic value, {String fallback = ''}) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

String _formatFare(dynamic sen) =>
    sen is num ? 'RM ${(sen / 100).toStringAsFixed(2)}' : 'Not available';

List<String> _stringIds(dynamic value) {
  if (value is! List) return [];
  return value.whereType<String>().where((id) => id.isNotEmpty).toList();
}
