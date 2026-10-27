import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'ride_matching_screen.dart';
import 'cancel_ride_screen.dart';
import 'driver_ride_screen.dart';
import 'form_widgets.dart' show rpAppBar;
import 'gps_view_screen.dart';
import 'passenger_home.dart' show RPColors;
import 'ride_widgets.dart';

/// Rides tab: details of the current ride.
class RidesScreen extends StatelessWidget {
  /// Creates the rides tab for a passenger or driver.
  const RidesScreen({super.key, required this.isDriver, this.requestId});

  /// Whether to show the driver-specific ride flow.
  final bool isDriver;

  /// Optional ride request ID used to open or cancel a specific request.
  final String? requestId;

  /// Opens the cancellation flow and reports a successful cancellation.
  Future<void> _openCancel(BuildContext context) async {
    if (requestId == null || requestId!.isEmpty) {
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
            CancelRideScreen(isDriver: false, requestId: requestId!),
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
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Please log in to view your rides.'),
        ),
      );
    }

    const activeStatuses = {
      'searching',
      'awaiting_choice',
      'solo_requested',
      'matching_driver',
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
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('Unable to load your active ride.'),
            ),
          );
        }

        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final requests = snapshot.data!.docs.where((doc) {
          final status = doc.data()['status'] as String?;
          return activeStatuses.contains(status);
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
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
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
                    'Your current ride requests will appear here '
                    'while matching or travelling.',
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Book a ride from the Home or Hubs tab.',
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Book a Ride'),
                  ),
                ],
              ),
            ),
          );
        }

        // Display the most recent active request.
        final doc = requests.first;
        final data = doc.data();

        final pickup = data['pickupName'] as String? ?? 'Pickup hub';
        final dropoff = data['dropoffAddress'] as String? ?? 'Destination';
        final status = data['status'] as String? ?? 'searching';
        final tripId = data['groupId'] as String?;

        final statusLabel = switch (status) {
          'searching' => 'Finding passengers',
          'awaiting_choice' => 'Action needed: choose your ride',
          'solo_requested' => 'Finding a solo driver',
          'matching_driver' => 'Finding a driver',
          'driver_assigned' => 'Driver assigned',
          'in_progress' => 'Ride in progress',
          _ => 'Ride active',
        };

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: Colors.white,
              elevation: 1,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: RPColors.teal.withValues(alpha: 0.25)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.route, color: RPColors.teal),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'YOUR ACTIVE RIDE',
                            style: TextStyle(
                              color: RPColors.teal,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      pickup,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: Icon(
                        Icons.arrow_downward,
                        size: 18,
                        color: RPColors.textGrey,
                      ),
                    ),
                    Text(dropoff),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: RPColors.teal.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        statusLabel,
                        style: const TextStyle(
                          color: RPColors.teal,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          if (status == 'driver_assigned' ||
                              status == 'in_progress') {
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
                          status == 'driver_assigned' || status == 'in_progress'
                              ? Icons.map_outlined
                              : Icons.open_in_new,
                        ),
                        label: Text(
                          status == 'driver_assigned' || status == 'in_progress'
                              ? 'View Live Map'
                              : 'View Matching Status',
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: RPColors.teal,
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(46),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if ((status == 'driver_assigned' || status == 'in_progress') &&
                tripId != null &&
                tripId.isNotEmpty)
              _assignedTripDetails(context, data, tripId),
          ],
        );
      },
    );
  }

  Widget _assignedTripDetails(
    BuildContext context,
    Map<String, dynamic> requestData,
    String tripId,
  ) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('trips')
          .doc(tripId)
          .snapshots(),
      builder: (context, tripSnapshot) {
        if (tripSnapshot.hasError) {
          return const Text('Unable to load trip details.');
        }

        if (!tripSnapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
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

        if (driverId == null || driverId.isEmpty) {
          return const Text('Waiting for driver information.');
        }

        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('users')
              .doc(driverId)
              .snapshots(),
          builder: (context, driverSnapshot) {
            if (driverSnapshot.hasError) {
              return const Text('Unable to load driver information.');
            }

            if (!driverSnapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final driver = driverSnapshot.data!.data() ?? {};

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

                final name = driver['name'] as String? ?? 'Assigned driver';
                final photo = driver['profilePic'] as String?;
                final make = vehicle['vehicleMake'] as String? ?? '';
                final model = vehicle['vehicleModel'] as String? ?? '';
                final color = vehicle['vehicleColor'] as String? ?? '';
                final plate = vehicle['plateNumber'] as String? ?? '';

                final fareShare = requestData['fareShareSen'];
                final totalFare = tripData['totalFareSen'];
                final passengers = tripData['totalPassengers'];

                String fare(dynamic amount) {
                  if (amount is num) {
                    return 'RM ${(amount / 100).toStringAsFixed(2)}';
                  }
                  return 'Not available';
                }

                Widget detail(String label, String value) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            label,
                            style: const TextStyle(
                              color: RPColors.textGrey,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        Flexible(
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

                return Card(
                  margin: const EdgeInsets.only(top: 16),
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'YOUR DRIVER',
                          style: TextStyle(
                            color: RPColors.teal,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
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
                        const Text(
                          'VEHICLE DETAILS',
                          style: TextStyle(
                            color: RPColors.teal,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 8),
                        detail('Vehicle', '$make $model'.trim()),
                        detail('Color', color),
                        detail('Plate number', plate),
                        const Divider(height: 28),
                        const Text(
                          'TRIP SUMMARY',
                          style: TextStyle(
                            color: RPColors.teal,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 8),
                        detail(
                          'Passengers',
                          passengers == null ? 'Not available' : '$passengers',
                        ),
                        detail('Your fare share', fare(fareShare)),
                        detail('Total trip fare', fare(totalFare)),
                        if (vehicleSnapshot.hasError)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text(
                              'Unable to load vehicle information.',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () => _openMap(context, tripId),
                            icon: const Icon(Icons.map_outlined),
                            label: const Text('View Live Map'),
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
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isDriver) return const DriverRideScreen();

    return Scaffold(
      backgroundColor: RPColors.bg,
      appBar: rpAppBar('Ride Details'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _activeRideRequestCard(context),
          const SizedBox(height: 16),

          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: TextButton(
              onPressed: () => _openCancel(context),
              child: const Text(
                'Cancel ride',
                style: TextStyle(
                  color: rpDangerDeep,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
