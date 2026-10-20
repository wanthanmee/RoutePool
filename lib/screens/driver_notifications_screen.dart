import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'passenger_home.dart' show RPColors;

class DriverNotificationsScreen extends StatefulWidget {
  const DriverNotificationsScreen({super.key});

  @override
  State<DriverNotificationsScreen> createState() =>
      _DriverNotificationsScreenState();
}

class _DriverNotificationsScreenState extends State<DriverNotificationsScreen> {
  String _filter = 'All';

  Stream<QuerySnapshot<Map<String, dynamic>>> _getTrips() {
    return FirebaseFirestore.instance
        .collection('trips')
        .where('status', isEqualTo: 'matching_driver')
        .snapshots();
  }

  Future<String> _getPassengerName(String? passengerId) async {
    if (passengerId == null || passengerId.isEmpty) {
      return 'Passenger details unavailable';
    }

    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(passengerId)
          .get();

      final data = doc.data();

      if (data == null) return 'Unknown passenger';

      final firstName = data['firstName']?.toString().trim() ?? '';
      final lastName = data['lastName']?.toString().trim() ?? '';

      final fullName = [
        firstName,
        lastName,
      ].where((part) => part.isNotEmpty).join(' ');

      if (fullName.isNotEmpty) return fullName;

      for (final field in ['fullName', 'name', 'userName']) {
        final value = data[field]?.toString().trim() ?? '';
        if (value.isNotEmpty) return value;
      }

      return 'Passenger name unavailable';
    } catch (e) {
      debugPrint('Could not load passenger name: $e');
      return 'Passenger details unavailable';
    }
  }

  Future<List<Map<String, dynamic>>> _getTripPassengerDetails(
    List<String> requestIds,
  ) async {
    final firestore = FirebaseFirestore.instance;
    final details = <Map<String, dynamic>>[];

    for (final requestId in requestIds) {
      final requestDoc = await firestore
          .collection('ride_requests')
          .doc(requestId)
          .get();

      if (!requestDoc.exists) continue;

      final requestData = requestDoc.data()!;

      final passengerName = await _getPassengerName(
        requestData['passengerId']?.toString(),
      );

      details.add({
        'name': passengerName,
        'destination':
            requestData['dropoffAddress']?.toString() ?? 'Unknown destination',
        'passengerCount': (requestData['passengerCount'] as num?)?.toInt() ?? 1,
      });
    }

    return details;
  }

  Future<void> _markAsRead(String tripId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      await FirebaseFirestore.instance.collection('trips').doc(tripId).update({
        'viewedBy': FieldValue.arrayUnion([user.uid]),
      });
    } catch (e) {
      debugPrint('Could not mark notification as read: $e');
    }
  }

  Future<void> _dismissNotification(
    String tripId, {
    bool declined = false,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      await FirebaseFirestore.instance.collection('trips').doc(tripId).update({
        'dismissedBy': FieldValue.arrayUnion([user.uid]),
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            declined
                ? 'Trip dismissed from your list.'
                : 'Notification removed from your list.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not remove notification: $e')),
      );
    }
  }

  Future<void> _acceptTrip(String tripId) async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Please sign in again.')));
      return;
    }

    try {
      final firestore = FirebaseFirestore.instance;

      await firestore.runTransaction((transaction) async {
        final tripRef = firestore.collection('trips').doc(tripId);
        final driverRef = firestore.collection('users').doc(user.uid);
        final vehicleRef = firestore.collection('vehicles').doc(user.uid);

        final tripSnapshot = await transaction.get(tripRef);
        final driverSnapshot = await transaction.get(driverRef);
        final vehicleSnapshot = await transaction.get(vehicleRef);

        if (!tripSnapshot.exists) {
          throw Exception('This trip no longer exists.');
        }

        final tripData = tripSnapshot.data()!;
        final driverData = driverSnapshot.data();
        final vehicleData = vehicleSnapshot.data();

        if (tripData['status'] != 'matching_driver' ||
            tripData['driverId'] != null) {
          throw Exception('This trip has already been taken.');
        }

        if (driverData?['verificationStatus'] != 'approved' ||
            driverData?['isAvailable'] != true) {
          throw Exception('Your driver account must be approved and online.');
        }

        if (vehicleData?['verificationStatus'] != 'approved' ||
            vehicleData?['isActive'] != true) {
          throw Exception('Your vehicle must be approved and active.');
        }

        final requestIds = List<String>.from(
          tripData['requestIds'] ?? <String>[],
        );

        if (requestIds.isEmpty) {
          throw Exception('This trip has no linked passenger requests.');
        }

        final requestRefs = requestIds
            .map((id) => firestore.collection('ride_requests').doc(id))
            .toList();

        // Read every linked request before performing any writes.
        final requestSnapshots = <DocumentSnapshot<Map<String, dynamic>>>[];

        for (final requestRef in requestRefs) {
          requestSnapshots.add(await transaction.get(requestRef));
        }

        for (final requestSnapshot in requestSnapshots) {
          if (!requestSnapshot.exists) {
            throw Exception('A linked passenger request could not be found.');
          }

          final requestData = requestSnapshot.data()!;

          if (requestData['status'] != 'matching_driver' ||
              requestData['driverId'] != null ||
              requestData['groupId'] != tripId) {
            throw Exception(
              'A passenger request has changed. Please refresh and try again.',
            );
          }
        }

        transaction.update(tripRef, {
          'driverId': user.uid,
          'status': 'driver_assigned',
          'updatedAt': FieldValue.serverTimestamp(),
        });

        for (final requestRef in requestRefs) {
          transaction.update(requestRef, {
            'driverId': user.uid,
            'status': 'driver_assigned',
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }

        transaction.update(driverRef, {
          'isAvailable': false,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Trip accepted successfully!')),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not accept trip: '
            '${e.toString().replaceFirst('Exception: ', '')}',
          ),
        ),
      );
    }
  }

  String _formatDeparture(dynamic departure) {
    if (departure is! Timestamp) return 'Not specified';

    final dateTime = departure.toDate();
    final day = dateTime.day.toString().padLeft(2, '0');
    final month = dateTime.month.toString().padLeft(2, '0');
    final year = dateTime.year;

    final time = MaterialLocalizations.of(context)
        .formatTimeOfDay(TimeOfDay.fromDateTime(dateTime));

    return '$day/$month/$year at $time';
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return Scaffold(
        backgroundColor: RPColors.bg,
        appBar: AppBar(title: const Text('Notifications')),
        body: const Center(child: Text('Please sign in again.')),
      );
    }

    return Scaffold(
      backgroundColor: RPColors.bg,
      appBar: AppBar(
        title: const Text(
          'Notifications',
          style: TextStyle(
            color: RPColors.textDark,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: RPColors.bg,
        foregroundColor: RPColors.textDark,
        elevation: 0,
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _getTrips(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text('Unable to load notifications: ${snapshot.error}'),
            );
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final allRequests = snapshot.data?.docs ?? [];

          // Each driver can dismiss a request only from their own list.
          final requests = allRequests
              .where((request) {
                final data = request.data();
                final dismissedBy = List<String>.from(
                  data['dismissedBy'] ?? <String>[],
                );

                return !dismissedBy.contains(user.uid);
              })
              .where((request) {
                final data = request.data();
                final viewedBy = List<String>.from(
                  data['viewedBy'] ?? <String>[],
                );
                final isUnread = !viewedBy.contains(user.uid);

                return _filter == 'All' || isUnread;
              })
              .toList();

          final unreadCount = allRequests.where((request) {
            final data = request.data();
            final dismissedBy = List<String>.from(
              data['dismissedBy'] ?? <String>[],
            );
            final viewedBy = List<String>.from(data['viewedBy'] ?? <String>[]);

            return !dismissedBy.contains(user.uid) &&
                !viewedBy.contains(user.uid);
          }).length;

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$unreadCount unread notification(s)',
                        style: const TextStyle(
                          color: RPColors.textGrey,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'All', label: Text('All')),
                        ButtonSegment(value: 'Unread', label: Text('Unread')),
                      ],
                      selected: {_filter},
                      onSelectionChanged: (selection) {
                        setState(() => _filter = selection.first);
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: requests.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.notifications_none,
                              size: 56,
                              color: RPColors.textGrey,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _filter == 'Unread'
                                  ? 'You have no unread notifications.'
                                  : 'You have no new ride requests.',
                              style: const TextStyle(
                                color: RPColors.textGrey,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        itemCount: requests.length,
                        itemBuilder: (context, index) {
                          final request = requests[index];
                          final data = request.data();

                          final viewedBy = List<String>.from(
                            data['viewedBy'] ?? <String>[],
                          );
                          final isUnread = !viewedBy.contains(user.uid);

                          final pickup =
                              data['pickupName']?.toString() ??
                              'Unknown pickup';
                          final passengerCount =
                              (data['totalPassengers'] as num?)?.toInt() ?? 1;
                          final fareSen =
                              (data['totalFareSen'] as num?)?.toDouble() ?? 0.0;
                          final fareText =
                              'RM ${(fareSen / 100).toStringAsFixed(2)}';

                          return Card(
                            margin: const EdgeInsets.only(bottom: 14),
                            color: RPColors.cardBg,
                            elevation: isUnread ? 3 : 1,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                              side: BorderSide(
                                color: isUnread
                                    ? RPColors.orange
                                    : RPColors.border,
                                width: isUnread ? 2 : 1,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.local_taxi,
                                        color: RPColors.teal,
                                        size: 28,
                                      ),
                                      const SizedBox(width: 10),
                                      const Expanded(
                                        child: Text(
                                          'Ride request',
                                          style: TextStyle(
                                            fontSize: 17,
                                            fontWeight: FontWeight.bold,
                                            color: RPColors.textDark,
                                          ),
                                        ),
                                      ),
                                      if (isUnread)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: RPColors.orange,
                                            borderRadius: BorderRadius.circular(
                                              20,
                                            ),
                                          ),
                                          child: const Text(
                                            'NEW',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                      IconButton(
                                        tooltip: 'Delete notification',
                                        onPressed: () =>
                                            _dismissNotification(request.id),
                                        icon: const Icon(
                                          Icons.delete_outline,
                                          color: Colors.red,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  _detailRow(
                                    Icons.my_location,
                                    'Pickup',
                                    pickup,
                                  ),
                                  const SizedBox(height: 10),
                                  FutureBuilder<List<Map<String, dynamic>>>(
                                    future: _getTripPassengerDetails(
                                      List<String>.from(
                                        data['requestIds'] ?? <String>[],
                                      ),
                                    ),
                                    builder: (context, passengerSnapshot) {
                                      if (passengerSnapshot.connectionState ==
                                          ConnectionState.waiting) {
                                        return _detailRow(
                                          Icons.location_on,
                                          'Destinations',
                                          'Loading destinations...',
                                        );
                                      }

                                      if (passengerSnapshot.hasError ||
                                          !passengerSnapshot.hasData ||
                                          passengerSnapshot.data!.isEmpty) {
                                        return _detailRow(
                                          Icons.location_on,
                                          'Destinations',
                                          'Destination details unavailable',
                                        );
                                      }

                                      final passengers =
                                          passengerSnapshot.data!;

                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          _detailRow(
                                            Icons.location_on,
                                            'Destinations',
                                            passengers
                                                .map(
                                                  (passenger) =>
                                                      passenger['destination']
                                                          as String,
                                                )
                                                .toSet()
                                                .join('\n'),
                                          ),
                                          const SizedBox(height: 12),

                                          // Passenger details heading
                                          const Padding(
                                            padding: EdgeInsets.only(bottom: 8),
                                            child: Text(
                                              'PASSENGER DETAILS',
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: 1.0,
                                                color: RPColors.teal,
                                              ),
                                            ),
                                          ),

                                          // Individual passenger booking cards
                                          ...passengers.map((passenger) {
                                            final name =
                                                passenger['name']?.toString() ??
                                                'Unknown passenger';
                                            final count =
                                                (passenger['passengerCount']
                                                        as num?)
                                                    ?.toInt() ??
                                                1;
                                            final destination =
                                                passenger['destination']
                                                    ?.toString() ??
                                                'Unknown destination';

                                            return Container(
                                              width: double.infinity,
                                              margin: const EdgeInsets.only(
                                                bottom: 8,
                                              ),
                                              padding: const EdgeInsets.all(12),
                                              decoration: BoxDecoration(
                                                color: RPColors.bg,
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                border: Border.all(
                                                  color: RPColors.border,
                                                  width: 1,
                                                ),
                                              ),
                                              child: Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  // Avatar
                                                  Container(
                                                    width: 44,
                                                    height: 44,
                                                    decoration: BoxDecoration(
                                                      color: RPColors.teal
                                                          .withValues(
                                                            alpha: 0.12,
                                                          ),
                                                      shape: BoxShape.circle,
                                                    ),
                                                    child: const Icon(
                                                      Icons.person_outline,
                                                      color: RPColors.teal,
                                                      size: 25,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 12),

                                                  // Passenger information
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Text(
                                                          name,
                                                          style:
                                                              const TextStyle(
                                                                fontSize: 16,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w800,
                                                                color: RPColors
                                                                    .textDark,
                                                              ),
                                                        ),
                                                        const SizedBox(
                                                          height: 5,
                                                        ),
                                                        Row(
                                                          children: [
                                                            const Icon(
                                                              Icons
                                                                  .people_outline,
                                                              size: 15,
                                                              color:
                                                                  RPColors.teal,
                                                            ),
                                                            const SizedBox(
                                                              width: 5,
                                                            ),
                                                            Expanded(
                                                              child: Text(
                                                                '$count passenger(s)',
                                                                style: const TextStyle(
                                                                  fontSize: 13,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w600,
                                                                  color: RPColors
                                                                      .textDark,
                                                                ),
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                        const SizedBox(
                                                          height: 5,
                                                        ),
                                                        Row(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .start,
                                                          children: [
                                                            const Icon(
                                                              Icons
                                                                  .place_outlined,
                                                              size: 15,
                                                              color:
                                                                  RPColors.teal,
                                                            ),
                                                            const SizedBox(
                                                              width: 5,
                                                            ),
                                                            Expanded(
                                                              child: Text(
                                                                destination,
                                                                style: const TextStyle(
                                                                  fontSize: 12,
                                                                  color: RPColors
                                                                      .textGrey,
                                                                ),
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                          }),
                                        ],
                                      );
                                    },
                                  ),
                                  const SizedBox(height: 10),
                                  _detailRow(
                                    Icons.people_outline,
                                    'Passengers',
                                    '$passengerCount',
                                  ),
                                  const SizedBox(height: 10),
                                  _detailRow(
                                    Icons.payments_outlined,
                                    'Total fare',
                                    fareText,
                                  ),
                                  const SizedBox(height: 10),
                                  _detailRow(
                                    Icons.schedule,
                                    'Departure',
                                    _formatDeparture(data['departureTime']),
                                  ),
                                  const SizedBox(height: 16),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: OutlinedButton(
                                          onPressed: () => _dismissNotification(
                                            request.id,
                                            declined: true,
                                          ),
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: Colors.red,
                                          ),
                                          child: const Text('Decline'),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: ElevatedButton(
                                          onPressed: () =>
                                              _acceptTrip(request.id),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: RPColors.teal,
                                            foregroundColor: Colors.white,
                                          ),
                                          child: const Text('Accept Ride'),
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (isUnread)
                                    TextButton.icon(
                                      onPressed: () => _markAsRead(request.id),
                                      icon: const Icon(
                                        Icons.drafts_outlined,
                                        size: 18,
                                      ),
                                      label: const Text('Mark as read'),
                                    ),
                                ],
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

  Widget _detailRow(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 19, color: RPColors.teal),
        const SizedBox(width: 10),
        SizedBox(
          width: 95,
          child: Text(
            '$label:',
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: RPColors.textDark,
            ),
          ),
        ),
        Expanded(
          child: Text(value, style: const TextStyle(color: RPColors.textDark)),
        ),
      ],
    );
  }
}
