import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Class: RideRequestService
/// -------------------------------------------------------------------
/// Handles ride request operations, including destination suggestions,
/// coordinate validation, and saving ride requests to Firestore.
class RideRequestService {
  // Provides access to the Firestore database.
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Provides access to the currently authenticated user.
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Method: _isWithinPenangBounds
  /// -----------------------------------------------------------------
  /// Checks whether the supplied coordinates fall within the approximate
  /// coordinate ranges defined for Penang Island or Seberang Perai.
  static bool _isWithinPenangBounds(double lat, double lon) {
    // Checks the approximate coordinate range for Penang Island.
    final onPenangIsland =
        lat >= 5.12 && lat <= 5.50 && lon >= 100.12 && lon <= 100.42;

    // Checks the approximate coordinate range for Seberang Perai.
    final onSeberangPerai =
        lat >= 5.10 && lat <= 5.72 && lon >= 100.28 && lon <= 100.62;

    // Accepts coordinates within either geographic range.
    return onPenangIsland || onSeberangPerai;
  }

  /// Method: _hasValidCoordinates
  /// -----------------------------------------------------------------
  /// Checks whether latitude and longitude are finite numbers within
  /// the valid global coordinate ranges.
  ///
  /// Latitude must be between -90 and 90 degrees, while longitude
  /// must be between -180 and 180 degrees.
  static bool _hasValidCoordinates(double lat, double lon) {
    return lat.isFinite &&
        lon.isFinite &&
        lat >= -90 &&
        lat <= 90 &&
        lon >= -180 &&
        lon <= 180;
  }

  /// Method: _isPenangResult
  /// -----------------------------------------------------------------
  /// Determines whether a Photon result qualifies as a Penang location.
  ///
  /// The method checks coordinate validity, the approximate Penang
  /// coordinate ranges, and administrative information returned by
  /// Photon, such as state, district, city, or municipality.
  static bool _isPenangResult(
    Map<String, dynamic> properties,
    double lat,
    double lon,
  ) {
    // Rejects invalid coordinates and locations outside the defined
    // approximate Penang coordinate ranges.
    if (!_hasValidCoordinates(lat, lon) || !_isWithinPenangBounds(lat, lon)) {
      return false;
    }

    // Collects administrative location fields provided by Photon.
    final administrativeFields = [
      properties['state'],
      properties['county'],
      properties['district'],
      properties['city'],
      properties['locality'],
      properties['municipality'],
    ];

    // Converts available fields to lowercase text for comparison.
    final administrativeText = administrativeFields
        .where((value) => value != null)
        .map((value) => value.toString().toLowerCase())
        .join(' ');

    // Accepts results whose administrative information contains
    // a recognised Penang-related name.
    return administrativeText.contains('penang') ||
        administrativeText.contains('pulau pinang') ||
        administrativeText.contains('seberang perai');
  }

  /// Method: searchDestinationSuggestions
  /// -----------------------------------------------------------------
  /// Searches for destination suggestions using the Photon API.
  ///
  /// The selected pickup coordinates are passed to Photon to prioritise
  /// nearby results. Returned results are filtered using coordinate
  /// validation and Penang-related administrative information.
  ///
  /// Returns a list of maps containing the destination address,
  /// latitude, and longitude.
  Future<List<Map<String, dynamic>>> searchDestinationSuggestions(
    String query, {
    required double pickupLat,
    required double pickupLon,
  }) async {
    // Removes unnecessary whitespace from the search query.
    final trimmedQuery = query.trim();

    // Requires at least three characters before searching.
    if (trimmedQuery.length < 3) {
      return [];
    }

    // Validates the pickup coordinates before making the request.
    if (!_hasValidCoordinates(pickupLat, pickupLon) ||
        !_isWithinPenangBounds(pickupLat, pickupLon)) {
      throw Exception('The pick-up coordinates are invalid or outside Penang.');
    }

    // Builds the Photon API request using the search query and
    // pickup coordinates to prioritise nearby search results.
    final uri = Uri.https('photon.komoot.io', '/api/', {
      'q': trimmedQuery,
      'limit': '15',
      'lang': 'en',
      'lat': pickupLat.toString(),
      'lon': pickupLon.toString(),
    });

    // Logs the request URL for debugging purposes.
    debugPrint('[Photon] Searching: $uri');

    // Sends the HTTP request with an application identifier and
    // a timeout to prevent the request from waiting indefinitely.
    final response = await http
        .get(uri, headers: {'User-Agent': 'RoutePool/1.0'})
        .timeout(const Duration(seconds: 20));

    // Reports an error if Photon does not return a successful response.
    if (response.statusCode != 200) {
      throw Exception('Unable to load destination suggestions.');
    }

    // Decodes the JSON response and extracts the returned features.
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final features = data['features'] as List<dynamic>? ?? [];

    // Stores only destination suggestions that pass validation.
    final suggestions = <Map<String, dynamic>>[];

    // Processes each result returned by Photon.
    for (final feature in features) {
      // Skips results that are not valid feature objects.
      if (feature is! Map<String, dynamic>) {
        continue;
      }

      // Extracts the place information and geographic coordinates.
      final properties = feature['properties'] as Map<String, dynamic>? ?? {};
      final geometry = feature['geometry'] as Map<String, dynamic>? ?? {};
      final coordinates = geometry['coordinates'] as List<dynamic>?;

      // GeoJSON coordinates use [longitude, latitude] order.
      // Skips results without both coordinate values.
      if (coordinates == null || coordinates.length < 2) {
        continue;
      }

      final rawLon = coordinates[0];
      final rawLat = coordinates[1];

      // Ensures both coordinate values are numeric.
      if (rawLat is! num || rawLon is! num) {
        continue;
      }

      // Converts the coordinate values to double precision.
      final lat = rawLat.toDouble();
      final lon = rawLon.toDouble();

      // Excludes results that fail the Penang location checks.
      if (!_isPenangResult(properties, lat, lon)) {
        continue;
      }

      // Builds the destination address from available Photon fields.
      final parts = <String>[
        if (properties['housenumber'] != null && properties['street'] != null)
          '${properties['housenumber']} ${properties['street']}'
        else if (properties['street'] != null)
          properties['street'].toString(),
        if (properties['name'] != null) properties['name'].toString(),
        if (properties['district'] != null) properties['district'].toString(),
        if (properties['city'] != null) properties['city'].toString(),
        if (properties['county'] != null) properties['county'].toString(),
        if (properties['state'] != null) properties['state'].toString(),
        if (properties['postcode'] != null) properties['postcode'].toString(),
        if (properties['country'] != null) properties['country'].toString(),
      ];

      // Removes empty and duplicate address components.
      final uniqueParts = <String>[];

      for (final part in parts) {
        final cleaned = part.trim();

        if (cleaned.isNotEmpty && !uniqueParts.contains(cleaned)) {
          uniqueParts.add(cleaned);
        }
      }

      // Combines the address components into a single readable string.
      final address = uniqueParts.join(', ');

      // Skips results without a usable address.
      if (address.isEmpty) {
        continue;
      }

      // Adds the validated destination to the suggestion list.
      suggestions.add({'address': address, 'lat': lat, 'lon': lon});

      // Stops after collecting five valid suggestions.
      if (suggestions.length >= 5) {
        break;
      }
    }

    // Returns the validated destination suggestions to the caller.
    return suggestions;
  }

  /// Method: createRideRequest
  /// -----------------------------------------------------------------
  /// Creates a ride request for the currently authenticated passenger.
  ///
  /// Validates the passenger's authentication status, departure time,
  /// passenger count, pickup coordinates, and selected destination.
  /// If validation succeeds, the ride request is saved to Firestore.
  ///
  /// Returns the document ID of the newly created ride request.
  Future<String> createRideRequest({
    required String pickupHubId,
    required String pickupName,
    required String pickupAddress,
    required double pickupLat,
    required double pickupLon,
    required String dropoffAddress,
    double? dropoffLat,
    double? dropoffLon,
    required int passengerCount,
  }) async {
    // Retrieves the currently authenticated Firebase user.
    final user = _auth.currentUser;

    // Prevents unauthenticated users from creating ride requests.
    if (user == null) {
      throw Exception('Please sign in before booking a ride.');
    }

    // Validate the passenger count against RoutePool's supported capacity.
    if (passengerCount < 1 || passengerCount > 12) {
      throw Exception('Passenger count must be between 1 and 12.');
    }

    // Validates the pickup coordinates and approximate Penang location.
    if (!_hasValidCoordinates(pickupLat, pickupLon) ||
        !_isWithinPenangBounds(pickupLat, pickupLon)) {
      throw Exception('The pick-up coordinates are invalid or outside Penang.');
    }

    // Requires a non-empty destination address.
    if (dropoffAddress.trim().isEmpty) {
      throw Exception('Please select a destination from the suggestions.');
    }

    // Requires destination coordinates from a selected suggestion.
    // Arbitrary typed addresses are not geocoded as a fallback.
    if (dropoffLat == null || dropoffLon == null) {
      throw Exception('Please select a destination from the suggestions.');
    }

    // Validates the destination coordinates and approximate Penang area.
    if (!_hasValidCoordinates(dropoffLat, dropoffLon) ||
        !_isWithinPenangBounds(dropoffLat, dropoffLon)) {
      throw Exception(
        'Your destination coordinates are invalid or outside Penang.',
      );
    }

    // Prepares the ride request data for storage in Firestore.
    final request = <String, dynamic>{
      'passengerId': user.uid,
      'pickupHubId': pickupHubId,
      'pickupName': pickupName,
      'pickupAddress': pickupAddress,
      'pickupLat': pickupLat,
      'pickupLon': pickupLon,
      'dropoffAddress': dropoffAddress.trim(),
      'dropoffLat': dropoffLat,
      'dropoffLon': dropoffLon,
      'departureTime': FieldValue.serverTimestamp(),
      'passengerCount': passengerCount,
      'status': 'searching',
      'groupId': null,
      'driverId': null,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    // Saves the ride request to the ride_requests collection.
    final doc = await _firestore.collection('ride_requests').add(request);

    // Returns the ID assigned to the newly created document.
    return doc.id;
  }
}
