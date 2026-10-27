import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

class DriverLocationService {
  DriverLocationService._();

  static final DriverLocationService instance = DriverLocationService._();

  static const Duration _heartbeatInterval = Duration(seconds: 30);
  static const Duration _minimumUploadInterval = Duration(seconds: 10);
  static const double _minimumMovementMeters = 20;

  StreamSubscription<Position>? _subscription;
  Timer? _heartbeatTimer;

  String? _driverId;
  Position? _lastPosition;
  DateTime? _lastUpload;

  bool _uploading = false;
  int _generation = 0;

  Future<void>? _startFuture;
  String? _startingDriverId;

  // Serializes GPS startup and shutdown operations.
  Future<void> _lifecycleQueue = Future<void>.value();

  // Invalidates outdated startup requests.
  int _requestId = 0;

  bool get isTracking =>
      _driverId != null && _subscription != null && _heartbeatTimer != null;

  /// Starts availability GPS tracking for the specified driver.
  ///
  /// Reuses an existing session or pending startup for the same driver.
  Future<void> startTracking(String driverId) {
    if (isTracking && _driverId == driverId) {
      return Future<void>.value();
    }

    if (_startFuture != null && _startingDriverId == driverId) {
      return _startFuture!;
    }

    final requestId = ++_requestId;
    _startingDriverId = driverId;

    final completer = Completer<void>();
    final future = completer.future;

    _startFuture = future;

    // Wait for any previous start/stop operation to finish.
    final operation = _lifecycleQueue.then((_) async {
      if (requestId != _requestId) {
        throw StateError('GPS startup was cancelled.');
      }

      await _resetTracking();

      if (requestId != _requestId) {
        throw StateError('GPS startup was cancelled.');
      }

      await _startTrackingInternal(driverId, requestId);
    });

    // Keep the lifecycle queue usable even if startup fails.
    _lifecycleQueue = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );

    operation.then(
      (_) {
        if (!completer.isCompleted) {
          completer.complete();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );

    future.then<void>(
      (_) {
        if (requestId == _requestId) {
          _startFuture = null;
          _startingDriverId = null;
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (requestId == _requestId) {
          _startFuture = null;
          _startingDriverId = null;
        }
      },
    );

    return future;
  }

  /// Performs GPS initialization after lifecycle coordination.
  Future<void> _startTrackingInternal(String driverId, int requestId) async {
    final generation = _generation;

    try {
      final enabled = await Geolocator.isLocationServiceEnabled();

      if (!enabled) {
        throw Exception('Please enable GPS before going online.');
      }

      var permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception(
          'Location permission is required to receive ride requests.',
        );
      }

      _ensureCurrentRequest(generation, requestId);

      _driverId = driverId;
      _lastPosition = null;
      _lastUpload = null;

      // Obtain the driver's initial GPS position.
      final initialPosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );

      _ensureCurrentRequest(generation, requestId);

      // Upload the initial location before enabling availability.
      await _saveLocation(initialPosition, generation: generation, force: true);

      _ensureCurrentRequest(generation, requestId);

      // A failed or skipped initial upload must not count as success.
      if (_lastUpload == null) {
        throw StateError('Initial GPS location was not uploaded.');
      }

      // Subscribe to movement updates.
      _subscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 20,
            ),
          ).listen(
            (position) {
              if (!_isCurrentSession(generation, driverId)) return;

              _saveLocation(position, generation: generation).catchError((
                Object error,
              ) {
                debugPrint('Driver GPS upload failed: $error');
              });
            },
            onError: (Object error) {
              debugPrint('Driver GPS tracking error: $error');
            },
          );

      // Refresh the driver's location even when stationary.
      _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
        _refreshLocation(generation, driverId);
      });

      _ensureCurrentRequest(generation, requestId);

      debugPrint('Driver GPS tracking started.');
    } catch (e) {
      // Only clean up if this startup still owns the GPS session.
      if (generation == _generation) {
        await _resetTracking();
      }

      rethrow;
    }
  }

  /// Throws if this startup has been cancelled or replaced.
  void _ensureCurrentRequest(int generation, int requestId) {
    if (_generation != generation || _requestId != requestId) {
      throw StateError('GPS startup was cancelled.');
    }
  }

  /// Checks whether a callback belongs to the current tracking session.
  bool _isCurrentSession(int generation, String driverId) {
    return _generation == generation && _driverId == driverId;
  }

  /// Refreshes GPS location on the heartbeat interval.
  Future<void> _refreshLocation(int generation, String driverId) async {
    if (!_isCurrentSession(generation, driverId)) return;

    // Avoid overlapping uploads.
    if (_uploading) return;

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );

      if (!_isCurrentSession(generation, driverId)) return;

      // Force an update to keep the Firestore timestamp fresh.
      await _saveLocation(position, generation: generation, force: true);
    } catch (e) {
      debugPrint('Driver GPS heartbeat failed: $e');
    }
  }

  /// Uploads the driver's current position to Firestore.
  Future<void> _saveLocation(
    Position position, {
    required int generation,
    bool force = false,
  }) async {
    final uid = _driverId;

    if (uid == null || !_isCurrentSession(generation, uid)) {
      return;
    }

    if (_uploading) return;

    final now = DateTime.now();

    // Avoid unnecessary movement-triggered uploads.
    // Heartbeat updates bypass this condition.
    if (!force && _lastUpload != null && _lastPosition != null) {
      final elapsed = now.difference(_lastUpload!);

      final distance = Geolocator.distanceBetween(
        _lastPosition!.latitude,
        _lastPosition!.longitude,
        position.latitude,
        position.longitude,
      );

      if (elapsed < _minimumUploadInterval ||
          distance < _minimumMovementMeters) {
        return;
      }
    }

    _uploading = true;

    try {
      await FirebaseFirestore.instance
          .collection('driver_locations')
          .doc(uid)
          .set({
            'lat': position.latitude,
            'lon': position.longitude,
            'accuracy': position.accuracy,
            'updatedAt': FieldValue.serverTimestamp(),
          });

      if (_isCurrentSession(generation, uid)) {
        _lastUpload = DateTime.now();
        _lastPosition = position;
      }

      debugPrint('Driver GPS location updated.');
    } finally {
      _uploading = false;
    }
  }

  /// Clears the active GPS session.
  ///
  /// This method does not invalidate the startup request ID.
  Future<void> _resetTracking() async {
    _generation++;
    _driverId = null;

    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    final oldSubscription = _subscription;
    _subscription = null;

    await oldSubscription?.cancel();

    _lastPosition = null;
    _lastUpload = null;

    debugPrint('Driver GPS tracking stopped.');
  }

  /// Stops availability GPS and cancels pending startup requests.
  Future<void> stopTracking() {
    // Immediately invalidate any pending startup.
    ++_requestId;

    _startingDriverId = null;
    _startFuture = null;

    final operation = _lifecycleQueue.then((_) async {
      await _resetTracking();
    });

    // Preserve queue continuity if cleanup fails.
    _lifecycleQueue = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );

    return operation;
  }
}
