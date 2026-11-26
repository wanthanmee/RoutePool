import 'package:cloud_functions/cloud_functions.dart';

/// Class: DriverTripService
/// --------------------------------------------------------------
/// Performs driver trip operations through trusted backend functions.
/// This service provides methods for drivers to accept or decline trips offered by the system.
/// The operations are executed via Firebase Cloud Functions to ensure secure and atomic updates to trip and request data.
class DriverTripService {
  DriverTripService({FirebaseFunctions? functions})
    : _functions =
          functions ?? FirebaseFunctions.instanceFor(region: 'asia-southeast1');

  final FirebaseFunctions _functions;

  /// Claims a matching trip and returns its linked passenger request IDs.
  Future<List<String>> acceptTrip(String tripId) async {
    final result = await _functions
        .httpsCallable('acceptRideTrip')
        .call<Map<String, dynamic>>({'tripId': tripId});

    final requestIds = result.data['requestIds'];
    if (result.data['success'] != true ||
        requestIds is! List ||
        requestIds.isEmpty ||
        requestIds.any((id) => id is! String)) {
      throw StateError('The server returned an invalid trip assignment.');
    }

    return requestIds.cast<String>();
  }

  /// Declines a trip currently offered to this driver.
  Future<void> declineTrip(String tripId) async {
    final result = await _functions
        .httpsCallable('declineRideTrip')
        .call<Map<String, dynamic>>({'tripId': tripId});

    if (result.data['success'] != true) {
      throw StateError('The server could not decline this trip.');
    }
  }
}
