import 'dart:async';

import 'dart:math' as math;

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:firebase_auth/firebase_auth.dart';

import 'package:flutter/material.dart';

import 'package:flutter_map/flutter_map.dart';

import 'package:geolocator/geolocator.dart';

import 'package:http/http.dart' as http;

import 'package:latlong2/latlong.dart';

import 'package:cloud_functions/cloud_functions.dart';

import 'passenger_home.dart' show RPColors;

import '../services/route_optimizer.dart';

const String _orsApiKey = String.fromEnvironment('ORS_API_KEY');

/// Displays a live map with the trip route and the signed-in user's location.

class LiveTripMap extends StatefulWidget {
  /// Creates the map for the trip identified by [tripId].

  ///

  /// [isDriver] determines which participant's location is being published.

  const LiveTripMap({super.key, required this.tripId, required this.isDriver});

  final String tripId;

  final bool isDriver;

  @override
  State<LiveTripMap> createState() => _LiveTripMapState();
}

/// Tracks device location and synchronizes trip map data with Firestore.

class _LiveTripMapState extends State<LiveTripMap> {
  final MapController _mapController = MapController();

  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<User?>? _authSubscription;
  String? _ownerUid;
  bool _authChanged = false;

  // Current device GPS position.

  LatLng? _myPosition;

  // GPS stability filtering.

  static const double _maximumGpsAccuracyM = 30;

  static const double _stationarySpeedMps = 0.5;

  static const Duration _maximumGpsPositionAge = Duration(minutes: 1);

  static const Duration _maximumSharedLocationAge = Duration(seconds: 90);

  static const Duration _gpsHeartbeatInterval = Duration(seconds: 30);

  static const Duration _minimumLocationPublishInterval = Duration(seconds: 5);

  static const Duration _locationFreshnessCheckInterval = Duration(seconds: 15);

  static const double _minimumLocationPublishDistanceM = 10;

  double _lastAcceptedAccuracyM = 0;
  LatLng? _lastPublishedLocation;
  DateTime? _lastLocationPublishedAt;
  Timer? _gpsHeartbeatTimer;
  Timer? _locationFreshnessTimer;
  bool _requestingFreshPosition = false;

  List<LatLng> _routePoints = [];

  bool _mapReady = false;

  bool _hasCenteredOnMyLocation = false;

  // Camera follows the driver for passengers and this device for drivers.
  bool _autoFollow = true;
  LatLng? _latestDriverPosition;
  LatLng? _lastCameraTarget;

  void _followTarget(LatLng? target, {bool force = false}) {
    if (!_mapReady || target == null || (!_autoFollow && !force)) {
      return;
    }

    if (!force &&
        _lastCameraTarget != null &&
        const Distance()(_lastCameraTarget!, target) < 2) {
      return;
    }

    _lastCameraTarget = target;
    _mapController.move(target, _mapController.camera.zoom);
  }

  void _scheduleFollow(LatLng? target) {
    if (target == null || !_autoFollow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _followTarget(target);
    });
  }

  bool _loadingRoute = false;

  // Incremented whenever a route request is replaced or invalidated.
  int _routeRequestVersion = 0;

  bool _locationError = false;

  bool _routeError = false;

  bool _publishingLocation = false;

  bool _hasPublishedLocation = false;

  bool _locationPublishError = false;

  Position? _pendingPosition;

  // Tracks the last requested route.

  LatLng? _lastRouteStart;

  String? _lastStopsKey;

  // Controls route retrying after an API error.

  DateTime? _routeRetryAt;

  // If the driver's movement distance is less than this threshold, the route is not recalculated.
  // Movement Distance is calculated from the last route start point, not the last published location.
  static const double _rerouteDistanceMeters = 150;

  // Stabilize navigation near the current pickup or drop-off.
  static const double _destinationProximityMeters = 50;

  // Allow rerouting if the driver moves away from the existing route.
  static const double _offRouteToleranceMeters = 35;

  // Wait 15 seconds before retrying a failed route.

  static const Duration _routeRetryDelay = Duration(seconds: 15);

  String? _lastDropoffRequestKey;

  // Real-time listeners for the trip's passenger requests.

  final Map<String, StreamSubscription> _requestSubscriptions = {};

  // Latest Firestore data for each passenger request.

  final Map<String, Map<String, dynamic>> _requests = {};

  // Stores the drop-off order calculated by OpenRouteService.

  String? _dropoffOrderKey;

  List<LatLng>? _fastestDropoffOrder;

  DocumentReference<Map<String, dynamic>> get _tripRef =>
      FirebaseFirestore.instance.collection('trips').doc(widget.tripId);

  String get _roleLabel => widget.isDriver ? 'DRIVER' : 'PASSENGER';

  @override
  void initState() {
    super.initState();

    // Keep this map bound to the account that opened it; stop all trip work
    // if authentication changes while the screen is still mounted.
    _ownerUid = FirebaseAuth.instance.currentUser?.uid;
    if (_ownerUid == null) {
      _authChanged = true;
      debugPrint(
        'Live map not started for trip=${widget.tripId}: no authenticated user.',
      );
      return;
    }

    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user?.uid == _ownerUid || _authChanged) return;
      debugPrint(
        'Live map stopped for trip=${widget.tripId}: authenticated user '
        'changed from $_ownerUid to ${user?.uid}.',
      );
      _authChanged = true;
      _stopTripActivity();
      if (mounted) setState(() {});
    });

    _startMyLocationUpdates();
    _locationFreshnessTimer = Timer.periodic(_locationFreshnessCheckInterval, (
      _,
    ) {
      if (mounted && _isAuthenticatedForTrip) setState(() {});
    });
  }

  bool get _isAuthenticatedForTrip =>
      !_authChanged &&
      _ownerUid != null &&
      FirebaseAuth.instance.currentUser?.uid == _ownerUid;

  void _stopTripActivity() {
    _routeRequestVersion++;
    _gpsHeartbeatTimer?.cancel();
    _gpsHeartbeatTimer = null;
    _locationFreshnessTimer?.cancel();
    _locationFreshnessTimer = null;
    unawaited(_positionSubscription?.cancel());
    _positionSubscription = null;
    for (final subscription in _requestSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    _requestSubscriptions.clear();
    _requests.clear();
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    _stopTripActivity();
    _mapController.dispose();

    super.dispose();
  }

  // Log GPS readings so we can diagnose marker separation.

  void _logPosition(Position position, String source) {
    debugPrint(
      '[$_roleLabel][$source] '
      'uid=${FirebaseAuth.instance.currentUser?.uid}, '
      'lat=${position.latitude}, '
      'lon=${position.longitude}, '
      'accuracy=${position.accuracy}m, '
      'time=${position.timestamp}',
    );
  }

  // Driver follows own GPS; passengers follow the driver's car instead.
  void _centerOnMyLocationIfNeeded() {
    if (!_mapReady || _hasCenteredOnMyLocation) return;
    final target = widget.isDriver ? _myPosition : _latestDriverPosition;
    if (target == null) return;
    _hasCenteredOnMyLocation = true;
    _followTarget(target);
  }

  bool _isValidGpsPosition(Position position) {
    if (!position.latitude.isFinite ||
        !position.longitude.isFinite ||
        position.latitude < -90 ||
        position.latitude > 90 ||
        position.longitude < -180 ||
        position.longitude > 180) {
      debugPrint('[$_roleLabel] GPS reading rejected: invalid coordinates.');
      return false;
    }

    if (!position.accuracy.isFinite ||
        position.accuracy < 0 ||
        position.accuracy > _maximumGpsAccuracyM) {
      debugPrint(
        '[$_roleLabel] GPS reading rejected: '
        'accuracy=${position.accuracy}m; '
        'required <= ${_maximumGpsAccuracyM}m.',
      );
      return false;
    }

    final age = DateTime.now().difference(position.timestamp);
    if (age.isNegative || age > _maximumGpsPositionAge) {
      debugPrint(
        '[$_roleLabel] GPS reading rejected: '
        'timestamp=${position.timestamp}, age=${age.inSeconds}s; '
        'maximum age=${_maximumGpsPositionAge.inSeconds}s.',
      );
      return false;
    }

    return true;
  }

  bool _shouldUpdateMapForPosition(Position position) {
    final current = _myPosition;
    if (current == null) {
      return true;
    }

    final distance = Geolocator.distanceBetween(
      current.latitude,

      current.longitude,

      position.latitude,

      position.longitude,
    );

    final isStationary =
        position.speed >= 0 && position.speed < _stationarySpeedMps;

    // Keep stationary GPS jitter from moving the marker.

    if (isStationary && distance < position.accuracy + _lastAcceptedAccuracyM) {
      debugPrint(
        '[$_roleLabel] GPS marker unchanged for stationary reading: '
        'distance=${distance}m, speed=${position.speed}m/s, '
        'accuracy=${position.accuracy}m, '
        'lastAccuracy=${_lastAcceptedAccuracyM}m.',
      );
      return false;
    }

    return true;
  }

  void _handleGpsPosition(Position position, String source) {
    _logPosition(position, source);

    if (!_isValidGpsPosition(position)) {
      if (mounted) setState(() => _locationError = true);
      return;
    }

    final shouldUpdateMap = _shouldUpdateMapForPosition(position);
    _lastAcceptedAccuracyM = position.accuracy;
    final point = LatLng(position.latitude, position.longitude);

    if (mounted) {
      if (shouldUpdateMap || _locationError) {
        setState(() {
          if (shouldUpdateMap) _myPosition = point;
          _locationError = false;
        });
      }

      if (shouldUpdateMap) {
        _centerOnMyLocationIfNeeded();
        if (widget.isDriver) _followTarget(point);
      }
    }

    // Map display and Firestore publication have separate movement thresholds.
    unawaited(_publishMyLocation(position));
  }

  Future<void> _requestFreshPosition(String source) async {
    if (_requestingFreshPosition) {
      debugPrint('[$_roleLabel] Skipping overlapping $source GPS request.');
      return;
    }

    _requestingFreshPosition = true;
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 0,
          timeLimit: Duration(seconds: 30),
        ),
      );

      if (mounted) _handleGpsPosition(position, source);
    } catch (error) {
      debugPrint('[$_roleLabel] $source GPS request failed: $error');
      if (mounted) setState(() => _locationError = true);
    } finally {
      _requestingFreshPosition = false;
    }
  }

  bool _shouldPublishLocation(LatLng point) {
    final lastPublishedAt = _lastLocationPublishedAt;
    final lastPublishedLocation = _lastPublishedLocation;

    // Publish the first fix, then publish on meaningful movement or a
    // heartbeat so the shared location does not become stale while stationary.
    if (lastPublishedAt == null || lastPublishedLocation == null) {
      return true;
    }

    final elapsed = DateTime.now().difference(lastPublishedAt);
    if (!elapsed.isNegative && elapsed >= _gpsHeartbeatInterval) {
      return true;
    }

    if (elapsed < _minimumLocationPublishInterval) {
      return false;
    }

    return Geolocator.distanceBetween(
          lastPublishedLocation.latitude,
          lastPublishedLocation.longitude,
          point.latitude,
          point.longitude,
        ) >=
        _minimumLocationPublishDistanceM;
  }

  // Start GPS tracking and request an initial position immediately.

  Future<void> _startMyLocationUpdates() async {
    if (!_isAuthenticatedForTrip) return;
    debugPrint(
      '[$_roleLabel] Starting GPS for trip=${widget.tripId}; '
      'authUid=${FirebaseAuth.instance.currentUser?.uid}, '
      'isDriver=${widget.isDriver}.',
    );
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {
        debugPrint('[$_roleLabel] Location services are disabled.');

        if (mounted) {
          setState(() => _locationError = true);
        }

        return;
      }

      var permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        debugPrint('[$_roleLabel] Location permission denied.');

        if (mounted) {
          setState(() => _locationError = true);
        }

        return;
      }

      // STEP 1: Obtain the current position before waiting for

      // the continuous GPS stream.

      await _requestFreshPosition('INITIAL');

      if (!mounted || !_isAuthenticatedForTrip) return;

      // STEP 2: Keep receiving location updates.

      _positionSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.bestForNavigation,

              distanceFilter: 3,
            ),
          ).listen(
            (position) {
              _handleGpsPosition(position, 'STREAM');
            },

            onError: (error) {
              debugPrint('[$_roleLabel] GPS stream error: $error');

              if (mounted) {
                setState(() => _locationError = true);
              }
            },
          );

      _gpsHeartbeatTimer = Timer.periodic(_gpsHeartbeatInterval, (_) {
        unawaited(_requestFreshPosition('HEARTBEAT'));
      });
    } catch (error) {
      debugPrint('[$_roleLabel] Unable to start GPS tracking: $error');

      if (mounted) {
        setState(() => _locationError = true);
      }
    }
  }

  // Publish this account's position to its own Firestore document.

  Future<void> _publishMyLocation(Position position) async {
    if (!_isAuthenticatedForTrip) return;
    if (!_isValidGpsPosition(position)) return;

    final point = LatLng(position.latitude, position.longitude);

    if (_publishingLocation) {
      // Keep the newest location instead of losing the update.

      _pendingPosition = position;

      return;
    }

    if (!_shouldPublishLocation(point)) {
      debugPrint(
        '[$_roleLabel] Skipping location write; movement and heartbeat '
        'thresholds have not been reached.',
      );
      return;
    }

    _publishingLocation = true;

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;

      if (uid == null) {
        debugPrint(
          '[$_roleLabel] Location not published for trip=${widget.tripId}: '
          'no authenticated user.',
        );

        return;
      }
      if (uid != _ownerUid || !_isAuthenticatedForTrip) return;

      final snapshot = await _tripRef.get();

      final data = snapshot.data();

      if (!snapshot.exists || data == null) {
        debugPrint(
          '[$_roleLabel] Location not published for trip=${widget.tripId}, '
          'uid=$uid: trip document does not exist or has no data.',
        );
        return;
      }

      final status = data['status'];
      final assignedDriverId = data['driverId'];
      final isAssignedDriver = assignedDriverId == uid;
      debugPrint(
        '[$_roleLabel] Publish check: trip=${widget.tripId}, uid=$uid, '
        'driverId=$assignedDriverId, status=$status, '
        'assignedDriver=$isAssignedDriver.',
      );

      if (![
        'driver_assigned',
        'driver_arrived',
        'in_progress',
      ].contains(status)) {
        debugPrint(
          '[$_roleLabel] Location not published for trip=${widget.tripId}; '
          'trip status is $status.',
        );

        return;
      }

      // Verify passenger membership before publishing.

      if (!isAssignedDriver) {
        final requestIds = data['requestIds'];

        if (requestIds is! List || requestIds.isEmpty) {
          debugPrint(
            '[$_roleLabel] Location not published for trip=${widget.tripId}, '
            'uid=$uid: user is not the assigned driver and trip has no '
            'passenger request IDs.',
          );
          return;
        }

        var isPassenger = false;

        for (final requestId in requestIds) {
          if (requestId is! String) continue;

          final request = await FirebaseFirestore.instance
              .collection('ride_requests')
              .doc(requestId)
              .get();

          if (request.exists && request.data()?['passengerId'] == uid) {
            isPassenger = true;

            break;
          }
        }

        if (!isPassenger) {
          debugPrint(
            '[$_roleLabel] Location not published for trip=${widget.tripId}, '
            'uid=$uid: user is not a passenger on this trip.',
          );

          return;
        }
      }

      if (!_isAuthenticatedForTrip || !_isValidGpsPosition(position)) return;

      final actualRole = isAssignedDriver ? 'driver' : 'passenger';

      // The document ID is the account UID, so the stream can identify each
      // participant and update their marker independently.
      final locationData = <String, dynamic>{
        'userId': uid,

        'role': actualRole,

        'lat': point.latitude,

        'lon': point.longitude,

        'updatedAt': FieldValue.serverTimestamp(),
      };

      // Each Firebase account has its own location document.

      // The driver publishes their own location, and each passenger publishes their own location.
      await _tripRef.collection('live_locations').doc(uid).set(locationData);
      _lastPublishedLocation = point;
      _lastLocationPublishedAt = DateTime.now();
      if (mounted) {
        setState(() {
          _hasPublishedLocation = true;
          _locationPublishError = false;
        });
      }

      debugPrint(
        '[$_roleLabel] Published $actualRole location to '
        'trips/${widget.tripId}/live_locations/$uid: '
        '${point.latitude}, ${point.longitude}',
      );
    } catch (error) {
      debugPrint(
        '[$_roleLabel] Unable to publish live location for '
        'trip=${widget.tripId}: $error',
      );
      if (mounted) setState(() => _locationPublishError = true);
    } finally {
      _publishingLocation = false;

      final pending = _pendingPosition;

      _pendingPosition = null;

      if (pending != null && mounted) {
        unawaited(_publishMyLocation(pending));
      }
    }
  }

  // Keep the linked ride requests synchronized with the trip.

  void _syncRequests(List<String> requestIds) {
    if (!_isAuthenticatedForTrip) {
      debugPrint(
        'Live map ignored request sync for trip=${widget.tripId}: '
        'authentication is no longer valid.',
      );
      return;
    }
    final linkedRequestIds = requestIds.where((id) => id.isNotEmpty).toSet();

    // Remove listeners for requests no longer associated with the trip.

    for (final id in _requestSubscriptions.keys.toList()) {
      if (!linkedRequestIds.contains(id)) {
        _requestSubscriptions.remove(id)?.cancel();

        _requests.remove(id);
      }
    }

    // Listen for changes to each passenger's request.

    for (final id in linkedRequestIds) {
      _requestSubscriptions[id] ??= FirebaseFirestore.instance
          .collection('ride_requests')
          .doc(id)
          .snapshots()
          .listen(
            (snapshot) {
              if (!mounted || !_requestSubscriptions.containsKey(id)) return;

              final data = snapshot.data();
              if (data != null && data['groupId'] != widget.tripId) {
                debugPrint(
                  '[$_roleLabel] Ignoring request $id not linked to '
                  'trip ${widget.tripId}.',
                );
              }

              setState(() {
                if (data == null || data['groupId'] != widget.tripId) {
                  _requests.remove(id);
                } else {
                  _requests[id] = data;
                }
              });

              final request = _requests[id];

              if (request != null) {
                debugPrint('========== LIVE PASSENGER REQUEST ==========');

                debugPrint('Request ID: $id');

                debugPrint('Status: ${request['status']}');

                debugPrint('Destination: ${request['dropoffAddress']}');

                debugPrint(
                  'Coordinates: '
                  '${request['dropoffLat']}, ${request['dropoffLon']}',
                );

                debugPrint('============================================');
              }
            },

            onError: (error) {
              final code = error is FirebaseException ? error.code : null;
              debugPrint(
                '[$_roleLabel] Trip request listener failed: '
                'trip=${widget.tripId}, request=$id, '
                'uid=${FirebaseAuth.instance.currentUser?.uid}, '
                'kind=${code == 'permission-denied' ? 'permission-denied' : 'stream-error'}, '
                'error=$error',
              );
            },
          );
    }
  }

  String _pointsKey(List<LatLng> points) =>
      points.map((point) => '${point.latitude},${point.longitude}').join(';');

  // Invalidate responses from any previous ORS directions request.
  void _invalidateRouteRequest() {
    _routeRequestVersion++;
    _loadingRoute = false;
    _lastStopsKey = null;
    _lastRouteStart = null;
    _routeRetryAt = null;
  }

  // Load the fastest drop-off order from OpenRouteService and save it to Firestore if this device is the driver.
  Future<void> _loadFastestDropoffOrder(
    LatLng origin,

    List<LatLng> dropoffs,
  ) async {
    final key =
        '${origin.latitude},${origin.longitude}|'
        '${_pointsKey(dropoffs)}';

    debugPrint('========== MATRIX OPTIMIZATION CHECK ==========');

    debugPrint('Is Driver: ${widget.isDriver}');

    debugPrint('Number of drop-offs: ${dropoffs.length}');

    debugPrint('ORS API key available: ${_orsApiKey.isNotEmpty}');

    debugPrint('Origin: $origin');

    debugPrint('================================================');

    if (!widget.isDriver) {
      debugPrint('MATRIX SKIPPED: Passenger device.');

      return;
    }

    if (dropoffs.length < 2) {
      debugPrint('MATRIX SKIPPED: Fewer than 2 drop-offs.');

      return;
    }

    if (_orsApiKey.isEmpty) {
      debugPrint('MATRIX SKIPPED: ORS API key is missing.');

      return;
    }

    if (key == _dropoffOrderKey) {
      debugPrint('MATRIX SKIPPED: This order was already requested.');

      return;
    }

    _dropoffOrderKey = key;

    _fastestDropoffOrder = null;

    try {
      // Request a duration matrix from OpenRouteService for the origin and drop-offs.
      final response = await http
          .post(
            Uri.https('api.openrouteservice.org', '/v2/matrix/driving-car'),

            headers: {
              'Authorization': _orsApiKey,

              'Content-Type': 'application/json',
            },

            body: jsonEncode({
              'locations': [
                origin,

                ...dropoffs,
              ].map((point) => [point.longitude, point.latitude]).toList(),

              'metrics': ['duration'],
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception(
          'ORS matrix returned ${response.statusCode}: ${response.body}',
        );
      }

      // Convert the JSON response into a 2D list of doubles, where each inner list
      final durations = [
        for (final row in jsonDecode(response.body)['durations'] as List)
          [
            for (final seconds in row as List)
              (seconds as num?)?.toDouble() ?? double.infinity,
          ],
      ];

      // Call route optimizer service
      final fastest = RouteOptimizer.findFastestOrder(durations);

      // If the fastest order is empty, it means that there was an error in the optimization process or that there are no valid routes between the points. In this case, we set the fastestSeconds to infinity to indicate that there is no valid route.
      final fastestSeconds = fastest.isEmpty
          ? double.infinity
          : RouteOptimizer.calculateDrivingTime(durations, fastest);

      if (!mounted || key != _dropoffOrderKey || fastest.isEmpty) {
        return;
      }

      // Optimizer indices include the origin at index 0, so subtract one to
      // look up each destination in the dropoffs-only list.
      setState(() {
        _fastestDropoffOrder = [for (final i in fastest) dropoffs[i - 1]];
      });

      // Only the driver proposes the shared drop-off order.

      if (widget.isDriver) {
        try {
          final tripSnapshot = await _tripRef.get();

          final tripData = tripSnapshot.data();

          final uid = FirebaseAuth.instance.currentUser?.uid;

          if (!mounted ||
              tripData == null ||
              uid == null ||
              tripData['driverId'] != uid ||
              tripData['status'] != 'in_progress') {
            return;
          }

          final requestIds = List<String>.from(
            tripData['requestIds'] ?? const [],
          );

          // Associate each destination with its request ID.

          final remainingRequestIds = <String>[];

          for (final requestId in requestIds) {
            final request = _requests[requestId];

            if (request == null) {
              return;
            }

            if ([
              'cancelled',

              'drop_off_confirmed',

              'completed',
            ].contains(request['status'])) {
              continue;
            }

            final destination = _readPoint(
              request['dropoffLat'],

              request['dropoffLon'],
            );

            if (destination == null) {
              return;
            }

            remainingRequestIds.add(requestId);
          }

          // Ensure every optimized destination has a matching request.

          if (remainingRequestIds.length != dropoffs.length) {
            return;
          }

          // The ORS result uses 1-based indices for destinations.
          // Save the optimized request IDs in the same order as the fastest route.
          final optimizedRequestIds = [
            for (final index in fastest) remainingRequestIds[index - 1],
          ];

          // Avoid overwriting an existing shared order.

          final existingOrder = tripData['optimizedDropoffOrder'];

          if (existingOrder is List && existingOrder.isNotEmpty) {
            debugPrint('Shared drop-off order already exists.');

            return;
          }

          final functions = FirebaseFunctions.instanceFor(
            region: 'asia-southeast1',
          );

          final callable = functions.httpsCallable('saveOptimizedDropoffOrder');

          await callable.call({
            'tripId': widget.tripId,
            'optimizedRequestIds': optimizedRequestIds,
          });

          debugPrint('========== SHARED DROPOFF ORDER ==========');

          debugPrint('Trip ID: ${widget.tripId}');

          debugPrint('Request order: $optimizedRequestIds');

          debugPrint('=========================================');
        } catch (error) {
          debugPrint('Unable to save shared drop-off order: $error');
        }
      }

      debugPrint('========== OPTIMIZED DROPOFF ORDER ==========');

      debugPrint('Order: $fastest');

      debugPrint(
        'Estimated driving time: '
        '${(fastestSeconds / 60).toStringAsFixed(1)} minutes',
      );

      for (var i = 0; i < _fastestDropoffOrder!.length; i++) {
        final point = _fastestDropoffOrder![i];

        debugPrint('Stop ${i + 1}: ${point.latitude}, ${point.longitude}');
      }

      debugPrint('=============================================');
    } catch (error) {
      debugPrint('Unable to load ORS matrix: $error');

      // Allow a future request to retry after an error.

      if (key == _dropoffOrderKey) {
        _dropoffOrderKey = null;
      }
    }
  }

  LatLng? _readPoint(dynamic lat, dynamic lon) {
    if (lat is! num || lon is! num) {
      return null;
    }

    final latitude = lat.toDouble();
    final longitude = lon.toDouble();

    if (!RouteOptimizer.isValidCoordinate(latitude, longitude)) {
      return null;
    }

    return LatLng(latitude, longitude);
  }

  bool _isFreshSharedLocation(Map location) {
    final updatedAt = location['updatedAt'];
    if (updatedAt is! Timestamp) return false;
    final age = DateTime.now().difference(updatedAt.toDate());
    return !age.isNegative && age <= _maximumSharedLocationAge;
  }

  double _distanceToRouteMeters(LatLng position, List<LatLng> route) {
    if (route.isEmpty) return double.infinity;

    const earthRadius = 6371000.0;
    final latitudeRadians = position.latitude * math.pi / 180;
    final longitudeScale = math.cos(latitudeRadians);

    // Convert coordinates into local metre-based coordinates.
    double x(LatLng point) =>
        (point.longitude - position.longitude) *
        math.pi /
        180 *
        earthRadius *
        longitudeScale;

    double y(LatLng point) =>
        (point.latitude - position.latitude) * math.pi / 180 * earthRadius;

    if (route.length == 1) {
      return const Distance()(position, route.first);
    }

    var nearestDistance = double.infinity;

    for (var i = 0; i < route.length - 1; i++) {
      final ax = x(route[i]);
      final ay = y(route[i]);

      final bx = x(route[i + 1]);
      final by = y(route[i + 1]);

      final dx = bx - ax;
      final dy = by - ay;

      final lengthSquared = dx * dx + dy * dy;

      final t = lengthSquared == 0
          ? 0.0
          : ((-ax * dx - ay * dy) / lengthSquared).clamp(0.0, 1.0).toDouble();

      final nearestX = ax + t * dx;
      final nearestY = ay + t * dy;

      final distance = math.sqrt(nearestX * nearestX + nearestY * nearestY);

      if (distance < nearestDistance) {
        nearestDistance = distance;
      }
    }

    return nearestDistance;
  }

  // Load a driving route through one or more stops.
  Future<void> _loadDrivingRoute(LatLng start, List<LatLng> stops) async {
    if (stops.isEmpty) return;

    if (_orsApiKey.isEmpty) {
      if (mounted && !_routeError) {
        setState(() {
          _routeError = true;

          _routePoints = [];
        });
      }

      return;
    }

    final stopsKey = _pointsKey(stops);

    // A new destination list supersedes an in-flight ORS request.
    // This check must run before the loading guard.
    if (_lastStopsKey != null && _lastStopsKey != stopsKey) {
      _invalidateRouteRequest();
    }

    // Preserve the existing route near the current destination,
    // provided the driver remains close to the route.
    final sameDestinations = _lastStopsKey == stopsKey;

    final currentDestination = stops.first;

    final distanceToDestination = const Distance()(start, currentDestination);

    final distanceFromRoute = _distanceToRouteMeters(start, _routePoints);

    final nearDestination =
        distanceToDestination <= _destinationProximityMeters;

    final followingExistingRoute =
        distanceFromRoute <= _offRouteToleranceMeters;

    if (sameDestinations &&
        _routePoints.length >= 2 &&
        nearDestination &&
        followingExistingRoute) {
      debugPrint(
        'Near destination: '
        '${distanceToDestination.toStringAsFixed(1)}m. '
        'Distance from route: '
        '${distanceFromRoute.toStringAsFixed(1)}m. '
        'Keeping existing route.',
      );

      return;
    }

    if (_loadingRoute) return;

    // Do not retry immediately after an API failure.

    if (_routeRetryAt != null && DateTime.now().isBefore(_routeRetryAt!)) {
      return;
    }

    // Avoid repeatedly requesting almost identical routes.

    if (_lastStopsKey == stopsKey &&
        _lastRouteStart != null &&
        const Distance()(_lastRouteStart!, start) < _rerouteDistanceMeters) {
      return;
    }

    _lastStopsKey = stopsKey;

    _lastRouteStart = start;

    final requestVersion = ++_routeRequestVersion;

    // Mark loading before the network call so the status card can reflect it.
    if (mounted) {
      setState(() {
        _loadingRoute = true;

        _routeError = false;
      });
    }

    // Generate the Actual Driving Route using ORS Directions
    try {
      final uri = Uri.https(
        'api.openrouteservice.org',

        '/v2/directions/driving-car/geojson',
      );

      // OpenRouteService requires longitude before latitude.

      final waypoints = [start, ...stops].map((point) {
        return [point.longitude, point.latitude];
      }).toList();

      debugPrint('========== MULTI-STOP ROUTE ==========');

      debugPrint('Starting point: $start');

      debugPrint('Number of stops: ${stops.length}');

      for (var i = 0; i < stops.length; i++) {
        debugPrint('Stop ${i + 1}: ${stops[i]}');
      }

      // Request duration matrix from ORS to determine the fastest drop-off order.
      final response = await http
          .post(
            uri,

            headers: {
              'Authorization': _orsApiKey,

              'Content-Type': 'application/json',
            },

            body: jsonEncode({'coordinates': waypoints}),
          )
          .timeout(const Duration(seconds: 25));

      if (response.statusCode != 200) {
        debugPrint('ORS status: ${response.statusCode}');

        debugPrint('ORS response: ${response.body}');

        throw Exception('ORS returned ${response.statusCode}');
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;

      final features = body['features'] as List<dynamic>;

      if (features.isEmpty) {
        throw Exception('No route found');
      }

      final geometry = features.first['geometry'] as Map<String, dynamic>;

      final coordinates = geometry['coordinates'] as List<dynamic>;

      // GeoJSON coordinates are [longitude, latitude]; Flutter map points
      // use LatLng(latitude, longitude).
      final points = coordinates.map((coordinate) {
        final pair = coordinate as List<dynamic>;

        return LatLng((pair[1] as num).toDouble(), (pair[0] as num).toDouble());
      }).toList();

      if (!mounted || requestVersion != _routeRequestVersion) {
        debugPrint('Ignoring outdated ORS route response.');
        return;
      }

      _routeRetryAt = null;

      setState(() {
        _routePoints = points;

        _routeError = false;
      });

      debugPrint('Route successfully loaded.');

      debugPrint('Route points: ${points.length}');

      debugPrint('======================================');

      // Keep the camera on its current target. Route geometry still updates.
    } catch (error) {
      if (!mounted || requestVersion != _routeRequestVersion) {
        debugPrint('Ignoring outdated ORS route error.');
        return;
      }

      debugPrint('Unable to load ORS route: $error');

      // Allow the route to be retried after a delay.

      _lastStopsKey = null;

      _routeRetryAt = DateTime.now().add(_routeRetryDelay);

      Future.delayed(_routeRetryDelay, () {
        if (mounted) {
          setState(() {});
        }
      });

      if (mounted) {
        setState(() {
          _routeError = true;

          _routePoints = [];
        });
      }
    } finally {
      if (mounted && requestVersion == _routeRequestVersion) {
        setState(() {
          _loadingRoute = false;
        });
      }
    }
  }

  void _clearDrivingRoute() {
    if (_routePoints.isEmpty &&
        !_routeError &&
        !_loadingRoute &&
        _lastStopsKey == null) {
      return;
    }

    _invalidateRouteRequest();

    if (!mounted) return;

    setState(() {
      _routePoints = [];
      _routeError = false;
    });
  }

  // Build the live map UI.
  @override
  Widget build(BuildContext context) {
    if (!_isAuthenticatedForTrip) {
      return const Center(
        child: Text('Please sign in again to view this trip.'),
      );
    }
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _tripRef.snapshots(),

      builder: (context, snapshot) {
        if (snapshot.hasError) {
          final error = snapshot.error!;
          final code = error is FirebaseException ? error.code : null;
          debugPrint(
            '[$_roleLabel] Trip listener failed: trip=${widget.tripId}, '
            'uid=${FirebaseAuth.instance.currentUser?.uid}, '
            'kind=${code == 'permission-denied' ? 'permission-denied' : 'stream-error'}, '
            'error=$error',
          );
          return const Center(child: Text('Unable to load trip details.'));
        }

        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final data = snapshot.data!.data();

        if (data == null) {
          debugPrint(
            '[$_roleLabel] Trip document missing: trip=${widget.tripId}, '
            'uid=${FirebaseAuth.instance.currentUser?.uid}, '
            'exists=${snapshot.data!.exists}.',
          );
          return const Center(child: Text('Trip not found.'));
        }

        final requestIds = List<String>.from(data['requestIds'] ?? const []);

        final requestKey = requestIds.join('|');

        if (_lastDropoffRequestKey != requestKey) {
          _lastDropoffRequestKey = requestKey;

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;

            _syncRequests(requestIds);
          });
        }

        final pickup = _readPoint(data['pickupLat'], data['pickupLon']);

        final dropoff = _readPoint(
          data['dropoffRefLat'],

          data['dropoffRefLon'],
        );

        // Driver uses their own GPS.
        // Passengers use the driver's live location document.
        final driverLocation = widget.isDriver
            ? _myPosition
            : _latestDriverPosition;

        // Current trip status.

        final status = data['status'];

        // Requests belonging to this trip.

        final tripRequestIds = List<String>.from(
          data['requestIds'] ?? const [],
        );

        final currentUid = FirebaseAuth.instance.currentUser?.uid;

        // Read passenger destinations from Firestore.

        final passengerDropoffs = <({LatLng point, bool done, bool mine})>[];

        for (final requestId in tripRequestIds) {
          final request = _requests[requestId];

          if (request == null) continue;

          // Ignore cancelled bookings.

          if (request['status'] == 'cancelled') continue;

          final destination = _readPoint(
            request['dropoffLat'],

            request['dropoffLon'],
          );

          if (destination == null) continue;

          passengerDropoffs.add((
            point: destination,

            done: const {
              'drop_off_confirmed',

              'completed',
            }.contains(request['status']),

            mine: request['passengerId'] == currentUid,
          ));
        }

        // Exclude destinations where passengers have already been dropped off.

        // Retrieves the remaining drop-off points for passengers who are still active in the trip.
        final remainingDropoffs = [
          for (final stop in passengerDropoffs)
            if (!stop.done) stop.point,
        ];

        // Calculate the preferred drop-off order.

        final orderOrigin = pickup ?? driverLocation;

        // Read the shared optimized order from Firestore.
        // Builds a list destinations that still need to be visited.
        final sharedOrder = List<String>.from(
          data['optimizedDropoffOrder'] ?? const [],
        );

        // Build the route using the shared request ID order.

        final orderedDropoffs = <LatLng>[];

        for (final requestId in sharedOrder) {
          final request = _requests[requestId];

          // Wait for the passenger request to load.

          if (request == null) continue;

          // Exclude passengers who are no longer part of the active route.

          if (const {
            'cancelled',

            'drop_off_confirmed',

            'completed',
          }.contains(request['status'])) {
            continue;
          }

          final destination = _readPoint(
            request['dropoffLat'],

            request['dropoffLon'],
          );

          if (destination != null) {
            orderedDropoffs.add(destination);
          }
        }

        // Select the route based on the current trip stage.

        final routeStops = <LatLng>[
          // Navigate to pickup before the trip begins.
          if (status == 'driver_assigned' && pickup != null) pickup,

          // Navigate to passenger destinations after starting.
          if (status == 'in_progress')
            ...(orderedDropoffs.isNotEmpty
                ? orderedDropoffs
                : remainingDropoffs),
        ];

        // Use the driver's current position as the route origin.

        final routeStart =
            (widget.isDriver ? _myPosition : driverLocation) ??
            (status == 'in_progress' ? pickup : null);

        // Trigger network work after build to avoid calling setState while
        // this StreamBuilder is constructing its current frame.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;

          if (widget.isDriver &&
              status == 'in_progress' &&
              sharedOrder.isEmpty &&
              orderOrigin != null &&
              remainingDropoffs.length >= 2) {
            unawaited(_loadFastestDropoffOrder(orderOrigin, remainingDropoffs));
          }

          if (routeStart != null && routeStops.isNotEmpty) {
            unawaited(_loadDrivingRoute(routeStart, routeStops));
          } else {
            _clearDrivingRoute();
          }
        });

        // Use the best available location until GPS arrives.

        final initialCenter =
            _myPosition ??
            driverLocation ??
            pickup ??
            dropoff ??
            const LatLng(5.4141, 100.3288);

        final markers = <Marker>[
          if (pickup != null)
            Marker(
              point: pickup,

              width: 44,

              height: 44,

              child: const Icon(
                Icons.trip_origin,

                size: 32,

                color: RPColors.teal,
              ),
            ),

          // Both drivers and passengers see all remaining drop-offs.
          for (final stop in passengerDropoffs)
            if (!stop.done)
              Marker(
                point: stop.point,

                width: 44,

                height: 44,

                child: const Icon(
                  Icons.location_on,

                  size: 38,

                  color: RPColors.orange,
                ),
              ),
        ];

        return Stack(
          children: [
            FlutterMap(
              mapController: _mapController,

              options: MapOptions(
                initialCenter: initialCenter,

                initialZoom: 16,

                onPositionChanged: (position, hasGesture) {
                  if (hasGesture) _autoFollow = false;
                },

                onMapReady: () {
                  _mapReady = true;

                  _centerOnMyLocationIfNeeded();

                  if (!widget.isDriver) {
                    _scheduleFollow(_latestDriverPosition);
                  }
                },
              ),

              children: [
                TileLayer(
                  // OpenStreetMap supplies the background tiles. Route
                  // geometry itself is requested separately from ORS above.
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',

                  userAgentPackageName: 'com.routepool.app',
                ),

                // Driving route.
                if (_routePoints.length > 1)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _routePoints,

                        strokeWidth: 5,

                        color: RPColors.teal,
                      ),
                    ],
                  ),

                // Live markers for trip participants. Passenger recieves live updates from driver
                // the driver recieve live updates from all the passengers
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _tripRef.collection('live_locations').snapshots(),

                  builder: (context, locationSnapshot) {
                    final liveMarkers = <Marker>[...markers];

                    for (final doc in locationSnapshot.data?.docs ?? []) {
                      final location = doc.data();

                      if (!_isFreshSharedLocation(location)) {
                        if (location['role'] == 'driver') {
                          _latestDriverPosition = null;
                        }
                        continue;
                      }

                      final point = _readPoint(
                        location['lat'],

                        location['lon'],
                      );

                      if (point == null) continue;

                      final isDriver = location['role'] == 'driver';

                      if (isDriver && !widget.isDriver) {
                        if (_latestDriverPosition != point) {
                          _latestDriverPosition = point;

                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (!mounted) return;

                            setState(() {});
                            _scheduleFollow(point);
                          });
                        }
                      }

                      liveMarkers.add(
                        Marker(
                          point: point,

                          width: 48,

                          height: 48,

                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,

                              shape: BoxShape.circle,

                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.15),

                                  blurRadius: 6,
                                ),
                              ],
                            ),

                            child: Icon(
                              isDriver
                                  ? Icons.directions_car
                                  : Icons.person_pin_circle,

                              size: 32,

                              color: isDriver ? Colors.blue : RPColors.teal,
                            ),
                          ),
                        ),
                      );
                    }

                    return MarkerLayer(markers: liveMarkers);
                  },
                ),
              ],
            ),

            // Trip status and GPS feedback.
            Positioned(
              top: 12,

              left: 12,

              right: 12,

              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),

                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,

                    mainAxisSize: MainAxisSize.min,

                    children: [
                      Text(
                        'Trip status: ${data['status'] ?? 'unknown'}',

                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),

                      if (_loadingRoute) const Text('Loading driving route...'),

                      if (_routeError)
                        const Text(
                          'Driving route unavailable. Check the ORS '
                          'key and route coordinates.',
                        ),

                      if (_locationError)
                        const Text(
                          'Location unavailable. Check device '
                          'location settings and app permissions.',
                        ),

                      if (_locationPublishError)
                        const Text(
                          'Unable to share your live location. Check your '
                          'connection and trip access.',
                        )
                      else if (_hasPublishedLocation &&
                          _lastLocationPublishedAt != null &&
                          DateTime.now().difference(
                                _lastLocationPublishedAt!,
                              ) <=
                              _maximumSharedLocationAge)
                        const Text('Your location is being shared live.')
                      else if (_myPosition != null && !_hasPublishedLocation)
                        const Text(
                          'GPS is active. Waiting for your first trip '
                          'location update to be shared...',
                        )
                      else if (_hasPublishedLocation)
                        const Text(
                          'Your last shared location is stale. Check GPS and '
                          'your connection.',
                        ),

                      if (driverLocation == null && !widget.isDriver)
                        const Text(
                          'Waiting for the driver to share '
                          'their location...',
                        ),
                    ],
                  ),
                ),
              ),
            ),

            // Manually recenter on the current device location.
            Positioned(
              right: 14,

              bottom: 18,

              child: FloatingActionButton.small(
                heroTag: 'recenter_trip_map',

                backgroundColor: Colors.white,

                foregroundColor: RPColors.teal,

                onPressed: () {
                  _autoFollow = true;
                  final target = widget.isDriver
                      ? (_myPosition ?? driverLocation)
                      : (_latestDriverPosition ?? driverLocation);
                  if (target != null) {
                    _followTarget(target, force: true);
                  }
                },

                child: const Icon(Icons.my_location),
              ),
            ),
          ],
        );
      },
    );
  }
}
