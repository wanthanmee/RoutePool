import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../services/fare_calculator.dart';

/// Watches the ride request document and displays its live status.
class RideMatchingScreen extends StatelessWidget {
  const RideMatchingScreen({super.key, required this.requestId});

  final String requestId;

  static const Color teal = Color(0xFF0F5C5F);
  static const Color orange = Color(0xFFF5A623);

  /// Updates the ride request with the passenger's choice.
  Future<void> _chooseRideOption(BuildContext context, String choice) async {
    final requestRef = FirebaseFirestore.instance
        .collection('ride_requests')
        .doc(requestId);

    try {
      await FirebaseFirestore.instance.runTransaction((transaction) async {
        final snapshot = await transaction.get(requestRef);

        if (!snapshot.exists) {
          throw Exception('Ride request not found.');
        }

        final data = snapshot.data()!;

        if (data['status'] != 'awaiting_choice') {
          throw Exception('This request is no longer waiting for your choice.');
        }

        if (choice == 'solo') {
          transaction.update(requestRef, {
            'status': 'solo_requested',
            'matchingChoice': 'solo',
            'updatedAt': FieldValue.serverTimestamp(),
          });
        } else {
          final now = DateTime.now();

          transaction.update(requestRef, {
            'status': 'searching',
            'searchStartedAt': Timestamp.fromDate(now),
            'searchExpiresAt': Timestamp.fromDate(
              now.add(const Duration(minutes: 5)),
            ),
            'matchingChoice': 'shared',
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      });
    } catch (e) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not update your ride: $e')));
    }
  }

  /// Cancels a booking while passenger/driver matching is still underway.
  Future<void> _cancelBooking(BuildContext context) async {
    final shouldCancel = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel booking?'),
        content: const Text('Are you sure you want to cancel this booking?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep Booking'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Cancel Booking'),
          ),
        ],
      ),
    );

    if (shouldCancel != true || !context.mounted) return;

    try {
      final callable = FirebaseFunctions.instanceFor(region: 'asia-southeast1')
          .httpsCallable('cancelRideBooking');

      await callable.call({'requestId': requestId});

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Booking cancelled successfully.')),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Could not cancel your booking.')),
      );
    } catch (e) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Something went wrong. Please try again.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F8),
      appBar: AppBar(
        title: const Text('Finding Your Ride'),
        backgroundColor: Colors.white,
        foregroundColor: teal,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Return to main screen',
          onPressed: () {
            Navigator.of(context).popUntil((route) => route.isFirst);
          },
        ),
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('ride_requests')
            .doc(requestId)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('Unable to load your request.'));
          }

          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const Center(child: Text('Ride request not found.'));
          }

          final data = snapshot.data!.data();

          if (data == null) {
            return const Center(child: Text('Ride request not found.'));
          }

          debugPrint('[Matching UI] Request ID: $requestId');
          debugPrint('[Matching UI] Current status: ${data['status']}');

          return _buildBody(context, data);
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, Map<String, dynamic> data) {
    final status = data['status'] as String? ?? 'searching';
    final pickup = data['pickupName'] as String? ?? 'Pickup hub';
    final dropoff = data['dropoffAddress'] as String? ?? 'Destination';

    final departure = data['departureTime'];
    final searchExpiresAt = data['searchExpiresAt'];

    final myPassengers = (data['passengerCount'] as num?)?.toInt() ?? 1;

    final tripPassengers = (data['tripPassengers'] as num?)?.toInt();

    final shareSen = (data['fareShareSen'] as num?)?.toInt();
    final soloSen = (data['soloFareSen'] as num?)?.toInt();

    final others = tripPassengers == null
        ? 0
        : (tripPassengers - myPassengers).clamp(0, 999);

    final (title, subtitle) = switch (status) {
      'searching' => (
        'Finding your RoutePool',
        'Looking for passengers heading the same way.',
      ),
      'awaiting_choice' => (
        'No passengers found yet',
        'Your 5-minute search has ended. You can try a solo ride or search again.',
      ),
      'solo_requested' => (
        'Finding a solo driver',
        'We are looking for a driver for your individual ride.',
      ),
      'matching_driver' => (
        'Waiting for a driver',
        others > 0
            ? 'Sharing with $others other passenger${others == 1 ? '' : 's'}. We are finding a driver for your group.'
            : 'No one to share with yet. We are finding you a driver.',
      ),
      'driver_assigned' => (
        'Driver found!',
        'Your driver is on the way to the pickup hub.',
      ),
      'in_progress' => ('Ride in progress', 'Enjoy your trip.'),
      'completed' => ('Ride completed', 'Thanks for riding with RoutePool.'),
      'cancelled' => (
        'Request cancelled',
        'This ride request is no longer active.',
      ),
      _ => ('Finding your RoutePool', 'Please wait while we update your ride.'),
    };

    final stage = switch (status) {
      'searching' || 'awaiting_choice' => 0,
      'solo_requested' || 'matching_driver' => 1,
      'driver_assigned' => 2,
      'in_progress' || 'completed' => 3,
      _ => 0,
    };

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // Status banner
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: status == 'cancelled' ? Colors.red.shade700 : teal,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.alt_route, color: Colors.white, size: 34),
              const SizedBox(height: 12),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: const TextStyle(color: Colors.white70, height: 1.4),
              ),
            ],
          ),
        ),

        // Passenger matching countdown
        if (status == 'searching' && searchExpiresAt is Timestamp) ...[
          const SizedBox(height: 18),
          _card(child: _SearchCountdown(expiresAt: searchExpiresAt)),
        ],

        const SizedBox(height: 18),

        // Trip details
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'YOUR TRIP',
                style: TextStyle(
                  color: teal,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.trip_origin, color: teal),
                  const SizedBox(width: 10),
                  Expanded(child: Text(pickup)),
                ],
              ),
              const Padding(
                padding: EdgeInsets.only(left: 11),
                child: SizedBox(
                  height: 24,
                  child: VerticalDivider(color: Colors.grey, thickness: 1.5),
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.location_on, color: Colors.red),
                  const SizedBox(width: 10),
                  Expanded(child: Text(dropoff)),
                ],
              ),
              if (departure is Timestamp) ...[
                const SizedBox(height: 16),
                Text(
                  'Departure: '
                  '${MaterialLocalizations.of(context).formatFullDate(departure.toDate())} at '
                  '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(departure.toDate()))}',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ],
            ],
          ),
        ),

        // Fare details
        if (shareSen != null) ...[
          const SizedBox(height: 18),
          _card(
            child: Row(
              children: [
                const Icon(Icons.payments_outlined, color: teal),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Your fare',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (soloSen != null && soloSen > shareSen) ...[
                  Text(
                    FareCalculator.format(soloSen),
                    style: const TextStyle(
                      color: Colors.black45,
                      decoration: TextDecoration.lineThrough,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(
                  FareCalculator.format(shareSen),
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                    color: teal,
                  ),
                ),
              ],
            ),
          ),
        ],

        // Choices after passenger matching times out
        if (status == 'awaiting_choice') ...[
          const SizedBox(height: 18),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.people_outline, color: teal, size: 36),
                const SizedBox(height: 12),
                const Text(
                  'No passengers found yet',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: teal,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'We could not find compatible passengers within '
                  'five minutes. What would you like to do?',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.black54, height: 1.5),
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: () => _chooseRideOption(context, 'solo'),
                  icon: const Icon(Icons.person_outline),
                  label: const Text('Try a solo ride'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: teal,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => _chooseRideOption(context, 'shared'),
                  icon: const Icon(Icons.people_outline),
                  label: const Text('Search again for 5 minutes'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: teal,
                    side: const BorderSide(color: teal),
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ],
            ),
          ),
        ],

        // Ride progress
        const SizedBox(height: 18),
        _card(
          child: Column(
            children: [
              _stage(
                0,
                stage,
                '1. Finding passengers',
                'Matching you with others heading the same way.',
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Divider(),
              ),
              _stage(
                1,
                stage,
                '2. Finding a driver',
                'Drivers nearby are being notified.',
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Divider(),
              ),
              _stage(
                2,
                stage,
                '3. Driver on the way',
                'Track your ride from the Rides tab.',
              ),
            ],
          ),
        ),

        const SizedBox(height: 18),

        if ({
          'searching',
          'awaiting_choice',
          'solo_requested',
          'matching_driver',
        }.contains(status)) ...[
          OutlinedButton.icon(
            onPressed: () => _cancelBooking(context),
            icon: const Icon(Icons.cancel_outlined),
            label: const Text('Cancel Booking'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.red,
              side: const BorderSide(color: Colors.red),
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ],
      ],
    );
  }

  /// Reusable white card.
  Widget _card({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }

  /// Displays an individual ride-progress stage.
  Widget _stage(int number, int current, String title, String subtitle) {
    final isComplete = current > number;
    final isCurrent = current == number;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 19,
          backgroundColor: isComplete || isCurrent
              ? teal
              : Colors.grey.shade300,
          child: isCurrent
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Icon(
                  isComplete ? Icons.check : Icons.circle,
                  size: isComplete ? 21 : 10,
                  color: Colors.white,
                ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: isCurrent || isComplete ? teal : Colors.black54,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(color: Colors.black54, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Displays the remaining passenger-matching time.
class _SearchCountdown extends StatefulWidget {
  const _SearchCountdown({required this.expiresAt});

  final Timestamp expiresAt;

  @override
  State<_SearchCountdown> createState() => _SearchCountdownState();
}

class _SearchCountdownState extends State<_SearchCountdown> {
  Timer? _timer;
  late Duration _remaining;

  @override
  void initState() {
    super.initState();
    _updateRemaining();

    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _updateRemaining(),
    );
  }

  void _updateRemaining() {
    final remaining = widget.expiresAt.toDate().difference(DateTime.now());

    if (!mounted) return;

    setState(() {
      _remaining = remaining.isNegative ? Duration.zero : remaining;
    });
  }

  @override
  void didUpdateWidget(covariant _SearchCountdown oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.expiresAt != widget.expiresAt) {
      _updateRemaining();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final minutes = _remaining.inMinutes;
    final seconds = _remaining.inSeconds % 60;

    final time =
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';

    return Row(
      children: [
        const Icon(Icons.timer_outlined, color: RideMatchingScreen.teal),
        const SizedBox(width: 10),
        const Expanded(
          child: Text(
            'Time remaining',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Text(
          time,
          style: const TextStyle(
            color: RideMatchingScreen.teal,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}
