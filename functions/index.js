const {
  onDocumentCreated,
  onDocumentUpdated,
} = require('firebase-functions/v2/firestore');


const { onSchedule } = require('firebase-functions/v2/scheduler');
const { onCall, onRequest, HttpsError } = require('firebase-functions/v2/https');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');
const crypto = require('crypto');

initializeApp();
const db = getFirestore();

// Must match the location of your Firestore database
// (Firebase console -> Firestore -> Data tab shows it).
const REGION = 'asia-southeast1';

// Matching rules
const MAX_PASSENGERS = 12;
const MAX_DROPOFF_DIFF_KM = 5;
const MATCHING_WINDOW_MS = 5 * 60 * 1000; // 5 minutes
const MAX_DEPARTURE_DIFF_MIN = 30;

// Fare rules. Keep in sync with lib/services/fare_calculator.dart.
const BASE_FARE_SEN = 300; // RM 3.00
const PER_KM_SEN = 120; // RM 1.20 per km
const MIN_FARE_SEN = 600; // RM 6.00
const ROAD_FACTOR = 1.3;

// Additional passengers in one booking contribute 50%.
const ADDITIONAL_PASSENGER_RATE = 0.50;

// Matched bookings receive a 20% discount.
const MATCHED_BOOKING_DISCOUNT = 0.20;

// Convert degrees to radians for the spherical-distance calculation.
function toRad(deg) {
  return (deg * Math.PI) / 180;
}

// Estimate straight-line distance between two latitude/longitude points.
function haversineKm(lat1, lon1, lat2, lon2) {
  const R = 6371;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// Approximate road distance by applying the configured road-distance factor.
function roadDistanceKm(lat1, lon1, lat2, lon2) {
  return haversineKm(lat1, lon1, lat2, lon2) * ROAD_FACTOR;
}


const DRIVER_LOCATION_MAX_AGE_MS = 90 * 1000; // 90 seconds
const DRIVER_MAX_ACCURACY_METERS = 100; // 100 meters
const DRIVER_OFFER_DURATION_MS = 30 * 1000; // 30 seconds
const DRIVER_OFFER_LOCKS = 'driver_offer_locks'; // Firestore collection for driver offer locks
const PUBLIC_TRIP_SHARE_DURATION_MS = 2 * 60 * 60 * 1000; // 2 hours
const PUBLIC_TRIP_LOCATION_MAX_AGE_MS = 2 * 60 * 1000; // 2 minutes
const PUBLIC_TRIP_ACTIVE_STATUSES = new Set([
  'driver_assigned',
  'driver_arrived',
  'in_progress',
]);

// Accept only finite latitude/longitude values within geographic bounds.
function isValidCoordinates(lat, lon) {
  return (
    typeof lat === 'number' &&
    Number.isFinite(lat) &&
    lat >= -90 &&
    lat <= 90 &&
    typeof lon === 'number' &&
    Number.isFinite(lon) &&
    lon >= -180 &&
    lon <= 180
  );
}

// Store only the hash of a share token so the raw bearer token is not persisted.
function publicTripShareHash(token) {
  return crypto.createHash('sha256').update(token).digest('hex');
}

/**
 * Resolve a share token to the limited, current tracking data exposed publicly.
 * Expired links and inactive trips are unavailable; stale or invalid locations
 * are returned as null.
 */
async function getPublicTripShareData(token) {
  const shareSnap = await db
    .collection('public_trip_shares')
    .doc(publicTripShareHash(token))
    .get();

  if (!shareSnap.exists) return null;

  const share = shareSnap.data();
  const expiresAt = share.expiresAt?.toMillis?.();
  if (!Number.isFinite(expiresAt) || expiresAt <= Date.now()) return null;

  const tripId = share.tripId;
  if (typeof tripId !== 'string' || tripId.trim().length === 0) return null;

  const tripSnap = await db.collection('trips').doc(tripId).get();
  if (!tripSnap.exists) return null;

  const trip = tripSnap.data();
  if (
    !PUBLIC_TRIP_ACTIVE_STATUSES.has(trip.status) ||
    typeof trip.driverId !== 'string'
  ) {
    return null;
  }

  const requestIds = Array.isArray(trip.requestIds) ? trip.requestIds : [];
  const requestSnaps = await Promise.all(
    requestIds
      .filter((id) => typeof id === 'string' && id.trim().length > 0)
      .map((id) => db.collection('ride_requests').doc(id).get())
  );
  const destinations = requestSnaps
    .map((requestSnap) => {
      if (!requestSnap.exists) return null;
      const request = requestSnap.data();
      if (
        request.groupId !== tripId ||
        ['completed', 'cancelled', 'drop_off_confirmed'].includes(
          request.status
        )
      ) {
        return null;
      }
      const destination = request.dropoffAddress;
      return typeof destination === 'string' && destination.trim()
        ? destination.trim()
        : null;
    })
    .filter(Boolean);

  const locationSnap = await db
    .collection('trips')
    .doc(tripId)
    .collection('live_locations')
    .doc(trip.driverId)
    .get();
  let driverLocation = null;
  if (locationSnap.exists) {
    const location = locationSnap.data();
    const updatedAt = location.updatedAt?.toMillis?.();
    if (
      location.role === 'driver' &&
      Number.isFinite(updatedAt) &&
      updatedAt <= Date.now() &&
      Date.now() - updatedAt <= PUBLIC_TRIP_LOCATION_MAX_AGE_MS &&
      isValidCoordinates(location.lat, location.lon)
    ) {
      driverLocation = {
        lat: location.lat,
        lon: location.lon,
        updatedAt: new Date(updatedAt).toISOString(),
      };
    }
  }

  return {
    pickup: typeof trip.pickupName === 'string' ? trip.pickupName : '',
    destinations: [...new Set(destinations)],
    status: trip.status,
    driverLocation,
    expiresAt: new Date(expiresAt).toISOString(),
  };
}

/**
 * Create a time-limited tracking link for an authenticated trip participant.
 * The returned token is shown to the caller; only its hash is stored.
 */
exports.createPublicTripShare = onCall({ region: REGION }, async (call) => {
  if (!call.auth) {
    throw new HttpsError('unauthenticated', 'Sign in to share this trip.');
  }

  const tripId = call.data?.tripId;
  if (typeof tripId !== 'string' || tripId.trim().length === 0) {
    throw new HttpsError('invalid-argument', 'A valid trip ID is required.');
  }

  const tripSnap = await db.collection('trips').doc(tripId).get();
  if (!tripSnap.exists) {
    throw new HttpsError('not-found', 'This trip could not be found.');
  }

  const trip = tripSnap.data();
  if (!PUBLIC_TRIP_ACTIVE_STATUSES.has(trip.status)) {
    throw new HttpsError(
      'failed-precondition',
      'Live sharing is only available while a trip is active.'
    );
  }

  const uid = call.auth.uid;
  let isParticipant = trip.driverId === uid;
  const requestIds = Array.isArray(trip.requestIds) ? trip.requestIds : [];
  if (!isParticipant) {
    const requestSnaps = await Promise.all(
      requestIds
        .filter((id) => typeof id === 'string' && id.trim().length > 0)
        .map((id) => db.collection('ride_requests').doc(id).get())
    );
    isParticipant = requestSnaps.some((requestSnap) => {
      if (!requestSnap.exists) return false;
      const request = requestSnap.data();
      return (
        request.groupId === tripId &&
        request.passengerId === uid &&
        !['completed', 'cancelled', 'drop_off_confirmed'].includes(
          request.status
        )
      );
    });
  }

  if (!isParticipant) {
    throw new HttpsError(
      'permission-denied',
      'Only an active trip participant can create a tracking link.'
    );
  }

  const token = crypto.randomBytes(32).toString('base64url');
  const expiresAt = new Date(Date.now() + PUBLIC_TRIP_SHARE_DURATION_MS);
  await db.collection('public_trip_shares').doc(publicTripShareHash(token)).set({
    tripId,
    createdBy: uid,
    createdAt: FieldValue.serverTimestamp(),
    expiresAt,
  });

  return { token, expiresAt: expiresAt.toISOString() };
});

/**
 * Return public tracking data for a valid share token.
 * POST is required and responses are not cached to avoid retaining live location data.
 */
exports.getPublicTripTracking = onRequest(
  { region: REGION, maxInstances: 20 },
  async (req, res) => {
    res.set('Cache-Control', 'no-store, max-age=0');
    res.set('X-Content-Type-Options', 'nosniff');
    res.set('Referrer-Policy', 'no-referrer');

    if (req.method !== 'POST') {
      res.status(405).json({ error: 'method-not-allowed' });
      return;
    }

    const token = req.body?.token;
    if (typeof token !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(token)) {
      res.status(404).json({ error: 'tracking-link-unavailable' });
      return;
    }

    const trackingData = await getPublicTripShareData(token);
    if (!trackingData) {
      res.status(404).json({ error: 'tracking-link-unavailable' });
      return;
    }

    res.status(200).json(trackingData);
  }
);

/**
 * Remove expired share-token records in bounded batches.
 * The batch limit keeps a scheduled cleanup run from attempting an unbounded write.
 */
exports.cleanupExpiredPublicTripShares = onSchedule(
  {
    schedule: 'every 60 minutes',
    timeZone: 'Asia/Kuala_Lumpur',
    region: REGION,
  },
  async () => {
    const now = new Date();
    for (let batchNumber = 0; batchNumber < 5; batchNumber += 1) {
      const expiredShares = await db
        .collection('public_trip_shares')
        .where('expiresAt', '<=', now)
        .limit(500)
        .get();
      if (expiredShares.empty) return;

      const batch = db.batch();
      for (const share of expiredShares.docs) {
        batch.delete(share.ref);
      }
      await batch.commit();
      if (expiredShares.size < 500) return;
    }
  }
);

/**
 * Find eligible online drivers, nearest first.
 *
 * This function only selects candidates.
 * It does not assign a driver or modify a trip.
 */
async function findNearestEligibleDrivers(trip) {
  const pickupLat = trip.pickupLat; // Latitude of the pickup location
  const pickupLon = trip.pickupLon; // Longitude of the pickup location
  const requiredSeats = trip.totalPassengers; // Number of seats required for the trip

  // Validate the input parameters to ensure they are within acceptable ranges.
  // If invalid, return an empty array to indicate no eligible drivers found.
  if (
    !Number.isFinite(pickupLat) ||
    !Number.isFinite(pickupLon) ||
    pickupLat < -90 ||
    pickupLat > 90 ||
    pickupLon < -180 ||
    pickupLon > 180 ||
    !Number.isInteger(requiredSeats) ||
    requiredSeats < 1 ||
    requiredSeats > MAX_PASSENGERS
  ) {
    return [];
  }

  // Query the Firestore database to find all online drivers
  // who are available for a trip.
  const onlineDriversSnap = await db
    .collection('users')
    .where('isAvailable', '==', true)
    .get();

  const now = Date.now(); // Current timestamp in milliseconds for time-based checks.
  const candidates = []; // Array to hold eligible drivers with their IDs and distances.

  // Iterate through each online driver and check their eligibility based on various criteria.
  for (const driverDoc of onlineDriversSnap.docs) {
    const driverId = driverDoc.id;
    const driver = driverDoc.data();

    if (driver.verificationStatus !== 'approved') {
      continue;
    }

    // Fetch the driver's vehicle and location data in parallel to reduce latency.
    const [vehicleSnap, locationSnap] = await Promise.all([
      db.collection('vehicles').doc(driverId).get(),
      db.collection('driver_locations').doc(driverId).get(),
    ]);

    if (!vehicleSnap.exists || !locationSnap.exists) {
      continue;
    }

    const vehicle = vehicleSnap.data();
    const location = locationSnap.data();

    // Check if the vehicle meets the required criteria for verification, activity status, and seat capacity.
    // If not, skip to the next driver.
    if (
      vehicle.verificationStatus !== 'approved' ||
      vehicle.isActive !== true ||
      !Number.isInteger(vehicle.seatCapacity) ||
      vehicle.seatCapacity < requiredSeats ||
      vehicle.seatCapacity > MAX_PASSENGERS
    ) {
      continue;
    }

    const locationTime = location.updatedAt?.toMillis?.();

    // Check if the driver's location data is valid and not stale.
    // If the location data is invalid or too old, skip to the next driver.
    if (
      !Number.isFinite(locationTime) ||
      locationTime > now + 5000 ||
      now - locationTime > DRIVER_LOCATION_MAX_AGE_MS
    ) {
      continue;
    }

    // Validate the driver's location coordinates and accuracy.
    if (
      !Number.isFinite(location.lat) ||
      !Number.isFinite(location.lon) ||
      location.lat < -90 ||
      location.lat > 90 ||
      location.lon < -180 ||
      location.lon > 180 ||
      !Number.isFinite(location.accuracy) ||
      location.accuracy < 0 ||
      location.accuracy > DRIVER_MAX_ACCURACY_METERS
    ) {
      continue;
    }

    // Calculate the distance from the driver's current location to the pickup location using the Haversine formula.
    const distanceKm = haversineKm(
      location.lat,
      location.lon,
      pickupLat,
      pickupLon
    );

    // Add the eligible driver to the candidates array with their ID and calculated distance.
    candidates.push({
      driverId,
      distanceKm,
    });
  }

  // Sort the candidates array by distance (nearest first) and then by driver ID for consistent ordering.
  candidates.sort(
    (a, b) =>
      a.distanceKm - b.distanceKm ||
      a.driverId.localeCompare(b.driverId)
  );

  return candidates;
}

/**
 * Atomically reserve a driver for a short-lived offer.
 * Rechecks trip, driver, vehicle, location, and existing-lock eligibility before writing.
 */
async function reserveDriverOffer(tripRef, candidate) {
  const driverRef = db.collection('users').doc(candidate.driverId);
  const vehicleRef = db.collection('vehicles').doc(candidate.driverId);
  const locationRef = db.collection('driver_locations').doc(candidate.driverId);
  const lockRef = db.collection(DRIVER_OFFER_LOCKS).doc(candidate.driverId);

  // Use a transaction to ensure that the trip, driver, vehicle, location, and existing lock are all eligible before making any writes.
  return db.runTransaction(async (tx) => {
    // Read everything before making any writes.
    const [tripSnap, lockSnap, driverSnap, vehicleSnap, locationSnap] =
      await Promise.all([
        tx.get(tripRef),
        tx.get(lockRef),
        tx.get(driverRef),
        tx.get(vehicleRef),
        tx.get(locationRef),
      ]);

    // If any of the required documents do not exist, return false to indicate that the reservation cannot be made.
    if (
      !tripSnap.exists ||
      !driverSnap.exists ||
      !vehicleSnap.exists ||
      !locationSnap.exists
    ) {
      return false;
    }

    // Extract the data from the snapshots for easier access.
    const trip = tripSnap.data();
    const driver = driverSnap.data();
    const vehicle = vehicleSnap.data();
    const location = locationSnap.data();

    // Check if the trip is still eligible for a driver offer.
    // If the trip is not in the 'matching_driver' status
    // or already has a driver assigned or an offered driver, return false.
    if (
      trip.status !== 'matching_driver' ||
      trip.driverId != null ||
      trip.offeredDriverId != null
    ) {
      return false;
    }

    // Do not offer the same trip to a driver who
    // previously declined or let their offer expire.
    const declinedDriverIds = Array.isArray(trip.declinedDriverIds)
      ? trip.declinedDriverIds
      : [];

    if (declinedDriverIds.includes(candidate.driverId)) {
      return false;
    }

    // Check if the driver, vehicle, and location meet the required criteria for
    // verification, availability, activity status, seat capacity, and location accuracy.
    if (
      driver.verificationStatus !== 'approved' ||
      driver.isAvailable !== true ||
      vehicle.verificationStatus !== 'approved' ||
      vehicle.isActive !== true ||
      !Number.isInteger(vehicle.seatCapacity) ||
      vehicle.seatCapacity < trip.totalPassengers ||
      vehicle.seatCapacity > MAX_PASSENGERS
    ) {
      return false;
    }

    // Check if the driver's location data is valid and not stale.
    const now = Date.now();
    const locationTime = location.updatedAt?.toMillis?.();

    // Validate the driver's location coordinates and accuracy.
    if (
      !Number.isFinite(locationTime) ||
      locationTime > now + 5000 ||
      now - locationTime > DRIVER_LOCATION_MAX_AGE_MS ||
      !Number.isFinite(location.lat) ||
      !Number.isFinite(location.lon) ||
      !Number.isFinite(location.accuracy) ||
      location.accuracy < 0 ||
      location.accuracy > DRIVER_MAX_ACCURACY_METERS
    ) {
      return false;
    }

    // Check if there is an existing lock for this driver and if it is still valid.
    const existingLock = lockSnap.exists ? lockSnap.data() : null;
    const lockExpiry = existingLock?.expiresAt?.toMillis?.();

    // Reject active reservations, including malformed locks.
    // If a lock expires, it is automatically released and the driver becomes eligible again.
    if (
      existingLock &&
      (!Number.isFinite(lockExpiry) || lockExpiry > now)
    ) {
      return false;
    }

    // If all checks pass, create a new lock for the driver
    // and update the trip with the offered driver ID and offer expiry time.
    const expiresAt = new Date(now + DRIVER_OFFER_DURATION_MS);


    // Write the new lock and update the trip atomically within the transaction.
    tx.set(lockRef, {
      tripId: tripRef.id,
      expiresAt,
      updatedAt: FieldValue.serverTimestamp(),
    });

    // Update the trip with the offered driver ID and offer expiry time.
    tx.update(tripRef, {
      offeredDriverId: candidate.driverId,
      offerExpiresAt: expiresAt,
      updatedAt: FieldValue.serverTimestamp(),
    });

    return true;
  });
}

/**
 * Clear a driver's expired offer and record that driver as declined for this trip.
 * Transactional rechecks prevent a stale timeout from releasing a newer offer.
 */
async function releaseExpiredDriverOffer(tripRef) {
  const tripSnap = await tripRef.get();

  if (!tripSnap.exists) return false;

  const trip = tripSnap.data();

  if (
    trip.status !== 'matching_driver' ||
    trip.driverId != null ||
    !trip.offeredDriverId
  ) {
    return false;
  }

  const expiresAt = trip.offerExpiresAt?.toMillis?.();

  if (
    Number.isFinite(expiresAt) &&
    expiresAt > Date.now()
  ) {
    return false;
  }

  const driverId = trip.offeredDriverId;
  const lockRef = db.collection(DRIVER_OFFER_LOCKS).doc(driverId);

  return db.runTransaction(async (tx) => {
    const [currentTripSnap, lockSnap] = await Promise.all([
      tx.get(tripRef),
      tx.get(lockRef),
    ]);

    if (!currentTripSnap.exists) return false;

    const current = currentTripSnap.data();
    const currentExpiry = current.offerExpiresAt?.toMillis?.();

    // Recheck inside the transaction to prevent races.
    if (
      current.status !== 'matching_driver' ||
      current.driverId != null ||
      current.offeredDriverId !== driverId ||
      (
        Number.isFinite(currentExpiry) &&
        currentExpiry > Date.now()
      )
    ) {
      return false;
    }

    const declined = Array.isArray(current.declinedDriverIds)
      ? current.declinedDriverIds
      : [];

    tx.update(tripRef, {
      offeredDriverId: null,
      offerExpiresAt: null,
      declinedDriverIds: [...new Set([...declined, driverId])],
      updatedAt: FieldValue.serverTimestamp(),
    });

    // Only remove a reservation belonging to this trip.
    if (lockSnap.exists && lockSnap.data().tripId === tripRef.id) {
      tx.delete(lockRef);
    }

    return true;
  });
}


// Calculate the rounded solo fare in cents for the estimated road distance.
function soloFareSen(km) {
  const raw = BASE_FARE_SEN + PER_KM_SEN * km;
  return Math.max(MIN_FARE_SEN, Math.round(raw / 10) * 10);
}

// Calculate the fare for one booking containing 1–12 passengers.
// The first passenger contributes 100% of the solo fare.
// Each additional passenger contributes 50%.
function bookingFareSen(soloFare, passengerCount) {
  if (
    !Number.isInteger(passengerCount) ||
    passengerCount < 1 ||
    passengerCount > MAX_PASSENGERS
  ) {
    throw new Error('Invalid booking passenger count.');
  }

  const multiplier =
    1 + (passengerCount - 1) * ADDITIONAL_PASSENGER_RATE; // 50% for each additional passenger

  const rawFare = soloFare * multiplier; // Calculate the raw fare before rounding.

  return Math.round(rawFare / 10) * 10; // Round to the nearest RM0.10 (10 sen).
}
/**
 * Calculate the final fare for each matched booking.
 *
 * Each booking:
 * 1. Calculates its fare based on passenger count.
 * 2. Receives a 20% shared-ride discount.
 * 3. Is rounded to the nearest RM0.10.
 *
 * Driver earnings = sum of all final booking fares.
 */
function computeShares(members) {
  if (members.length === 0) return {};

  const shares = {};

  // Calculate the final fare for each member in the matched group.
  for (const member of members) {
    const originalBookingFare = bookingFareSen(
      member.soloFareSen,
      member.passengerCount
    );

    const discountedFare =
      originalBookingFare * (1 - MATCHED_BOOKING_DISCOUNT); // Apply the 20% discount for shared rides.

    shares[member.id] = Math.round(discountedFare / 10) * 10; // Round to the nearest RM0.10 (10 sen).
  }

  return shares;
}

// Check the fields required before a ride request can be matched or priced.
function isValidRequest(r) {
  const isNum = (v) =>
    typeof v === 'number' && Number.isFinite(v);

  const validCoordinates = (lat, lon) =>
    isNum(lat) &&
    isNum(lon) &&
    lat >= -90 &&
    lat <= 90 &&
    lon >= -180 &&
    lon <= 180;

  return (
    r !== null &&
    typeof r === 'object' &&
    validCoordinates(r.pickupLat, r.pickupLon) &&
    validCoordinates(r.dropoffLat, r.dropoffLon) &&
    typeof r.pickupHubId === 'string' &&
    r.pickupHubId.trim().length > 0 &&
    typeof r.pickupName === 'string' &&
    r.pickupName.trim().length > 0 &&
    Number.isInteger(r.passengerCount) &&
    r.passengerCount >= 1 &&
    r.passengerCount <= MAX_PASSENGERS &&
    r.departureTime !== null &&
    r.departureTime !== undefined &&
    typeof r.departureTime.toMillis === 'function' &&
    Number.isFinite(r.departureTime.toMillis())
  );
}

// Requests can share a trip only when identity, pickup, departure, and destination rules pass.
function areRequestsCompatible(a, b) {
  if (!isValidRequest(a) || !isValidRequest(b)) return false;

  // Prevent the same passenger from matching with themselves.
  if (a.passengerId === b.passengerId) return false;

  // Passengers must select the same pickup hub.
  if (a.pickupHubId !== b.pickupHubId) return false;

  // Departure times must be within 30 minutes.
  const departureDifference = Math.abs(
    a.departureTime.toMillis() - b.departureTime.toMillis()
  );

  if (departureDifference > MAX_DEPARTURE_DIFF_MIN * 60 * 1000) {
    return false;
  }

  // Calculate the distance between passenger destinations.
  const destinationDifference = haversineKm(
    a.dropoffLat,
    a.dropoffLon,
    b.dropoffLat,
    b.dropoffLon
  );

  // Destinations must be within 5 km.
  return destinationDifference <= MAX_DROPOFF_DIFF_KM;
}

// A candidate joins only if every current member is compatible and seats remain.
function canJoinGroup(candidate, members, capacity) {

  //Calculates the total number of passengers in the group, including the candidate.
  const total = members.reduce(
    (sum, member) => sum + member.passengerCount,
    0
  );


  //Checks if there are enough seats in the vehicle and
  // if the candidate is compatible with all current members of the group.
  return (
    total + candidate.passengerCount <= capacity &&
    members.every((member) =>
      areRequestsCompatible(candidate, member)
    )
  );
}

/**
 * Initialise a five-minute passenger-search window when a booking is created.
 */
exports.matchRideRequest = onDocumentCreated(
  { document: 'ride_requests/{requestId}', region: REGION },
  async (event) => {
    const requestId = event.params.requestId;
    const ref = db.collection('ride_requests').doc(requestId);

    // Use a transaction to ensure that the request is still eligible for matching before updating its search window.
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) return;

      const data = snap.data();

      // Only initialize the search window if the request is still searching and has no group assignment or existing expiry time.
      if (
        data.status !== 'searching' ||
        data.groupId ||
        data.searchExpiresAt
      ) {
        return;
      }

      const now = Date.now();

      tx.update(ref, {
        searchStartedAt: new Date(now),
        searchExpiresAt: new Date(now + MATCHING_WINDOW_MS),

        // Initially, the passenger has not joined a shared group.
        groupSearchId: null,
        groupSearchExpiresAt: null,

        updatedAt: FieldValue.serverTimestamp(),
      });
    });
  }
);

/**
 * Collect compatible passenger bookings into shared groups.
 * Keep the original group's five-minute deadline.
 * After expiry, finalize shared trips or offer an unmatched
 * passenger the option to search again or request a solo ride.
 */
exports.processPassengerMatching = onSchedule(
  {
    schedule: '* * * * *', //runs every minute to check for new ride requests and matching groups
    timeZone: 'Asia/Kuala_Lumpur',
    region: REGION,
  },
  async () => {
    const now = Date.now();

    // Find the largest currently approved, active vehicle capacity.
    const vehiclesSnap = await db.collection('vehicles')
      .where('verificationStatus', '==', 'approved')
      .get();

    // Filter out vehicles that are inactive or have invalid seat capacities.
    const capacities = vehiclesSnap.docs
      .map((doc) => doc.data())
      .filter((v) =>
        v.isActive === true &&
        Number.isInteger(v.seatCapacity) &&
        v.seatCapacity >= 1 &&
        v.seatCapacity <= MAX_PASSENGERS
      )
      .map((v) => v.seatCapacity);

    const capacity = capacities.length
      ? Math.max(...capacities)
      : 0;

    // Fetch all ride requests that are currently searching for a match.
    const requestsSnap = await db.collection('ride_requests')
      .where('status', '==', 'searching')
      .get();

    // Filter out requests that are invalid or have expired search windows before matching them into groups.
    const requests = requestsSnap.docs
      .map((doc) => ({
        ...doc.data(),
        id: doc.id,
        ref: doc.ref,
      }))
      .filter((r) =>
        isValidRequest(r) && //checks if the request has valid coordinates, pickup hub, passenger count, and departure time
        r.searchStartedAt?.toMillis?.() != null && //checks if the request has a valid search start time
        r.searchExpiresAt?.toMillis?.() != null //checks if the request has a valid search expiry time
      );

    // Create a map of request IDs to their corresponding request objects for quick lookup.
    const requestMap = new Map(
      requests.map((r) => [r.id, r])
    );

    // Fetch all currently collecting matching groups.
    const groupsSnap = await db.collection('matching_groups')
      .where('status', '==', 'collecting')
      .get();

    // Map each group document to an object containing its ID, reference, and data.
    const groups = groupsSnap.docs.map((doc) => ({
      id: doc.id,
      ref: doc.ref,
      ...doc.data(),
    }));

    const reserved = new Set();

    // --------------------------------------------------
    // PHASE 1: Add new bookings to existing groups.
    // --------------------------------------------------

    for (const group of groups) {
      const deadline = group.searchExpiresAt?.toMillis?.();

      //Checks if the group has a valid search expiry time and if the deadline has not passed yet.
      if (deadline == null || deadline <= now) continue;

      // Get the list of member IDs in the group and filter out any invalid or missing members.
      const memberIds = Array.isArray(group.requestIds)
        ? group.requestIds
        : [];

      // Map each member ID to its corresponding request object and filter out any missing members.
      const members = memberIds
        .map((id) => requestMap.get(id))
        .filter(Boolean);

      // Only join a group if all its members can be verified.
      if (members.length !== memberIds.length) continue;

      // Check if the group has enough capacity to accommodate new members.
      for (const candidate of requests) {
        if (reserved.has(candidate.id)) continue;
        if (candidate.groupSearchId || candidate.groupId) continue;

        if (candidate.searchExpiresAt.toMillis() <= now) {
          continue;
        }

        if (!canJoinGroup(candidate, members, capacity)) {
          continue;
        }

        let joined = false;

        // Use a transaction to ensure that the group and candidate are still eligible to be joined together.
        await db.runTransaction(async (tx) => {
          const groupSnap = await tx.get(group.ref);

          if (!groupSnap.exists) return;

          const currentGroup = groupSnap.data();

          if (
            currentGroup.status !== 'collecting' ||
            currentGroup.searchExpiresAt?.toMillis?.() <= Date.now()
          ) {
            return;
          }

          const currentIds = currentGroup.requestIds || [];

          const memberRefs = currentIds.map((id) =>
            db.collection('ride_requests').doc(id)
          );

          const [candidateSnap, ...memberSnaps] =
            await Promise.all([
              tx.get(candidate.ref),
              ...memberRefs.map((ref) => tx.get(ref)),
            ]);

          if (!candidateSnap.exists) return;
          if (memberSnaps.some((snap) => !snap.exists)) return;

          const currentCandidate = candidateSnap.data();

          const currentMembers = memberSnaps.map(
            (snap) => snap.data()
          );

          if (
            currentCandidate.status !== 'searching' ||
            currentCandidate.groupId ||
            currentCandidate.groupSearchId ||
            currentCandidate.searchExpiresAt?.toMillis?.() <= Date.now()
          ) {
            return;
          }

          if (
            currentMembers.some((m) =>
              m.status !== 'searching' ||
              m.groupSearchId !== group.id ||
              m.groupId
            )
          ) {
            return;
          }

          if (!canJoinGroup(
            currentCandidate,
            currentMembers,
            capacity
          )) {
            return;
          }

          const newTotal = currentMembers.reduce(
            (sum, m) => sum + m.passengerCount,
            currentCandidate.passengerCount
          );

          // Update the group with the new member and update the candidate's group assignment.
          tx.update(group.ref, {
            requestIds: [...currentIds, candidate.id],
            totalPassengers: newTotal,
            updatedAt: FieldValue.serverTimestamp(),
          });

          // Update the candidate's group assignment and search expiry time to match the group's.
          tx.update(candidate.ref, {
            groupSearchId: group.id,
            groupSearchExpiresAt: currentGroup.searchExpiresAt,
            updatedAt: FieldValue.serverTimestamp(),
          });

          joined = true;
        });

        // Records that the candidate has been added to a group to prevent it from being added to another group in this run.
        if (joined) {
          reserved.add(candidate.id);
          members.push(candidate);
        }
      }
    }

    // --------------------------------------------------
    // PHASE 2: Create new collecting groups.
    // --------------------------------------------------

    // Filter out ungrouped requests that are still searching and have not expired.
    // Sort them by search start time to prioritize earlier requests.
    const ungrouped = requests
      .filter((r) =>
        !r.groupSearchId &&
        !r.groupId &&
        !reserved.has(r.id) &&
        r.searchExpiresAt.toMillis() > now
      )
      .sort((a, b) =>
        a.searchStartedAt.toMillis() -
        b.searchStartedAt.toMillis()
      );

    // Selecting the first passenger as the anchor of a new group.
    // The anchor's search expiry time becomes the group's deadline.
    for (const anchor of ungrouped) {
      if (reserved.has(anchor.id)) continue;
      if (anchor.passengerCount > capacity) continue;

      const members = [anchor];

      // Attempt to add compatible passengers to the group.
      for (const candidate of ungrouped) {
        // Don't add the anchor again.
        if (candidate.id === anchor.id) continue;

        // Don't add a booking already assigned during this run.
        if (reserved.has(candidate.id)) continue;

        // Don't add the same booking twice to this group.
        if (members.some((m) => m.id === candidate.id)) continue;

        // Only include bookings whose search hasn't expired.
        if (candidate.searchExpiresAt.toMillis() <= Date.now()) {
          continue;
        }

        // Check passenger identity, pickup hub, destination proximity,
        // and available seat capacity. System immediately adds the candidate to the group if eligible.
        if (canJoinGroup(candidate, members, capacity)) {
          members.push(candidate);
        }
      }

      const groupRef = db.collection('matching_groups').doc();
      const deadline = anchor.searchExpiresAt;

      let created = false;

      // Use a transaction to ensure that the group and its members are still eligible to be created together.
      await db.runTransaction(async (tx) => {
        const snapshots = await Promise.all(
          members.map((r) => tx.get(r.ref))
        );

        if (snapshots.some((snap) => !snap.exists)) return;

        const currentMembers = snapshots.map(
          (snap) => snap.data()
        );

        if (currentMembers.some((m) =>
          m.status !== 'searching' ||
          m.groupId ||
          m.groupSearchId ||
          !isValidRequest(m) ||
          m.searchExpiresAt?.toMillis?.() <= Date.now()
        )) {
          return;
        }

        const currentAnchor = currentMembers[0];

        if (
          currentAnchor.searchExpiresAt.toMillis() !==
          deadline.toMillis()
        ) {
          return;
        }

        let validGroup = true;
        const checked = [];

        for (const member of currentMembers) {
          if (checked.length > 0 &&
              !canJoinGroup(member, checked, capacity)) {
            validGroup = false;
            break;
          }

          checked.push(member);
        }

        if (!validGroup) return;

        const totalPassengers = currentMembers.reduce(
          (sum, m) => sum + m.passengerCount,
          0
        );

        tx.set(groupRef, {
          status: 'collecting',
          requestIds: members.map((m) => m.id),
          totalPassengers,
          pickupHubId: anchor.pickupHubId,
          searchStartedAt: anchor.searchStartedAt,
          searchExpiresAt: deadline,
          createdAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        });

        for (const member of members) {
          tx.update(member.ref, {
            groupSearchId: groupRef.id,
            groupSearchExpiresAt: deadline,
            updatedAt: FieldValue.serverTimestamp(),
          });
        }

        created = true;
      });

      if (created) {
        members.forEach((m) => reserved.add(m.id));
      }
    }

    // --------------------------------------------------
    // PHASE 3: Finalize groups whose five minutes ended.
    // --------------------------------------------------

    // Fetch all currently collecting matching groups that have expired.
    const expiredGroupsSnap = await db
      .collection('matching_groups')
      .where('status', '==', 'collecting')
      .get();

    // Filter out groups that have not yet expired.
    for (const groupDoc of expiredGroupsSnap.docs) {
      const group = groupDoc.data();

      const groupDeadline = group.searchExpiresAt?.toMillis?.();

      if (groupDeadline == null || groupDeadline > Date.now()) {
        continue;
      }

      // Get the list of request IDs in the group, defaulting to an empty array if not present.
      const ids = Array.isArray(group.requestIds)
        ? group.requestIds
        : [];

      // If the group has no members, mark it as cancelled and skip to the next group.
      const tripRef = db.collection('trips').doc();

      // Use a transaction to ensure that the group and its members are still eligible to be finalized together.
      await db.runTransaction(async (tx) => {
        const groupSnap = await tx.get(groupDoc.ref);

        if (!groupSnap.exists) return;

        const currentGroup = groupSnap.data();

        const currentDeadline =
          currentGroup.searchExpiresAt?.toMillis?.();

        if (
          currentGroup.status !== 'collecting' ||
          currentDeadline == null ||
          currentDeadline > Date.now()
        ) {
          return;
        }

        const currentIds = currentGroup.requestIds || [];

        const refs = currentIds.map((id) =>
          db.collection('ride_requests').doc(id)
        );

        const snaps = await Promise.all(
          refs.map((ref) => tx.get(ref))
        );

        if (snaps.some((snap) => !snap.exists)) return;

        const active = snaps.map((snap, index) => ({
          ...snap.data(),
          id: currentIds[index],
          ref: refs[index],
        }));

        if (active.some((r) =>
          r.status !== 'searching' ||
          r.groupSearchId !== groupDoc.id ||
          r.groupId ||
          !isValidRequest(r)
        )) {
          return;
        }

        if (active.length === 0) {
          tx.update(groupDoc.ref, {
            status: 'cancelled',
            updatedAt: FieldValue.serverTimestamp(),
          });
          return;
        }

        // If only one passenger remains, they are returned to the awaiting_choice state.
        if (active.length === 1) {
          tx.update(active[0].ref, {
            status: 'awaiting_choice',
            groupSearchId: null,
            groupSearchExpiresAt: null,
            updatedAt: FieldValue.serverTimestamp(),
          });

          // Mark the group as completed without creating a trip.
          tx.update(groupDoc.ref, {
            status: 'completed',
            updatedAt: FieldValue.serverTimestamp(),
          });

          return;
        }

        // Calculate the total number of passengers in the group.
        const totalPassengers = active.reduce(
          (sum, r) => sum + r.passengerCount,
          0
        );

        // If the total number of passengers exceeds the largest currently approved vehicle capacity,
        // the group is disbanded and all members are returned to the awaiting_choice state.
        if (totalPassengers > capacity) {
          for (const passenger of active) {
            tx.update(passenger.ref, {
              status: 'awaiting_choice',
              groupSearchId: null,
              groupSearchExpiresAt: null,
              updatedAt: FieldValue.serverTimestamp(),
            });
          }

          // Mark the group as completed without creating a trip.
          tx.update(groupDoc.ref, {
            status: 'completed',
            updatedAt: FieldValue.serverTimestamp(),
          });

          return;
        }

        // Calculate the distance and solo fare for each member of the group.
        const members = active.map((r) => {
          const distanceKm = roadDistanceKm(
            r.pickupLat,
            r.pickupLon,
            r.dropoffLat,
            r.dropoffLon
          );

          // The solo fare is calculated based on the distance and the number of passengers in the booking.
          return {
            id: r.id,
            passengerCount: r.passengerCount,
            distanceKm,
            soloFareSen: soloFareSen(distanceKm),
          };
        });

        // Calculate the fare share for each member of the group based on their solo fare and passenger count.
        const shares = computeShares(members);

        // Calculate the total fare for the group by summing the individual fare shares.
        const totalFareSen = Object.values(shares)
          .reduce((sum, value) => sum + value, 0);

        const anchor = active[0];

        // Create a new trip document with the combined information from the group members.
        tx.set(tripRef, {
          status: 'matching_driver',
          pickupHubId: anchor.pickupHubId,
          pickupName: anchor.pickupName,
          pickupLat: anchor.pickupLat,
          pickupLon: anchor.pickupLon,
          departureTime: anchor.departureTime,
          dropoffRefLat: anchor.dropoffLat,
          dropoffRefLon: anchor.dropoffLon,
          requestIds: active.map((r) => r.id),
          passengerIds: [...new Set(active.map((r) => r.passengerId))],
          totalPassengers,
          totalFareSen,
          driverId: null,
          createdAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        });

        for (const member of members) {
          const ref = db.collection('ride_requests')
            .doc(member.id);

          tx.update(ref, {
            status: 'matching_driver',
            groupId: tripRef.id,
            groupSearchId: null,
            groupSearchExpiresAt: null,
            distanceKm: member.distanceKm,
            soloFareSen: member.soloFareSen,
            fareShareSen: shares[member.id],
            tripPassengers: totalPassengers,
            updatedAt: FieldValue.serverTimestamp(),
          });
        }

        tx.update(groupDoc.ref, {
          status: 'completed',
          tripId: tripRef.id,
          updatedAt: FieldValue.serverTimestamp(),
        });
      });
    }
    // --------------------------------------------------
    // PHASE 4: Handle expired requests without a group.
    // --------------------------------------------------

    // Find all ride requests that are still searching but have no group and have expired.
    const expiredUngrouped = await db.collection('ride_requests')
      .where('status', '==', 'searching')
      .get();

    // For each expired ungrouped request, update its status to awaiting_choice.
    for (const doc of expiredUngrouped.docs) {
      const r = doc.data();

      if (r.groupId || r.groupSearchId) continue;

      if (
        r.searchExpiresAt?.toMillis?.() == null ||
        r.searchExpiresAt.toMillis() > Date.now()
      ) {
        continue;
      }

      await db.runTransaction(async (tx) => {
        const snap = await tx.get(doc.ref);

        if (!snap.exists) return;

        const current = snap.data();

        // If the request is still searching, has no group, and has expired, update its status to awaiting_choice.
        if (
          current.status === 'searching' &&
          !current.groupId &&
          !current.groupSearchId &&
          current.searchExpiresAt?.toMillis?.() <= Date.now()
        ) {
          tx.update(doc.ref, {
            status: 'awaiting_choice',
            updatedAt: FieldValue.serverTimestamp(),
          });
        }
      });
    }
  }
);


/**
 * Handle a passenger's choice after a search window expires.
 * Reset group-search fields when searching again, or create a solo trip on request.
 */
exports.handleRideRequestChoice = onDocumentUpdated(
  { document: 'ride_requests/{requestId}', region: REGION },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();

    // Clear previous group information when searching again.
    if (
      before.status === 'awaiting_choice' &&
      after.status === 'searching'
    ) {
      const ref = event.data.after.ref;

      await db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);

        if (!snap.exists) return;

        const current = snap.data();

        // Only reset the group-search fields if the request is still searching and has no group assignment.
        if (current.status !== 'searching' || current.groupId) {
          return;
        }

        // Reset the group-search fields to null when the passenger chooses to search again.
        tx.update(ref, {
          groupSearchId: null,
          groupSearchExpiresAt: null,
          updatedAt: FieldValue.serverTimestamp(),
        });
      });

      return;
    }

    if (
      before.status === after.status ||
      after.status !== 'solo_requested'
    ) {
      return;
    }

    const ref = event.data.after.ref;

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) return;

      const r = snap.data();

      // Only create a solo trip if the request is still solo_requested and has no group assignment.
      if (r.status !== 'solo_requested' || r.groupId) return;
      if (!isValidRequest(r)) return;

      // Calculate the road distance between the pickup and dropoff locations.
      const distanceKm = roadDistanceKm(
        r.pickupLat, r.pickupLon, r.dropoffLat, r.dropoffLon
      );

      // Calculate the solo fare based on the distance.
      const solo = soloFareSen(distanceKm);

      // Calculate the total fare for the booking based on the solo fare and passenger count.
      const bookingFare = bookingFareSen(
        solo,
        r.passengerCount
      );

      const tripRef = db.collection('trips').doc();

      // Create a new trip document with the relevant information from the ride request.
      tx.set(tripRef, {
        status: 'matching_driver',
        pickupHubId: r.pickupHubId,
        pickupName: r.pickupName,
        pickupLat: r.pickupLat,
        pickupLon: r.pickupLon,
        departureTime: r.departureTime,
        dropoffRefLat: r.dropoffLat,
        dropoffRefLon: r.dropoffLon,
        requestIds: [event.params.requestId],
        passengerIds: [r.passengerId],
        totalPassengers: r.passengerCount,
        totalFareSen: bookingFare,
        driverId: null,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });

      tx.update(ref, {
        status: 'matching_driver',
        groupId: tripRef.id,
        distanceKm,
        soloFareSen: solo,
        fareShareSen: bookingFare,
        tripPassengers: r.passengerCount,
        matchingChoice: 'solo',
        updatedAt: FieldValue.serverTimestamp(),
      });
    });
  }
);


/**
 * Offer a newly created trip to the nearest eligible driver.
 */
exports.offerTripToNearestDriver = onDocumentCreated(
  {
    document: 'trips/{tripId}',
    region: REGION,
  },
  async (event) => {
    const tripId = event.params.tripId;
    const tripRef = db.collection('trips').doc(tripId);

    const tripSnap = await tripRef.get();

    if (!tripSnap.exists) return;

    const trip = tripSnap.data();

    if (
      trip.status !== 'matching_driver' ||
      trip.driverId != null
    ) {
      return;
    }

    const candidates = await findNearestEligibleDrivers(trip);

    if (candidates.length === 0) {
      console.log(`No eligible drivers for trip ${tripId}`);
      return;
    }


    for (const candidate of candidates) {
      const reserved = await reserveDriverOffer(
        tripRef,
        candidate
      );

      if (reserved) {
        console.log(
          `Trip ${tripId} offered to driver ${candidate.driverId}`
        );
        return;
      }
    }

    console.log(
      `No available driver could be reserved for trip ${tripId}`
    );

  }
);


/**
 * Check pending driver offers every minute.
 * Release expired offers and try the next nearest driver.
 */
exports.processDriverOfferTimeouts = onSchedule(
  {
    schedule: '* * * * *',
    timeZone: 'Asia/Kuala_Lumpur',
    region: REGION,
  },
  async () => {
    const tripsSnap = await db
      .collection('trips')
      .where('status', '==', 'matching_driver')
      .get();

    for (const tripDoc of tripsSnap.docs) {
      const tripRef = tripDoc.ref;

      try {
        const trip = tripDoc.data();

        if (trip.driverId != null) continue;

        // If an offer exists, wait until it expires.
        if (trip.offeredDriverId != null) {
          const expiresAt = trip.offerExpiresAt?.toMillis?.();

          if (
            Number.isFinite(expiresAt) &&
            expiresAt > Date.now()
          ) {
            continue;
          }

          const released = await releaseExpiredDriverOffer(tripRef);

          if (!released) continue;
        }

        // Refresh the trip after releasing an expired offer.
        const latestSnap = await tripRef.get();

        if (!latestSnap.exists) continue;

        const latest = latestSnap.data();

        if (
          latest.status !== 'matching_driver' ||
          latest.driverId != null ||
          latest.offeredDriverId != null
        ) {
          continue;
        }

        const declined = new Set(
          Array.isArray(latest.declinedDriverIds)
            ? latest.declinedDriverIds
            : []
        );

        const candidates = await findNearestEligibleDrivers(latest);

        // Don't offer the same trip again to a driver who
        // already declined or let the offer expire.
        for (const candidate of candidates) {
          if (declined.has(candidate.driverId)) continue;

          const reserved = await reserveDriverOffer(
            tripRef,
            candidate
          );

          if (reserved) {
            console.log(
              `Trip ${tripRef.id} reassigned to driver ${candidate.driverId}`
            );
            break;
          }
        }
      } catch (error) {
        console.error(
          `Error processing driver offers for trip ${tripRef.id}:`,
          error
        );
      }
    }
  }
);

/**
 * Atomically assign a matching trip and all linked requests to one driver.
 */
exports.acceptRideTrip = onCall(
  { region: REGION },
  async (call) => {
    if (!call.auth) {
      throw new HttpsError(
        'unauthenticated',
        'Please sign in before accepting a trip.'
      );
    }

    const tripId = call.data?.tripId;

    if (typeof tripId !== 'string' || tripId.trim().length === 0) {
      throw new HttpsError(
        'invalid-argument',
        'A valid trip ID is required.'
      );
    }
    // Get the trip and driver documents, and the driver's vehicle and offer lock documents.
    const driverId = call.auth.uid;
    const tripRef = db.collection('trips').doc(tripId);
    const driverRef = db.collection('users').doc(driverId);
    const vehicleRef = db.collection('vehicles').doc(driverId);
    const lockRef = db.collection(DRIVER_OFFER_LOCKS).doc(driverId);

    // Use a transaction to ensure that the trip, driver, vehicle,
    // and offer lock are all valid and consistent before assigning the trip to the driver.
    return db.runTransaction(async (tx) => {
    const [tripSnap, driverSnap, vehicleSnap, lockSnap] =
      await Promise.all([
        tx.get(tripRef),
        tx.get(driverRef),
        tx.get(vehicleRef),
        tx.get(lockRef),
      ]);

      // Validate that the trip, driver, and vehicle documents exist.
      if (!tripSnap.exists) {
        throw new HttpsError('not-found', 'This trip no longer exists.');
      }

      //  Validate that the driver document exists.
      if (!driverSnap.exists) {
        throw new HttpsError(
          'failed-precondition',
          'Your driver profile could not be found.'
        );
      }

      // Snapshot the vehicle document and validate its existence.
      const trip = tripSnap.data();
      const driver = driverSnap.data();
      const vehicle = vehicleSnap.data();

      // Ensure that the trip is still available for matching and has not already been assigned to another driver.
      if (trip.status !== 'matching_driver' || trip.driverId != null) {
        throw new HttpsError(
          'failed-precondition',
          'This trip has already been taken.'
        );
      }

      // Only the driver selected by nearest-driver matching
      // can accept this trip.
      if (trip.offeredDriverId !== driverId) {
        throw new HttpsError(
          'permission-denied',
          'This trip is not currently offered to you.'
        );
      }

      // Check whether the driver's offer has expired.
      const offerExpiresAt = trip.offerExpiresAt?.toMillis?.();

      if (
        !Number.isFinite(offerExpiresAt) ||
        offerExpiresAt <= Date.now()
      ) {
        throw new HttpsError(
          'failed-precondition',
          'This trip offer has expired.'
        );
      }


      // Verify that this driver still holds the reservation.
      const lock = lockSnap.exists ? lockSnap.data() : null;

      if (
        lock?.tripId !== tripId ||
        lock?.expiresAt?.toMillis?.() !== offerExpiresAt
      ) {
        throw new HttpsError(
          'failed-precondition',
          'Your driver offer reservation is no longer valid.'
        );
      }

      // Ensure that the driver is approved and available, and that the vehicle is approved and active.
      if (
        driver.verificationStatus !== 'approved' ||
        driver.isAvailable !== true
      ) {
        throw new HttpsError(
          'failed-precondition',
          'Your driver account must be approved and online.'
        );
      }

      if (
        !vehicleSnap.exists ||
        vehicle.verificationStatus !== 'approved' ||
        vehicle.isActive !== true
      ) {
        throw new HttpsError(
          'failed-precondition',
          'Your vehicle must be approved and active.'
        );
      }

      // STEP 1: Get the vehicle's passenger seat capacity.
      const seatCapacity = vehicle.seatCapacity;

      // STEP 2: Get the total passengers assigned to the trip.
      const requiredSeats = trip.totalPassengers;

      // STEP 3: Validate the registered vehicle capacity.
      if (
        !Number.isInteger(seatCapacity) ||
        seatCapacity < 1 ||
        seatCapacity > MAX_PASSENGERS
      ) {
        throw new HttpsError(
          'failed-precondition',
          'Your vehicle has an invalid passenger seat capacity.'
        );
      }

      // STEP 4: Validate the trip's total passenger count.
      if (
        !Number.isInteger(requiredSeats) ||
        requiredSeats < 1 ||
        requiredSeats > MAX_PASSENGERS
      ) {
        throw new HttpsError(
          'failed-precondition',
          'This trip has an invalid passenger count.'
        );
      }

      // STEP 5: Ensure the driver has enough passenger seats.
      if (requiredSeats > seatCapacity) {
        throw new HttpsError(
          'failed-precondition',
          `This trip requires ${requiredSeats} passenger seats, ` +
            `but your vehicle only has ${seatCapacity}.`
        );
      }

      // STEP 6: Validate the linked passenger requests.
      const requestIds = trip.requestIds;

      // Validate that the request IDs are a non-empty array of unique, non-empty strings.
      if (
        !Array.isArray(requestIds) ||
        requestIds.length === 0 ||
        requestIds.some(
          (id) => typeof id !== 'string' || id.trim().length === 0
        ) ||
        new Set(requestIds).size !== requestIds.length
      ) {
        throw new HttpsError(
          'failed-precondition',
          'This trip has invalid passenger requests.'
        );
      }

      // Validate that all linked passenger requests are still searching for a driver and belong to this trip.
      const requestRefs = requestIds.map((id) =>
        db.collection('ride_requests').doc(id)
      );
      const requestSnaps = await Promise.all(
        requestRefs.map((ref) => tx.get(ref))
      );

      // Validate that each request exists, is still searching for a driver, has no assigned driver, and belongs to this trip.
      for (const requestSnap of requestSnaps) {
        if (!requestSnap.exists) {
          throw new HttpsError(
            'failed-precondition',
            'A linked passenger request could not be found.'
          );
        }

        const request = requestSnap.data();

        // Validate that the request is still searching for a driver, has no assigned driver, and belongs to this trip.
        if (
          request.status !== 'matching_driver' ||
          request.driverId != null ||
          request.groupId !== tripId
        ) {
          throw new HttpsError(
            'failed-precondition',
            'A passenger request has changed or is no longer available.'
          );
        }
      }

      // Reuse the validated driver profile and store its name with the assignment.
      const driverName =
        typeof driver.name === 'string' ? driver.name.trim() : '';
      const now = FieldValue.serverTimestamp();

      // STEP 7: Update the trip, driver, and passenger requests atomically.
      tx.update(tripRef, {
        driverId,
        ...(driverName ? { driverName } : {}),
        status: 'driver_assigned',
        updatedAt: now,
      });

      // Mark the driver as unavailable and update the timestamp.
      tx.update(driverRef, {
        isAvailable: false,
        updatedAt: now,
      });

      // Remove the driver offer lock to free up the driver for future offers.
      tx.delete(lockRef);

      // Update each linked passenger request to reflect the assigned driver
      //  and change the status to 'driver_assigned'.
      for (const requestRef of requestRefs) {
        tx.update(requestRef, {
          driverId,
          status: 'driver_assigned',
          updatedAt: now,
        });
      }

      // Return the list of request IDs for confirmation.
      return { success: true, requestIds };
    });
  }
);


/**
 * Allow the currently offered driver to decline a trip.
 * Release the reservation so another driver can be selected.
 */
exports.declineRideTrip = onCall(
  { region: REGION },
  async (call) => {
    if (!call.auth) {
      throw new HttpsError(
        'unauthenticated',
        'Please sign in before declining a trip.'
      );
    }

    const tripId = call.data?.tripId;

    if (typeof tripId !== 'string' || tripId.trim().length === 0) {
      throw new HttpsError(
        'invalid-argument',
        'A valid trip ID is required.'
      );
    }

    const driverId = call.auth.uid;
    const tripRef = db.collection('trips').doc(tripId);
    const lockRef = db.collection(DRIVER_OFFER_LOCKS).doc(driverId);

    return db.runTransaction(async (tx) => {
      // Read both documents before making changes.
      const [tripSnap, lockSnap] = await Promise.all([
        tx.get(tripRef),
        tx.get(lockRef),
      ]);

      if (!tripSnap.exists) {
        throw new HttpsError(
          'not-found',
          'This trip no longer exists.'
        );
      }

      const trip = tripSnap.data();

      if (
        trip.status !== 'matching_driver' ||
        trip.driverId != null
      ) {
        throw new HttpsError(
          'failed-precondition',
          'This trip is no longer waiting for a driver.'
        );
      }

      // Only the driver who received the offer can decline it.
      if (trip.offeredDriverId !== driverId) {
        throw new HttpsError(
          'permission-denied',
          'This trip is not currently offered to you.'
        );
      }

      const declined = Array.isArray(trip.declinedDriverIds)
        ? trip.declinedDriverIds
        : [];

      tx.update(tripRef, {
        offeredDriverId: null,
        offerExpiresAt: null,
        declinedDriverIds: [...new Set([...declined, driverId])],
        updatedAt: FieldValue.serverTimestamp(),
      });

      // Only delete the lock if it belongs to this trip.
      if (
        lockSnap.exists &&
        lockSnap.data().tripId === tripId
      ) {
        tx.delete(lockRef);
      }

      return {
        success: true,
        message: 'Trip declined successfully.',
      };
    });
  }
);

/**
 * Cancel one passenger's booking before the trip begins.
 * Other passengers' bookings remain active.
 */
exports.cancelRideBooking = onCall(
  { region: REGION },
  async (call) => {
    if (!call.auth) {
      throw new HttpsError(
        'unauthenticated',
        'Please sign in before cancelling a booking.'
      );
    }

    const requestId = call.data?.requestId;

    const cancellationReason = call.data?.cancellationReason;
    const cancellationDetails = call.data?.cancellationDetails ?? '';

    if (
      typeof requestId !== 'string' ||
      requestId.trim().length === 0
    ) {
      throw new HttpsError(
        'invalid-argument',
        'A valid ride request ID is required.'
      );
    }

    if (
      typeof cancellationReason !== 'string' ||
      cancellationReason.trim().length === 0 ||
      cancellationReason.trim().length > 100
    ) {
      throw new HttpsError(
        'invalid-argument',
        'Please select a valid cancellation reason.'
      );
    }

    if (
      typeof cancellationDetails !== 'string' ||
      cancellationDetails.length > 1000
    ) {
      throw new HttpsError(
        'invalid-argument',
        'Cancellation details must not exceed 1000 characters.'
      );
    }

    const requestRef = db.collection('ride_requests').doc(requestId);

    return db.runTransaction(async (tx) => {
      const requestSnap = await tx.get(requestRef);

      if (!requestSnap.exists) {
        throw new HttpsError(
          'not-found',
          'This booking could not be found.'
        );
      }

      const booking = requestSnap.data();

      // Passengers may only cancel their own bookings.
      if (booking.passengerId !== call.auth.uid) {
        throw new HttpsError(
          'permission-denied',
          'You can only cancel your own booking.'
        );
      }

      if (booking.status === 'cancelled') {
        return { success: true, alreadyCancelled: true };
      }

      // In-progress trips need a separate early-exit workflow.
      if (
        booking.status === 'in_progress' ||
        booking.status === 'completed'
      ) {
        throw new HttpsError(
          'failed-precondition',
          'This booking can no longer be cancelled as a pre-trip booking.'
        );
      }

      const cancellableStatuses = [
        'searching',
        'awaiting_choice',
        'solo_requested',
        'matching_driver',
        'driver_assigned',
      ];

      if (!cancellableStatuses.includes(booking.status)) {
        throw new HttpsError(
          'failed-precondition',
          'This booking cannot be cancelled in its current state.'
        );
      }

      let tripRef = null;
      let trip = null;
      let remainingRequests = [];
      let offerLockRef = null;
      let assignedDriverRef = null;
      let assignedDriver = null;

      if (booking.groupId) {
        tripRef = db.collection('trips').doc(booking.groupId);
        const tripSnap = await tx.get(tripRef);

        if (tripSnap.exists) {
          trip = tripSnap.data();

            // Read the assigned driver's information before writing.
            if (trip.driverId) {
              assignedDriverRef = db
                .collection('users')
                .doc(trip.driverId);

              const assignedDriverSnap = await tx.get(assignedDriverRef);

              if (assignedDriverSnap.exists) {
                assignedDriver = assignedDriverSnap.data();
              }
            }

          // Read the active driver's offer reservation.
          // Firestore transactions must read before writing.
          if (trip.offeredDriverId) {
            offerLockRef = db
              .collection(DRIVER_OFFER_LOCKS)
              .doc(trip.offeredDriverId);

            const offerLockSnap = await tx.get(offerLockRef);

            if (
              !offerLockSnap.exists ||
              offerLockSnap.data().tripId !== tripRef.id
            ) {
              offerLockRef = null;
            }
          }


          if (
            trip.status === 'in_progress' ||
            trip.status === 'completed'
          ) {
            throw new HttpsError(
              'failed-precondition',
              'The trip has already started or completed.'
            );
          }

          const requestIds = Array.isArray(trip.requestIds)
            ? trip.requestIds
            : [];

          // Read all other passenger requests before writing anything.
          const otherIds = requestIds.filter(
            (id) => id !== requestId
          );

          const otherSnapshots = await Promise.all(
            otherIds.map((id) =>
              tx.get(db.collection('ride_requests').doc(id))
            )
          );

          remainingRequests = otherSnapshots
            .filter((snap) => snap.exists)
            .map((snap) => ({
              id: snap.id,
              ref: snap.ref,
              data: snap.data(),
            }))
            .filter((r) =>
              r.data.status !== 'cancelled' &&
              r.data.status !== 'completed'
            );
        }
      }

            // Remove this booking from a collecting passenger group.
      if (booking.groupSearchId && !booking.groupId) {
        const collectingGroupRef = db
          .collection('matching_groups')
          .doc(booking.groupSearchId);

        const collectingGroupSnap = await tx.get(collectingGroupRef);

        if (collectingGroupSnap.exists) {
          const collectingGroup = collectingGroupSnap.data();

          if (collectingGroup.status === 'collecting') {
            const currentIds = Array.isArray(collectingGroup.requestIds)
              ? collectingGroup.requestIds
              : [];

            const remainingIds = currentIds.filter(
              (id) => id !== requestId
            );

            const remainingCount = Math.max(
              0,
              (collectingGroup.totalPassengers || 0) -
                booking.passengerCount
            );

            tx.update(collectingGroupRef, {
              requestIds: remainingIds,
              totalPassengers: remainingCount,
              status: remainingIds.length === 0
                ? 'cancelled'
                : 'collecting',
              updatedAt: FieldValue.serverTimestamp(),
            });
          }
        }
      }

      // Mark only this passenger's booking as cancelled.
      tx.update(requestRef, {
        status: 'cancelled',

        groupSearchId: null,
        groupSearchExpiresAt: null,

        cancellationReason: cancellationReason.trim(),
        cancellationDetails: cancellationDetails.trim(),
        cancelledBy: 'passenger',

        cancelledAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });

      if (tripRef && trip) {
        const remainingIds = remainingRequests.map((r) => r.id);

        const remainingPassengerIds = [
          ...new Set(remainingRequests.map((r) => r.data.passengerId)),
        ];

        const remainingPassengerCount = remainingRequests.reduce(
          (sum, r) => sum + (r.data.passengerCount || 1),
          0
        );

        if (remainingRequests.length === 0) {
          // Nobody remains: cancel the trip and release its driver.
          tx.update(tripRef, {
            status: 'cancelled',
            requestIds: [],
            passengerIds: [],
            totalPassengers: 0,
            totalFareSen: 0,
            driverId: null,
            offeredDriverId: null,
            offerExpiresAt: null,
            updatedAt: FieldValue.serverTimestamp(),
          });

          if (offerLockRef) {
            tx.delete(offerLockRef);
          }

          if (
            assignedDriverRef &&
            assignedDriver &&
            assignedDriver.verificationStatus === 'approved'
          ) {
            tx.update(assignedDriverRef, {
              isAvailable: true,
              updatedAt: FieldValue.serverTimestamp(),
            });
          }

        } else {
          // Refresh the trip using the remaining booking's information.
          const reference = remainingRequests[0].data;

          // Preserve confirmed booking fares after a cancellation.
          const totalFareSen = remainingRequests.reduce(
            (sum, r) => sum + (r.data.fareShareSen || 0),
            0
          );

          // Update the passenger count for each remaining booking.
          for (const r of remainingRequests) {
            tx.update(r.ref, {
              tripPassengers: remainingPassengerCount,
              updatedAt: FieldValue.serverTimestamp(),
            });
          }

          // Update the trip without changing confirmed booking fares.
          tx.update(tripRef, {
            requestIds: remainingIds,
            passengerIds: remainingPassengerIds,
            totalPassengers: remainingPassengerCount,
            totalFareSen,
            pickupHubId: reference.pickupHubId,
            pickupName: reference.pickupName,
            pickupLat: reference.pickupLat,
            pickupLon: reference.pickupLon,
            departureTime: reference.departureTime,
            dropoffRefLat: reference.dropoffLat,
            dropoffRefLon: reference.dropoffLon,
            updatedAt: FieldValue.serverTimestamp(),
          });
        }
        }
      return { success: true };
    });
  }
);

/**
 * Release an assigned trip back to driver matching before it starts.
 * Passenger bookings remain active and are offered to another driver.
 */
exports.cancelDriverTrip = onCall(
  { region: REGION },
  async (call) => {
    if (!call.auth) {
      throw new HttpsError(
        'unauthenticated',
        'Please sign in before cancelling a trip.'
      );
    }

    const { tripId, cancellationReason, cancellationDetails = '' } =
      call.data || {};

    if (
      typeof tripId !== 'string' ||
      !tripId.trim() ||
      typeof cancellationReason !== 'string' ||
      !cancellationReason.trim() ||
      cancellationReason.trim().length > 100 ||
      typeof cancellationDetails !== 'string' ||
      cancellationDetails.length > 1000
    ) {
      throw new HttpsError(
        'invalid-argument',
        'A valid trip ID, cancellation reason, and details are required.'
      );
    }

    const driverId = call.auth.uid;
    const tripRef = db.collection('trips').doc(tripId);
    const driverRef = db.collection('users').doc(driverId);
    const lockRef = db.collection(DRIVER_OFFER_LOCKS).doc(driverId);

    return db.runTransaction(async (tx) => {
      const [tripSnap, driverSnap, lockSnap] = await Promise.all([
        tx.get(tripRef),
        tx.get(driverRef),
        tx.get(lockRef),
      ]);

      if (!tripSnap.exists) {
        throw new HttpsError('not-found', 'Trip not found.');
      }

      const trip = tripSnap.data();
      if (trip.driverId !== driverId) {
        throw new HttpsError(
          'permission-denied',
          'You are not the assigned driver.'
        );
      }
      if (!['driver_assigned', 'driver_arrived'].includes(trip.status)) {
        throw new HttpsError(
          'failed-precondition',
          'A trip can only be cancelled before it starts.'
        );
      }

      const requestIds = trip.requestIds;
      if (
        !Array.isArray(requestIds) ||
        requestIds.length === 0 ||
        requestIds.some((id) => typeof id !== 'string' || !id.trim()) ||
        new Set(requestIds).size !== requestIds.length
      ) {
        throw new HttpsError(
          'failed-precondition',
          'Invalid passenger bookings for this trip.'
        );
      }

      const requestSnaps = await Promise.all(
        requestIds.map((id) =>
          tx.get(db.collection('ride_requests').doc(id))
        )
      );
      for (const requestSnap of requestSnaps) {
        const booking = requestSnap.data();
        if (
          !requestSnap.exists ||
          booking.groupId !== tripId ||
          booking.driverId !== driverId ||
          !['driver_assigned', 'driver_arrived'].includes(booking.status)
        ) {
          throw new HttpsError(
            'failed-precondition',
            'A passenger booking is inconsistent with this trip.'
          );
        }
      }

      const timestamp = FieldValue.serverTimestamp();
      const declinedDriverIds = Array.isArray(trip.declinedDriverIds)
        ? trip.declinedDriverIds
        : [];
      tx.update(tripRef, {
        status: 'matching_driver',
        driverId: null,
        offeredDriverId: null,
        offerExpiresAt: null,
        declinedDriverIds: [...new Set([...declinedDriverIds, driverId])],
        optimizedDropoffOrder: [],
        driverCancellationReason: cancellationReason.trim(),
        driverCancellationDetails: cancellationDetails.trim(),
        driverCancelledAt: timestamp,
        updatedAt: timestamp,
      });

      for (const requestSnap of requestSnaps) {
        tx.update(requestSnap.ref, {
          status: 'matching_driver',
          driverId: null,
          driverCancelledAt: timestamp,
          updatedAt: timestamp,
        });
      }

      if (lockSnap.exists && lockSnap.data().tripId === tripId) {
        tx.delete(lockRef);
      }
      if (driverSnap.exists && driverSnap.data().verificationStatus === 'approved') {
        tx.update(driverRef, {
          isAvailable: true,
          updatedAt: timestamp,
        });
      }

      return { success: true, tripId, status: 'matching_driver' };
    });
  }
);


/**
 * PHASE 4D — Secure Driver Trip Advancement
 *
 * Handles:
 * driver_assigned -> driver_arrived
 * driver_arrived  -> in_progress
 *
 * Only the assigned driver can advance a trip.
 * Updates the trip and eligible passenger requests atomically.
 */
exports.advanceDriverTrip = onCall(
  { region: REGION },
  async (call) => {
    if (!call.auth) {
      throw new HttpsError(
        'unauthenticated',
        'Please sign in before updating a trip.'
      );
    }

    const tripId = call.data?.tripId;
    const nextStatus = call.data?.nextStatus;

    if (
      typeof tripId !== 'string' ||
      !tripId.trim() ||
      !['driver_arrived', 'in_progress'].includes(nextStatus)
    ) {
      throw new HttpsError(
        'invalid-argument',
        'A valid trip ID and next status are required.'
      );
    }

    const expectedStatus =
      nextStatus === 'driver_arrived'
        ? 'driver_assigned'
        : 'driver_arrived';

    const driverId = call.auth.uid;
    const tripRef = db.collection('trips').doc(tripId);

    return db.runTransaction(async (tx) => {
      const tripSnap = await tx.get(tripRef);

      if (!tripSnap.exists) {
        throw new HttpsError(
          'not-found',
          'Trip not found.'
        );
      }

      const trip = tripSnap.data();

      if (trip.driverId !== driverId) {
        throw new HttpsError(
          'permission-denied',
          'You are not the assigned driver.'
        );
      }

      if (trip.status !== expectedStatus) {
        throw new HttpsError(
          'failed-precondition',
          'Trip status has changed. Please refresh.'
        );
      }

      const requestIds = trip.requestIds;

      if (
        !Array.isArray(requestIds) ||
        requestIds.length === 0 ||
        requestIds.some(
          (id) => typeof id !== 'string' || !id.trim()
        ) ||
        new Set(requestIds).size !== requestIds.length
      ) {
        throw new HttpsError(
          'failed-precondition',
          'Invalid passenger bookings for this trip.'
        );
      }

      const requestRefs = requestIds.map((id) =>
        db.collection('ride_requests').doc(id)
      );

      const requestSnaps = await Promise.all(
        requestRefs.map((ref) => tx.get(ref))
      );

      const participants = new Set([driverId]);

      for (const requestSnap of requestSnaps) {
        if (!requestSnap.exists) {
          throw new HttpsError(
            'failed-precondition',
            'A passenger booking could not be found.'
          );
        }

        const request = requestSnap.data();

        if (
          request.groupId !== tripId ||
          request.driverId !== driverId
        ) {
          throw new HttpsError(
            'failed-precondition',
            'Passenger booking does not belong to this trip.'
          );
        }

        if (nextStatus === 'in_progress') {
          if (
            ['cancelled', 'completed', 'drop_off_confirmed']
              .includes(request.status)
          ) {
            continue;
          }

          if (
            typeof request.passengerId !== 'string' ||
            !request.passengerId
          ) {
            throw new HttpsError(
              'failed-precondition',
              'Passenger account information is missing.'
            );
          }

          participants.add(request.passengerId);
        }
      }

      if (
        nextStatus === 'in_progress' &&
        participants.size === 1
      ) {
        throw new HttpsError(
          'failed-precondition',
          'No active passengers remain.'
        );
      }

      // Check live GPS freshness for the driver and,
      // when starting the trip, all active passengers.
      const locationRefs = [...participants].map((uid) =>
        tripRef.collection('live_locations').doc(uid)
      );

      const locationSnaps = await Promise.all(
        locationRefs.map((ref) => tx.get(ref))
      );

      const now = Date.now();
      const maxAgeMs = 90 * 1000;

      for (let i = 0; i < locationSnaps.length; i++) {
        const locationSnap = locationSnaps[i];
        const location = locationSnap.exists
          ? locationSnap.data()
          : null;

        const updatedAt = location?.updatedAt?.toMillis?.();

        if (
          !Number.isFinite(updatedAt) ||
          updatedAt > now ||
          now - updatedAt > maxAgeMs
        ) {
          throw new HttpsError(
            'failed-precondition',
            'All required participants must have fresh GPS locations.'
          );
        }

        if (!isValidCoordinates(location.lat, location.lon)) {
          throw new HttpsError(
            'failed-precondition',
            'A participant has invalid GPS coordinates.'
          );
        }
      }

      // All transaction reads are complete.
      const timestamp = FieldValue.serverTimestamp();

      tx.update(tripRef, {
        status: nextStatus,
        updatedAt: timestamp,
      });

      for (const requestSnap of requestSnaps) {
        if (requestSnap.data().status === expectedStatus) {
          tx.update(requestSnap.ref, {
            status: nextStatus,
            updatedAt: timestamp,
          });
        }
      }

      return {
        success: true,
        tripId,
        status: nextStatus,
      };
    });
  }
);


/**
 * PHASE 4D — Secure Passenger Drop-Off Confirmation
 *
 * Only the assigned driver can confirm a drop-off.
 * Enforces the saved optimized drop-off order.
 * Completes the trip after its final passenger drop-off.
 * Preserves passenger review eligibility.
 */
exports.confirmPassengerDropOff = onCall(
  { region: REGION },
  async (call) => {
    if (!call.auth) {
      throw new HttpsError(
        'unauthenticated',
        'Please sign in before confirming a drop-off.'
      );
    }

    const { tripId, requestId } = call.data || {};

    if (
      typeof tripId !== 'string' ||
      !tripId.trim() ||
      typeof requestId !== 'string' ||
      !requestId.trim()
    ) {
      throw new HttpsError(
        'invalid-argument',
        'A valid trip ID and passenger request ID are required.'
      );
    }

    const driverId = call.auth.uid;
    const tripRef = db.collection('trips').doc(tripId);

    return db.runTransaction(async (tx) => {
      const tripSnap = await tx.get(tripRef);

      if (!tripSnap.exists) {
        throw new HttpsError(
          'not-found',
          'Trip not found.'
        );
      }

      const trip = tripSnap.data();

      // Only the assigned driver may confirm drop-offs.
      if (trip.driverId !== driverId) {
        throw new HttpsError(
          'permission-denied',
          'You are not the assigned driver.'
        );
      }

      if (trip.status !== 'in_progress') {
        throw new HttpsError(
          'failed-precondition',
          'The trip must be in progress.'
        );
      }

      const driverRef = db.collection('users').doc(driverId);
      const driverSnap = await tx.get(driverRef);
      const requestIds = trip.requestIds;

      if (
        !Array.isArray(requestIds) ||
        requestIds.length === 0 ||
        requestIds.some(
          (id) => typeof id !== 'string' || !id.trim()
        ) ||
        new Set(requestIds).size !== requestIds.length
      ) {
        throw new HttpsError(
          'failed-precondition',
          'Trip passenger requests are invalid.'
        );
      }

      if (!requestIds.includes(requestId)) {
        throw new HttpsError(
          'permission-denied',
          'This passenger booking does not belong to the trip.'
        );
      }

      // Read the saved optimized order.
      let dropoffOrder = trip.optimizedDropoffOrder;

      // Single-booking trips do not require an optimized order.
      if (
        requestIds.length === 1 &&
        (!Array.isArray(dropoffOrder) ||
          dropoffOrder.length === 0)
      ) {
        dropoffOrder = [...requestIds];
      }

      // For shared trips, the saved order must contain
      // every current request exactly once.
      if (
        !Array.isArray(dropoffOrder) ||
        dropoffOrder.length !== requestIds.length ||
        new Set(dropoffOrder).size !== requestIds.length ||
        dropoffOrder.some((id) => !requestIds.includes(id))
      ) {
        throw new HttpsError(
          'failed-precondition',
          'The optimized drop-off order is missing or invalid.'
        );
      }

      const requestRefs = requestIds.map((id) =>
        db.collection('ride_requests').doc(id)
      );

      // Read all passenger bookings before making any writes.
      const requestSnaps = await Promise.all(
        requestRefs.map((ref) => tx.get(ref))
      );

      if (requestSnaps.some((snap) => !snap.exists)) {
        throw new HttpsError(
          'failed-precondition',
          'A passenger booking could not be found.'
        );
      }

      const requestsById = new Map();

      for (const snap of requestSnaps) {
        const booking = snap.data();

        if (
          booking.groupId !== tripId ||
          booking.driverId !== driverId ||
          typeof booking.passengerId !== 'string' ||
          !booking.passengerId.trim()
        ) {
          throw new HttpsError(
            'failed-precondition',
            'A passenger booking is inconsistent with this trip.'
          );
        }

        if (
          ![
            'in_progress',
            'drop_off_confirmed',
            'cancelled',
            'completed',
          ].includes(booking.status)
        ) {
          throw new HttpsError(
            'failed-precondition',
            'A passenger booking has an unexpected status.'
          );
        }

        requestsById.set(snap.id, {
          ref: snap.ref,
          data: booking,
        });
      }

      const target = requestsById.get(requestId);

      // A passenger cannot be dropped off twice.
      if (target.data.status !== 'in_progress') {
        throw new HttpsError(
          'failed-precondition',
          'This passenger has already been dropped off.'
        );
      }

      // Only bookings still in progress require drop-off.
      const remainingIds = dropoffOrder.filter(
        (id) =>
          requestsById.get(id).data.status === 'in_progress'
      );

      if (
        remainingIds.length === 0 ||
        remainingIds[0] !== requestId
      ) {
        throw new HttpsError(
          'failed-precondition',
          'Passengers must be dropped off in the optimized order.'
        );
      }

      const timestamp = FieldValue.serverTimestamp();

      // Confirm this passenger's drop-off.
      tx.update(target.ref, {
        status: 'drop_off_confirmed',
        droppedOffAt: timestamp,
        reviewPromptEligibleAt: timestamp,
        updatedAt: timestamp,
      });

      const tripCompleted = requestIds.every((id) => {
        const status = id === requestId
          ? 'drop_off_confirmed'
          : requestsById.get(id).data.status;
        return ['drop_off_confirmed', 'completed', 'cancelled'].includes(
          status
        );
      });
      tx.update(tripRef, {
        ...(tripCompleted
          ? { status: 'completed', completedAt: timestamp }
          : {}),
        updatedAt: timestamp,
      });
      if (
        tripCompleted &&
        driverSnap.exists &&
        driverSnap.data().verificationStatus === 'approved'
      ) {
        tx.update(driverRef, {
          isAvailable: true,
          updatedAt: timestamp,
        });
      }

      return {
        success: true,
        tripId,
        requestId,
        tripCompleted,
        status: 'drop_off_confirmed',
      };
    });
  }
);

/**
 * Completes a trip only after every passenger has been dropped off or cancelled.
 */
exports.completeDriverTrip = onCall(
  { region: REGION },
  async (call) => {
    if (!call.auth) {
      throw new HttpsError(
        'unauthenticated',
        'Please sign in before ending the trip.'
      );
    }

    const { tripId } = call.data || {};
    if (typeof tripId !== 'string' || !tripId.trim()) {
      throw new HttpsError('invalid-argument', 'A valid trip ID is required.');
    }

    const driverId = call.auth.uid;
    const tripRef = db.collection('trips').doc(tripId);

    return db.runTransaction(async (tx) => {
      const tripSnap = await tx.get(tripRef);
      if (!tripSnap.exists) {
        throw new HttpsError('not-found', 'Trip not found.');
      }

      const trip = tripSnap.data();
      if (trip.driverId !== driverId) {
        throw new HttpsError(
          'permission-denied',
          'You are not the assigned driver.'
        );
      }
      if (trip.status !== 'in_progress') {
        throw new HttpsError(
          'failed-precondition',
          'The trip must be in progress.'
        );
      }

      const driverRef = db.collection('users').doc(driverId);
      const driverSnap = await tx.get(driverRef);
      const requestIds = trip.requestIds;
      if (
        !Array.isArray(requestIds) ||
        requestIds.length === 0 ||
        requestIds.some((id) => typeof id !== 'string' || !id.trim()) ||
        new Set(requestIds).size !== requestIds.length
      ) {
        throw new HttpsError(
          'failed-precondition',
          'Invalid passenger bookings for this trip.'
        );
      }

      const requestSnaps = await Promise.all(
        requestIds.map((id) =>
          tx.get(db.collection('ride_requests').doc(id))
        )
      );
      for (const requestSnap of requestSnaps) {
        const booking = requestSnap.data();
        if (
          !requestSnap.exists ||
          booking.groupId !== tripId ||
          booking.driverId !== driverId
        ) {
          throw new HttpsError(
            'failed-precondition',
            'A passenger booking is inconsistent with this trip.'
          );
        }
        if (!['drop_off_confirmed', 'completed', 'cancelled'].includes(
          booking.status
        )) {
          throw new HttpsError(
            'failed-precondition',
            'Every passenger must be dropped off or cancelled before ending the trip.'
          );
        }
      }

      const timestamp = FieldValue.serverTimestamp();
      tx.update(tripRef, {
        status: 'completed',
        completedAt: timestamp,
        updatedAt: timestamp,
      });
      if (
        driverSnap.exists &&
        driverSnap.data().verificationStatus === 'approved'
      ) {
        tx.update(driverRef, {
          isAvailable: true,
          updatedAt: timestamp,
        });
      }

      return { success: true, tripId, status: 'completed' };
    });
  }
);


/**
 * Saves a driver's proposed passenger drop-off order.
 *
 * The server verifies authorization, trip membership,
 * request statuses, and order completeness.
 *
 * Note: This validates the order but does not independently
 * verify that it is the fastest possible route.
 */
exports.saveOptimizedDropoffOrder = onCall(
  { region: REGION },
  async (request) => {
    const uid = request.auth?.uid;

    if (!uid) {
      throw new HttpsError(
        'unauthenticated',
        'Please log in before saving a route.'
      );
    }

    const { tripId, optimizedRequestIds } = request.data || {};

    if (
      typeof tripId !== 'string' ||
      !tripId.trim() ||
      !Array.isArray(optimizedRequestIds) ||
      optimizedRequestIds.length === 0 ||
      optimizedRequestIds.some(
        (id) => typeof id !== 'string' || !id.trim()
      )
    ) {
      throw new HttpsError(
        'invalid-argument',
        'A valid trip ID and drop-off order are required.'
      );
    }

    if (
      new Set(optimizedRequestIds).size !==
      optimizedRequestIds.length
    ) {
      throw new HttpsError(
        'invalid-argument',
        'The drop-off order contains duplicate bookings.'
      );
    }

    const tripRef = db.collection('trips').doc(tripId);

    return db.runTransaction(async (transaction) => {
      const tripSnapshot = await transaction.get(tripRef);

      if (!tripSnapshot.exists) {
        throw new HttpsError(
          'not-found',
          'Trip not found.'
        );
      }

      const trip = tripSnapshot.data();

      if (trip.driverId !== uid) {
        throw new HttpsError(
          'permission-denied',
          'Only the assigned driver can save the route.'
        );
      }

      if (trip.status !== 'in_progress') {
        throw new HttpsError(
          'failed-precondition',
          'The trip must be in progress.'
        );
      }

      const requestIds = trip.requestIds;

      if (
        !Array.isArray(requestIds) ||
        requestIds.length === 0 ||
        requestIds.some(
          (id) => typeof id !== 'string' || !id.trim()
        ) ||
        new Set(requestIds).size !== requestIds.length
      ) {
        throw new HttpsError(
          'failed-precondition',
          'The trip has an invalid passenger list.'
        );
      }

      const existingOrder = trip.optimizedDropoffOrder;

      if (
        existingOrder !== undefined &&
        existingOrder !== null
      ) {
        throw new HttpsError(
          'already-exists',
          'A drop-off order has already been saved.'
        );
      }

      if (
        optimizedRequestIds.length !== requestIds.length ||
        !optimizedRequestIds.every(
          (id) => requestIds.includes(id)
        )
      ) {
        throw new HttpsError(
          'invalid-argument',
          'The order must contain every trip booking exactly once.'
        );
      }

      // Read and validate all linked bookings before writing.
      for (const id of requestIds) {
        const bookingSnapshot = await transaction.get(
          db.collection('ride_requests').doc(id)
        );

        if (!bookingSnapshot.exists) {
          throw new HttpsError(
            'failed-precondition',
            'A passenger booking is missing.'
          );
        }

        const booking = bookingSnapshot.data();

        if (
          booking.groupId !== tripId ||
          booking.driverId !== uid ||
          typeof booking.passengerId !== 'string' ||
          !booking.passengerId.trim()
        ) {
          throw new HttpsError(
            'failed-precondition',
            'A passenger booking does not match this trip.'
          );
        }

        if (booking.status !== 'in_progress') {
          throw new HttpsError(
            'failed-precondition',
            'All passenger bookings must be in progress.'
          );
        }
      }

      // All validations passed; save the optimized order in trips collection.
      transaction.update(tripRef, {
        optimizedDropoffOrder: [...optimizedRequestIds],
        routeUpdatedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });

      return {
        success: true,
        tripId,
        optimizedDropoffOrder: [...optimizedRequestIds],
      };
    });
  }
);

/**
 * Return names and profile photos for a trip's driver and passengers.
 * Only a participant in the trip may retrieve these profiles.
 */
exports.getTripParticipantProfiles = onCall(
  { region: REGION },
  async (call) => {
    if (!call.auth) {
      throw new HttpsError(
        'unauthenticated',
        'Please sign in.'
      );
    }

    const tripId = call.data?.tripId;

    if (typeof tripId !== 'string' || !tripId.trim()) {
      throw new HttpsError(
        'invalid-argument',
        'A valid trip ID is required.'
      );
    }

    const tripSnap = await db.collection('trips').doc(tripId).get();

    if (!tripSnap.exists) {
      throw new HttpsError('not-found', 'Trip not found.');
    }

    const trip = tripSnap.data();
    const uid = call.auth.uid;

    const requestIds = Array.isArray(trip.requestIds)
      ? trip.requestIds
      : [];

    const requestSnaps = await Promise.all(
      requestIds.map((id) =>
        db.collection('ride_requests').doc(id).get()
      )
    );

    const validRequests = requestSnaps
      .filter((snap) => snap.exists)
      .map((snap) => snap.data())
      .filter((request) => request.groupId === tripId);

    const passengerIds = [
      ...new Set(
        validRequests
          .map((request) => request.passengerId)
          .filter((id) => typeof id === 'string' && id.length > 0)
      )
    ];

    const driverId = trip.driverId;

    if (driverId !== uid && !passengerIds.includes(uid)) {
      throw new HttpsError(
        'permission-denied',
        'You are not a participant in this trip.'
      );
    }

    const profileIds = [
      ...new Set([
        ...passengerIds,
        ...(typeof driverId === 'string' && driverId
          ? [driverId]
          : [])
      ])
    ];

    const profiles = {};

    await Promise.all(
      profileIds.map(async (id) => {
        const userSnap = await db.collection('users').doc(id).get();

        if (!userSnap.exists) return;

        const user = userSnap.data();

        profiles[id] = {
          name: typeof user.name === 'string' ? user.name : '',
          profilePic: typeof user.profilePic === 'string'
            ? user.profilePic
            : ''
        };
      })
    );

    return { profiles };
  }
);


/**
 * Return the number of approved drivers currently marked as available.
 * This count is visible only to authenticated, approved passenger accounts.
 */
exports.getAvailableDriverCount = onCall(
  { region: REGION },
  async (call) => {
    if (!call.auth) {
      throw new HttpsError(
        'unauthenticated',
        'Please sign in.'
      );
    }

    const passengerSnap = await db
      .collection('users')
      .doc(call.auth.uid)
      .get();

    if (
      !passengerSnap.exists ||
      passengerSnap.data().role !== 'passenger' ||
      passengerSnap.data().verificationStatus !== 'approved'
    ) {
      throw new HttpsError(
        'permission-denied',
        'An approved passenger account is required.'
      );
    }

    const countSnap = await db
      .collection('users')
      .where('role', '==', 'driver')
      .where('verificationStatus', '==', 'approved')
      .where('isAvailable', '==', true)
      .count()
      .get();

    return { count: countSnap.data().count };
  }
);
