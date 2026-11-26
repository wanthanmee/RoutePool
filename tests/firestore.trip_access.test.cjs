
const { test, before, after, beforeEach } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');

const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require('@firebase/rules-unit-testing');

const {
  doc,
  setDoc,
  updateDoc,
  getDoc,
  getDocs,
  query,
  collection,
  where,
} = require('firebase/firestore');

let env;

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'routepool-9405b',
    firestore: {
      host: '127.0.0.1',
      port: 8181,
      rules: fs.readFileSync(
        path.join(__dirname, '../firestore.rules'),
        'utf8'
      ),
    },
  });
});

after(async () => {
  if (env) await env.cleanup();
});

beforeEach(async () => {
  await env.clearFirestore();

  // Simulate records created by trusted Cloud Functions.
  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();

    await setDoc(doc(db, 'users/passenger_001'), {
      role: 'passenger',
      verificationStatus: 'approved',
    });

    await setDoc(doc(db, 'users/passenger_002'), {
      role: 'passenger',
      verificationStatus: 'approved',
    });

    await setDoc(doc(db, 'users/driver_001'), {
      role: 'driver',
      verificationStatus: 'approved',
    });

    await setDoc(doc(db, 'users/driver_002'), {
      role: 'driver',
      verificationStatus: 'approved',
    });

    // Trip assigned to driver_001.
    await setDoc(doc(db, 'trips/trip_001'), {
      requestIds: ['request_001'],
      passengerIds: ['passenger_001'],
      pickupHubId: '12001010',
      pickupName: 'Apartmen Taman Bendera',
      totalPassengers: 1,
      totalFareSen: 1000,
      driverId: 'driver_001',
      offeredDriverId: null,
      status: 'driver_assigned',
    });

    // Trip offered to driver_002.
    await setDoc(doc(db, 'trips/trip_002'), {
      requestIds: ['request_002'],
      passengerIds: ['passenger_002'],
      pickupHubId: '12001010',
      pickupName: 'Apartmen Taman Bendera',
      totalPassengers: 1,
      totalFareSen: 1200,
      driverId: null,
      offeredDriverId: 'driver_002',
      status: 'matching_driver',
    });

    // Trip without a passengerIds field (legacy record).
    await setDoc(doc(db, 'trips/trip_legacy'), {
      requestIds: ['request_legacy'],
      totalPassengers: 1,
      totalFareSen: 1000,
      driverId: null,
      status: 'matching_driver',
    });
  });
});

function database(uid) {
  return uid
    ? env.authenticatedContext(uid).firestore()
    : env.unauthenticatedContext().firestore();
}

// TEST 45
test('45. Passenger can read their own trip', async () => {
  const snapshot = await assertSucceeds(
    getDoc(doc(database('passenger_001'), 'trips/trip_001'))
  );

  if (!snapshot.exists()) {
    throw new Error('Expected trip_001 to exist.');
  }
});

// TEST 46
test('46. Assigned driver can read their trip', async () => {
  await assertSucceeds(
    getDoc(doc(database('driver_001'), 'trips/trip_001'))
  );
});

// TEST 47
test('47. Offered driver can read their offered trip', async () => {
  await assertSucceeds(
    getDoc(doc(database('driver_002'), 'trips/trip_002'))
  );
});

// TEST 48
test('48. Unrelated passenger cannot read another trip', async () => {
  await assertFails(
    getDoc(doc(database('passenger_002'), 'trips/trip_001'))
  );
});

// TEST 49
test('49. Unassigned driver cannot read another trip', async () => {
  await assertFails(
    getDoc(doc(database('driver_002'), 'trips/trip_001'))
  );
});

// TEST 50
test('50. Unauthenticated user cannot read a trip', async () => {
  await assertFails(
    getDoc(doc(database(), 'trips/trip_001'))
  );
});

// TEST 51
test('51. Passenger cannot modify trip fare', async () => {
  await assertFails(
    updateDoc(doc(database('passenger_001'), 'trips/trip_001'), {
      totalFareSen: 10,
    })
  );
});

// TEST 52
test('52. Assigned driver cannot directly change trip status', async () => {
  await assertFails(
    updateDoc(doc(database('driver_001'), 'trips/trip_001'), {
      status: 'completed',
    })
  );
});

// TEST 53
test('53. Passenger can query trips containing their UID', async () => {
  const tripsQuery = query(
    collection(database('passenger_001'), 'trips'),
    where('passengerIds', 'array-contains', 'passenger_001')
  );

  const snapshot = await assertSucceeds(getDocs(tripsQuery));

  if (snapshot.size !== 1) {
    throw new Error(`Expected 1 trip, found ${snapshot.size}.`);
  }
});

// TEST 54
test('54. Assigned driver can query their trips', async () => {
  const tripsQuery = query(
    collection(database('driver_001'), 'trips'),
    where('driverId', '==', 'driver_001')
  );

  const snapshot = await assertSucceeds(getDocs(tripsQuery));

  if (snapshot.size !== 1) {
    throw new Error(`Expected 1 trip, found ${snapshot.size}.`);
  }
});

// TEST 55
test('55. Unrestricted trip query is denied', async () => {
  await assertFails(
    getDocs(collection(database('passenger_001'), 'trips'))
  );
});

// TEST 56
test('56. Passenger cannot read a legacy trip without passengerIds', async () => {
  await assertFails(
    getDoc(doc(database('passenger_001'), 'trips/trip_legacy'))
  );
});

// Shared-trip booking visibility tests

async function createSharedTripFixtures() {
  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();

    await setDoc(doc(db, 'trips/shared_trip_001'), {
      requestIds: ['shared_request_001', 'shared_request_002'],
      passengerIds: ['passenger_001', 'passenger_002'],
      driverId: 'driver_001',
      status: 'in_progress',
    });

    await setDoc(doc(db, 'ride_requests/shared_request_001'), {
      passengerId: 'passenger_001',
      groupId: 'shared_trip_001',
      status: 'in_progress',
      dropoffAddress: 'Destination A',
    });

    await setDoc(doc(db, 'ride_requests/shared_request_002'), {
      passengerId: 'passenger_002',
      groupId: 'shared_trip_001',
      status: 'in_progress',
      dropoffAddress: 'Destination B',
    });

    await setDoc(doc(db, 'ride_requests/unrelated_request'), {
      passengerId: 'passenger_002',
      groupId: null,
      status: 'searching',
    });
  });
}

test('57. Passenger can read another booking in the same trip', async () => {
  await createSharedTripFixtures();

  await assertSucceeds(
    getDoc(
      doc(database('passenger_001'), 'ride_requests/shared_request_002')
    )
  );
});

test('58. Passenger cannot read an unrelated booking', async () => {
  await createSharedTripFixtures();

  await assertFails(
    getDoc(
      doc(database('passenger_001'), 'ride_requests/unrelated_request')
    )
  );
});

test('59. Passenger cannot modify another passenger booking', async () => {
  await createSharedTripFixtures();

  await assertFails(
    updateDoc(
      doc(database('passenger_001'), 'ride_requests/shared_request_002'),
      { dropoffAddress: 'Unauthorized destination' }
    )
  );
});

test('60. Assigned driver can read both shared bookings', async () => {
  await createSharedTripFixtures();

  const db = database('driver_001');

  await assertSucceeds(
    getDoc(doc(db, 'ride_requests/shared_request_001'))
  );

  await assertSucceeds(
    getDoc(doc(db, 'ride_requests/shared_request_002'))
  );
});

test('61. Unrelated driver cannot read shared bookings', async () => {
  await createSharedTripFixtures();

  await assertFails(
    getDoc(
      doc(database('driver_002'), 'ride_requests/shared_request_001')
    )
  );
});