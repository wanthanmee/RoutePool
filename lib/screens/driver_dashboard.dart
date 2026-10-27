import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'passenger_home.dart' show RPColors;

import 'driver_notifications_screen.dart';
import 'driver_ride_screen.dart';
import '../services/driver_trip_service.dart';
import '../services/driver_location_service.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Summary details for a ride request shown to a driver.
class IncomingRideRequest {
  const IncomingRideRequest({
    required this.passengerName,
    required this.fare,
    required this.distanceKm,
    required this.etaMinutes,
    required this.pickup,
    required this.dropoff,
  });

  final String passengerName;
  final double fare;
  final double distanceKm;
  final int etaMinutes;
  final String pickup;
  final String dropoff;
}

/// Displays the driver's earnings, ride activity, and availability controls.
class DriverDashboardScreen extends StatefulWidget {
  /// Creates a dashboard with optional summary values and an incoming request.
  const DriverDashboardScreen({
    super.key,
    this.driverName = 'Alex',
    this.todayEarnings = 142.50,
    this.earningsChangePercent = 12,
    this.averageRating = 4.9,
    this.tripsToday = 12,
    this.incomingRequest = const IncomingRideRequest(
      passengerName: 'Sarah M.',
      fare: 18.00,
      distanceKm: 2.4,
      etaMinutes: 14,
      pickup: 'Georgetown',
      dropoff: 'Queensbay Mall',
    ),
  });

  final String driverName;
  final double todayEarnings;
  final int earningsChangePercent;
  final double averageRating;
  final int tripsToday;
  final IncomingRideRequest? incomingRequest;

  @override
  State<DriverDashboardScreen> createState() => _DriverDashboardScreenState();
}

/// Loads driver availability and handles online status changes.
class _DriverDashboardScreenState extends State<DriverDashboardScreen> {
  bool isOnline = false;
  bool _isLoadingAvailability = true;
  bool _isUpdatingAvailability = false;
  bool _isSyncingAvailability = false;
  bool? _latestFirestoreAvailability;
  bool _availabilitySyncPending = false;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _availabilitySubscription;

  @override
  void initState() {
    super.initState();
    _listenToAvailability();
  }

  void _listenToAvailability() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) setState(() => _isLoadingAvailability = false);
      return;
    }

    _availabilitySubscription = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted) return;
            _latestFirestoreAvailability =
                snapshot.exists && snapshot.data()?['isAvailable'] == true;
            _availabilitySyncPending = true;
            _syncAvailability();
          },
          onError: (Object error) {
            debugPrint('Driver availability listener error: $error');
            if (mounted) {
              setState(() => _isLoadingAvailability = false);
            }
          },
        );
  }

  /// Serializes Firestore-driven GPS changes and handles newer snapshots.
  Future<void> _syncAvailability() async {
    if (!mounted || _isSyncingAvailability || _isUpdatingAvailability) return;
    if (_latestFirestoreAvailability == null) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _isSyncingAvailability = true;
    if (mounted) setState(() {});

    try {
      while (mounted && _availabilitySyncPending && !_isUpdatingAvailability) {
        _availabilitySyncPending = false;
        final available = _latestFirestoreAvailability == true;

        if (available) {
          try {
            await DriverLocationService.instance.startTracking(user.uid);
            if (!mounted) return;
            if (_latestFirestoreAvailability != true) {
              _availabilitySyncPending = true;
              continue;
            }
            setState(() {
              isOnline = true;
              _isLoadingAvailability = false;
            });
          } catch (error) {
            debugPrint('Could not start driver GPS: $error');
            if (!mounted) return;
            if (_latestFirestoreAvailability != true) {
              _availabilitySyncPending = true;
              continue;
            }
            try {
              await FirebaseFirestore.instance
                  .collection('users')
                  .doc(user.uid)
                  .update({
                    'isAvailable': false,
                    'updatedAt': FieldValue.serverTimestamp(),
                  });
            } catch (updateError) {
              debugPrint('Could not set driver offline: $updateError');
            }
            if (!mounted) return;
            _latestFirestoreAvailability = false;
            _availabilitySyncPending = true;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'GPS is unavailable. You have been switched offline.',
                ),
              ),
            );
          }
        } else {
          await DriverLocationService.instance.stopTracking();
          if (!mounted) return;
          if (_latestFirestoreAvailability != false) {
            _availabilitySyncPending = true;
            continue;
          }
          setState(() {
            isOnline = false;
            _isLoadingAvailability = false;
          });
        }
      }
    } catch (error) {
      debugPrint('Driver availability sync error: $error');
    } finally {
      _isSyncingAvailability = false;
      if (mounted) {
        setState(() => _isLoadingAvailability = false);
        if (_availabilitySyncPending && !_isUpdatingAvailability) {
          // Schedule another pass rather than recursively running in finally.
          scheduleMicrotask(_syncAvailability);
        }
      }
    }
  }

  @override
  void dispose() {
    _availabilitySubscription?.cancel();
    super.dispose();
  }

  /// Returns an explanation when the account or vehicle cannot go online.
  ///
  /// Returns `null` when the driver's account and vehicle meet the
  /// requirements for becoming available.
  Future<String?> _getOnlineBlockReason(String uid) async {
    final firestore = FirebaseFirestore.instance;

    final results = await Future.wait([
      firestore.collection('users').doc(uid).get(),
      firestore.collection('vehicles').doc(uid).get(),
    ]);

    final userDoc = results[0];
    final vehicleDoc = results[1];

    if (!userDoc.exists) {
      return 'Your driver account could not be found. Please contact support.';
    }

    final userData = userDoc.data();

    if (userData?['verificationStatus'] != 'approved') {
      return 'Your driver account must be approved before you can go online.';
    }

    if (!vehicleDoc.exists) {
      return 'Please add your vehicle details and registration document first.';
    }

    final vehicleData = vehicleDoc.data();

    final vehicleStatus = vehicleData?['verificationStatus']
        ?.toString()
        .toLowerCase();

    if (vehicleStatus != 'approved') {
      switch (vehicleStatus) {
        case 'pending':
          return 'Your vehicle registration is pending admin review.';

        case 'rejected':
          return 'Your vehicle registration was rejected. Please review the reason in Edit Profile and submit a replacement document.';

        case 'not_submitted':
        case null:
          return 'Please submit your vehicle registration document for verification.';

        default:
          return 'Your vehicle verification status is not approved. Please contact support.';
      }
    }

    if (vehicleData?['isActive'] != true) {
      return 'Your vehicle is inactive. Please contact support.';
    }

    return null;
  }

  Future<void> _updateAvailability(bool value) async {
    if (_isLoadingAvailability ||
        _isUpdatingAvailability ||
        _isSyncingAvailability) {
      return;
    }

    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Please log in again.')));
      return;
    }

    setState(() => _isUpdatingAvailability = true);

    final userRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid);

    try {
      // STEP 1: Check eligibility before going ONLINE.
      if (value) {
        final blockReason = await _getOnlineBlockReason(user.uid);

        if (!mounted) return;

        if (blockReason != null) {
          await DriverLocationService.instance.stopTracking();

          await userRef.update({
            'isAvailable': false,
            'updatedAt': FieldValue.serverTimestamp(),
          });

          if (!mounted) return;

          setState(() => isOnline = false);

          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(blockReason)));

          return;
        }

        // STEP 2: Start GPS tracking before becoming available.
        await DriverLocationService.instance.startTracking(user.uid);

        // STEP 3: Set ONLINE only after GPS starts successfully.
        try {
          await userRef.update({
            'isAvailable': true,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        } catch (_) {
          await DriverLocationService.instance.stopTracking();
          rethrow;
        }
      } else {
        // STEP 4: Switch OFFLINE before stopping GPS tracking.
        await userRef.update({
          'isAvailable': false,
          'updatedAt': FieldValue.serverTimestamp(),
        });

        await DriverLocationService.instance.stopTracking();
      }

      if (!mounted) return;

      setState(() {
        isOnline = value;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(value ? 'You are now online.' : 'You are now offline.'),
        ),
      );
    } catch (e) {
      debugPrint('Update driver availability error: $e');

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update availability: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isUpdatingAvailability = false);
        if (_availabilitySyncPending) _syncAvailability();
      }
    }
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _getIncomingRequests() {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid == null) {
      return const Stream.empty();
    }

    return FirebaseFirestore.instance
        .collection('trips')
        .where('status', isEqualTo: 'matching_driver')
        .where('offeredDriverId', isEqualTo: uid)
        .snapshots();
  }

  Widget _buildLiveIncomingRequests(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _getIncomingRequests(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Unable to load requests: ${snapshot.error}'),
            ),
          );
        }

        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }

        final allRequests = snapshot.data?.docs ?? [];
        final currentUserId = FirebaseAuth.instance.currentUser?.uid;

        final requests = currentUserId == null
            ? allRequests
            : allRequests.where((request) {
                final data = request.data();
                final dismissedBy = List<String>.from(
                  data['dismissedBy'] ?? <String>[],
                );

                return !dismissedBy.contains(currentUserId);
              }).toList();

        if (requests.isEmpty) {
          return Card(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.hourglass_empty,
                    color: RPColors.teal,
                    size: 32,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Waiting for ride requests',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text('New requests will appear here.'),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () {
                        _updateAvailability(false);
                      },
                      child: const Text('Go offline'),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.55,
          ),
          decoration: BoxDecoration(
            color: RPColors.bg,
            borderRadius: BorderRadius.circular(18),
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(4),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Incoming Ride Requests',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: RPColors.textDark,
                        ),
                      ),
                    ),
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: RPColors.teal,
                      child: Text(
                        '${requests.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ...requests.map((request) {
                final data = request.data();
                final currentUserId = FirebaseAuth.instance.currentUser?.uid;

                final viewedBy = List<String>.from(
                  data['viewedBy'] ?? <String>[],
                );

                final isUnread =
                    currentUserId != null && !viewedBy.contains(currentUserId);

                final pickup =
                    data['pickupName'] as String? ?? 'Unknown pickup';

                final passengers =
                    (data['totalPassengers'] as num?)?.toInt() ?? 1;

                final fareSen = (data['totalFareSen'] as num?)?.toInt() ?? 0;

                final fareText = 'RM ${(fareSen / 100).toStringAsFixed(2)}';

                final dropoff = 'Trip with $passengers passenger(s)';

                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  color: RPColors.cardBg,
                  elevation: 3,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(
                      color: RPColors.orange.withValues(alpha: 0.7),
                    ),
                  ),
                  child: InkWell(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const DriverNotificationsScreen(),
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const CircleAvatar(
                                backgroundColor: Color(0xFFE1F0EF),
                                child: Icon(
                                  Icons.local_taxi,
                                  color: RPColors.teal,
                                ),
                              ),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Text(
                                  'New Ride Request',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    color: RPColors.textDark,
                                  ),
                                ),
                              ),
                              if (isUnread)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 9,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFF1D6),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: const Text(
                                    'NEW',
                                    style: TextStyle(
                                      color: Color(0xFF9A6200),
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.trip_origin,
                                color: RPColors.teal,
                                size: 20,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'PICKUP',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: RPColors.textGrey,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      pickup,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const Padding(
                            padding: EdgeInsets.only(left: 9),
                            child: SizedBox(
                              height: 22,
                              child: VerticalDivider(
                                color: RPColors.border,
                                thickness: 2,
                              ),
                            ),
                          ),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.location_on,
                                color: Colors.red,
                                size: 20,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'DESTINATION',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: RPColors.textGrey,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      dropoff,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const Divider(height: 26),

                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // First row: Passenger count and fare.
                              Row(
                                children: [
                                  const Icon(
                                    Icons.people_outline,
                                    size: 20,
                                    color: RPColors.teal,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      '$passengers passenger(s)',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),

                              const SizedBox(height: 10),

                              // Second row: Departure time.
                              const Row(
                                children: [
                                  Icon(
                                    Icons.access_time,
                                    size: 18,
                                    color: RPColors.teal,
                                  ),
                                  SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      'As Soon as Possible',
                                      softWrap: true,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),

                          const SizedBox(height: 16),
                          Row(
                            children: [
                              const Icon(
                                Icons.payments_outlined,
                                size: 20,
                                color: RPColors.teal,
                              ),
                              const SizedBox(width: 6),
                              const Text('Total trip fare'),
                              const Spacer(),
                              Text(
                                fareText,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: RPColors.teal,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () =>
                                      _declineTrip(context, request.id),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.red,
                                    side: const BorderSide(color: Colors.red),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 13,
                                    ),
                                  ),
                                  child: const Text('Decline'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: () =>
                                      _acceptTrip(context, request.id),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: RPColors.teal,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 13,
                                    ),
                                  ),
                                  child: const Text('Accept Ride'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Future<void> _acceptTrip(BuildContext context, String tripId) async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Please sign in again.')));
      return;
    }

    try {
      final requestIds = await DriverTripService().acceptTrip(tripId);

      await DriverLocationService.instance.stopTracking();

      if (!context.mounted) return;

      setState(() => isOnline = false);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Trip accepted successfully!')),
      );

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DriverRideScreen(requestId: requestIds.first),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;

      final message = e is FirebaseFunctionsException
          ? e.message ?? 'Could not accept this trip.'
          : e.toString().replaceFirst('Exception: ', '');

      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _declineTrip(BuildContext context, String tripId) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Please sign in again.')));
      return;
    }

    try {
      await DriverTripService().declineTrip(tripId);

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Trip declined. Searching for another driver.'),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;

      final message = e is FirebaseFunctionsException
          ? e.message ?? 'Could not decline this trip.'
          : e.toString().replaceFirst('Exception: ', '');

      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: RPColors.bg,
      body: SafeArea(
        child: Stack(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 140),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(),
                  const SizedBox(height: 20),
                  _buildOnlineToggle(),
                  const SizedBox(height: 16),
                  _buildEarningsCard(),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(child: _buildRatingCard()),
                      const SizedBox(width: 12),
                      Expanded(child: _buildStatCard()),
                      const SizedBox(width: 12),
                      Expanded(child: _buildRideHistoryCard(context)),
                    ],
                  ),
                ],
              ),
            ),
            if (isOnline)
              Positioned(
                left: 20,
                right: 20,
                bottom: 20,
                child: _buildLiveIncomingRequests(context),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        CircleAvatar(
          radius: 22,
          backgroundColor: RPColors.teal.withValues(alpha: 0.1),
          child: const Icon(Icons.person, color: RPColors.teal),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'Good morning, ${widget.driverName}',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: RPColors.textDark,
            ),
          ),
        ),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: isOnline ? _getIncomingRequests() : null,
          builder: (context, snapshot) {
            final currentUserId = FirebaseAuth.instance.currentUser?.uid;
            final allRequests = snapshot.data?.docs ?? [];

            final count = currentUserId == null
                ? 0
                : allRequests.where((request) {
                    final data = request.data();

                    final viewedBy = List<String>.from(
                      data['viewedBy'] ?? <String>[],
                    );
                    final dismissedBy = List<String>.from(
                      data['dismissedBy'] ?? <String>[],
                    );

                    return !viewedBy.contains(currentUserId) &&
                        !dismissedBy.contains(currentUserId);
                  }).length;

            return InkWell(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const DriverNotificationsScreen(),
                  ),
                );
              },
              borderRadius: BorderRadius.circular(30),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: RPColors.cardBg,
                  shape: BoxShape.circle,
                  border: Border.all(color: RPColors.border),
                ),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(
                      Icons.notifications_none,
                      color: RPColors.textDark,
                    ),
                    if (isOnline && count > 0)
                      Positioned(
                        right: -7,
                        top: -7,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(
                            minWidth: 18,
                            minHeight: 18,
                          ),
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            count > 99 ? '99+' : '$count',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildOnlineToggle() {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: RPColors.cardBg,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: RPColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: _toggleButton(
              'GO OFFLINE',
              selected: !isOnline,
              offline: true,
            ),
          ),
          Expanded(
            child: _toggleButton('ONLINE', selected: isOnline, offline: false),
          ),
        ],
      ),
    );
  }

  Widget _toggleButton(
    String label, {
    required bool selected,
    required bool offline,
  }) {
    return GestureDetector(
      onTap:
          (_isLoadingAvailability ||
              _isUpdatingAvailability ||
              _isSyncingAvailability)
          ? null
          : () => _updateAvailability(!offline),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected ? RPColors.teal : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : RPColors.textGrey,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildEarningsCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: RPColors.cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: RPColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                "Tap to switch availability status",
                style: TextStyle(fontSize: 11, color: RPColors.textGrey),
              ),
              const Spacer(),
              const Icon(Icons.trending_up, size: 14, color: Colors.green),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            "Today's earnings",
            style: TextStyle(fontSize: 13, color: RPColors.textGrey),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'RM${widget.todayEarnings.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: RPColors.textDark,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '+${widget.earningsChangePercent}% vs yesterday',
                    softWrap: true,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.green,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRatingCard() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 10),
      decoration: BoxDecoration(
        color: RPColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RPColors.border),
      ),
      child: Column(
        children: [
          const Icon(Icons.star, color: RPColors.orange, size: 20),
          const SizedBox(height: 6),
          Text(
            '${widget.averageRating} ★',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
          const SizedBox(height: 2),
          const Text(
            'Average Rating',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10, color: RPColors.textGrey),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 10),
      decoration: BoxDecoration(
        color: RPColors.cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: RPColors.border),
      ),
      child: Column(
        children: [
          const Icon(Icons.directions_car, color: RPColors.teal, size: 20),
          const SizedBox(height: 6),
          Text(
            '${widget.tripsToday}',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
          const SizedBox(height: 2),
          const Text(
            'Trips Today',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10, color: RPColors.textGrey),
          ),
        ],
      ),
    );
  }

  Widget _buildRideHistoryCard(BuildContext context) {
    return InkWell(
      onTap: () {
        // TODO: once driver_rideHistory.dart is added, replace with:
        // Navigator.of(context).push(
        //   MaterialPageRoute(builder: (_) => const DriverRideHistoryScreen()),
        // );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ride History screen not added yet.')),
        );
      },
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 10),
        decoration: BoxDecoration(
          color: RPColors.cardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: RPColors.border),
        ),
        child: const Column(
          children: [
            Icon(Icons.history, color: RPColors.teal, size: 20),
            SizedBox(height: 6),
            Text(
              'Ride History',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: RPColors.textDark,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
