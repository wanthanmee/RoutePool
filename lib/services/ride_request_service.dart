import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class RideRequestService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  final FirebaseAuth _auth = FirebaseAuth.instance;

  Future<List<Map<String, dynamic>>> searchDestinationSuggestions(
    String query,
  ) async {
    final trimmedQuery = query.trim();

    if (trimmedQuery.length < 3) {
      return [];
    }

    final uri = Uri.https('photon.komoot.io', '/api/', {
      'q': trimmedQuery,
      'limit': '5',
      'lang': 'en',
      'lat': '5.4141',
      'lon': '100.3288',
    });

    debugPrint('[Photon Service] Request URL: $uri');
    debugPrint('[Photon Service] Sending HTTP request...');

    final response = await http
        .get(uri, headers: {'User-Agent': 'RoutePool/1.0'})
        .timeout(const Duration(seconds: 20));

    debugPrint('[Photon Service] Status: ${response.statusCode}');
    debugPrint('[Photon Service] Response: ${response.body}');

    if (response.statusCode != 200) {
      throw Exception('Unable to load destination suggestions.');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final features = data['features'] as List<dynamic>? ?? [];

    return features
        .map((feature) {
          final item = feature as Map<String, dynamic>;
          final properties = item['properties'] as Map<String, dynamic>? ?? {};
          final geometry = item['geometry'] as Map<String, dynamic>? ?? {};
          final coordinates = geometry['coordinates'] as List<dynamic>? ?? [];

          final parts = <String>[
            if (properties['housenumber'] != null &&
                properties['street'] != null)
              '${properties['housenumber']} ${properties['street']}'
            else if (properties['street'] != null)
              properties['street'].toString(),
            if (properties['name'] != null) properties['name'].toString(),
            if (properties['district'] != null)
              properties['district'].toString(),
            if (properties['city'] != null) properties['city'].toString(),
            if (properties['state'] != null) properties['state'].toString(),
            if (properties['postcode'] != null)
              properties['postcode'].toString(),
            if (properties['country'] != null) properties['country'].toString(),
          ];

          // Remove repeated address components.
          final uniqueParts = <String>[];
          for (final part in parts) {
            if (!uniqueParts.contains(part)) {
              uniqueParts.add(part);
            }
          }

          return <String, dynamic>{
            'address': uniqueParts.join(', '),
            'lat': coordinates.length >= 2
                ? (coordinates[1] as num).toDouble()
                : null,
            'lon': coordinates.length >= 2
                ? (coordinates[0] as num).toDouble()
                : null,
          };
        })
        .where((suggestion) {
          return (suggestion['address'] as String).isNotEmpty;
        })
        .toList();
  }

  /// Converts a destination address into coordinates
  /// using OpenStreetMap Nominatim.
  Future<Map<String, dynamic>> _geocodeDestination(String address) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': address,
      'format': 'jsonv2',
      'limit': '1',
      'countrycodes': 'my',
    });

    final response = await http
        .get(uri, headers: {'User-Agent': 'RoutePool/1.0'})
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception(
        'Unable to search for the destination. Please try again.',
      );
    }

    final results = jsonDecode(response.body) as List<dynamic>;

    if (results.isEmpty) {
      throw Exception(
        'Destination not found. Please enter a more specific address.',
      );
    }

    final place = results.first as Map<String, dynamic>;

    return {
      'address': place['display_name'] as String,
      'lat': double.parse(place['lat'].toString()),
      'lon': double.parse(place['lon'].toString()),
    };
  }

  /// Creates a ride request for the currently signed-in passenger.
  Future<String> createRideRequest({
    required String pickupHubId,
    required String pickupName,
    required String pickupAddress,
    required double pickupLat,
    required double pickupLon,
    required String dropoffAddress,
    double? dropoffLat,
    double? dropoffLon,
    required DateTime departureDateTime,
    required int passengerCount,
  }) async {
    final user = _auth.currentUser;

    if (user == null) {
      throw Exception('Please sign in before booking a ride.');
    }

    if (!departureDateTime.isAfter(DateTime.now())) {
      throw Exception('Departure time must be in the future.');
    }

    if (passengerCount < 1 || passengerCount > 4) {
      throw Exception('Passenger count must be between 1 and 4.');
    }

    if (dropoffAddress.trim().isEmpty) {
      throw Exception('Please enter your destination.');
    }

    // Use the coordinates from the selected Photon suggestion.
    // Only geocode the address if coordinates are unavailable.
    final Map<String, dynamic> destination;

    if (dropoffLat != null && dropoffLon != null) {
      destination = {
        'address': dropoffAddress.trim(),
        'lat': dropoffLat,
        'lon': dropoffLon,
      };
    } else {
      destination = await _geocodeDestination(dropoffAddress.trim());
    }

    // Validate that destination coordinates exist.
    if (destination['lat'] == null || destination['lon'] == null) {
      throw Exception(
        'Unable to determine your destination. Please select a location suggestion.',
      );
    }

    // Convert coordinates to double.
    final double lat = (destination['lat'] as num).toDouble();
    final double lon = (destination['lon'] as num).toDouble();

    // Validate coordinate ranges.
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      throw Exception('The destination coordinates are invalid.');
    }

    final request = <String, dynamic>{
      'passengerId': user.uid,
      'pickupHubId': pickupHubId,
      'pickupName': pickupName,
      'pickupAddress': pickupAddress,
      'pickupLat': pickupLat,
      'pickupLon': pickupLon,
      'dropoffAddress': destination['address'],
      'dropoffLat': lat,
      'dropoffLon': lon,
      'departureTime': Timestamp.fromDate(departureDateTime),
      'passengerCount': passengerCount,
      'status': 'searching',
      'groupId': null,
      'driverId': null,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    final doc = await _firestore.collection('ride_requests').add(request);

    return doc.id;
  }
}
