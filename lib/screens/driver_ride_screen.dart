import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'live_trip_map.dart';
import 'cancel_ride_screen.dart';
import 'passenger_home.dart' show RPColors;
import 'ride_widgets.dart';

/// Driver's Rides tab: live map plus the Active Trip panel.
class DriverRideScreen extends StatelessWidget {
  const DriverRideScreen({super.key, this.requestId});

  /// Optional request ID associated with the active trip.
  final String? requestId;

  /// Asks the driver to confirm ending the ride.
  Future<void> _confirmEndRide(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: RPColors.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'End this ride?',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        content: const Text(
          'Make sure all passengers have been dropped off.',
          style: TextStyle(fontSize: 13, color: RPColors.textGrey),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep Driving'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: rpDangerDeep),
            child: const Text('End Ride'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      // TODO: mark the ride as completed in Firestore and trigger payouts.
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Ride ended')));
    }
  }


  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return const Scaffold(
        body: Center(child: Text('Please log in to view your active trip.')),
      );
    }

    return Scaffold(
      backgroundColor: RPColors.cardBg,
      appBar: AppBar(
        title: const Text('My Active Trip'),
        backgroundColor: RPColors.cardBg,
        elevation: 0,
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('trips')
            .where('driverId', isEqualTo: user.uid)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text('Unable to load trips: ${snapshot.error}'),
            );
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final activeTrips = snapshot.data!.docs.where((doc) {
            final data = doc.data();
            final status = data['status'];

            return status == 'driver_assigned' || status == 'in_progress';
          }).toList();

          if (activeTrips.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No active trip found.\n\n'
                  'Accept a ride request to see your trip here.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final tripDoc = activeTrips.first;
          final tripData = tripDoc.data();
          final tripId = tripDoc.id;

          final requestIds = List<String>.from(tripData['requestIds'] ?? []);

          return Column(
            children: [
              Expanded(
                flex: 3,
                child: LiveTripMap(
                  key: ValueKey(tripId),
                  tripId: tripId,
                  isDriver: true,
                ),
              ),
              Expanded(
                flex: 2,
                child: _ActiveTripPanel(
                  tripId: tripId,
                  tripData: tripData,
                  requestIds: requestIds,
                  onEndRide: () => _confirmEndRide(context),
                  onCancel: () {
                    if (requestIds.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('No linked ride requests were found.'),
                        ),
                      );
                      return;
                    }

                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => CancelRideScreen(
                          isDriver: true,
                          requestId: requestIds.first,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// Keep _ActiveTripPanel below this point.
/// Shows an active trip's live map and relevant passenger information.
class _ActiveTripPanel extends StatelessWidget {
  const _ActiveTripPanel({
    required this.tripId,
    required this.tripData,
    required this.requestIds,
    required this.onEndRide,
    required this.onCancel,
  });

  final String tripId;
  final Map<String, dynamic> tripData;
  final List<String> requestIds;
  final VoidCallback onEndRide;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final status = tripData['status']?.toString() ?? 'unknown';

    final pickup =
        tripData['pickupName'] ??
        tripData['pickupAddress'] ??
        'Pickup location';

    final destination =
        tripData['dropoffAddress'] ?? tripData['dropoffName'] ?? 'Destination';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: RPColors.cardBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: ListView(
        children: [
          Text('Trip details', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),

          Text('Status: ${status.replaceAll('_', ' ')}'),
          const SizedBox(height: 8),

          Text('Pickup: $pickup'),
          Text('Destination: $destination'),

          const Divider(height: 24),

          Text(
            'Passengers (${requestIds.length} requests)',
            style: Theme.of(context).textTheme.titleMedium,
          ),

          if (requestIds.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('No linked passenger requests found.'),
            )
          else
            ...requestIds.map(
              (requestId) => _PassengerRequestTile(requestId: requestId),
            ),

          const SizedBox(height: 12),

          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onCancel,
                  child: const Text('Cancel trip'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: onEndRide,
                  child: const Text('End trip'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Summarizes one passenger's request within the driver's active trip.
class _PassengerRequestTile extends StatelessWidget {
  const _PassengerRequestTile({required this.requestId});

  final String requestId;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('ride_requests')
          .doc(requestId)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const ListTile(
            leading: Icon(Icons.error_outline),
            title: Text('Unable to load passenger'),
          );
        }

        if (!snapshot.hasData) {
          return const ListTile(
            leading: CircularProgressIndicator(),
            title: Text('Loading passenger request...'),
          );
        }

        final request = snapshot.data!.data();

        if (request == null) {
          return const ListTile(
            leading: Icon(Icons.person_off_outlined),
            title: Text('Passenger request not found'),
          );
        }

        final passengerCount = request['totalPassengers'] ?? 1;
        final pickup = request['pickupName'] ?? 'Pickup location';
        final destination = request['dropoffAddress'] ?? 'Destination';
        final status = request['status'] ?? 'unknown';

        return Card(
          child: ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person)),
            title: Text('$passengerCount passenger(s)'),
            subtitle: Text(
              '$pickup → $destination\n'
              'Status: ${status.toString().replaceAll('_', ' ')}',
            ),
            isThreeLine: true,
          ),
        );
      },
    );
  }
}
