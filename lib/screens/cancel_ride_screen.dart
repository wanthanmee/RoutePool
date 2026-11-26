import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'form_widgets.dart' show RPFieldLabel, rpAppBar, rpInputDecoration;
import 'passenger_home.dart' show RPColors;
import 'ride_widgets.dart';

// ------------------------------------------------------------
// Cancellation Reasons
// ------------------------------------------------------------

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

// ------------------------------------------------------------
// Cancel Ride Screen
// ------------------------------------------------------------

/// Displays the cancellation form for passengers and drivers.
///
/// Passenger and driver cancellations are processed through Firebase
/// Cloud Functions.
///
/// The Cloud Function updates the passenger's ride request
/// and its associated trip when necessary.
class CancelRideScreen extends StatefulWidget {
  const CancelRideScreen({
    super.key,
    required this.isDriver,
    required this.requestId,
    this.tripId,
  });

  /// Determines whether the user is a driver.
  final bool isDriver;

  /// Firestore ID of the ride request being cancelled.
  final String requestId;

  /// Required for driver cancellations; passenger cancellations use requestId.
  final String? tripId;

  @override
  State<CancelRideScreen> createState() => _CancelRideScreenState();
}

class _CancelRideScreenState extends State<CancelRideScreen> {
  // ----------------------------------------------------------
  // State Variables
  // ----------------------------------------------------------

  List<String> get _reasons =>
      widget.isDriver ? _driverReasons : _passengerReasons;

  final TextEditingController _details = TextEditingController();

  String? _reason;

  bool _submitting = false;

  // ----------------------------------------------------------
  // Dispose
  // ----------------------------------------------------------

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  // ----------------------------------------------------------
  // Submit Cancellation
  // ----------------------------------------------------------

  /// Sends the cancellation request to Firebase Cloud Functions.
  ///
  /// The backend validates the caller and trip state, then either removes
  /// the passenger booking or returns the assigned trip to driver matching.
  Future<void> _submit() async {
    // Prevent duplicate submissions.
    if (_submitting) return;

    // Ensure a cancellation reason has been selected.
    if (_reason == null || _reason!.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a cancellation reason.')),
      );
      return;
    }

    // Validate the ride request ID.
    if (widget.requestId.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No valid ride request was found.')),
      );
      return;
    }

    if (widget.isDriver &&
        (widget.tripId == null || widget.tripId!.trim().isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No valid trip was found to cancel.')),
      );
      return;
    }

    // Validate additional details.
    final cancellationDetails = _details.text.trim();

    if (cancellationDetails.length > 1000) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Additional details must not exceed 1000 characters.'),
        ),
      );
      return;
    }

    setState(() {
      _submitting = true;
    });

    try {
      // ------------------------------------------------------
      // Connect to Firebase Cloud Functions
      // ------------------------------------------------------

      // Must match the region used in functions/index.js.
      final functions = FirebaseFunctions.instanceFor(
        region: 'asia-southeast1',
      );

      final callable = functions.httpsCallable(
        widget.isDriver ? 'cancelDriverTrip' : 'cancelRideBooking',
      );

      // ------------------------------------------------------
      // Send Cancellation Request
      // ------------------------------------------------------

      final result = await callable.call<Map<String, dynamic>>({
        if (widget.isDriver) 'tripId': widget.tripId!.trim(),
        if (!widget.isDriver) 'requestId': widget.requestId.trim(),
        'cancellationReason': _reason!.trim(),
        'cancellationDetails': cancellationDetails,
      });

      // ------------------------------------------------------
      // Check Cloud Function Response
      // ------------------------------------------------------

      final response = result.data;

      if (response['success'] != true) {
        throw Exception('The cancellation could not be completed.');
      }

      // Ensure the screen still exists.
      if (!mounted) return;

      // Return to the previous screen.
      //
      // The previous screen receives true to indicate
      // that the cancellation was successful.
      Navigator.of(context).pop(true);
    } on FirebaseFunctionsException catch (e) {
      // ------------------------------------------------------
      // Handle Firebase Cloud Function Errors
      // ------------------------------------------------------

      if (!mounted) return;

      String errorMessage;

      switch (e.code) {
        case 'unauthenticated':
          errorMessage = 'Please sign in before cancelling your ride.';
          break;

        case 'permission-denied':
          errorMessage = 'You do not have permission to cancel this ride.';
          break;

        case 'not-found':
          errorMessage = 'This ride request could not be found.';
          break;

        case 'failed-precondition':
          errorMessage = e.message ?? 'This ride can no longer be cancelled.';
          break;

        case 'invalid-argument':
          errorMessage = e.message ?? 'Invalid cancellation information.';
          break;

        case 'unavailable':
          errorMessage = 'Unable to connect to the server. Please try again.';
          break;

        default:
          errorMessage =
              e.message ?? 'Unable to cancel your ride. Please try again.';
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMessage),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } catch (e) {
      // ------------------------------------------------------
      // Handle Unexpected Errors
      // ------------------------------------------------------

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not cancel ride: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      // Re-enable the button after the operation finishes.
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  // ----------------------------------------------------------
  // Build UI
  // ----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final canSubmit = _reason != null && !_submitting;

    return Scaffold(
      backgroundColor: RPColors.bg,
      appBar: rpAppBar(widget.isDriver ? 'Cancel Trip' : 'Cancel Ride'),

      body: ListView(
        padding: const EdgeInsets.all(16),

        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,

        children: [
          // --------------------------------------------------
          // Cancellation Reason Header
          // --------------------------------------------------

          const Text(
            'Please select a reason for cancellation',
            style: TextStyle(fontSize: 13, color: RPColors.textGrey),
          ),

          const SizedBox(height: 12),

          // --------------------------------------------------
          // Cancellation Reasons
          // --------------------------------------------------
          for (final reason in _reasons) ...[
            _ReasonTile(
              label: reason,
              selected: _reason == reason,
              onTap: () {
                if (_submitting) return;

                setState(() {
                  _reason = reason;
                });
              },
            ),

            const SizedBox(height: 8),
          ],

          const SizedBox(height: 8),

          // --------------------------------------------------
          // Additional Details
          // --------------------------------------------------
          const RPFieldLabel('Additional details'),

          TextField(
            controller: _details,
            maxLines: 4,
            maxLength: 1000,
            enabled: !_submitting,
            decoration: rpInputDecoration(hint: 'Tell us more...'),
          ),

          const SizedBox(height: 16),

          // --------------------------------------------------
          // Cancellation Policy
          // --------------------------------------------------
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

                const SizedBox(width: 10),

                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,

                    children: [
                      const Text(
                        'Cancellation Policy',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: RPColors.textDark,
                        ),
                      ),

                      const SizedBox(height: 2),

                      Text(
                        widget.isDriver
                            ? 'Frequent cancellations may affect driver '
                                  'rating or result in a penalty fee to '
                                  'maintain platform reliability.'
                            : 'If your driver is already on the way, a '
                                  'cancellation fee may apply. Frequent '
                                  'cancellations may also affect your '
                                  'account.',

                        style: const TextStyle(
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

          // --------------------------------------------------
          // Confirm Cancellation Button
          // --------------------------------------------------
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

// ------------------------------------------------------------
// Cancellation Reason Tile
// ------------------------------------------------------------

/// Displays an individual cancellation reason.
///
/// Highlights the selected reason using RoutePool's
/// primary teal colour.
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
  Widget build(BuildContext context) {
    return InkWell(
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
}
