// og file: index.js
const { onDocumentCreated } = require('firebase-functions/v2/firestore');
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
 * When a passenger books, put them into an open trip (same pickup hub,
 * similar departure, nearby drop-off, free seats) or start a new trip.
 */
exports.matchRideRequest = onDocumentCreated(
  { document: 'ride_requests/{requestId}', region: REGION },
  async (event) => {
    const requestId = event.params.requestId;
    const reqRef = db.collection('ride_requests').doc(requestId);

    await db.runTransaction(async (tx) => {
      // ---- reads (all reads must come before any write) ----
      const fresh = await tx.get(reqRef);
      if (!fresh.exists) return;

      const r = fresh.data();
      if (r.status !== 'searching' || r.groupId) return; // already handled

      if (!isValidRequest(r)) {
        tx.update(reqRef, {
          status: 'cancelled',
          cancelledBy: 'system',
          cancelReason: 'invalid_request',
          updatedAt: FieldValue.serverTimestamp(),
        });
        return;
      }

      // Recalculate on the server. Never trust fare values sent by the app.
      const distanceKm = roadDistanceKm(
        r.pickupLat,
        r.pickupLon,
        r.dropoffLat,
        r.dropoffLon
      );
      const solo = soloFareSen(distanceKm);
      const me = {
        id: requestId,
        passengerCount: r.passengerCount,
        distanceKm,
        soloFareSen: solo,
      };

      const departureMs = r.departureTime.toMillis();
      const openTrips = await tx.get(
        db
          .collection('trips')
          .where('status', '==', 'matching_driver')
          .where('pickupHubId', '==', r.pickupHubId)
      );


    const compatibleTrips = openTrips.docs
    .filter((doc) => {
        const t = doc.data();

        const validTimestamp =
        t.departureTime &&
        typeof t.departureTime.toMillis === 'function';

        const validDestination =
        Number.isFinite(t.dropoffRefLat) &&
        Number.isFinite(t.dropoffRefLon) &&
        t.dropoffRefLat >= -90 &&
        t.dropoffRefLat <= 90 &&
        t.dropoffRefLon >= -180 &&
        t.dropoffRefLon <= 180;

        const validPassengerCount =
        Number.isInteger(t.totalPassengers) &&
        t.totalPassengers >= 1 &&
        t.totalPassengers <= MAX_PASSENGERS;

        const validMembers =
        Array.isArray(t.requestIds) &&
        t.requestIds.length > 0;

        if (
        !validTimestamp ||
        !validDestination ||
        !validPassengerCount ||
        !validMembers
        ) {
        return false;
        }

        const timeDifference = Math.abs(
        t.departureTime.toMillis() - departureMs
        );

        const destinationDifference = haversineKm(
        t.dropoffRefLat,
        t.dropoffRefLon,
        r.dropoffLat,
        r.dropoffLon
        );

        return (
        t.totalPassengers + r.passengerCount <= MAX_PASSENGERS &&
        timeDifference <= MAX_DEPARTURE_DIFF_MIN * 60000 &&
        destinationDifference <= MAX_DROPOFF_DIFF_KM
        );
    })
    .sort((a, b) => {
        const tripA = a.data();
        const tripB = b.data();

        const timeA = Math.abs(
        tripA.departureTime.toMillis() - departureMs
        );

        const timeB = Math.abs(
        tripB.departureTime.toMillis() - departureMs
        );

        if (timeA !== timeB) {
        return timeA - timeB;
        }

        const distanceA = haversineKm(
        tripA.dropoffRefLat,
        tripA.dropoffRefLon,
        r.dropoffLat,
        r.dropoffLon
        );

        const distanceB = haversineKm(
        tripB.dropoffRefLat,
        tripB.dropoffRefLon,
        r.dropoffLat,
        r.dropoffLon
        );

        return distanceA - distanceB;
    });

    const candidate = compatibleTrips[0] ?? null;


      // ---- no open trip: start a new one ----
      if (!candidate) {
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
          requestIds: [requestId],
          totalPassengers: r.passengerCount,
          totalFareSen: solo,
          driverId: null,
          createdAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        });

        tx.update(reqRef, {
          groupId: tripRef.id,
          status: 'matching_driver',
          distanceKm,
          soloFareSen: solo,
          fareShareSen: solo,
          tripPassengers: r.passengerCount,
          updatedAt: FieldValue.serverTimestamp(),
        });
        return;
      }

      // ---- join an existing trip ----
      const trip = candidate.data();
      const memberRefs = trip.requestIds.map((id) =>
        db.collection('ride_requests').doc(id)
      );
      const memberDocs = await tx.getAll(...memberRefs);


    const members = [];

    for (const d of memberDocs) {
    if (!d.exists) continue;

    const data = d.data();

    if (
        data.status !== 'matching_driver' ||
        data.groupId !== candidate.id ||
        !isValidRequest(data)
    ) {
        continue;
    }

    const memberDistanceKm = roadDistanceKm(
        data.pickupLat,
        data.pickupLon,
        data.dropoffLat,
        data.dropoffLon
    );

    members.push({
        id: d.id,
        passengerCount: data.passengerCount,
        distanceKm: memberDistanceKm,
        soloFareSen: soloFareSen(memberDistanceKm),
    });
    }

    members.push(me);


      const shares = computeShares(members);
      const totalPassengers = members.reduce(
        (sum, m) => sum + m.passengerCount,
        0
      );
      const totalFareSen = Object.values(shares).reduce((a, b) => a + b, 0);

      // ---- writes ----
      tx.update(candidate.ref, {
        requestIds: members.map((m) => m.id),
        totalPassengers,
        totalFareSen,
        updatedAt: FieldValue.serverTimestamp(),
      });

      for (const m of members) {
        if (m.id === requestId) continue;
        tx.update(db.collection('ride_requests').doc(m.id), {
        distanceKm: m.distanceKm,
        soloFareSen: m.soloFareSen,
        fareShareSen: shares[m.id],
        tripPassengers: totalPassengers,
        updatedAt: FieldValue.serverTimestamp(),
        });
      }

      tx.update(reqRef, {
        groupId: candidate.id,
        status: 'matching_driver',
        distanceKm,
        soloFareSen: solo,
        fareShareSen: shares[requestId],
        tripPassengers: totalPassengers,
        updatedAt: FieldValue.serverTimestamp(),
      });
    });
  }
);