
'use strict';

const { test, before, after, beforeEach } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');

const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require('@firebase/rules-unit-testing');

const { doc, setDoc, getDoc } = require('firebase/firestore');

let env;

const uid = 'driver_offered';

const base = {
  passengerId: 'passenger_1',
  groupId: 'trip_offer',
  status: 'matching_driver',
  dropoffAddress: 'Test destination',
};

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
});

async function seed(trip, request = base) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();

    await setDoc(doc(db, 'trips/trip_offer'), {
      requestIds: ['request_1'],
      passengerIds: ['passenger_1'],
      driverId: null,
      status: 'matching_driver',
      offeredDriverId: uid,
      ...trip,
    });

    await setDoc(doc(db, 'ride_requests/request_1'), request);
  });
}

function read(as, id = 'request_1') {
  return getDoc(
    doc(
      env.authenticatedContext(as).firestore(),
      `ride_requests/${id}`
    )
  );
}

test('offered driver reads booking during valid offer', async () => {
  await seed({ offerExpiresAt: new Date(Date.now() + 600000) });
  await assertSucceeds(read(uid));
});

test('other driver cannot read offered booking', async () => {
  await seed({ offerExpiresAt: new Date(Date.now() + 600000) });
  await assertFails(read('driver_other'));
});

test('expired offer cannot read booking', async () => {
  await seed({ offerExpiresAt: new Date(Date.now() - 600000) });
  await assertFails(read(uid));
});

test('missing offer expiry cannot read booking', async () => {
  await seed({});
  await assertFails(read(uid));
});

test('booking must belong to offered trip requestIds', async () => {
  await seed({
    requestIds: ['some_other_request'],
    offerExpiresAt: new Date(Date.now() + 600000),
  });
  await assertFails(read(uid));
});

test('offered driver cannot read after offer status ends', async () => {
  await seed({
    status: 'completed',
    offerExpiresAt: new Date(Date.now() + 600000),
  });
  await assertFails(read(uid));
});

test('assigned driver can read booking', async () => {
  await seed({
    status: 'driver_assigned',
    driverId: uid,
    offeredDriverId: null,
  });
  await assertSucceeds(read(uid));
});

test('passenger can read own booking', async () => {
  await seed({});
  await assertSucceeds(read('passenger_1'));
});

test('unrelated passenger cannot read booking', async () => {
  await seed({});
  await assertFails(read('passenger_2'));
});
