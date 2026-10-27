import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'form_widgets.dart' show RPFieldLabel, rpAppBar, rpInputDecoration;

import 'passenger_home.dart' show RPColors;
import 'ride_widgets.dart';

const _driverReasons = [
  'Emergency',
  'Vehicle Issue',
  'Passenger No Show',
  'Other',
];

const _passengerReasons = [
  'Change of plans',
  'Driver is taking too long',
  'Found another ride',
  'Wrong pickup or drop-off',
  'Other',
];

/// Pops with `true` when the driver confirms the cancellation.
/// Presents role-specific cancellation reasons and records the selected reason.
class CancelRideScreen extends StatefulWidget {
  /// Creates the cancellation form for the specified request.
  const CancelRideScreen({
    super.key,
    required this.isDriver,
    required this.requestId,
  });

  /// Whether the person cancelling the ride is the driver.
  final bool isDriver;

  /// Firestore ID of the ride request to cancel.
  final String requestId;

  @override
  State<CancelRideScreen> createState() => _CancelRideScreenState();
}

/// Validates and submits the ride cancellation details.
class _CancelRideScreenState extends State<CancelRideScreen> {
  List<String> get _reasons =>
      widget.isDriver ? _driverReasons : _passengerReasons;

  final _details = TextEditingController();
  String? _reason;
  bool _submitting = false;

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  /// Updates the request to cancelled if it is still in a cancellable state.
  Future<void> _submit() async {
    if (_reason == null || _submitting) return;

    setState(() => _submitting = true);

    try {
      final requestRef = FirebaseFirestore.instance
          .collection('ride_requests')
          .doc(widget.requestId);

      await FirebaseFirestore.instance.runTransaction((transaction) async {
        final snapshot = await transaction.get(requestRef);

        if (!snapshot.exists) {
          throw Exception('Ride request not found.');
        }

        final data = snapshot.data()!;

        final status = data['status'] as String? ?? '';

        const cancellableStatuses = {
          'searching',
          'awaiting_choice',
          'solo_requested',
          'matching_driver',
          'matched',
          'driver_assigned',
        };

        if (!cancellableStatuses.contains(status)) {
          throw Exception(
            'This ride can no longer be cancelled '
            'from its current status.',
          );
        }

        transaction.update(requestRef, {
          'status': 'cancelled',
          'cancellationReason': _reason,
          'cancellationDetails': _details.text.trim(),
          'cancelledBy': widget.isDriver ? 'driver' : 'passenger',
          'cancelledAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });

      if (!mounted) return;

      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not cancel ride: $e')));
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = _reason != null && !_submitting;

    return Scaffold(
      backgroundColor: RPColors.bg,
      appBar: rpAppBar('Cancel Ride'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          const Text(
            'Please select a reason for cancellation',
            style: TextStyle(fontSize: 13, color: RPColors.textGrey),
          ),
          const SizedBox(height: 12),
          for (final r in _reasons) ...[
            _ReasonTile(
              label: r,
              selected: _reason == r,
              onTap: () => setState(() => _reason = r),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 8),
          const RPFieldLabel('Additional details'),
          TextField(
            controller: _details,
            maxLines: 4,
            decoration: rpInputDecoration(hint: 'Tell us more...'),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: RPColors.orange.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: RPColors.orange.withValues(alpha: 0.45),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: RPColors.orange,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Cancellation Policy',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: RPColors.textDark,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        widget.isDriver
                            ? 'Frequent cancellations may affect driver '
                                  'rating or result in a penalty fee to '
                                  'maintain platform reliability.'
                            : 'If your driver is already on the way, a '
                                  'cancellation fee may apply. Frequent '
                                  'cancellations may also affect your '
                                  'account.',
                        style: TextStyle(
                          fontSize: 11,
                          color: RPColors.textDark,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: canSubmit ? _submit : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: rpDangerDeep,
                foregroundColor: Colors.white,
                disabledBackgroundColor: rpDangerDeep.withValues(alpha: 0.4),
                disabledForegroundColor: Colors.white70,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _submitting
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'Confirm Cancellation',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Displays a selectable cancellation reason and optional supporting details.
class _ReasonTile extends StatelessWidget {
  const _ReasonTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(10),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: RPColors.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected ? RPColors.teal : RPColors.border,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: RPColors.textDark,
              ),
            ),
          ),
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? RPColors.teal : RPColors.textGrey,
                width: 1.5,
              ),
            ),
            child: selected
                ? Center(
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: RPColors.teal,
                        shape: BoxShape.circle,
                      ),
                    ),
                  )
                : null,
          ),
        ],
      ),
    ),
  );
}
