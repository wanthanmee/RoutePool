
const { test, before, after, beforeEach } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');

const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require('@firebase/rules-unit-testing');

const {
  doc,
  setDoc,
  updateDoc,
  getDoc,
  serverTimestamp,
  Timestamp,
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

  await env.withSecurityRulesDisabled(async (context) => {
    const database = context.firestore();

    await setDoc(doc(database, 'users/passenger_001'), {
      name: 'Passenger One',
      role: 'passenger',
      verificationStatus: 'approved',
    });

    await setDoc(doc(database, 'users/passenger_002'), {
      name: 'Passenger Two',
      role: 'passenger',
      verificationStatus: 'approved',
    });

    await setDoc(doc(database, 'users/passenger_pending'), {
      name: 'Pending Passenger',
      role: 'passenger',
      verificationStatus: 'pending',
    });

    await setDoc(doc(database, 'users/driver_001'), {
      name: 'Test Driver',
      role: 'driver',
      verificationStatus: 'approved',
    });
  });
});

function database(uid) {
  return uid
    ? env.authenticatedContext(uid).firestore()
    : env.unauthenticatedContext().firestore();
}

function validBooking(passengerId = 'passenger_001') {
  return {
    passengerId,
    pickupHubId: '12001010',
    pickupName: 'Apartmen Taman Bendera',
    pickupAddress: 'Penang, Malaysia',
    pickupLat: 5.4141,
    pickupLon: 100.3288,
    dropoffAddress: 'Sushi Mentai Bayan Baru',
    dropoffLat: 5.326,
    dropoffLon: 100.285,
    departureTime: serverTimestamp(),
    passengerCount: 1,
    status: 'searching',
    groupId: null,
    driverId: null,
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
  };
}

async function seedAwaitingChoice(id = 'request_001') {
  await env.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), 'ride_requests', id),
      {
        ...validBooking(),
        status: 'awaiting_choice',
        searchStartedAt: Timestamp.fromMillis(
          Date.now() - 6 * 60 * 1000
        ),
        searchExpiresAt: Timestamp.fromMillis(
          Date.now() - 60 * 1000
        ),
        groupSearchId: null,
        groupSearchExpiresAt: null,
      }
    );
  });
}

// TEST 29
test('29. Approved passenger can create a valid booking', async () => {
  await assertSucceeds(
    setDoc(
      doc(database('passenger_001'), 'ride_requests/request_001'),
      validBooking()
    )
  );
});

// TEST 30
test('30. Unauthenticated booking is denied', async () => {
  await assertFails(
    setDoc(
      doc(database(), 'ride_requests/request_001'),
      validBooking()
    )
  );
});

// TEST 31
test('31. Unapproved passenger cannot create a booking', async () => {
  await assertFails(
    setDoc(
      doc(database('passenger_pending'), 'ride_requests/request_001'),
      validBooking('passenger_pending')
    )
  );
});

// TEST 32
test('32. Passenger cannot impersonate another passenger', async () => {
  await assertFails(
    setDoc(
      doc(database('passenger_001'), 'ride_requests/request_001'),
      validBooking('passenger_002')
    )
  );
});

// TEST 33
test('33. Invalid passenger count is rejected', async () => {
  for (const count of [0, 13, -1]) {
    await assertFails(
      setDoc(
        doc(database('passenger_001'), 'ride_requests/request_' + count),
        {
          ...validBooking(),
          passengerCount: count,
        }
      )
    );
  }
});

// TEST 34
test('34. Passenger cannot preassign a driver or fare', async () => {
  await assertFails(
    setDoc(
      doc(database('passenger_001'), 'ride_requests/fake_driver'),
      {
        ...validBooking(),
        driverId: 'driver_001',
      }
    )
  );

  await assertFails(
    setDoc(
      doc(database('passenger_001'), 'ride_requests/fake_fare'),
      {
        ...validBooking(),
        fareShareSen: 100,
      }
    )
  );
});

// TEST 35
test('35. Passenger can select Try Solo', async () => {
  await seedAwaitingChoice();

  const ref = doc(
    database('passenger_001'),
    'ride_requests/request_001'
  );

  await assertSucceeds(
    updateDoc(ref, {
      status: 'solo_requested',
      matchingChoice: 'solo',
      updatedAt: serverTimestamp(),
    })
  );

  const snapshot = await getDoc(ref);

  if (snapshot.data().status !== 'solo_requested') {
    throw new Error('Solo status was not saved.');
  }
});

// TEST 36
test('36. Passenger can select Search Again', async () => {
  await seedAwaitingChoice();

  const ref = doc(
    database('passenger_001'),
    'ride_requests/request_001'
  );

  const now = Date.now();

  await assertSucceeds(
    updateDoc(ref, {
      status: 'searching',
      searchStartedAt: Timestamp.fromMillis(now),
      searchExpiresAt: Timestamp.fromMillis(
        now + 5 * 60 * 1000
      ),
      groupSearchId: null,
      groupSearchExpiresAt: null,
      matchingChoice: 'shared',
      updatedAt: serverTimestamp(),
    })
  );

  const snapshot = await getDoc(ref);

  if (snapshot.data().status !== 'searching') {
    throw new Error('Search Again status was not saved.');
  }
});
