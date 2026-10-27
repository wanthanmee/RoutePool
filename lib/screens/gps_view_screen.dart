import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'form_widgets.dart' show rpAppBar;
import 'live_trip_map.dart';
import 'passenger_home.dart' show RPColors;
import 'share_trip_sheet.dart';
import 'sos_dialog.dart';

/// Combines a live trip map with the trip's current route and fare details.
class GpsViewScreen extends StatelessWidget {
  /// Creates the live trip view for [tripId].
  ///
  /// Set [isDriver] to true to show driver-specific navigation labels.
  const GpsViewScreen({super.key, required this.tripId, this.isDriver = false});

  final String tripId;
  final bool isDriver;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RPColors.cardBg,
      appBar: rpAppBar('Live GPS'),
      body: Column(
        children: [
          Expanded(
            child: LiveTripMap(tripId: tripId, isDriver: isDriver),
          ),
          _TripInfoPanel(tripId: tripId, isDriver: isDriver),
        ],
      ),
    );
  }
}

/// Streams trip information and displays its route, status, and fare summary.
class _TripInfoPanel extends StatelessWidget {
  const _TripInfoPanel({required this.tripId, required this.isDriver});

  final String tripId;
  final bool isDriver;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('trips')
          .doc(tripId)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Padding(
            padding: EdgeInsets.all(20),
            child: Text('Unable to load trip information.'),
          );
        }

        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const Padding(
            padding: EdgeInsets.all(20),
            child: CircularProgressIndicator(),
          );
        }

        final data = snapshot.data!.data() ?? {};
        final status = data['status'] as String? ?? 'unknown';
        final pickup = data['pickupName'] as String? ?? 'Pickup location';
        final dropoff =
            data['dropoffAddress'] as String? ?? 'Drop-off location';

        final passengers = data['totalPassengers'] as num? ?? 0;
        final fareSen = data['totalFareSen'] as num? ?? 0;
        final fare = (fareSen / 100).toStringAsFixed(2);

        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        isDriver ? 'Driver Navigation' : 'Your Shared Ride',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: RPColors.textDark,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: RPColors.teal.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        status.replaceAll('_', ' ').toUpperCase(),
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: RPColors.teal,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _LocationRow(
                  icon: Icons.trip_origin,
                  color: RPColors.teal,
                  label: 'Pickup',
                  value: pickup,
                ),
                const SizedBox(height: 8),
                _LocationRow(
                  icon: Icons.location_on,
                  color: RPColors.orange,
                  label: 'Drop-off',
                  value: dropoff,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(
                      Icons.people_outline,
                      color: RPColors.textGrey,
                      size: 20,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${passengers.toInt()} passengers',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const Spacer(),
                    const Icon(
                      Icons.payments_outlined,
                      color: RPColors.textGrey,
                      size: 20,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'RM $fare total',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => showShareTripSheet(context),
                        icon: const Icon(Icons.share_outlined),
                        label: const Text('Share Trip'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => showSosDialog(context),
                        icon: const Icon(Icons.sos, color: RPColors.danger),
                        label: const Text('SOS'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Displays a labeled pickup or drop-off value with its matching map icon.
class _LocationRow extends StatelessWidget {
  const _LocationRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 8),
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: RPColors.textGrey),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: RPColors.textDark,
            ),
          ),
        ),
      ],
    );
  }
}
