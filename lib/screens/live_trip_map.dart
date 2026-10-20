import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'passenger_home.dart' show RPColors;

const String _orsApiKey = String.fromEnvironment('ORS_API_KEY');

class LiveTripMap extends StatefulWidget {
  const LiveTripMap({super.key, required this.tripId, required this.isDriver});

  final String tripId;
  final bool isDriver;

  @override
  State<LiveTripMap> createState() => _LiveTripMapState();
}

class _LiveTripMapState extends State<LiveTripMap> {
  final MapController _mapController = MapController();

  StreamSubscription<Position>? _positionSubscription;

  // Current device GPS position.
  LatLng? _myPosition;

  List<LatLng> _routePoints = [];

  bool _mapReady = false;
  bool _hasCenteredOnMyLocation = false;
  bool _loadingRoute = false;
  bool _locationError = false;
  bool _routeError = false;
  bool _publishingLocation = false;

  LatLng? _pendingLocation;

  String? _lastRouteKey;

  DocumentReference<Map<String, dynamic>> get _tripRef =>
      FirebaseFirestore.instance.collection('trips').doc(widget.tripId);

  String get _roleLabel => widget.isDriver ? 'DRIVER' : 'PASSENGER';

  @override
  void initState() {
    super.initState();
    _startMyLocationUpdates();
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
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

  // Center on the first available GPS position once the map is ready.
  // Do not force the camera to follow every subsequent GPS update.
  void _centerOnMyLocationIfNeeded() {
    if (!_mapReady || _myPosition == null || _hasCenteredOnMyLocation) {
      return;
    }

    _hasCenteredOnMyLocation = true;

    _mapController.move(_myPosition!, 16);

    debugPrint(
      '[$_roleLabel] Map centered on initial GPS position: '
      '${_myPosition!.latitude}, ${_myPosition!.longitude}',
    );
  }

  // Start GPS tracking and request an initial position immediately.
  Future<void> _startMyLocationUpdates() async {
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
      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 0,
            timeLimit: Duration(seconds: 30),
          ),
        );

        _logPosition(position, 'INITIAL');

        if (!mounted) return;

        setState(() {
          _myPosition = LatLng(position.latitude, position.longitude);
        });

        await _publishMyLocation(LatLng(position.latitude, position.longitude));

        _centerOnMyLocationIfNeeded();
      } catch (error) {
        debugPrint('[$_roleLabel] Initial GPS request failed: $error');

        // Continue with the location stream even if the
        // initial GPS request times out.
      }

      if (!mounted) return;

      // STEP 2: Keep receiving location updates.
      _positionSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.bestForNavigation,
              distanceFilter: 3,
            ),
          ).listen(
            (position) {
              _logPosition(position, 'STREAM');

              final point = LatLng(position.latitude, position.longitude);

              if (mounted) {
                setState(() {
                  _myPosition = point;
                  _locationError = false;
                });

                _centerOnMyLocationIfNeeded();
              }

              unawaited(_publishMyLocation(point));
            },
            onError: (error) {
              debugPrint('[$_roleLabel] GPS stream error: $error');

              if (mounted) {
                setState(() => _locationError = true);
              }
            },
          );
    } catch (error) {
      debugPrint('[$_roleLabel] Unable to start GPS tracking: $error');

      if (mounted) {
        setState(() => _locationError = true);
      }
    }
  }

  // Publish this account's position to its own Firestore document.
  Future<void> _publishMyLocation(LatLng point) async {
    if (_publishingLocation) {
      // Keep the newest location instead of losing the update.
      _pendingLocation = point;
      return;
    }

    _publishingLocation = true;

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;

      if (uid == null) {
        debugPrint('[$_roleLabel] No authenticated user.');
        return;
      }

      final snapshot = await _tripRef.get();
      final data = snapshot.data();

      if (!snapshot.exists || data == null) return;

      final status = data['status'];

      if (!['driver_assigned', 'in_progress'].contains(status)) {
        debugPrint(
          '[$_roleLabel] Location not published; '
          'trip status is $status.',
        );
        return;
      }

      final isAssignedDriver = data['driverId'] == uid;

      // Verify passenger membership before publishing.
      if (!isAssignedDriver) {
        final requestIds = data['requestIds'];

        if (requestIds is! List || requestIds.isEmpty) {
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
            '[$_roleLabel] User is not a passenger '
            'on this trip.',
          );
          return;
        }
      }

      final actualRole = isAssignedDriver ? 'driver' : 'passenger';

      final locationData = <String, dynamic>{
        'userId': uid,
        'role': actualRole,
        'lat': point.latitude,
        'lon': point.longitude,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      // Each Firebase account has its own location document.
      await _tripRef.collection('live_locations').doc(uid).set(locationData);

      // Preserve the existing driverLocation field.
      if (isAssignedDriver) {
        await _tripRef.set({
          'driverLocation': {
            'lat': point.latitude,
            'lon': point.longitude,
            'updatedAt': FieldValue.serverTimestamp(),
          },
        }, SetOptions(merge: true));
      }

      debugPrint(
        '[$_roleLabel] Published $actualRole location: '
        '${point.latitude}, ${point.longitude}',
      );
    } catch (error) {
      debugPrint('[$_roleLabel] Unable to publish live location: $error');
    } finally {
      _publishingLocation = false;

      final pending = _pendingLocation;
      _pendingLocation = null;

      if (pending != null && mounted) {
        unawaited(_publishMyLocation(pending));
      }
    }
  }

  LatLng? _readPoint(dynamic lat, dynamic lon) {
    if (lat is num && lon is num) {
      return LatLng(lat.toDouble(), lon.toDouble());
    }

    return null;
  }

  LatLng? _readDriverLocation(Map<String, dynamic> data) {
    final location = data['driverLocation'];

    if (location is Map) {
      return _readPoint(location['lat'], location['lon']);
    }

    return null;
  }

  // Load the driving route without automatically moving the camera.
  Future<void> _loadDrivingRoute(LatLng start, LatLng end) async {
    if (_orsApiKey.isEmpty) {
      if (mounted) {
        setState(() {
          _routeError = true;
          _routePoints = [];
        });
      }
      return;
    }

    final routeKey =
        '${start.latitude},${start.longitude};'
        '${end.latitude},${end.longitude}';

    if (_lastRouteKey == routeKey || _loadingRoute) return;

    _lastRouteKey = routeKey;

    if (mounted) {
      setState(() {
        _loadingRoute = true;
        _routeError = false;
      });
    }

    try {
      final uri = Uri.https(
        'api.openrouteservice.org',
        '/v2/directions/driving-car',
        {
          'start': '${start.longitude},${start.latitude}',
          'end': '${end.longitude},${end.latitude}',
        },
      );

      final response = await http
          .get(uri, headers: {'Authorization': _orsApiKey})
          .timeout(const Duration(seconds: 15));

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

      final points = coordinates.map((coordinate) {
        final pair = coordinate as List<dynamic>;

        // OpenRouteService uses [longitude, latitude].
        return LatLng((pair[1] as num).toDouble(), (pair[0] as num).toDouble());
      }).toList();

      if (!mounted) return;

      setState(() {
        _routePoints = points;
        _routeError = false;
      });

      // Intentionally do not call fitCamera here.
      // Loading a route should not move the map camera.
    } catch (error) {
      debugPrint('Unable to load ORS route: $error');

      if (mounted) {
        setState(() {
          _routeError = true;
          _routePoints = [];
        });
      }
    } finally {
      if (mounted) {
        setState(() => _loadingRoute = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _tripRef.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text('Unable to load trip details.'));
        }

        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final data = snapshot.data!.data();

        if (data == null) {
          return const Center(child: Text('Trip not found.'));
        }

        final pickup = _readPoint(data['pickupLat'], data['pickupLon']);

        final dropoff = _readPoint(
          data['dropoffRefLat'],
          data['dropoffRefLon'],
        );

        final firestoreDriverLocation = _readDriverLocation(data);

        // Driver uses its current GPS position when available.
        // Passenger initially falls back to Firestore's driver
        // location until the driver's live location is received.
        final driverLocation = widget.isDriver
            ? (_myPosition ?? firestoreDriverLocation)
            : firestoreDriverLocation;

        if (pickup != null && dropoff != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              unawaited(_loadDrivingRoute(pickup, dropoff));
            }
          });
        }

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
          if (dropoff != null)
            Marker(
              point: dropoff,
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
                onMapReady: () {
                  _mapReady = true;
                  _centerOnMyLocationIfNeeded();
                },
              ),
              children: [
                TileLayer(
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

                // Live markers for trip participants.
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _tripRef.collection('live_locations').snapshots(),
                  builder: (context, locationSnapshot) {
                    final liveMarkers = <Marker>[...markers];

                    for (final doc in locationSnapshot.data?.docs ?? []) {
                      final location = doc.data();

                      final point = _readPoint(
                        location['lat'],
                        location['lon'],
                      );

                      if (point == null) continue;

                      final isDriver = location['role'] == 'driver';

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
                      if (driverLocation == null && !widget.isDriver)
                        const Text(
                          'Waiting for the driver to share '
                          'their location...',
                        ),
                      if (_myPosition != null && !_locationError)
                        const Text('Your GPS location is active.'),
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
                  final target =
                      _myPosition ?? driverLocation ?? pickup ?? dropoff;

                  if (target != null) {
                    _mapController.move(target, 16);
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
