import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'passenger_home.dart' show RPColors;
import 'rate_driver_screen.dart';

/// Displays a completed ride's summary together with the passenger review and
/// trip-level details for the current user.
class RideHistoryDetailScreen extends StatelessWidget {
  const RideHistoryDetailScreen({
    super.key,
    required this.rideId,
    required this.isDriver,
  });

  final String rideId;
  final bool isDriver;

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return const Scaffold(body: Center(child: Text('Please sign in.')));
    }

    final db = FirebaseFirestore.instance;
    final ref = db.collection(isDriver ? 'trips' : 'ride_requests').doc(rideId);

    return Scaffold(
      backgroundColor: RPColors.bg,
      appBar: AppBar(title: const Text('Ride Details')),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: ref.snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('Unable to load ride.'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final ride = snapshot.data!.data();
          if (ride == null ||
              ride[isDriver ? 'driverId' : 'passengerId'] != uid) {
            return const Center(child: Text('Ride unavailable.'));
          }

          final status = ride['status'];
          final completed =
              status == 'completed' ||
              (!isDriver && status == 'drop_off_confirmed');
          if (!completed) {
            return const Center(child: Text('This ride is not completed.'));
          }

          final pickup =
              (ride['pickupName'] ?? ride['pickupAddress'] ?? 'Unavailable')
                  .toString();
          final dropoff =
              (ride['dropoffAddress'] ?? ride['dropoffName'] ?? 'Unavailable')
                  .toString();
          final fareSen = isDriver
              ? ride['totalFareSen']
              : ride['fareShareSen'];
          final fare = fareSen is num
              ? 'RM ${(fareSen / 100).toStringAsFixed(2)}'
              : 'Unavailable';
          final date = _rideDate(ride);

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Card(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.check_circle, color: Colors.green),
                          SizedBox(width: 8),
                          Text(
                            'RIDE COMPLETED',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      if (!isDriver) ...[
                        const SizedBox(height: 16),
                        _PassengerDriverCard(
                          groupId: (ride['groupId'] ?? '').toString(),
                        ),
                        const Divider(height: 28),
                      ] else
                        const SizedBox(height: 20),
                      _detail('Date', _formatDate(date)),
                      _detail('Pickup', pickup),
                      _detail(
                        isDriver ? 'Trip' : 'Destination',
                        isDriver
                            ? 'Shared trip with ${ride['totalPassengers'] ?? '?'} passenger(s)'
                            : dropoff,
                      ),
                      _detail(isDriver ? 'Total Trip Fare' : 'Your Fare', fare),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (!isDriver) ...[_PassengerReviewSection(requestId: rideId)],
              if (isDriver) ...[
                _TripPassengerDetails(
                  tripId: rideId,
                  requestIds: (ride['requestIds'] as List<dynamic>? ?? const [])
                      .map((id) => id.toString())
                      .where((id) => id.isNotEmpty)
                      .toList(),
                ),
                const SizedBox(height: 16),
                _DriverTripReviews(tripId: rideId),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _detail(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: RPColors.textGrey, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          ),
        ],
      ),
    );
  }
}

/// Shows either the saved review or the rating CTA for a completed ride.
class _PassengerReviewSection extends StatelessWidget {
  const _PassengerReviewSection({required this.requestId});

  final String requestId;

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: db.collection('reviews').doc(requestId).snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Text('Unable to load review.');
        }
        if (!snapshot.hasData) {
          return const LinearProgressIndicator();
        }
        if (snapshot.data!.exists) {
          return _reviewCard(snapshot.data!.data()!);
        }
        return _rateButton(context);
      },
    );
  }

  Widget _reviewCard(Map<String, dynamic> review) {
    final tags = (review['tags'] as List<dynamic>? ?? [])
        .map((tag) => tag.toString())
        .join(', ');
    final comment = (review['comment'] ?? '').toString();
    return Card(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Expanded(
                  child: Text(
                    'Your Review',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
                  ),
                ),
                Icon(Icons.check_circle, color: Color(0xFF23834B), size: 18),
                SizedBox(width: 5),
                Text(
                  'Reviewed',
                  style: TextStyle(
                    color: Color(0xFF23834B),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('⭐ ${review['rating']} / 5'),
            if (tags.isNotEmpty) ...[const SizedBox(height: 8), Text(tags)],
            if (comment.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(comment),
            ],
          ],
        ),
      ),
    );
  }

  Widget _rateButton(BuildContext context) {
    return FilledButton.icon(
      style: FilledButton.styleFrom(backgroundColor: RPColors.teal),
      onPressed: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => RateDriverScreen(requestId: requestId),
          ),
        );
      },
      icon: const Icon(Icons.star),
      label: const Text('Rate Your Driver'),
    );
  }
}

class _DriverTripReviews extends StatelessWidget {
  const _DriverTripReviews({required this.tripId});

  final String tripId;

  @override
  Widget build(BuildContext context) {
    final db = FirebaseFirestore.instance;
    final driverId = FirebaseAuth.instance.currentUser?.uid;

    if (driverId == null) {
      return const Text('Please sign in to view reviews.');
    }
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: db
          .collection('reviews')
          .where('tripId', isEqualTo: tripId)
          .where('driverId', isEqualTo: driverId)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Text('Unable to load passenger reviews.');
        }
        if (!snapshot.hasData) {
          return const LinearProgressIndicator();
        }
        final reviews = snapshot.data!.docs.map((doc) => doc.data()).toList();
        if (reviews.isEmpty) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No passenger reviews yet.'),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Passenger Reviews',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            for (final review in reviews)
              Card(
                color: Colors.white,
                child: ListTile(
                  title: Text('⭐ ${review['rating']} / 5'),
                  subtitle: (review['comment'] ?? '').toString().isEmpty
                      ? const Text('No written comment')
                      : Text(review['comment'].toString()),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Driver-only: shows the bookings that made up this completed trip.
/// A booking may represent multiple seats, so it is not necessarily one seat.
class _TripPassengerDetails extends StatelessWidget {
  const _TripPassengerDetails({required this.tripId, required this.requestIds});

  final String tripId;
  final List<String> requestIds;

  Future<List<_PassengerBooking>> _loadBookings() async {
    final db = FirebaseFirestore.instance;

    final results = await Future.wait(
      requestIds.map((id) async {
        final snapshot = await db.collection('ride_requests').doc(id).get();
        return (id, snapshot.data());
      }),
    );

    final callable = FirebaseFunctions.instanceFor(region: 'asia-southeast1')
        .httpsCallable('getTripParticipantProfiles');

    final response = await callable.call(<String, dynamic>{'tripId': tripId});

    final data = Map<String, dynamic>.from(response.data as Map);
    final profiles = Map<String, dynamic>.from(data['profiles'] as Map);

    return results.map((entry) {
      final request = entry.$2;
      final passengerId = (request?['passengerId'] ?? '').toString();

      final profileData = profiles[passengerId];

      return _PassengerBooking(
        requestId: entry.$1,
        request: request,
        profile: profileData is Map
            ? Map<String, dynamic>.from(profileData)
            : null,
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PASSENGER DETAILS (${requestIds.length} bookings)',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 14),
            if (requestIds.isEmpty)
              const Text('No passenger bookings were recorded for this trip.')
            else
              FutureBuilder<List<_PassengerBooking>>(
                future: _loadBookings(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Text('Unable to load passenger details.');
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final bookings = snapshot.data!;
                  return Column(
                    children: [
                      for (var i = 0; i < bookings.length; i++) ...[
                        if (i > 0) const Divider(height: 28),
                        _PassengerBookingTile(booking: bookings[i]),
                      ],
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _PassengerBooking {
  const _PassengerBooking({
    required this.requestId,
    required this.request,
    required this.profile,
  });

  final String requestId;
  final Map<String, dynamic>? request;
  final Map<String, dynamic>? profile;
}

class _PassengerBookingTile extends StatelessWidget {
  const _PassengerBookingTile({required this.booking});

  final _PassengerBooking booking;

  @override
  Widget build(BuildContext context) {
    final request = booking.request;
    if (request == null) {
      return const Text('Passenger booking unavailable.');
    }

    final name = (booking.profile?['name'] ?? 'Passenger').toString();
    final photo = (booking.profile?['profilePic'] ?? '').toString();
    final destination =
        (request['dropoffAddress'] ??
                request['dropoffName'] ??
                'Destination unavailable')
            .toString();
    final count = request['passengerCount'];
    final seats = count is num ? count.toInt() : 1;
    final fareSen = request['fareShareSen'];
    final fare = fareSen is num
        ? 'RM ${(fareSen / 100).toStringAsFixed(2)}'
        : 'Unavailable';
    final status = (request['status'] ?? 'Unavailable').toString();
    final statusText = status == 'completed' || status == 'drop_off_confirmed'
        ? 'Completed'
        : status.replaceAll('_', ' ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: RPColors.teal,
              child: CircleAvatar(
                radius: 23,
                backgroundColor: Colors.white,
                backgroundImage: photo.isNotEmpty ? NetworkImage(photo) : null,
                child: photo.isEmpty
                    ? const Icon(Icons.person, color: RPColors.teal, size: 30)
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (statusText == 'Completed')
              const Icon(
                Icons.check_circle,
                color: Color(0xFF23834B),
                size: 20,
              ),
          ],
        ),
        const SizedBox(height: 12),
        _bookingLine('Destination', destination),
        _bookingLine('Seats booked', '$seats'),
        _bookingLine('Booking fare', fare),
        _bookingLine('Status', statusText),
      ],
    );
  }

  Widget _bookingLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 105,
            child: Text(
              label,
              style: const TextStyle(color: RPColors.textGrey, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

class _PassengerDriverCard extends StatelessWidget {
  const _PassengerDriverCard({required this.groupId});

  final String groupId;

  Future<Map<String, dynamic>?> _loadDriverProfile(String driverId) async {
    final callable = FirebaseFunctions.instanceFor(region: 'asia-southeast1')
        .httpsCallable('getTripParticipantProfiles');

    final response = await callable.call(<String, dynamic>{'tripId': groupId});

    final data = Map<String, dynamic>.from(response.data as Map);
    final profiles = Map<String, dynamic>.from(data['profiles'] as Map);

    final driver = profiles[driverId];

    return driver is Map ? Map<String, dynamic>.from(driver) : null;
  }

  @override
  Widget build(BuildContext context) {
    if (groupId.isEmpty) {
      return const _DriverUnavailable();
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('trips')
          .doc(groupId)
          .snapshots(),
      builder: (context, tripSnapshot) {
        if (tripSnapshot.hasError) {
          return const _DriverUnavailable(
            message: 'Unable to load driver information.',
          );
        }

        if (!tripSnapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final driverId = (tripSnapshot.data!.data()?['driverId'] ?? '')
            .toString();

        if (driverId.isEmpty) {
          return const _DriverUnavailable();
        }

        return FutureBuilder<Map<String, dynamic>?>(
          future: _loadDriverProfile(driverId),
          builder: (context, driverSnapshot) {
            if (driverSnapshot.hasError) {
              return const _DriverUnavailable(
                message: 'Unable to load driver profile.',
              );
            }

            if (driverSnapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }

            if (driverSnapshot.data == null) {
              return const _DriverUnavailable();
            }
            final driver = driverSnapshot.data;
            final name = (driver?['name'] ?? 'Your Driver').toString();
            final photo = (driver?['profilePic'] ?? '').toString();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'YOUR DRIVER',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: RPColors.teal,
                      child: CircleAvatar(
                        radius: 25,
                        backgroundColor: Colors.white,
                        backgroundImage: photo.isNotEmpty
                            ? NetworkImage(photo)
                            : null,
                        child: photo.isEmpty
                            ? const Icon(
                                Icons.person,
                                color: RPColors.teal,
                                size: 34,
                              )
                            : null,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Your driver for this trip',
                            style: TextStyle(
                              color: RPColors.textGrey,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _DriverUnavailable extends StatelessWidget {
  const _DriverUnavailable({this.message = 'Driver information unavailable.'});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'YOUR DRIVER',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(message, style: const TextStyle(color: RPColors.textGrey)),
      ],
    );
  }
}

DateTime _rideDate(Map<String, dynamic> data) {
  for (final key in [
    'droppedOffAt',
    'completedAt',
    'departureTime',
    'createdAt',
  ]) {
    final value = data[key];
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}

String _formatDate(DateTime date) {
  if (date.millisecondsSinceEpoch == 0) return 'Date unavailable';
  final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
  final minute = date.minute.toString().padLeft(2, '0');
  final suffix = date.hour < 12 ? 'AM' : 'PM';
  return '${date.day}/${date.month}/${date.year}, $hour:$minute $suffix';
}
