
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
  serverTimestamp,
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

    await setDoc(doc(db, 'users/driver_001'), {
      role: 'driver',
      verificationStatus: 'approved',
    });

    await setDoc(doc(db, 'trips/trip_001'), {
      requestIds: ['request_001'],
      pickupHubId: '12001010',
      pickupName: 'Apartmen Taman Bendera',
      totalPassengers: 1,
      totalFareSen: 1000,
      driverId: null,
      status: 'matching_driver',
    });

    await setDoc(doc(db, 'matching_groups/group_001'), {
      pickupHubId: '12001010',
      requestIds: ['request_001'],
      totalPassengers: 1,
      status: 'collecting',
    });

    await setDoc(doc(db, 'driver_offer_locks/driver_001'), {
      driverId: 'driver_001',
      tripId: 'trip_001',
    });
  });
});

function database(uid) {
  return uid
    ? env.authenticatedContext(uid).firestore()
    : env.unauthenticatedContext().firestore();
}

// TEST 37
test('37. Passenger cannot create a fake trip', async () => {
  await assertFails(
    setDoc(
      doc(database('passenger_001'), 'trips/fake_trip'),
      {
        requestIds: ['request_001'],
        totalPassengers: 1,
        totalFareSen: 100,
        status: 'driver_assigned',
        driverId: 'driver_001',
        createdAt: serverTimestamp(),
      }
    )
  );
});

// TEST 38
test('38. Driver cannot create a fake trip', async () => {
  await assertFails(
    setDoc(
      doc(database('driver_001'), 'trips/fake_trip'),
      {
        requestIds: ['request_001'],
        totalPassengers: 1,
        totalFareSen: 1000,
        status: 'driver_assigned',
        driverId: 'driver_001',
        createdAt: serverTimestamp(),
      }
    )
  );
});

// TEST 39
test('39. Passenger cannot manipulate trip fare', async () => {
  await assertFails(
    updateDoc(
      doc(database('passenger_001'), 'trips/trip_001'),
      {
        totalFareSen: 10,
      }
    )
  );
});

// TEST 40
test('40. Driver cannot assign themselves to a trip', async () => {
  await assertFails(
    updateDoc(
      doc(database('driver_001'), 'trips/trip_001'),
      {
        driverId: 'driver_001',
        status: 'driver_assigned',
      }
    )
  );
});

// TEST 41
test('41. Passenger cannot modify matching groups', async () => {
  await assertFails(
    updateDoc(
      doc(database('passenger_001'), 'matching_groups/group_001'),
      {
        totalPassengers: 12,
        status: 'completed',
      }
    )
  );
});

// TEST 42
test('42. Driver cannot create a fake offer lock', async () => {
  await assertFails(
    setDoc(
      doc(database('driver_001'), 'driver_offer_locks/fake_driver'),
      {
        driverId: 'fake_driver',
        tripId: 'trip_001',
      }
    )
  );
});

// TEST 43
test('43. Unauthenticated user cannot read trip data', async () => {
  await assertFails(
    getDoc(
      doc(database(), 'trips/trip_001')
    )
  );
});

// TEST 44
test('44. Unauthenticated user cannot read matching groups', async () => {
  await assertFails(
    getDoc(
      doc(database(), 'matching_groups/group_001')
    )
  );
});
