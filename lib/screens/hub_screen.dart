import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:flutter_compass/flutter_compass.dart';

import 'book_ride_screen.dart';

/// Transit or pickup hub loaded from a RoutePool or GTFS JSON record.
class Hub {
  final String id;
  final String name;
  final String address;
  final double lat;
  final double lon;
  final int waiting;
  final String nextBus;
  final String services;
  Hub({
    required this.id,
    required this.name,
    required this.address,
    required this.lat,
    required this.lon,
    required this.waiting,
    required this.nextBus,
    required this.services,
  });

  /// Creates a hub from a GTFS bus-stop record, accepting both field formats.
  factory Hub.fromStopJson(Map<String, dynamic> json) {
    return Hub(
      id: (json['id'] ?? json['stop_id']).toString(),
      name: (json['name'] ?? json['stop_name']).toString(),
      address: (json['address'] ?? json['stop_desc'] ?? '').toString(),
      lat: ((json['lat'] ?? json['stop_lat']) as num).toDouble(),
      lon: ((json['lon'] ?? json['stop_lon']) as num).toDouble(),
      waiting: 0,
      nextBus: '',
      services: '',
    );
  }
}

/// A navigation instruction associated with a range of route-point indexes.
class WalkingNavigationStep {
  final String instruction;
  final int type;
  final int startIndex;
  final int endIndex;
  const WalkingNavigationStep({
    required this.instruction,
    required this.type,
    required this.startIndex,
    required this.endIndex,
  });
}

/// The current distances along a route and away from its path.
class RouteProgress {
  final double distanceAlongRoute;
  final double distanceFromRoute;
  const RouteProgress({
    required this.distanceAlongRoute,
    required this.distanceFromRoute,
  });
}

/// Displays nearby hubs, location search, and walking directions to a hub.
class HubScreen extends StatefulWidget {
  /// Whether the screen is being used in the driver flow.
  final bool isDriver;

  /// Optional OpenRouteService key used for route requests.
  final String? orsApiKey;

  /// Creates the hub map for a passenger or driver.
  const HubScreen({super.key, required this.isDriver, this.orsApiKey});
  @override
  State<HubScreen> createState() => _HubScreenState();
}

/// Manages hub data, map markers, location tracking, and route guidance.
class _HubScreenState extends State<HubScreen> {
  static const Color _primary = Color(0xFF2563EB);
  static const Color _secondary = Color(0xFF0F766E);
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  final LatLng _defaultCenter = const LatLng(5.4141, 100.3288);
  final List<Hub> _hubs = [];
  List<Marker> _hubMarkers = [];
  List<Hub> _searchResults = [];
  Hub? _nearestHub;
  Hub? _selectedHub;
  LatLng? _myLocation;
  List<LatLng> _routePoints = [];
  List<WalkingNavigationStep> _navigationSteps = [];
  Hub? _guidingHub;
  double? _routeDistanceM;
  double? _routeDurationS;
  double? _routeTotalDistanceM;
  double? _routeTotalDurationS;
  double _heading = 0.0;
  String? _nextInstruction;
  double? _distanceToNextTurnM;
  bool _isRouting = false;
  int _offRouteReadings = 0;
  int _arrivalReadings = 0;
  int _routeRequestVersion = 0;
  DateTime _lastReroute = DateTime.fromMillisecondsSinceEpoch(0);
  static const double _maximumGuidanceAccuracyM = 35;
  static const double _offRouteThresholdM = 35;
  static const int _requiredOffRouteReadings = 3;
  StreamSubscription<Position>? _positionStream;
  StreamSubscription<CompassEvent>? _compassStream;
  bool _hasCompassHeading = false;
  bool _isLoading = true;
  String? _errorMessage;
  bool _showSearchResults = false;

  @override
  void initState() {
    super.initState();

    _loadHubs();
    _startLocationTracking();
    _startCompassTracking();

    _searchController.addListener(_searchHubs);
  }

  void _startCompassTracking() {
    final compassEvents = FlutterCompass.events;

    if (compassEvents == null) {
      debugPrint('[HUB COMPASS] Compass sensor unavailable.');
      return;
    }

    _compassStream = compassEvents.listen(
      (CompassEvent event) {
        if (!mounted) return;

        final heading = event.heading;

        if (heading == null || !heading.isFinite) return;

        setState(() {
          _heading = (heading + 360) % 360;
          _hasCompassHeading = true;
        });
      },
      onError: (Object error) {
        debugPrint('[HUB COMPASS] Error: $error');

        if (!mounted) return;

        setState(() {
          _hasCompassHeading = false;
        });
      },
    );
  }

  @override
  void dispose() {
    _compassStream?.cancel();
    _positionStream?.cancel();

    _searchController.removeListener(_searchHubs);
    _searchController.dispose();

    super.dispose();
  }

  // ------------------------------------------------------------
  // LOAD HUB DATA
  // ------------------------------------------------------------

  Future<void> _loadHubs() async {
    try {
      // Load bus-stop data from the GTFS JSON file.
      final String stopsString = await rootBundle.loadString(
        'assets/bus_stops.json',
      );

      // Convert each bus-stop record into a Hub object.
      final List<Hub> stops = (json.decode(stopsString) as List<dynamic>)
          .map((e) => Hub.fromStopJson(e as Map<String, dynamic>))
          .toList();

      if (!mounted) return;

      setState(() {
        // Use only GTFS bus stops for both account types.
        _hubs
          ..clear()
          ..addAll(stops);

        // Generate map markers for the loaded bus stops.
        _hubMarkers = _hubs.map(_buildStopMarker).toList();

        _isLoading = false;
        _errorMessage = null;
      });

      debugPrint('Loaded ${stops.length} GTFS bus stops.');

      // Refresh the nearest bus-stop information.
      _updateNearestHub();
    } catch (e, stackTrace) {
      debugPrint('Hub load error: $e');
      debugPrintStack(stackTrace: stackTrace);

      if (!mounted) return;

      setState(() {
        _isLoading = false;
        _errorMessage = 'Unable to load Hub data.';
      });
    }
  }

  // ------------------------------------------------------------
  // SEARCH HUBS
  // ------------------------------------------------------------
  void _searchHubs() {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      setState(() {
        _searchResults = [];
        _showSearchResults = false;
      });
      return;
    }
    final results = _hubs
        .where((hub) {
          return hub.name.toLowerCase().contains(query) ||
              hub.address.toLowerCase().contains(query);
        })
        .take(20)
        .toList();
    setState(() {
      _searchResults = results;
      _showSearchResults = true;
    });
  }

  void _clearSearch() {
    _searchController.clear();
    _routeRequestVersion++;
    setState(() {
      _searchResults = [];
      _showSearchResults = false;
      _selectedHub = null;
      _guidingHub = null;
      _routePoints = [];
      _navigationSteps = [];
      _routeDistanceM = null;
      _routeDurationS = null;
      _routeTotalDistanceM = null;
      _routeTotalDurationS = null;
      _nextInstruction = null;
      _distanceToNextTurnM = null;
      _offRouteReadings = 0;
      _arrivalReadings = 0;
    });
  }

  // ------------------------------------------------------------
  // SHOW NEAREST HUBS
  // ------------------------------------------------------------
  void _showNearestHubs() {
    if (_myLocation == null) {
      setState(() {
        _errorMessage = 'Your current location is not available yet.';
      });
      return;
    }
    if (_hubs.isEmpty) return;
    final Distance distance = const Distance();
    final List<Hub> nearestHubs = List<Hub>.from(_hubs)
      ..sort((a, b) {
        final double distanceA = distance(_myLocation!, LatLng(a.lat, a.lon));
        final double distanceB = distance(_myLocation!, LatLng(b.lat, b.lon));
        return distanceA.compareTo(distanceB);
      });
    setState(() {
      _searchResults = nearestHubs.take(5).toList();
      _showSearchResults = true;
      _errorMessage = null;
    });
  }

  // ------------------------------------------------------------
  // SELECT HUB
  // ------------------------------------------------------------
  void _selectHub(Hub hub) {
    FocusScope.of(context).unfocus();
    setState(() {
      _selectedHub = hub;
      _searchController.text = hub.name;
      _searchResults = [];
      _showSearchResults = false;
      _routePoints = [];
      _guidingHub = null;
      _routeDistanceM = null;
      _routeDurationS = null;
      _routeRequestVersion++;
      _navigationSteps = [];
      _routeTotalDistanceM = null;
      _routeTotalDurationS = null;
      _nextInstruction = null;
      _distanceToNextTurnM = null;
      _offRouteReadings = 0;
      _arrivalReadings = 0;
    });
    final double currentZoom = _mapController.camera.zoom;
    _mapController.move(
      LatLng(hub.lat, hub.lon),
      currentZoom < 17 ? 17 : currentZoom,
    );
  }

  // ------------------------------------------------------------
  // LOCATION PERMISSION
  // ------------------------------------------------------------
  Future<bool> _ensureLocationPermission() async {
    final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Please enable location services on your device.';
        });
      }
      return false;
    }
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) {
        setState(() {
          _errorMessage =
              'Location permission is required to find nearby Bus Stops.';
        });
      }
      return false;
    }
    return true;
  }

  // ------------------------------------------------------------
  // LOCATION TRACKING
  // ------------------------------------------------------------
  Future<void> _startLocationTracking() async {
    final bool hasPermission = await _ensureLocationPermission();
    if (!hasPermission) return;
    try {
      final Position position = await Geolocator.getCurrentPosition(
        //get the user's current position
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      if (!mounted) return;
      setState(() {
        _myLocation = LatLng(position.latitude, position.longitude);
      });
      try {
        _mapController.move(_myLocation!, 15);
      } catch (_) {
        // Map not ready yet; ignore.
      }
      _updateNearestHub();
      _positionStream =
          Geolocator.getPositionStream(
            //start listening to the user's position stream
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.bestForNavigation,
              distanceFilter: 5,
            ),
          ).listen(
            (Position position) {
              if (!mounted) return;
              debugPrint(
                '[HUB GPS] lat=${position.latitude}, lon=${position.longitude}, accuracy=${position.accuracy}m',
              );
              setState(() {
                _myLocation = LatLng(position.latitude, position.longitude);

                if (!_hasCompassHeading &&
                    position.speed > 0.8 &&
                    position.heading.isFinite &&
                    position.heading >= 0 &&
                    position.heading <= 360) {
                  _heading = position.heading;
                }
              });
              _updateNearestHub();
              _updateGuidance(position);
            },
            onError: (Object error) {
              debugPrint('[HUB GPS] Stream error: $error');
              if (!mounted) return;
              setState(() {
                _errorMessage =
                    'GPS tracking interrupted. Check location settings.';
              });
            },
          );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Unable to get your current location.';
      });
    }
  }

  // ------------------------------------------------------------
  // FIND NEAREST HUB
  // ------------------------------------------------------------
  void _updateNearestHub() {
    if (_myLocation == null || _hubs.isEmpty) {
      return;
    }
    final Distance distance = const Distance();
    Hub? closestHub;
    double? closestDistance;
    for (final hub in _hubs) {
      final double currentDistance = distance(
        _myLocation!,
        LatLng(hub.lat, hub.lon),
      );
      if (closestDistance == null || currentDistance < closestDistance) {
        closestDistance = currentDistance;
        closestHub = hub;
      }
    }
    if (!mounted) return;
    setState(() {
      _nearestHub = closestHub;
    });
  }

  // ------------------------------------------------------------
  // DISTANCE
  // ------------------------------------------------------------
  double _distanceToHub(Hub hub) {
    if (_myLocation == null) {
      return 0;
    }
    const Distance distance = Distance();
    return distance(_myLocation!, LatLng(hub.lat, hub.lon));
  }

  String _formatDistance(double distance) {
    if (distance < 1000) {
      return '${distance.round()} m';
    }
    return '${(distance / 1000).toStringAsFixed(1)} km';
  }

  // -----------------------------------------------------------
  // MARKER BUILDER
  // -----------------------------------------------------------
  Marker _buildStopMarker(Hub hub) {
    return Marker(
      point: LatLng(hub.lat, hub.lon),
      width: 34,
      height: 34,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _selectHub(hub),
        child: Container(
          decoration: BoxDecoration(
            color: _secondary,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 4,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: const Icon(
            Icons.directions_bus,
            size: 18,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------
  // CENTER ON MY LOCATION
  // ------------------------------------------------------------
  void _centerOnMe() {
    if (_myLocation == null) {
      // No fix yet (permission denied, GPS off, or still loading): try again.
      setState(() {
        _errorMessage = 'Looking for your location...';
      });
      if (_positionStream == null) {
        _startLocationTracking();
      }
      return;
    }
    _mapController.move(_myLocation!, 16);
  }

  double _distanceBetween(LatLng a, LatLng b) {
    return const Distance().as(LengthUnit.Meter, a, b);
  }

  RouteProgress? _calculateRouteProgress(LatLng position) {
    if (_routePoints.length < 2) return null;
    double closestDistance = double.infinity;
    double closestProgress = 0;
    double accumulatedDistance = 0;
    final latitudeRadians = position.latitude * 3.141592653589793 / 180;
    final longitudeScale = 111320.0 * cos(latitudeRadians);
    const latitudeScale = 111320.0;
    for (int i = 0; i < _routePoints.length - 1; i++) {
      final start = _routePoints[i];
      final end = _routePoints[i + 1];
      final ax = (start.longitude - position.longitude) * longitudeScale;
      final ay = (start.latitude - position.latitude) * latitudeScale;
      final bx = (end.longitude - position.longitude) * longitudeScale;
      final by = (end.latitude - position.latitude) * latitudeScale;
      final dx = bx - ax;
      final dy = by - ay;
      final lengthSquared = dx * dx + dy * dy;
      double fraction = 0;
      if (lengthSquared > 0) {
        fraction = (-(ax * dx + ay * dy) / lengthSquared)
            .clamp(0.0, 1.0)
            .toDouble();
      }
      final nearestX = ax + fraction * dx;
      final nearestY = ay + fraction * dy;
      final distanceFromSegment = sqrt(
        nearestX * nearestX + nearestY * nearestY,
      );
      final segmentLength = _distanceBetween(start, end);
      if (distanceFromSegment < closestDistance) {
        closestDistance = distanceFromSegment;
        closestProgress = accumulatedDistance + segmentLength * fraction;
      }
      accumulatedDistance += segmentLength;
    }
    return RouteProgress(
      distanceAlongRoute: closestProgress,
      distanceFromRoute: closestDistance,
    );
  }

  double _distanceAlongRouteToIndex(int index) {
    if (_routePoints.isEmpty) return 0;
    final safeIndex = index.clamp(0, _routePoints.length - 1);
    double total = 0;
    for (int i = 0; i < safeIndex; i++) {
      total += _distanceBetween(_routePoints[i], _routePoints[i + 1]);
    }
    return total;
  }

  // ------------------------------------------------------------
  // WALKING DIRECTIONS
  // ------------------------------------------------------------
  Future<void> _guideMeToHub(Hub hub) async {
    if (widget.orsApiKey == null || widget.orsApiKey!.trim().isEmpty) {
      setState(() {
        _errorMessage = 'OpenRouteService API key is missing.';
      });
      return;
    }
    // Get a fresh fix instead of trusting the last cached one.
    try {
      final Position fresh = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 8),
        ),
      );
      _myLocation = LatLng(fresh.latitude, fresh.longitude);
    } catch (_) {
      // Fall back to the last known location.
    }
    if (_myLocation == null) {
      setState(() {
        _errorMessage = 'Your current location is not available yet.';
      });
      return;
    }
    setState(() {
      _guidingHub = hub;
      _selectedHub = hub;
      _errorMessage = null;
    });
    await _fetchRoute(hub, fitCamera: true);
  }

  Future<void> _fetchRoute(Hub hub, {bool fitCamera = false}) async {
    if (_myLocation == null || _isRouting) return;
    _isRouting = true;
    _lastReroute = DateTime.now();
    final requestVersion = ++_routeRequestVersion;
    final startLocation = _myLocation!;
    try {
      final response = await http
          .post(
            Uri.parse(
              'https://api.openrouteservice.org/v2/directions/foot-walking/geojson',
            ),
            headers: {
              'Authorization': widget.orsApiKey!,
              'Content-Type': 'application/json',
            },
            body: json.encode({
              'coordinates': [
                [startLocation.longitude, startLocation.latitude],
                [hub.lon, hub.lat],
              ],
              'instructions': true,
            }),
          )
          .timeout(const Duration(seconds: 20));
      debugPrint('========== ORS RESPONSE ==========');
      debugPrint('Status code: ${response.statusCode}');
      debugPrint('Response body: ${response.body}');
      debugPrint('==================================');

      if (response.statusCode != 200) {
        throw Exception('ORS HTTP ${response.statusCode}: ${response.body}');
      }
      final data = json.decode(response.body) as Map<String, dynamic>;
      final features = data['features'] as List<dynamic>;
      if (features.isEmpty) {
        throw Exception('No walking route returned.');
      }
      final feature = features.first as Map<String, dynamic>;
      final geometry = feature['geometry'] as Map<String, dynamic>;
      final properties = feature['properties'] as Map<String, dynamic>;
      final coordinates = geometry['coordinates'] as List<dynamic>;
      final summary = properties['summary'] as Map<String, dynamic>;
      final route = coordinates.map<LatLng>((coordinate) {
        final pair = coordinate as List<dynamic>;
        return LatLng((pair[1] as num).toDouble(), (pair[0] as num).toDouble());
      }).toList();
      if (route.length < 2) {
        throw Exception('Walking route has insufficient coordinates.');
      }
      final steps = <WalkingNavigationStep>[];
      final segments = properties['segments'] as List<dynamic>? ?? [];
      for (final segment in segments) {
        final segmentData = segment as Map<String, dynamic>;
        final rawSteps = segmentData['steps'] as List<dynamic>? ?? [];
        for (final rawStep in rawSteps) {
          final step = rawStep as Map<String, dynamic>;
          final wayPoints = step['way_points'] as List<dynamic>?;
          if (wayPoints == null || wayPoints.length < 2) {
            continue;
          }
          steps.add(
            WalkingNavigationStep(
              instruction:
                  step['instruction']?.toString() ?? 'Continue walking',
              type: (step['type'] as num?)?.toInt() ?? -1,
              startIndex: (wayPoints[0] as num).toInt(),
              endIndex: (wayPoints[1] as num).toInt(),
            ),
          );
        }
      }
      if (!mounted ||
          requestVersion != _routeRequestVersion ||
          _guidingHub?.id != hub.id) {
        return;
      }
      setState(() {
        // Keep the original ORS route unchanged.
        _routePoints = route;
        _navigationSteps = steps;
        _routeTotalDistanceM = (summary['distance'] as num).toDouble();
        _routeTotalDurationS = (summary['duration'] as num).toDouble();
        _routeDistanceM = _routeTotalDistanceM;
        _routeDurationS = _routeTotalDurationS;
        _nextInstruction = steps.isNotEmpty
            ? steps.first.instruction
            : 'Follow the walking route';
        _distanceToNextTurnM = steps.isNotEmpty
            ? _distanceAlongRouteToIndex(steps.first.startIndex)
            : null;
        _offRouteReadings = 0;
        _arrivalReadings = 0;
        _errorMessage = null;
      });
      if (steps.isEmpty) {
        debugPrint('[HUB NAVIGATION] ORS returned no walking instructions.');
      }

      if (fitCamera) {
        _mapController.fitCamera(
          CameraFit.coordinates(
            coordinates: route,
            padding: const EdgeInsets.all(80),
          ),
        );
      }
      debugPrint(
        'Walking route loaded: '
        '${route.length} coordinates, '
        '${steps.length} navigation steps',
      );
    } catch (error, stackTrace) {
      debugPrint('===== WALKING ROUTE ERROR =====');
      debugPrint('Error: $error');
      debugPrintStack(stackTrace: stackTrace);
      debugPrint('===============================');
      debugPrint('Walking route error: $error');
      if (!mounted || requestVersion != _routeRequestVersion) return;
      setState(() {
        _errorMessage =
            'Unable to update walking directions. Please check the route.';
      });
    } finally {
      _isRouting = false;
    }
  }

  void _updateGuidance(Position position) {
    final hub = _guidingHub;
    if (hub == null || _routePoints.length < 2) return;
    // Do not make navigation decisions using unreliable GPS fixes.
    if (position.accuracy > _maximumGuidanceAccuracyM) {
      _offRouteReadings = 0;
      _arrivalReadings = 0;
      return;
    }
    final me = LatLng(position.latitude, position.longitude);
    final destination = LatLng(hub.lat, hub.lon);
    final progress = _calculateRouteProgress(me);
    if (progress == null) return;
    // Detect arrival using repeated accurate readings.
    final distanceToHub = _distanceBetween(me, destination);
    if (distanceToHub <= 20 && position.accuracy <= 20) {
      _arrivalReadings++;
    } else {
      _arrivalReadings = 0;
    }
    if (_arrivalReadings >= 3) {
      _stopGuiding();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('You have arrived at ${hub.name}')),
      );
      return;
    }
    // Only reroute after several reliable off-route readings.
    if (progress.distanceFromRoute > _offRouteThresholdM) {
      _offRouteReadings++;
    } else {
      _offRouteReadings = 0;
    }
    if (_offRouteReadings >= _requiredOffRouteReadings &&
        !_isRouting &&
        DateTime.now().difference(_lastReroute).inSeconds >= 20) {
      _offRouteReadings = 0;
      unawaited(_fetchRoute(hub));
      return;
    }
    // Calculate remaining distance without modifying the route.
    final totalGeometryDistance = _distanceAlongRouteToIndex(
      _routePoints.length - 1,
    );
    final remainingGeometryDistance =
        (totalGeometryDistance - progress.distanceAlongRoute)
            .clamp(0.0, totalGeometryDistance)
            .toDouble();
    // Use the route service's distance for the displayed total.
    final scale = totalGeometryDistance > 0
        ? (_routeTotalDistanceM ?? totalGeometryDistance) /
              totalGeometryDistance
        : 1.0;
    final remainingDistance = remainingGeometryDistance * scale;
    final totalDuration = _routeTotalDurationS ?? 0;
    final remainingDuration = totalGeometryDistance > 0
        ? totalDuration * (remainingGeometryDistance / totalGeometryDistance)
        : 0.0;
    String instruction = 'Continue following the walking route';
    double? distanceToTurn;
    for (int i = 0; i < _navigationSteps.length; i++) {
      final step = _navigationSteps[i];
      final startDistance = _distanceAlongRouteToIndex(step.startIndex);
      if (startDistance + 5 >= progress.distanceAlongRoute) {
        instruction = step.instruction;
        distanceToTurn = (startDistance - progress.distanceAlongRoute)
            .clamp(0.0, double.infinity)
            .toDouble();
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _routeDistanceM = remainingDistance;
      _routeDurationS = remainingDuration;
      _nextInstruction = instruction;
      _distanceToNextTurnM = distanceToTurn;
    });
  }

  void _stopGuiding() {
    _routeRequestVersion++;
    setState(() {
      _guidingHub = null;
      _routePoints = [];
      _navigationSteps = [];
      _routeDistanceM = null;
      _routeDurationS = null;
      _routeTotalDistanceM = null;
      _routeTotalDurationS = null;
      _nextInstruction = null;
      _distanceToNextTurnM = null;
      _offRouteReadings = 0;
      _arrivalReadings = 0;
    });
  }

  String _formatDuration(double seconds) {
    final int minutes = (seconds / 60).ceil();
    if (minutes < 60) return '$minutes min';
    return '${minutes ~/ 60} h ${minutes % 60} min';
  }

  // ------------------------------------------------------------
  // BUILD
  // ------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby Bus Stops'),
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
      ),
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          _buildMap(),
          // ---- Top overlay: search bar / results / banner ----
          // Positioned independently (not sharing a Column+Spacer with the
          // bottom card) so it only ever takes the height its own content
          // needs. This is what avoids the "bottom overflowed" error when
          // the keyboard shrinks the available body height.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: _buildSearchBar(),
                  ),
                  if (_showSearchResults) ...[
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _buildSearchResults(),
                    ),
                  ],
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _buildBanner(),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // ---- Bottom overlay: hub card ----
          // Hidden while the keyboard is open since it isn't useful mid-search
          // and would otherwise fight the keyboard for space.
          if (MediaQuery.of(context).viewInsets.bottom == 0)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Align(
                        alignment: Alignment.centerRight,
                        child: FloatingActionButton.small(
                          heroTag: 'my_location_fab',
                          onPressed: _centerOnMe,
                          backgroundColor: Colors.white,
                          foregroundColor: _primary,
                          tooltip: 'My location',
                          child: const Icon(Icons.my_location),
                        ),
                      ),
                      const SizedBox(height: 10),
                      _buildHubCard(),
                    ],
                  ),
                ),
              ),
            ),
          if (_isLoading)
            Container(
              color: Colors.black.withValues(alpha: 0.05),
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------
  // SEARCH BAR
  // ------------------------------------------------------------
  Widget _buildSearchBar() {
    return Material(
      elevation: 5,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            const Icon(Icons.search, color: Colors.grey),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'Search for a Bus Stop...',
                  border: InputBorder.none,
                  isCollapsed: true,
                ),
              ),
            ),
            if (_searchController.text.isNotEmpty)
              IconButton(
                onPressed: _clearSearch,
                tooltip: 'Clear',
                icon: const Icon(Icons.close, color: Colors.grey, size: 20),
              ),
            IconButton(
              onPressed: _showNearestHubs,
              tooltip: 'Nearby Bus Stops',
              icon: const Icon(Icons.near_me, color: _primary),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------
  // SEARCH RESULTS
  // ------------------------------------------------------------
  Widget _buildSearchResults() {
    return Material(
      elevation: 5,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(14),
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 260),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: _searchResults.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'No Bus Stops found.',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.black54,
                  ),
                ),
              )
            : ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _searchResults.length,
                separatorBuilder: (context, index) =>
                    const Divider(height: 1, indent: 16, endIndent: 16),
                itemBuilder: (context, index) {
                  final Hub hub = _searchResults[index];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.location_on, color: _primary),
                    title: Text(
                      hub.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      hub.address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: _myLocation != null
                        ? Text(
                            _formatDistance(_distanceToHub(hub)),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.black54,
                            ),
                          )
                        : null,
                    onTap: () {
                      _selectHub(hub);
                    },
                  );
                },
              ),
      ),
    );
  }

  // ------------------------------------------------------------
  // MAP
  // ------------------------------------------------------------
  Widget _buildMap() {
    final LatLng center = _myLocation ?? _defaultCenter;
    return FlutterMap(
      mapController:
          _mapController, // controls the map view (center, zoom, etc.)
      options: MapOptions(
        initialCenter: center,
        initialZoom: 13,
        minZoom: 10,
        maxZoom: 19,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', //loads the map tiles from OpenStreetMap
          userAgentPackageName: 'com.routepool.app',
          maxNativeZoom: 19,
        ),
        // Walking route (under the markers)
        if (_routePoints.isNotEmpty)
          PolylineLayer(
            polylines: [
              Polyline(
                points: _routePoints,
                strokeWidth: 5,
                color: _primary,
              ), //d
            ],
          ),
        // Hub markers (clustered). The list never changes on selection.
        MarkerClusterLayerWidget(
          //Groups nearby bus stop markers
          options: MarkerClusterLayerOptions(
            maxClusterRadius: 45,
            size: const Size(44, 44),
            padding: const EdgeInsets.all(50),
            maxZoom: 19,
            disableClusteringAtZoom: 17,
            markers: _hubMarkers,
            builder: (context, markers) => Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _primary,
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black38,
                    blurRadius: 5,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: Text(
                '${markers.length}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ),
        // Nearest stop (orange, larger, always visible)
        if (_nearestHub != null && _nearestHub?.id != _selectedHub?.id)
          MarkerLayer(
            markers: [
              Marker(
                point: LatLng(_nearestHub!.lat, _nearestHub!.lon),
                width: 44,
                height: 44,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _selectHub(_nearestHub!),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.orange,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black38,
                          blurRadius: 5,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.directions_bus,
                      size: 24,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        // Selected stop (big pin, tip sits exactly on the stop)
        if (_selectedHub != null)
          MarkerLayer(
            markers: [
              Marker(
                point: LatLng(_selectedHub!.lat, _selectedHub!.lon),
                width: 56,
                height: 56,
                alignment: Alignment.topCenter,
                child: const Icon(
                  Icons.location_on,
                  size: 52,
                  color: _primary,
                  shadows: [Shadow(color: Colors.black45, blurRadius: 6)],
                ),
              ),
            ],
          ),
        // Current location (always on top)
        // Current location with directional arrow
        if (_myLocation != null)
          MarkerLayer(
            markers: [
              Marker(
                point: _myLocation!,
                width: 60,
                height: 60,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.blue.withValues(alpha: 0.15),
                      ),
                    ),
                    Transform.rotate(
                      angle: _heading * pi / 180,
                      child: const Icon(
                        Icons.navigation,
                        size: 38,
                        color: Colors.blue,
                        shadows: [Shadow(color: Colors.black26, blurRadius: 5)],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }

  // ------------------------------------------------------------
  // ERROR / INFO BANNER
  // ------------------------------------------------------------
  Widget _buildBanner() {
    return Material(
      elevation: 4,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(12),
      color: Colors.white,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline, color: Colors.orange),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _errorMessage!,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: () => setState(() => _errorMessage = null),
              child: const Icon(Icons.close, size: 18, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------
  // HUB CARD
  // ------------------------------------------------------------
  Widget _buildHubCard() {
    final Hub? hub = _selectedHub ?? _nearestHub;
    if (hub == null) {
      return Material(
        elevation: 5,
        shadowColor: Colors.black26,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Text(
            'No nearby Bus Stops available.',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
      );
    }
    return Material(
      elevation: 6,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.30,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.location_on, color: _primary, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _selectedHub != null
                            ? 'Selected Bus Stop'
                            : 'Nearest Bus Stop',
                        style: const TextStyle(
                          color: _primary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (_myLocation != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: _primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _formatDistance(_distanceToHub(hub)),
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: _primary,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  hub.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  hub.address,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (_guidingHub?.id == hub.id && _nextInstruction != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: _primary.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.directions_walk,
                          color: _primary,
                          size: 28,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Walking directions',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: _primary,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                _nextInstruction!,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (_distanceToNextTurnM != null) ...[
                                const SizedBox(height: 5),
                                Text(
                                  '${_formatDistance(_distanceToNextTurnM!)} until next instruction',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade700,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                if (_guidingHub?.id == hub.id && _routeDistanceM != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(
                        Icons.directions_walk,
                        size: 16,
                        color: _primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${_formatDistance(_routeDistanceM!)} · '
                        '${_formatDuration(_routeDurationS!)} walk',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _primary,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final bool isNarrow = constraints.maxWidth < 320;
                    final bool isGuiding = _guidingHub?.id == hub.id;
                    final guideButton = _HubActionButton(
                      onPressed: () =>
                          isGuiding ? _stopGuiding() : _guideMeToHub(hub),
                      icon: isGuiding ? Icons.close : Icons.directions_walk,
                      label: isGuiding ? 'Stop' : 'Guide me',
                      color: isGuiding ? Colors.red.shade600 : _primary,
                    );
                    if (widget.isDriver) {
                      return SizedBox(
                        width: double.infinity,
                        child: guideButton,
                      );
                    }
                    final bookButton = _HubActionButton(
                      onPressed: () {
                        // Explicitly selected hub takes priority.
                        // If none is selected, use the nearest hub.
                        final Hub? pickupHub = _selectedHub ?? _nearestHub;
                        if (pickupHub == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'No pickup hub available. Please select a bus stop.',
                              ),
                            ),
                          );
                          return;
                        }
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => BookRideScreen(
                              pickupHubId: pickupHub.id,
                              pickupName: pickupHub.name,
                              pickupAddress: pickupHub.address,
                              pickupLat: pickupHub.lat,
                              pickupLon: pickupHub.lon,
                            ),
                          ),
                        );
                      },
                      icon: Icons.book_online,
                      label: 'Book from here',
                      color: _secondary,
                    );
                    if (isNarrow) {
                      return Column(
                        children: [
                          SizedBox(width: double.infinity, child: guideButton),
                          const SizedBox(height: 10),
                          SizedBox(width: double.infinity, child: bookButton),
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: guideButton),
                        const SizedBox(width: 10),
                        Expanded(child: bookButton),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------
// REUSABLE ACTION BUTTON (overflow-safe label)
// ------------------------------------------------------------
/// Renders a labeled action button used in the selected-hub panel.
class _HubActionButton extends StatelessWidget {
  final VoidCallback onPressed;
  final IconData icon;
  final String label;
  final Color color;
  const _HubActionButton({
    required this.onPressed,
    required this.icon,
    required this.label,
    required this.color,
  });
  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
