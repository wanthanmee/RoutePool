import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'form_widgets.dart' show rpAppBar;
import 'live_trip_map.dart';
import 'passenger_home.dart' show RPColors;
import 'share_trip_sheet.dart';
import 'sos_dialog.dart';
import 'trip_eta_card.dart';

/// Live GPS screen with a trip summary and real-time optimized drop-off cards.
/// Passengers can follow the route but cannot confirm drop-offs.
class GpsViewScreen extends StatefulWidget {
  const GpsViewScreen({super.key, required this.tripId, this.isDriver = false});

  final String tripId;
  final bool isDriver;

  @override
  State<GpsViewScreen> createState() => _GpsViewScreenState();
}

/// Tracks the authenticated user and the "live" trip session state for viewing
/// the active route while the user is signed in.
class _GpsViewScreenState extends State<GpsViewScreen> {
  StreamSubscription<User?>? _authSubscription;
  String? _ownerUid;
  bool _authChanged = false;

  @override
  void initState() {
    super.initState();
    _ownerUid = FirebaseAuth.instance.currentUser?.uid;
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user?.uid == _ownerUid || _authChanged) return;
      debugPrint(
        'Live GPS stopped for trip=${widget.tripId}: authenticated user '
        'changed from $_ownerUid to ${user?.uid}.',
      );
      if (mounted) setState(() => _authChanged = true);
    });
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_ownerUid == null || _authChanged) {
      return Scaffold(
        backgroundColor: RPColors.bg,
        appBar: rpAppBar('Live GPS'),
        body: const Center(
          child: Text('Please sign in again to view this trip.'),
        ),
      );
    }

    if (widget.tripId.trim().isEmpty) {
      return Scaffold(
        backgroundColor: RPColors.bg,
        appBar: rpAppBar('Live GPS'),
        body: const Center(child: Text('Trip information is unavailable.')),
      );
    }

    return Scaffold(
      backgroundColor: RPColors.bg,
      appBar: rpAppBar('Live GPS'),
      body: Column(
        children: [
          Expanded(
            flex: 3,
            child: LiveTripMap(
              tripId: widget.tripId,
              isDriver: widget.isDriver,
            ),
          ),
          Expanded(
            flex: 4,
            child: _TripInfoPanel(
              tripId: widget.tripId,
              isDriver: widget.isDriver,
            ),
          ),
        ],
      ),
    );
  }
}

/// Summarises the active trip status, participant checks, and actions that can
/// be taken while tracking a live route.
class _TripInfoPanel extends StatelessWidget {
  const _TripInfoPanel({required this.tripId, required this.isDriver});

  final String tripId;
  final bool isDriver;

  /// Normalises Firestore list values into a clean string ID list.
  List<String> _stringIds(dynamic value) {
    if (value is! List) return const [];
    return value.whereType<String>().where((id) => id.isNotEmpty).toList();
  }

  /// Builds the trip-share sheet using the trip metadata and linked requests so
  /// participants can send location details without exposing the driver's profile.
  Future<void> _shareTrip(
    BuildContext context,
    Map<String, dynamic> trip,
    String pickup,
  ) async {
    try {
      final requestIds = _stringIds(trip['requestIds']);
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
            return data['dropoffAddress']?.toString().trim();
          })
          .whereType<String>()
          .where((destination) => destination.isNotEmpty)
          .toSet()
          .toList();

      if (destinations.isEmpty) {
        throw StateError('No destinations are linked to this trip.');
      }

      // Use the trip's shared name; participants cannot read the driver's profile.
      final tripDriverName = trip['driverName'];
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
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('trips')
          .doc(tripId)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          _logTripReadFailure(tripId, snapshot.error!);
          return const Center(child: Text('Unable to load trip information.'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final trip = snapshot.data!.data();
        if (trip == null) {
          debugPrint(
            'Live GPS trip data missing: trip=$tripId, '
            'uid=${FirebaseAuth.instance.currentUser?.uid}, '
            'documentExists=${snapshot.data!.exists}.',
          );
          return const Center(child: Text('Trip information is unavailable.'));
        }

        final uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid == null) {
          debugPrint(
            'Live GPS trip data ignored after sign-out: trip=$tripId.',
          );
          return const Center(child: Text('Please sign in again.'));
        }
        final passengerIds = _stringIds(trip['passengerIds']);
        final assignedDriverId = trip['driverId']?.toString();
        final isAuthorizedParticipant = isDriver
            ? assignedDriverId == uid
            : passengerIds.contains(uid);
        if (!isAuthorizedParticipant) {
          debugPrint(
            'Live GPS trip membership mismatch: trip=$tripId, uid=$uid, '
            'isDriver=$isDriver, driverId=$assignedDriverId, '
            'passengerIds=$passengerIds.',
          );
          return const Center(child: Text('Trip access is unavailable.'));
        }

        final status = (trip['status'] ?? 'unknown').toString();
        final pickup =
            (trip['pickupName'] ?? trip['pickupAddress'] ?? 'Pickup location')
                .toString();
        final passengerCount = trip['totalPassengers'];
        final totalFare = _formatFare(trip['totalFareSen']);
        final requestIds = _stringIds(trip['requestIds']);
        if (requestIds.toSet().length != requestIds.length) {
          debugPrint(
            'Live GPS trip has duplicate requestIds: trip=$tripId, '
            'requestIds=$requestIds.',
          );
        }
        final optimizedOrder = _stringIds(trip['optimizedDropoffOrder']);
        final displayOrder = <String>{
          ...optimizedOrder.where(requestIds.contains),
          ...requestIds.where((id) => !optimizedOrder.contains(id)),
        }.toList();

        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFFF7F9FA),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              _PanelCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.route, color: RPColors.teal),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            isDriver ? 'DRIVER NAVIGATION' : 'YOUR SHARED RIDE',
                            style: const TextStyle(
                              color: RPColors.teal,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        _StatusPill(label: _readableStatus(status)),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _InfoRow(label: 'Pickup', value: pickup),
                    _InfoRow(
                      label: 'Passengers',
                      value: passengerCount == null
                          ? 'Not available'
                          : '$passengerCount',
                    ),
                    _InfoRow(label: 'Total Trip Fare', value: totalFare),

                    const SizedBox(height: 12),

                    // Displays the current passenger's individual fare.
                    StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: FirebaseFirestore.instance
                          .collection('ride_requests')
                          .where(
                            'passengerId',
                            isEqualTo: FirebaseAuth.instance.currentUser?.uid,
                          )
                          .where('groupId', isEqualTo: tripId)
                          .snapshots(),
                      builder: (context, fareSnapshot) {
                        if (fareSnapshot.hasError) {
                          debugPrint(
                            'Live GPS fare read failed for trip=$tripId, '
                            'uid=${FirebaseAuth.instance.currentUser?.uid}, '
                            'error=${fareSnapshot.error}',
                          );
                          return const Text(
                            'Unable to load your fare',
                            style: TextStyle(color: RPColors.textGrey),
                          );
                        }

                        if (!fareSnapshot.hasData) {
                          return const LinearProgressIndicator();
                        }

                        final requests = fareSnapshot.data!.docs;

                        if (requests.isEmpty) {
                          return const SizedBox.shrink();
                        }

                        final fareSen = requests.first.data()['fareShareSen'];
                        final yourFare = _formatFare(fareSen);

                        return Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            color: RPColors.teal.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: RPColors.teal.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.payments_outlined,
                                color: RPColors.teal,
                                size: 26,
                              ),

                              const SizedBox(width: 12),

                              const Expanded(
                                child: Text(
                                  'YOUR FARE',
                                  style: TextStyle(
                                    color: RPColors.teal,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),

                              Text(
                                yourFare,
                                style: const TextStyle(
                                  color: RPColors.teal,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _shareTrip(context, trip, pickup),
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
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              const Row(
                children: [
                  Icon(Icons.alt_route, color: RPColors.teal, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'OPTIMIZED DROP-OFF ROUTE',
                      style: TextStyle(
                        color: RPColors.teal,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Stops update automatically as the driver confirms drop-offs.',
                style: TextStyle(color: RPColors.textGrey, fontSize: 12),
              ),
              const SizedBox(height: 12),
              if (displayOrder.isEmpty)
                const _PanelCard(
                  child: Text('No passenger stops are available yet.'),
                )
              else
                TripEtaEstimates(
                  tripId: tripId,
                  tripData: trip,
                  builder: (_, estimates) => _LiveDropoffCards(
                    tripId: tripId,
                    requestIds: displayOrder,
                    tripStatus: status,
                    currentUserId: FirebaseAuth.instance.currentUser?.uid,
                    estimates: estimates,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Reads the trip's linked ride requests in real time so that every card
/// reflects the latest drop-off status, including the next eligible stop.
class _LiveDropoffCards extends StatefulWidget {
  const _LiveDropoffCards({
    required this.tripId,
    required this.requestIds,
    required this.tripStatus,
    required this.currentUserId,
    required this.estimates,
  });

  final String tripId;
  final List<String> requestIds;
  final String tripStatus;
  final String? currentUserId;
  final TripEtaResult estimates;

  @override
  State<_LiveDropoffCards> createState() => _LiveDropoffCardsState();
}

class _LiveDropoffCardsState extends State<_LiveDropoffCards> {
  final Map<String, StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>>
  _requestSubscriptions = {};
  final Map<String, Map<String, dynamic>> _requestsById = {};
  final Set<String> _loadedRequestIds = {};
  final Set<String> _failedRequestIds = {};

  @override
  void initState() {
    super.initState();
    _syncRequestListeners();
  }

  // Updates the Firestore listeners if the trip ID or request IDs change.
  @override
  void didUpdateWidget(covariant _LiveDropoffCards oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tripId != widget.tripId ||
        !_sameRequestIds(oldWidget.requestIds, widget.requestIds)) {
      _cancelRequestListeners();
      _requestsById.clear();
      _loadedRequestIds.clear();
      _failedRequestIds.clear();
      _syncRequestListeners();
    }
  }

  bool _sameRequestIds(List<String> first, List<String> second) {
    return first.length == second.length && first.toSet().containsAll(second);
  }

  // Cancels all active Firestore listeners for ride requests.
  void _cancelRequestListeners() {
    for (final subscription in _requestSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    _requestSubscriptions.clear();
  }

  // Synchronizes Firestore listeners for the current set of request IDs.
  void _syncRequestListeners() {
    for (final id in widget.requestIds.toSet()) {
      _requestSubscriptions[id] = FirebaseFirestore.instance
          .collection('ride_requests')
          .doc(id)
          .snapshots()
          .listen(
            (snapshot) {
              if (!mounted) return;
              final request = snapshot.data();
              if (request != null && request['groupId'] != widget.tripId) {
                debugPrint(
                  'Ignoring drop-off request $id not linked to '
                  'trip ${widget.tripId}.',
                );
              } else if (request == null) {
                debugPrint(
                  'Live GPS drop-off request is missing: '
                  'trip=${widget.tripId}, request=$id, '
                  'uid=${FirebaseAuth.instance.currentUser?.uid}.',
                );
              }
              setState(() {
                _loadedRequestIds.add(id);
                _failedRequestIds.remove(id);
                if (request == null || request['groupId'] != widget.tripId) {
                  _requestsById.remove(id);
                } else {
                  _requestsById[id] = {
                    'passengerId': request['passengerId'],
                    'status': request['status'],
                    'pickupName': request['pickupName'],
                    'pickupAddress': request['pickupAddress'],
                    'dropoffAddress': request['dropoffAddress'],
                    'dropoffName': request['dropoffName'],
                    'passengerCount': request['passengerCount'],
                    'totalPassengers': request['totalPassengers'],
                  };
                }
              });
            },
            onError: (Object error) {
              final code = error is FirebaseException ? error.code : null;
              debugPrint(
                'Live GPS drop-off listener failed: '
                'trip=${widget.tripId}, request=$id, '
                'uid=${FirebaseAuth.instance.currentUser?.uid}, '
                'kind=${code == 'permission-denied' ? 'permission-denied' : 'stream-error'}, '
                'error=$error',
              );
              if (!mounted) return;
              if (FirebaseAuth.instance.currentUser?.uid !=
                  widget.currentUserId) {
                debugPrint(
                  'Ignoring drop-off listener error after authentication '
                  'changed for trip=${widget.tripId}.',
                );
                return;
              }
              setState(() {
                _loadedRequestIds.add(id);
                _failedRequestIds.add(id);
              });
            },
          );
    }
  }

  @override
  void dispose() {
    _cancelRequestListeners();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failedRequestIds.isNotEmpty) {
      return const _PanelCard(
        child: Text('Unable to load drop-off stops. Check trip access.'),
      );
    }
    if (!widget.requestIds.every(_loadedRequestIds.contains)) {
      return const _PanelCard(child: LinearProgressIndicator());
    }

    // Do not mark a later stop as NEXT STOP until all linked requests load.
    final allRequestsAvailable = widget.requestIds.every(
      _requestsById.containsKey,
    );
    String? nextRequestId;
    if (allRequestsAvailable) {
      for (final id in widget.requestIds) {
        final status = (_requestsById[id]?['status'] ?? '').toString();
        if (status != 'drop_off_confirmed' &&
            status != 'completed' &&
            status != 'cancelled') {
          nextRequestId = id;
          break;
        }
      }
    }

    return Column(
      children: [
        for (var index = 0; index < widget.requestIds.length; index++)
          _buildStopCard(index, nextRequestId),
      ],
    );
  }

  Widget _buildStopCard(int index, String? nextRequestId) {
    final requestId = widget.requestIds[index];
    final request = _requestsById[requestId];
    final isOwnStop =
        widget.currentUserId != null &&
        request?['passengerId'] == widget.currentUserId;

    return _DropoffStopCard(
      stopNumber: index + 1,
      request: request,
      isOwnStop: isOwnStop,
      isNextStop:
          widget.tripStatus == 'in_progress' && nextRequestId == requestId,
      tripStatus: widget.tripStatus,
      estimate:
          widget.estimates.stopEtas[requestId] ??
          (isOwnStop ? widget.estimates.message : null),
    );
  }
}

class _DropoffStopCard extends StatelessWidget {
  const _DropoffStopCard({
    required this.stopNumber,
    required this.request,
    required this.isOwnStop,
    required this.isNextStop,
    required this.tripStatus,
    required this.estimate,
  });

  final int stopNumber;
  final Map<String, dynamic>? request;
  final bool isOwnStop;
  final bool isNextStop;
  final String tripStatus;
  final String? estimate;

  @override
  Widget build(BuildContext context) {
    if (request == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _PanelCard(
          child: Text('Stop $stopNumber: details unavailable.'),
        ),
      );
    }

    final status = (request!['status'] ?? 'unknown').toString();
    final droppedOff = status == 'drop_off_confirmed' || status == 'completed';
    final cancelled = status == 'cancelled';
    final pickup =
        (request!['pickupName'] ??
                request!['pickupAddress'] ??
                'Pickup location')
            .toString();
    final destination =
        (request!['dropoffAddress'] ?? request!['dropoffName'] ?? 'Destination')
            .toString();
    final passengerCount =
        request!['passengerCount'] ?? request!['totalPassengers'] ?? 1;

    final label = droppedOff
        ? 'DROPPED OFF'
        : cancelled
        ? 'CANCELLED'
        : isNextStop
        ? 'NEXT STOP'
        : 'PENDING';
    final accent = droppedOff
        ? Colors.green.shade700
        : cancelled
        ? Colors.red.shade700
        : RPColors.teal;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isOwnStop
              ? RPColors.teal.withValues(alpha: 0.07)
              : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isOwnStop ? RPColors.teal : accent.withValues(alpha: 0.22),
            width: isOwnStop ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: accent.withValues(alpha: 0.1),
                  child: Text(
                    '$stopNumber',
                    style: TextStyle(
                      color: accent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'PASSENGER STOP $stopNumber',
                        style: const TextStyle(
                          color: RPColors.teal,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (isOwnStop) ...[
                        const SizedBox(height: 4),
                        const Text(
                          'YOUR STOP',
                          style: TextStyle(
                            color: RPColors.orange,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: droppedOff
                                ? Colors.green.withValues(alpha: 0.10)
                                : cancelled
                                ? Colors.red.withValues(alpha: 0.10)
                                : isNextStop
                                ? RPColors.orange.withValues(alpha: 0.12)
                                : Colors.grey.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            label,
                            style: TextStyle(
                              color: droppedOff
                                  ? Colors.green.shade700
                                  : cancelled
                                  ? Colors.red.shade700
                                  : isNextStop
                                  ? RPColors.orange
                                  : Colors.grey.shade700,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            _InfoRow(label: 'Pickup', value: pickup),
            _InfoRow(label: 'Destination', value: destination),
            _InfoRow(label: 'Passengers', value: '$passengerCount'),
            if (!droppedOff &&
                !cancelled &&
                const {'driver_arrived', 'in_progress'}.contains(tripStatus) &&
                (estimate != null || isOwnStop))
              _InfoRow(
                label: 'Estimated drop-off',
                value: estimate ?? 'Calculating…',
              ),
            if (droppedOff)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green, size: 19),
                    SizedBox(width: 7),
                    Text(
                      'Passenger dropped off',
                      style: TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

void _logTripReadFailure(String tripId, Object error) {
  final code = error is FirebaseException ? error.code : null;
  debugPrint(
    'Live GPS trip listener failed: trip=$tripId, '
    'uid=${FirebaseAuth.instance.currentUser?.uid}, '
    'kind=${code == 'permission-denied' ? 'permission-denied' : 'stream-error'}, '
    'error=$error',
  );
}

class _PanelCard extends StatelessWidget {
  const _PanelCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: RPColors.teal.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: RPColors.teal,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
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
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatFare(dynamic sen) =>
    sen is num ? 'RM ${(sen / 100).toStringAsFixed(2)}' : 'Not available';

String _readableStatus(String status) =>
    status.replaceAll('_', ' ').toUpperCase();
