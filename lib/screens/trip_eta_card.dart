import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const String _orsApiKey = String.fromEnvironment('ORS_API_KEY');

class TripEtaEstimates extends StatefulWidget {
  const TripEtaEstimates({
    super.key,
    required this.tripId,
    required this.tripData,
    required this.builder,
  });

  final String tripId;
  final Map<String, dynamic> tripData;
  final Widget Function(BuildContext context, TripEtaResult estimates) builder;

  @override
  State<TripEtaEstimates> createState() => _TripEtaEstimatesState();
}

class TripEtaResult {
  const TripEtaResult({this.pickupEta, this.stopEtas = const {}, this.message});

  final String? pickupEta;
  final Map<String, String> stopEtas;
  final String? message;
}

class _TripEtaEstimatesState extends State<TripEtaEstimates> {
  static const _refreshInterval = Duration(minutes: 1);
  static const _driverLocationMaxAge = Duration(seconds: 90);

  Timer? _refreshTimer;
  String? _currentRouteKey;
  String? _driverLocationStreamKey;
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _driverLocationStream;
  DateTime? _lastRequestedAt;
  Future<List<double>>? _estimate;
  List<({String id, double lat, double lon})> _pendingStops = [];
  ({double lat, double lon})? _pendingOrigin;
  bool _isPickupEstimate = false;

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.tripData['status']?.toString() ?? '';
    if (!const {
      'driver_assigned',
      'driver_arrived',
      'in_progress',
    }.contains(status)) {
      return widget.builder(context, const TripEtaResult());
    }

    final requestIds = _stringIds(widget.tripData['requestIds']);
    if (requestIds.isEmpty) {
      return widget.builder(
        context,
        const TripEtaResult(message: 'Estimated times are unavailable.'),
      );
    }

    return _loadRequests(requestIds, 0, const {});
  }

  Widget _loadRequests(
    List<String> requestIds,
    int index,
    Map<String, Map<String, dynamic>?> requests,
  ) {
    if (index >= requestIds.length) return _buildEstimate(requests);

    final requestId = requestIds[index];
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('ride_requests')
          .doc(requestId)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return widget.builder(
            context,
            TripEtaResult(
              message: 'Unable to load ride stops: ${snapshot.error}',
            ),
          );
        }
        if (!snapshot.hasData) {
          return widget.builder(
            context,
            const TripEtaResult(message: 'Loading estimated times…'),
          );
        }
        return _loadRequests(requestIds, index + 1, {
          ...requests,
          requestId: snapshot.data!.data(),
        });
      },
    );
  }

  Widget _buildEstimate(Map<String, Map<String, dynamic>?> requests) {
    final driverId = widget.tripData['driverId'];
    if (driverId is! String || driverId.isEmpty) {
      return _buildEstimateFromLocation(requests, null);
    }

    final streamKey = '${widget.tripId}/$driverId';
    if (_driverLocationStreamKey != streamKey) {
      _driverLocationStreamKey = streamKey;
      _driverLocationStream = FirebaseFirestore.instance
          .collection('trips')
          .doc(widget.tripId)
          .collection('live_locations')
          .doc(driverId)
          .snapshots();
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _driverLocationStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return widget.builder(
            context,
            const TripEtaResult(
              message: 'Unable to load the driver’s live location.',
            ),
          );
        }
        return _buildEstimateFromLocation(
          requests,
          _readDriverLocation(snapshot.data?.data()),
        );
      },
    );
  }

  Widget _buildEstimateFromLocation(
    Map<String, Map<String, dynamic>?> requests,
    ({double lat, double lon})? driverLocation,
  ) {
    final trip = widget.tripData;
    final status = trip['status']?.toString() ?? '';
    final pickup = _readPoint(trip['pickupLat'], trip['pickupLon']);

    final stops = <({String id, double lat, double lon})>[];
    var isPickupEstimate = false;
    if (status == 'driver_assigned') {
      if (pickup == null) {
        return widget.builder(
          context,
          const TripEtaResult(
            message: 'Pickup coordinates are unavailable for the driver ETA.',
          ),
        );
      }
      stops.add((id: 'pickup', lat: pickup.lat, lon: pickup.lon));
      isPickupEstimate = true;
    } else {
      final requestIds = _stringIds(trip['requestIds']);
      final optimizedOrder = _stringIds(trip['optimizedDropoffOrder']);
      final orderedIds = <String>{
        ...optimizedOrder.where(requestIds.contains),
        ...requestIds.where((id) => !optimizedOrder.contains(id)),
      };

      for (final id in orderedIds) {
        final request = requests[id];
        if (request == null ||
            const {
              'cancelled',
              'drop_off_confirmed',
              'completed',
            }.contains(request['status'])) {
          continue;
        }
        final point = _readPoint(request['dropoffLat'], request['dropoffLon']);
        if (point != null) {
          stops.add((id: id, lat: point.lat, lon: point.lon));
        }
      }
    }

    if (stops.isEmpty) {
      return widget.builder(
        context,
        const TripEtaResult(message: 'No drop-off estimates are available.'),
      );
    }

    final origin = status == 'driver_assigned'
        ? driverLocation
        : (driverLocation ?? (status == 'driver_arrived' ? pickup : null));
    if (origin == null) {
      return widget.builder(
        context,
        const TripEtaResult(
          message: 'Waiting for the driver’s live location to estimate times.',
        ),
      );
    }

    final routeKey = [
      widget.tripId,
      status,
      '${origin.lat},${origin.lon}',
      for (final stop in stops) '${stop.id}:${stop.lat},${stop.lon}',
    ].join('|');

    _pendingOrigin = origin;
    _pendingStops = stops;
    _isPickupEstimate = isPickupEstimate;
    if (routeKey != _currentRouteKey) {
      _currentRouteKey = routeKey;
      _estimate = null;
      _scheduleEstimate();
    }

    return FutureBuilder<List<double>>(
      future: _estimate,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return widget.builder(
            context,
            TripEtaResult(
              message: 'Unable to calculate ETAs: ${snapshot.error}',
            ),
          );
        }
        if (!snapshot.hasData) {
          return widget.builder(
            context,
            const TripEtaResult(message: 'Calculating estimated times…'),
          );
        }

        final durations = snapshot.data!;
        var cumulativeSeconds = 0.0;
        if (_isPickupEstimate) {
          return widget.builder(
            context,
            TripEtaResult(
              pickupEta: 'About ${_formatMinutes(durations.first)}',
            ),
          );
        }
        final stopEtas = <String, String>{};
        for (var index = 0; index < stops.length; index++) {
          cumulativeSeconds += durations[index];
          stopEtas[stops[index].id] =
              'Drive ${_formatMinutes(durations[index])} · arrive in about '
              '${_formatMinutes(cumulativeSeconds)}';
        }
        return widget.builder(context, TripEtaResult(stopEtas: stopEtas));
      },
    );
  }

  void _scheduleEstimate() {
    final lastRequestedAt = _lastRequestedAt;
    final elapsed = lastRequestedAt == null
        ? _refreshInterval
        : DateTime.now().difference(lastRequestedAt);
    if (elapsed >= _refreshInterval) {
      _startEstimate();
      return;
    }

    _refreshTimer ??= Timer(_refreshInterval - elapsed, () {
      if (!mounted) return;
      setState(() {
        _refreshTimer = null;
        _currentRouteKey = null;
      });
    });
  }

  void _startEstimate() {
    final origin = _pendingOrigin;
    final stops = _pendingStops;
    if (origin == null || stops.isEmpty) return;

    _lastRequestedAt = DateTime.now();
    _estimate = _fetchDurations(origin, stops);
    _refreshTimer?.cancel();
    _refreshTimer = Timer(_refreshInterval, () {
      if (!mounted) return;
      setState(() {
        _refreshTimer = null;
        _currentRouteKey = null;
      });
    });
  }

  Future<List<double>> _fetchDurations(
    ({double lat, double lon}) origin,
    List<({String id, double lat, double lon})> stops,
  ) async {
    if (_orsApiKey.isEmpty) {
      throw StateError('OpenRouteService is not configured.');
    }

    final locations = [
      [origin.lon, origin.lat],
      for (final stop in stops) [stop.lon, stop.lat],
    ];
    final response = await http
        .post(
          Uri.https('api.openrouteservice.org', '/v2/matrix/driving-car'),
          headers: {
            'Authorization': _orsApiKey,
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'locations': locations,
            'metrics': ['duration'],
          }),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw StateError('Routing service returned ${response.statusCode}.');
    }

    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic> || body['durations'] is! List) {
      throw const FormatException(
        'Routing service returned invalid durations.',
      );
    }
    final matrix = body['durations'] as List;
    final durations = <double>[];
    var from = 0;
    for (var index = 1; index < locations.length; index++) {
      if (from >= matrix.length || matrix[from] is! List) {
        throw const FormatException(
          'Routing service returned an incomplete route.',
        );
      }
      final row = matrix[from] as List;
      if (index >= row.length || row[index] is! num) {
        throw const FormatException(
          'A route segment has no duration estimate.',
        );
      }
      final seconds = (row[index] as num).toDouble();
      if (!seconds.isFinite || seconds < 0) {
        throw const FormatException('A route segment has an invalid duration.');
      }
      durations.add(seconds);
      from = index;
    }
    return durations;
  }
}

({double lat, double lon})? _readPoint(dynamic lat, dynamic lon) {
  if (lat is! num || lon is! num) return null;
  final latitude = lat.toDouble();
  final longitude = lon.toDouble();
  if (!latitude.isFinite ||
      !longitude.isFinite ||
      latitude < -90 ||
      latitude > 90 ||
      longitude < -180 ||
      longitude > 180) {
    return null;
  }
  return (lat: latitude, lon: longitude);
}

({double lat, double lon})? _readDriverLocation(
  Map<String, dynamic>? location,
) {
  if (location == null || location['role'] != 'driver') return null;
  final updatedAt = location['updatedAt'];
  if (updatedAt is! Timestamp) return null;
  final age = DateTime.now().difference(updatedAt.toDate());
  if (age.isNegative || age > _TripEtaEstimatesState._driverLocationMaxAge) {
    return null;
  }
  return _readPoint(location['lat'], location['lon']);
}

List<String> _stringIds(dynamic value) {
  if (value is! List) return const [];
  return value.whereType<String>().where((id) => id.isNotEmpty).toList();
}

String _formatMinutes(double seconds) {
  final minutes = (seconds / 60).ceil();
  return minutes < 1 ? 'less than 1 min' : '$minutes min';
}
