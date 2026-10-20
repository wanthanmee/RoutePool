const {
  onDocumentCreated,
  onDocumentUpdated,
} = require('firebase-functions/v2/firestore');


const { onSchedule } = require('firebase-functions/v2/scheduler');
const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');

initializeApp();
const db = getFirestore();

// Must match the location of your Firestore database
// (Firebase console -> Firestore -> Data tab shows it).
const REGION = 'asia-southeast1'; 

// Matching rules (same values the old matching screen used)
const MAX_PASSENGERS = 4;
const MAX_DEPARTURE_DIFF_MIN = 30;
const MAX_DROPOFF_DIFF_KM = 5;

// Fare rules. Keep in sync with lib/services/fare_calculator.dart.
const BASE_FARE_SEN = 300; // RM 3.00
const PER_KM_SEN = 120; // RM 1.20 per km
const MIN_FARE_SEN = 600; // RM 6.00
const ROAD_FACTOR = 1.3;

function toRad(deg) {
  return (deg * Math.PI) / 180;
}

function haversineKm(lat1, lon1, lat2, lon2) {
  const R = 6371;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function roadDistanceKm(lat1, lon1, lat2, lon2) {
  return haversineKm(lat1, lon1, lat2, lon2) * ROAD_FACTOR;
}

function soloFareSen(km) {
  const raw = BASE_FARE_SEN + PER_KM_SEN * km;
  return Math.max(MIN_FARE_SEN, Math.round(raw / 10) * 10);
}

/**
 * The trip costs as much as its longest solo fare. Each request pays a share
 * of that, weighted by (passengers x distance), and never more than its own
 * solo fare. The trip total is the sum of the shares.
 */

    function computeShares(members) {
    if (members.length === 0) return {};

    const tripFareSen = Math.max(
        ...members.map((m) => m.soloFareSen)
    );

    const targetUnits = Math.round(tripFareSen / 10);

    const allocations = members.map((m) => ({
        id: m.id,
        capUnits: Math.floor(m.soloFareSen / 10),
        weight:
        m.passengerCount *
        (Number.isFinite(m.distanceKm) && m.distanceKm > 0
            ? m.distanceKm
            : 1),
        units: 0,
    }));

    const shares = {};
    let remaining = targetUnits;

    // Allocate one 10-sen unit at a time.
    // Lower normalized allocation means a member receives
    // the next unit, while respecting their solo-fare cap.
    while (remaining > 0) {
        const eligible = allocations
        .filter((m) => m.units < m.capUnits)
        .sort((a, b) => {
            const ratioA = (a.units + 1) / a.weight;
            const ratioB = (b.units + 1) / b.weight;

            return ratioA - ratioB || a.id.localeCompare(b.id);
        });

        if (eligible.length === 0) {
        throw new Error(
            'Unable to allocate the complete trip fare.'
        );
        }

        eligible[0].units += 1;
        remaining -= 1;
    }

    for (const m of allocations) {
        shares[m.id] = m.units * 10;
    }

    return shares;
    }



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


/**
 * Initialise a five-minute passenger-search window when a booking is created.
 */
exports.matchRideRequest = onDocumentCreated(
  { document: 'ride_requests/{requestId}', region: REGION },
  async (event) => {
    const requestId = event.params.requestId;
    const ref = db.collection('ride_requests').doc(requestId);

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) return;

      const data = snap.data();
      if (data.status !== 'searching' || data.groupId) return;

      const now = Date.now();

      tx.update(ref, {
        searchStartedAt: new Date(now),
        searchExpiresAt: new Date(now + 5 * 60 * 1000),
        updatedAt: FieldValue.serverTimestamp(),
      });
    });
  }
);

/**
 * Periodically match waiting requests.
 * A compatible pair proceeds to driver matching immediately.
 * Unmatched requests become eligible for the passenger's choice at expiry.
 */
exports.processPassengerMatching = onSchedule(
  {
    schedule: '* * * * *',
    timeZone: 'Asia/Kuala_Lumpur',
    region: REGION,
  },
  async () => {
    const now = Date.now();

    const waiting = await db.collection('ride_requests')
      .where('status', '==', 'searching')
      .get();

    const requests = waiting.docs
      .map((doc) => ({ id: doc.id, ref: doc.ref, ...doc.data() }))
      .filter((r) => !r.groupId && isValidRequest(r));

    // First, expire requests whose five-minute window has ended.
    for (const r of requests) {
      const expires = r.searchExpiresAt?.toMillis?.();

      if (expires && expires <= now) {
        await db.runTransaction(async (tx) => {
          const snap = await tx.get(r.ref);
          if (!snap.exists) return;

          const current = snap.data();

          if (
            current.status === 'searching' &&
            !current.groupId &&
            current.searchExpiresAt?.toMillis?.() <= now
          ) {
            tx.update(r.ref, {
              status: 'awaiting_choice',
              updatedAt: FieldValue.serverTimestamp(),
            });
          }
        });
      }
    }

    // Only requests still within their passenger-search window can match.
    const active = requests.filter((r) => {
      const expires = r.searchExpiresAt?.toMillis?.();
      return expires && expires > now;
    });

    const used = new Set();

    for (let i = 0; i < active.length; i++) {
      const a = active[i];

      if (used.has(a.id)) continue;

      for (let j = i + 1; j < active.length; j++) {
        const b = active[j];

        if (used.has(b.id)) continue;
        if (a.passengerId === b.passengerId) continue;
        if (a.pickupHubId !== b.pickupHubId) continue;

        if (a.passengerCount + b.passengerCount > MAX_PASSENGERS) {
          continue;
        }

        const timeDifference = Math.abs(
          a.departureTime.toMillis() - b.departureTime.toMillis()
        );

        if (timeDifference > MAX_DEPARTURE_DIFF_MIN * 60000) {
          continue;
        }

        const destinationDifference = haversineKm(
          a.dropoffLat,
          a.dropoffLon,
          b.dropoffLat,
          b.dropoffLon
        );

        if (destinationDifference > MAX_DROPOFF_DIFF_KM) {
          continue;
        }

        const tripRef = db.collection('trips').doc();

        const distanceA = roadDistanceKm(
          a.pickupLat, a.pickupLon, a.dropoffLat, a.dropoffLon
        );
        const distanceB = roadDistanceKm(
          b.pickupLat, b.pickupLon, b.dropoffLat, b.dropoffLon
        );

        const soloA = soloFareSen(distanceA);
        const soloB = soloFareSen(distanceB);

        const members = [
          {
            id: a.id,
            passengerCount: a.passengerCount,
            distanceKm: distanceA,
            soloFareSen: soloA,
          },
          {
            id: b.id,
            passengerCount: b.passengerCount,
            distanceKm: distanceB,
            soloFareSen: soloB,
          },
        ];

        const shares = computeShares(members);
        const totalPassengers = a.passengerCount + b.passengerCount;
        const totalFareSen = Object.values(shares)
          .reduce((sum, share) => sum + share, 0);

        let matched = false;

        await db.runTransaction(async (tx) => {
          // Read both requests again to prevent duplicate grouping.
          const snapA = await tx.get(a.ref);
          const snapB = await tx.get(b.ref);

          if (!snapA.exists || !snapB.exists) return;

          const currentA = snapA.data();
          const currentB = snapB.data();

          if (
            currentA.status !== 'searching' ||
            currentB.status !== 'searching' ||
            currentA.groupId ||
            currentB.groupId ||
            currentA.searchExpiresAt?.toMillis?.() <= Date.now() ||
            currentB.searchExpiresAt?.toMillis?.() <= Date.now()
          ) {
            return;
          }

          tx.set(tripRef, {
            status: 'matching_driver',
            pickupHubId: a.pickupHubId,
            pickupName: a.pickupName,
            pickupLat: a.pickupLat,
            pickupLon: a.pickupLon,
            departureTime: a.departureTime,
            dropoffRefLat: a.dropoffLat,
            dropoffRefLon: a.dropoffLon,
            requestIds: [a.id, b.id],
            totalPassengers,
            totalFareSen,
            driverId: null,
            createdAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
          });

          for (const member of members) {
            const ref = db.collection('ride_requests').doc(member.id);

            tx.update(ref, {
              groupId: tripRef.id,
              status: 'matching_driver',
              distanceKm: member.distanceKm,
              soloFareSen: member.soloFareSen,
              fareShareSen: shares[member.id],
              tripPassengers: totalPassengers,
              updatedAt: FieldValue.serverTimestamp(),
            });
          }

          matched = true;
        });

        if (matched) {
          used.add(a.id);
          used.add(b.id);
          break;
        }
      }
    }
  }
);

/**
 * When the passenger chooses a solo ride, the request is handled separately.
 * The solo-ride action will be added in the next step.
 */
exports.handleRideRequestChoice = onDocumentUpdated(
  { document: 'ride_requests/{requestId}', region: REGION },
  async (event) => {
    const before = event.data.before.data();
    const after = event.data.after.data();

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

      if (r.status !== 'solo_requested' || r.groupId) return;
      if (!isValidRequest(r)) return;

      const distanceKm = roadDistanceKm(
        r.pickupLat, r.pickupLon, r.dropoffLat, r.dropoffLon
      );

      const solo = soloFareSen(distanceKm);
      const tripRef = db.collection('trips').doc();

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
        totalPassengers: r.passengerCount,
        totalFareSen: solo,
        driverId: null,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });

      tx.update(ref, {
        status: 'matching_driver',
        groupId: tripRef.id,
        distanceKm,
        soloFareSen: solo,
        fareShareSen: solo,
        tripPassengers: r.passengerCount,
        matchingChoice: 'solo',
        updatedAt: FieldValue.serverTimestamp(),
      });
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

    if (
      typeof requestId !== 'string' ||
      requestId.trim().length === 0
    ) {
      throw new HttpsError(
        'invalid-argument',
        'A valid ride request ID is required.'
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

      if (booking.groupId) {
        tripRef = db.collection('trips').doc(booking.groupId);
        const tripSnap = await tx.get(tripRef);

        if (tripSnap.exists) {
          trip = tripSnap.data();

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

      // Mark only this passenger's booking as cancelled.
      tx.update(requestRef, {
        status: 'cancelled',
        cancelledAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });

      if (tripRef && trip) {
        const remainingIds = remainingRequests.map((r) => r.id);

        const remainingPassengerCount = remainingRequests.reduce(
          (sum, r) => sum + (r.data.passengerCount || 1),
          0
        );

        if (remainingRequests.length === 0) {
          // Nobody remains: cancel the trip and release its driver.
          tx.update(tripRef, {
            status: 'cancelled',
            requestIds: [],
            totalPassengers: 0,
            totalFareSen: 0,
            driverId: null,
            updatedAt: FieldValue.serverTimestamp(),
          });
        } else {
          // Use the remaining booking to refresh the trip's reference data.
          const reference = remainingRequests[0].data;

          let totalFareSen = 0;

          if (remainingRequests.length === 1) {
            // A sole remaining booking pays its solo fare.
            totalFareSen = reference.soloFareSen || 0;

            tx.update(remainingRequests[0].ref, {
              fareShareSen: totalFareSen,
              tripPassengers: remainingPassengerCount,
              updatedAt: FieldValue.serverTimestamp(),
            });
          } else {
            // Preserve the remaining passengers' existing fare shares.
            totalFareSen = remainingRequests.reduce(
              (sum, r) => sum + (r.data.fareShareSen || 0),
              0
            );

            for (const r of remainingRequests) {
              tx.update(r.ref, {
                tripPassengers: remainingPassengerCount,
                updatedAt: FieldValue.serverTimestamp(),
              });
            }
          }

          tx.update(tripRef, {
            requestIds: remainingIds,
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
