import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:firebase_auth/firebase_auth.dart';

import 'package:flutter/material.dart';

import 'package:cloud_functions/cloud_functions.dart';

import 'live_trip_map.dart';

import 'cancel_ride_screen.dart';
import 'passenger_home.dart' show RPColors;
import 'share_trip_sheet.dart';
import 'sos_dialog.dart';
import 'trip_eta_card.dart';

/// Displays the live trip screen for a driver, including trip state updates and
/// the actions needed to manage pickup, drop-off, and cancellation.
class DriverRideScreen extends StatelessWidget {
  const DriverRideScreen({super.key, this.requestId});

  final String? requestId;

  static const Set<String> _activeRequestStatuses = {
    'driver_assigned',

    'driver_arrived',

    'in_progress',
  };

  /// Advances a trip to its next lifecycle state after the driver confirms
  /// pickup or trip start in the backend.
  Future<void> _advanceTrip(
    BuildContext context, {
    required String tripId,
    required String expectedStatus,
    required String nextStatus,
  }) async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Please log in again.')));
      return;
    }

    try {
      final functions = FirebaseFunctions.instanceFor(
        region: 'asia-southeast1',
      );

      final callable = functions.httpsCallable('advanceDriverTrip');

      await callable.call({
        'tripId': tripId,
        'expectedStatus': expectedStatus,
        'nextStatus': nextStatus,
      });

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            nextStatus == 'driver_arrived'
                ? 'You have arrived at the pickup hub.'
                : 'Trip started successfully.',
          ),
        ),
      );
    } on FirebaseFunctionsException catch (error) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Unable to update trip: ${error.message ?? error.code}',
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Unable to update trip: $error')));
    }
  }

  /// Confirms a passenger has been dropped off and closes the trip step when
  /// the backend accepts the driver's completion action.
  Future<void> _confirmDropOff(
    BuildContext context, {
    required String tripId,
    required String requestId,
  }) async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Please log in again.')));
      return;
    }

    try {
      final functions = FirebaseFunctions.instanceFor(
        region: 'asia-southeast1',
      );

      final callable = functions.httpsCallable('confirmPassengerDropOff');

      final result = await callable.call<Map<String, dynamic>>({
        'tripId': tripId,
        'requestId': requestId,
      });

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.data['tripCompleted'] == true
                ? 'All passenger drop-offs confirmed. Trip completed.'
                : 'Passenger drop-off confirmed.',
          ),
        ),
      );
    } on FirebaseFunctionsException catch (error) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Unable to confirm drop-off: ${error.message ?? error.code}',
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to confirm drop-off: $error')),
      );
    }
  }

  /// Opens the cancellation flow for the current trip and closes the screen if
  /// the backend successfully marks the trip as cancelled.
  Future<void> _cancelTrip(
    BuildContext context, {
    required String tripId,
    required String requestId,
  }) async {
    final cancelled = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CancelRideScreen(
          isDriver: true,
          requestId: requestId,
          tripId: tripId,
        ),
      ),
    );
    if (cancelled == true && context.mounted) {
      Navigator.of(context).maybePop();
    }
  }

  Widget _noActiveTripState() {
    const message = Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No active trip found.\n\nAccept a ride request to see your trip here.',
          textAlign: TextAlign.center,
        ),
      ),
    );
    if (requestId == null || requestId!.isEmpty) return message;

    final db = FirebaseFirestore.instance;
    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: db.collection('ride_requests').doc(requestId).get(),
      builder: (context, requestSnapshot) {
        if (requestSnapshot.hasError) {
          return Center(
            child: Text(
              'Unable to verify trip status: ${requestSnapshot.error}',
            ),
          );
        }
        if (!requestSnapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final tripId = requestSnapshot.data!.data()?['groupId']?.toString();
        if (tripId == null || tripId.isEmpty) return message;

        return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          future: db.collection('trips').doc(tripId).get(),
          builder: (context, tripSnapshot) {
            if (tripSnapshot.hasError) {
              return Center(
                child: Text(
                  'Unable to verify trip status: ${tripSnapshot.error}',
                ),
              );
            }
            if (!tripSnapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            if (tripSnapshot.data!.data()?['status'] != 'completed') {
              return message;
            }
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      size: 48,
                      color: RPColors.teal,
                    ),
                    SizedBox(height: 12),
                    Text(
                      'Trip completed.\nAll passenger drop-offs are confirmed.',
                      textAlign: TextAlign.center,
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
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      initialData: FirebaseAuth.instance.currentUser,
      builder: (context, authSnapshot) {
        final user = authSnapshot.data;
        if (user == null) {
          return const Scaffold(
            body: Center(
              child: Text('Please log in to view your active trip.'),
            ),
          );
        }
        return _buildForUser(context, user);
      },
    );
  }

  Widget _buildForUser(BuildContext context, User user) {
    return Scaffold(
      backgroundColor: RPColors.bg,
      appBar: AppBar(title: const Text('Ride Details')),
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
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final activeTrips = snapshot.data!.docs.where((doc) {
            return const {
              'driver_assigned',
              'driver_arrived',
              'in_progress',
            }.contains(doc.data()['status']);
          }).toList();
          if (activeTrips.isEmpty) {
            return _noActiveTripState();
          }
          // Prefer the trip explicitly requested, when it is active.
          final selected = activeTrips.where((doc) {
            final ids = List<String>.from(doc.data()['requestIds'] ?? []);
            return requestId != null && ids.contains(requestId);
          });
          final tripDoc = selected.isNotEmpty
              ? selected.first
              : activeTrips.first;
          final tripData = tripDoc.data();
          final tripId = tripDoc.id;
          final requestIds = List<String>.from(tripData['requestIds'] ?? []);
          final status = tripData['status']?.toString() ?? '';

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
                flex: 4,
                child: _ActiveTripPanel(
                  tripData: tripData,
                  tripId: tripId,
                  requestIds: requestIds,
                  onConfirmDropOff: (id) =>
                      _confirmDropOff(context, tripId: tripId, requestId: id),
                  onArrived: () => _advanceTrip(
                    context,
                    tripId: tripId,
                    expectedStatus: 'driver_assigned',
                    nextStatus: 'driver_arrived',
                  ),
                  onStartTrip: () => _advanceTrip(
                    context,
                    tripId: tripId,
                    expectedStatus: 'driver_arrived',
                    nextStatus: 'in_progress',
                  ),
                  onCancel: () => _cancelTrip(
                    context,
                    tripId: tripId,
                    requestId: requestIds.first,
                  ),
                  canCancel:
                      requestIds.isNotEmpty &&
                      (status == 'driver_assigned' ||
                          status == 'driver_arrived'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ActiveTripPanel extends StatelessWidget {
  const _ActiveTripPanel({
    required this.tripData,
    required this.tripId,
    required this.requestIds,
    required this.onConfirmDropOff,
    required this.onArrived,
    required this.onStartTrip,
    required this.onCancel,
    required this.canCancel,
  });

  final Map<String, dynamic> tripData;
  final String tripId;
  final List<String> requestIds;
  final ValueChanged<String> onConfirmDropOff;
  final VoidCallback onArrived;
  final VoidCallback onStartTrip;
  final VoidCallback onCancel;
  final bool canCancel;

  Future<void> _shareTrip(BuildContext context, String pickup) async {
    try {
      final requests = await Future.wait(
        requestIds.map((id) async {
          try {
            return await FirebaseFirestore.instance
                .collection('ride_requests')
                .doc(id)
                .get();
          } on FirebaseException catch (error) {
            debugPrint(
              'Share Trip ride_requests/$id read failed for trip=$tripId: '
              '${error.code}',
            );
            rethrow;
          }
        }),
      );
      final destinations = requests
          .map((request) {
            final data = request.data();
            if (data == null || data['groupId'] != tripId) return null;
            return (data['dropoffAddress'] ?? data['dropoffName'])
                ?.toString()
                .trim();
          })
          .whereType<String>()
          .where((destination) => destination.isNotEmpty)
          .toSet()
          .toList();

      if (destinations.isEmpty) {
        throw StateError('No destinations are linked to this trip.');
      }

      // Use the trip's shared name; participants cannot read the driver's profile.
      final tripDriverName = tripData['driverName'];
      final driverName =
          tripDriverName is String && tripDriverName.trim().isNotEmpty
          ? tripDriverName.trim()
          : 'Assigned Driver';

      if (!context.mounted) return;
      await showShareTripSheet(
        context,
        pickupName: pickup,
        destination: destinations.join('\n'),
        driverName: driverName,
        tripId: tripId,
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to prepare trip details: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = tripData['status']?.toString() ?? 'unknown';
    final pickup =
        (tripData['pickupName'] ??
                tripData['pickupAddress'] ??
                'Pickup location')
            .toString();
    final optimizedOrder = List<String>.from(
      tripData['optimizedDropoffOrder'] ?? [],
    );
    final displayOrder = <String>{
      ...optimizedOrder.where(requestIds.contains),
      ...requestIds.where((id) => !optimizedOrder.contains(id)),
    }.toList();
    final totalFareSen = tripData['totalFareSen'];
    final totalPassengers = tripData['totalPassengers'];

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF7F9FA),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: TripEtaEstimates(
        tripId: tripId,
        tripData: tripData,
        builder: (context, estimates) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _sectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionTitle(
                    icon: Icons.route,
                    text: 'YOUR ACTIVE TRIP',
                  ),
                  const SizedBox(height: 14),
                  _detail('Status', _readableStatus(status)),
                  _detail('Pickup', pickup),
                  if (status == 'driver_assigned')
                    _detail(
                      'Estimated arrival',
                      estimates.pickupEta ??
                          estimates.message ??
                          'Calculating…',
                    ),
                  _detail('Passenger bookings', '${requestIds.length}'),
                  if (totalPassengers != null)
                    _detail('Total passengers', '$totalPassengers'),
                  _detail('Total trip fare', _formatFare(totalFareSen)),
                  const SizedBox(height: 12),
                  if (status == 'driver_assigned')
                    _actionButton(
                      "I've Arrived",
                      Icons.location_on_outlined,
                      onArrived,
                    ),
                  if (status == 'driver_arrived')
                    _actionButton('Start Trip', Icons.play_arrow, onStartTrip),
                  if (status == 'in_progress')
                    const Chip(
                      avatar: Icon(Icons.directions_car, color: RPColors.teal),
                      label: Text('Trip in progress'),
                    ),
                  if (canCancel) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: onCancel,
                        icon: const Icon(Icons.cancel_outlined),
                        label: const Text('Cancel Trip'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _shareTrip(context, pickup),
                          icon: const Icon(Icons.share_outlined),
                          label: const Text('Share Trip'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              showSosDialog(context, tripId: tripId),
                          icon: const Icon(Icons.sos, color: RPColors.danger),
                          label: const Text('SOS'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: RPColors.danger,
                            side: const BorderSide(color: RPColors.danger),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const _SectionTitle(
              icon: Icons.alt_route,
              text: 'OPTIMIZED DROP-OFF ROUTE',
            ),
            const SizedBox(height: 6),
            const Text(
              'Passenger cards follow the saved optimized route order.',
              style: TextStyle(color: RPColors.textGrey, fontSize: 12),
            ),
            const SizedBox(height: 10),
            if (displayOrder.isEmpty)
              _sectionCard(
                child: const Text('No linked passenger requests found.'),
              )
            else
              _OptimizedPassengerCards(
                requestIds: displayOrder,
                tripStatus: status,
                stopEtas: estimates.stopEtas,
                onConfirmDropOff: onConfirmDropOff,
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _OptimizedPassengerCards extends StatelessWidget {
  const _OptimizedPassengerCards({
    required this.requestIds,
    required this.tripStatus,
    required this.stopEtas,
    required this.onConfirmDropOff,
  });

  final List<String> requestIds;
  final String tripStatus;
  final Map<String, String> stopEtas;
  final ValueChanged<String> onConfirmDropOff;

  @override
  Widget build(BuildContext context) {
    // Watch all ride requests so that the NEXT STOP changes immediately
    // when a driver confirms a drop-off. One subscription per request.
    return Column(
      children: [
        for (var i = 0; i < requestIds.length; i++)
          _PassengerStopCard(
            key: ValueKey(requestIds[i]),
            requestId: requestIds[i],
            orderedRequestIds: requestIds,
            stopNumber: i + 1,
            tripStatus: tripStatus,
            eta: stopEtas[requestIds[i]],
            onConfirmDropOff: () => onConfirmDropOff(requestIds[i]),
          ),
      ],
    );
  }
}

class _PassengerStopCard extends StatelessWidget {
  const _PassengerStopCard({
    super.key,
    required this.requestId,
    required this.orderedRequestIds,
    required this.stopNumber,
    required this.tripStatus,
    required this.eta,
    required this.onConfirmDropOff,
  });

  final String requestId;
  final List<String> orderedRequestIds;
  final int stopNumber;
  final String tripStatus;
  final String? eta;
  final VoidCallback onConfirmDropOff;

  Stream<Map<String, Map<String, dynamic>>> _watchRequests(List<String> ids) {
    return Stream.multi((controller) {
      final requests = <String, Map<String, dynamic>>{};
      final loadedIds = <String>{};
      final subscriptions = <StreamSubscription>[];

      for (final id in ids) {
        final subscription = FirebaseFirestore.instance
            .collection('ride_requests')
            .doc(id)
            .snapshots()
            .listen(
              (snapshot) {
                loadedIds.add(id);

                final data = snapshot.data();

                if (data == null) {
                  requests.remove(id);
                } else {
                  requests[id] = data;
                }

                if (loadedIds.length == ids.length) {
                  controller.add(Map.of(requests));
                }
              },
              onError: (Object error, StackTrace stackTrace) {
                controller.addError(error, stackTrace);
              },
            );

        subscriptions.add(subscription);
      }

      controller.onCancel = () {
        for (final subscription in subscriptions) {
          subscription.cancel();
        }
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, Map<String, dynamic>>>(
      stream: _watchRequests(orderedRequestIds),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _sectionCard(child: Text('Unable to load stop $stopNumber.'));
        }
        if (!snapshot.hasData) {
          return _sectionCard(child: const LinearProgressIndicator());
        }
        final byId = snapshot.data!;
        final request = byId[requestId];
        if (request == null) {
          return _sectionCard(
            child: Text('Stop $stopNumber: request unavailable.'),
          );
        }
        final status = request['status']?.toString() ?? 'unknown';
        final droppedOff =
            status == 'drop_off_confirmed' || status == 'completed';
        final cancelled = status == 'cancelled';
        final nextId = orderedRequestIds.cast<String?>().firstWhere((id) {
          final s = byId[id]?['status'];
          return s != 'drop_off_confirmed' &&
              s != 'completed' &&
              s != 'cancelled';
        }, orElse: () => null);
        final nextStop = !droppedOff && !cancelled && nextId == requestId;
        final canDropOff =
            tripStatus == 'in_progress' &&
            nextStop &&
            DriverRideScreen._activeRequestStatuses.contains(status);
        final pickup =
            (request['pickupName'] ??
                    request['pickupAddress'] ??
                    'Pickup location')
                .toString();
        final destination =
            (request['dropoffAddress'] ??
                    request['dropoffName'] ??
                    'Destination')
                .toString();
        final passengerCount =
            request['passengerCount'] ?? request['totalPassengers'] ?? 1;
        final fare = _formatFare(request['fareShareSen']);
        final label = droppedOff
            ? 'DROPPED OFF'
            : cancelled
            ? 'CANCELLED'
            : nextStop && tripStatus == 'in_progress'
            ? 'NEXT STOP'
            : 'PENDING';
        final accent = droppedOff
            ? Colors.green.shade700
            : cancelled
            ? Colors.red.shade700
            : RPColors.teal;

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          color: Colors.white,
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: accent.withValues(alpha: 0.25)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: accent.withValues(alpha: 0.10),
                      child: Text(
                        '$stopNumber',
                        style: TextStyle(
                          color: accent,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'PASSENGER STOP $stopNumber',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: RPColors.teal,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 11,
                        color: accent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const Divider(height: 24),
                _detail('Pickup', pickup),
                _detail('Destination', destination),
                _detail('Passengers', '$passengerCount'),
                _detail('Fare owed', fare),
                if (eta != null &&
                    const {
                      'driver_arrived',
                      'in_progress',
                    }.contains(tripStatus))
                  _detail('Estimated time', eta!),
                _detail('Status', _readableStatus(status)),
                if (droppedOff) ...[
                  const SizedBox(height: 8),
                  const Row(
                    children: [
                      Icon(Icons.check_circle, color: Colors.green, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Passenger dropped off',
                        style: TextStyle(
                          color: Colors.green,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
                if (tripStatus == 'in_progress' &&
                    !droppedOff &&
                    !cancelled) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: canDropOff
                          ? () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (dialogContext) => AlertDialog(
                                  title: const Text(
                                    'Confirm Passenger Drop-off',
                                  ),
                                  content: Text(
                                    'Has this passenger arrived at $destination?',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext, false),
                                      child: const Text('Cancel'),
                                    ),
                                    ElevatedButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext, true),
                                      child: const Text('Confirm'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed == true && context.mounted) {
                                onConfirmDropOff();
                              }
                            }
                          : null,
                      icon: const Icon(Icons.location_on_outlined),
                      label: Text(
                        canDropOff
                            ? 'Confirm Drop-off'
                            : 'Waiting for previous stop',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: RPColors.teal,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

Widget _sectionCard({required Widget child}) {
  return Card(
    margin: EdgeInsets.zero,
    color: Colors.white,
    elevation: 1,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, color: RPColors.teal, size: 20),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          text,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: RPColors.teal,
            fontSize: 13,
          ),
        ),
      ),
    ],
  );
}

Widget _detail(String label, String value) => Padding(
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
          value,
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

Widget _actionButton(String text, IconData icon, VoidCallback onPressed) =>
    SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(text),
        style: ElevatedButton.styleFrom(
          backgroundColor: RPColors.teal,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(46),
        ),
      ),
    );

String _formatFare(dynamic sen) =>
    sen is num ? 'RM ${(sen / 100).toStringAsFixed(2)}' : 'Not available';

String _readableStatus(String status) {
  switch (status) {
    case 'driver_assigned':
      return 'Driver assigned';
    case 'driver_arrived':
      return 'Driver arrived';
    case 'in_progress':
      return 'In progress';
    case 'drop_off_confirmed':
      return 'Dropped off';
    case 'completed':
      return 'Completed';
    case 'cancelled':
      return 'Cancelled';
    default:
      return status.replaceAll('_', ' ');
  }
}
