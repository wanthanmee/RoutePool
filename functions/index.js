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

// Matching rules
const MAX_PASSENGERS = 12;
const MAX_DEPARTURE_DIFF_MIN = 30;
const MAX_DROPOFF_DIFF_KM = 5;
const MATCHING_WINDOW_MS = 5 * 60 * 1000;

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


const DRIVER_LOCATION_MAX_AGE_MS = 90 * 1000;
const DRIVER_MAX_ACCURACY_METERS = 100;
const DRIVER_OFFER_DURATION_MS = 30 * 1000;
const DRIVER_OFFER_LOCKS = 'driver_offer_locks';

/**
 * Find eligible online drivers, nearest first.
 *
 * This function only selects candidates.
 * It does not assign a driver or modify a trip.
 */
async function findNearestEligibleDrivers(trip) {
  const pickupLat = trip.pickupLat;
  const pickupLon = trip.pickupLon;
  const requiredSeats = trip.totalPassengers;

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

  const onlineDriversSnap = await db
    .collection('users')
    .where('isAvailable', '==', true)
    .get();

  const now = Date.now();
  const candidates = [];

  for (const driverDoc of onlineDriversSnap.docs) {
    const driverId = driverDoc.id;
    const driver = driverDoc.data();

    if (driver.verificationStatus !== 'approved') {
      continue;
    }

    const [vehicleSnap, locationSnap] = await Promise.all([
      db.collection('vehicles').doc(driverId).get(),
      db.collection('driver_locations').doc(driverId).get(),
    ]);

    if (!vehicleSnap.exists || !locationSnap.exists) {
      continue;
    }

    const vehicle = vehicleSnap.data();
    const location = locationSnap.data();

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

    if (
      !Number.isFinite(locationTime) ||
      locationTime > now + 5000 ||
      now - locationTime > DRIVER_LOCATION_MAX_AGE_MS
    ) {
      continue;
    }

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

    const distanceKm = haversineKm(
      location.lat,
      location.lon,
      pickupLat,
      pickupLon
    );

    candidates.push({
      driverId,
      distanceKm,
    });
  }

  candidates.sort(
    (a, b) =>
      a.distanceKm - b.distanceKm ||
      a.driverId.localeCompare(b.driverId)
  );

  return candidates;
}


async function reserveDriverOffer(tripRef, candidate) {
  const driverRef = db.collection('users').doc(candidate.driverId);
  const vehicleRef = db.collection('vehicles').doc(candidate.driverId);
  const locationRef = db.collection('driver_locations').doc(candidate.driverId);
  const lockRef = db.collection(DRIVER_OFFER_LOCKS).doc(candidate.driverId);

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

    if (
      !tripSnap.exists ||
      !driverSnap.exists ||
      !vehicleSnap.exists ||
      !locationSnap.exists
    ) {
      return false;
    }

    const trip = tripSnap.data();
    const driver = driverSnap.data();
    const vehicle = vehicleSnap.data();
    const location = locationSnap.data();


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

    const now = Date.now();
    const locationTime = location.updatedAt?.toMillis?.();

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

    const existingLock = lockSnap.exists ? lockSnap.data() : null;
    const lockExpiry = existingLock?.expiresAt?.toMillis?.();

    // Reject active reservations, including malformed locks.
    if (
      existingLock &&
      (!Number.isFinite(lockExpiry) || lockExpiry > now)
    ) {
      return false;
    }

    const expiresAt = new Date(now + DRIVER_OFFER_DURATION_MS);

    tx.set(lockRef, {
      tripId: tripRef.id,
      expiresAt,
      updatedAt: FieldValue.serverTimestamp(),
    });

    tx.update(tripRef, {
      offeredDriverId: candidate.driverId,
      offerExpiresAt: expiresAt,
      updatedAt: FieldValue.serverTimestamp(),
    });

    return true;
  });
}


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

function areRequestsCompatible(a, b) {
  if (!isValidRequest(a) || !isValidRequest(b)) return false;

  if (a.passengerId === b.passengerId) return false;
  if (a.pickupHubId !== b.pickupHubId) return false;

  const timeDifference = Math.abs(
    a.departureTime.toMillis() - b.departureTime.toMillis()
  );

  if (timeDifference > MAX_DEPARTURE_DIFF_MIN * 60 * 1000) {
    return false;
  }

  const destinationDifference = haversineKm(
    a.dropoffLat,
    a.dropoffLon,
    b.dropoffLat,
    b.dropoffLon
  );

  return destinationDifference <= MAX_DROPOFF_DIFF_KM;
}

function canJoinGroup(candidate, members, capacity) {
  const total = members.reduce(
    (sum, member) => sum + member.passengerCount,
    0
  );

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

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) return;

      const data = snap.data();

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
    schedule: '* * * * *',
    timeZone: 'Asia/Kuala_Lumpur',
    region: REGION,
  },
  async () => {
    const now = Date.now();

    // Find the largest currently approved, active vehicle capacity.
    const vehiclesSnap = await db.collection('vehicles')
      .where('verificationStatus', '==', 'approved')
      .get();

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

    const requestsSnap = await db.collection('ride_requests')
      .where('status', '==', 'searching')
      .get();

    const requests = requestsSnap.docs
      .map((doc) => ({
        ...doc.data(),
        id: doc.id,
        ref: doc.ref,
      }))
      .filter((r) =>
        isValidRequest(r) &&
        r.searchStartedAt?.toMillis?.() != null &&
        r.searchExpiresAt?.toMillis?.() != null
      );

    const requestMap = new Map(
      requests.map((r) => [r.id, r])
    );

    const groupsSnap = await db.collection('matching_groups')
      .where('status', '==', 'collecting')
      .get();

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

      if (deadline == null || deadline <= now) continue;

      const memberIds = Array.isArray(group.requestIds)
        ? group.requestIds
        : [];

      const members = memberIds
        .map((id) => requestMap.get(id))
        .filter(Boolean);

      // Only join a group if all its members can be verified.
      if (members.length !== memberIds.length) continue;

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

          tx.update(group.ref, {
            requestIds: [...currentIds, candidate.id],
            totalPassengers: newTotal,
            updatedAt: FieldValue.serverTimestamp(),
          });

          tx.update(candidate.ref, {
            groupSearchId: group.id,
            groupSearchExpiresAt: currentGroup.searchExpiresAt,
            updatedAt: FieldValue.serverTimestamp(),
          });

          joined = true;
        });

        if (joined) {
          reserved.add(candidate.id);
          members.push(candidate);
        }
      }
    }

    // --------------------------------------------------
    // PHASE 2: Create new collecting groups.
    // --------------------------------------------------

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

    for (const anchor of ungrouped) {
      if (reserved.has(anchor.id)) continue;
      if (anchor.passengerCount > capacity) continue;

      const members = [anchor];

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

        // Check destination, departure time and seat capacity.
        if (canJoinGroup(candidate, members, capacity)) {
          members.push(candidate);
        }
      }

      const groupRef = db.collection('matching_groups').doc();
      const deadline = anchor.searchExpiresAt;

      let created = false;

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

    const expiredGroupsSnap = await db
      .collection('matching_groups')
      .where('status', '==', 'collecting')
      .get();

    for (const groupDoc of expiredGroupsSnap.docs) {
      const group = groupDoc.data();

      const groupDeadline = group.searchExpiresAt?.toMillis?.();

      if (groupDeadline == null || groupDeadline > Date.now()) {
        continue;
      }

      const ids = Array.isArray(group.requestIds)
        ? group.requestIds
        : [];

      const tripRef = db.collection('trips').doc();

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

        if (active.length === 1) {
          tx.update(active[0].ref, {
            status: 'awaiting_choice',
            groupSearchId: null,
            groupSearchExpiresAt: null,
            updatedAt: FieldValue.serverTimestamp(),
          });

          tx.update(groupDoc.ref, {
            status: 'completed',
            updatedAt: FieldValue.serverTimestamp(),
          });

          return;
        }

        const totalPassengers = active.reduce(
          (sum, r) => sum + r.passengerCount,
          0
        );

        if (totalPassengers > capacity) {
          // No currently eligible vehicle can accommodate
          // the entire passenger group.
          // End this collection window without creating a trip.

          for (const passenger of active) {
            tx.update(passenger.ref, {
              status: 'awaiting_choice',
              groupSearchId: null,
              groupSearchExpiresAt: null,
              updatedAt: FieldValue.serverTimestamp(),
            });
          }

          tx.update(groupDoc.ref, {
            status: 'completed',
            updatedAt: FieldValue.serverTimestamp(),
          });

          return;
        }

        const members = active.map((r) => {
          const distanceKm = roadDistanceKm(
            r.pickupLat,
            r.pickupLon,
            r.dropoffLat,
            r.dropoffLon
          );

          return {
            id: r.id,
            passengerCount: r.passengerCount,
            distanceKm,
            soloFareSen: soloFareSen(distanceKm),
          };
        });

        const shares = computeShares(members);

        const totalFareSen = Object.values(shares)
          .reduce((sum, value) => sum + value, 0);

        const anchor = active[0];

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

    const expiredUngrouped = await db.collection('ride_requests')
      .where('status', '==', 'searching')
      .get();

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
 * When the passenger chooses a solo ride, the request is handled separately.
 * The solo-ride action will be added in the next step.
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

        if (current.status !== 'searching' || current.groupId) {
          return;
        }

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

    const driverId = call.auth.uid;
    const tripRef = db.collection('trips').doc(tripId);
    const driverRef = db.collection('users').doc(driverId);
    const vehicleRef = db.collection('vehicles').doc(driverId);
    const lockRef = db.collection(DRIVER_OFFER_LOCKS).doc(driverId);

    return db.runTransaction(async (tx) => {
    const [tripSnap, driverSnap, vehicleSnap, lockSnap] =
      await Promise.all([
        tx.get(tripRef),
        tx.get(driverRef),
        tx.get(vehicleRef),
        tx.get(lockRef),
      ]);


      if (!tripSnap.exists) {
        throw new HttpsError('not-found', 'This trip no longer exists.');
      }

      if (!driverSnap.exists) {
        throw new HttpsError(
          'failed-precondition',
          'Your driver profile could not be found.'
        );
      }

      const trip = tripSnap.data();
      const driver = driverSnap.data();
      const vehicle = vehicleSnap.data();

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

      const requestIds = trip.requestIds;

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

      const requestRefs = requestIds.map((id) =>
        db.collection('ride_requests').doc(id)
      );
      const requestSnaps = await Promise.all(
        requestRefs.map((ref) => tx.get(ref))
      );

      for (const requestSnap of requestSnaps) {
        if (!requestSnap.exists) {
          throw new HttpsError(
            'failed-precondition',
            'A linked passenger request could not be found.'
          );
        }

        const request = requestSnap.data();

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

      const now = FieldValue.serverTimestamp();

      tx.update(tripRef, {
        driverId,
        status: 'driver_assigned',
        updatedAt: now,
      });

      tx.update(driverRef, {
        isAvailable: false,
        updatedAt: now,
      });

      tx.delete(lockRef);

      for (const requestRef of requestRefs) {
        tx.update(requestRef, {
          driverId,
          status: 'driver_assigned',
          updatedAt: now,
        });
      }

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
      let offerLockRef = null;
      let assignedDriverRef = null;

      if (booking.groupId) {
        tripRef = db.collection('trips').doc(booking.groupId);
        const tripSnap = await tx.get(tripRef);

        if (tripSnap.exists) {
          trip = tripSnap.data();

            // Read the assigned driver before any transaction writes.
            if (trip.driverId) {
              assignedDriverRef = db
                .collection('users')
                .doc(trip.driverId);

              await tx.get(assignedDriverRef);
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
          offeredDriverId: null,
          offerExpiresAt: null,
          updatedAt: FieldValue.serverTimestamp(),
        });


          // Clear the outstanding offer reservation.
          if (offerLockRef) {
            tx.delete(offerLockRef);
          }

          // Automatically put the assigned driver back online.
          if (assignedDriverRef) {
            tx.update(assignedDriverRef, {
              isAvailable: true,
              updatedAt: FieldValue.serverTimestamp(),
            });
          }

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
