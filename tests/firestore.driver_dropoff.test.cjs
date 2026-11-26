'use strict';
// Phase 4D: isolated Firebase Auth + Firestore + Functions emulator tests.
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { initializeApp, deleteApp } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');

const projectId = 'routepool-9405b';
const authBase = `http://127.0.0.1:9199/identitytoolkit.googleapis.com/v1`;
const callableUrl = `http://127.0.0.1:5101/${projectId}/asia-southeast1/confirmPassengerDropOff`;
const completeUrl = `http://127.0.0.1:5101/${projectId}/asia-southeast1/completeDriverTrip`;
const cancelUrl = `http://127.0.0.1:5101/${projectId}/asia-southeast1/cancelDriverTrip`;
process.env.FIRESTORE_EMULATOR_HOST = '127.0.0.1:8181';
process.env.FIREBASE_AUTH_EMULATOR_HOST = '127.0.0.1:9199';
const app = initializeApp({ projectId }, 'dropoff-test');
const db = getFirestore(app);
const runId = `dropoff_${Date.now()}_${process.pid}`;
const ids = {
  driver: `${runId}_driver`,
  other: `${runId}_other`,
  passenger1: `${runId}_p1`,
  passenger2: `${runId}_p2`,
  trip: `${runId}_trip`,
  r1: `${runId}_r1`,
  r2: `${runId}_r2`,
};
const tokens = {};
const created = [];

async function authRequest(endpoint, data) {
  const response = await fetch(`${authBase}/accounts:${endpoint}?key=fake-api-key`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data),
  });
  const result = await response.json();
  if (!response.ok) throw new Error(`Auth emulator: ${JSON.stringify(result)}`);
  return result;
}
async function createUser(uid) {
  const email = `${uid}@example.test`;
  const password = 'test-password-12345';
  const registered = await authRequest('signUp', { email, password, returnSecureToken: true });
  // The auth emulator assigns its own uid. Use that uid in the Firestore fixture.
  return { uid: registered.localId, token: registered.idToken };
}
async function callDropoff(token, tripId = ids.trip, requestId = ids.r1) {
  const response = await fetch(callableUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify({ data: { tripId, requestId } }),
  });
  const body = await response.json();
  return { httpStatus: response.status, result: body.result, error: body.error };
}
async function callEndRide(token, tripId = ids.trip) {
  const response = await fetch(completeUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: ['Bearer ', token].join('') } : {}),
    },
    body: JSON.stringify({ data: { tripId } }),
  });
  const body = await response.json();
  return { httpStatus: response.status, result: body.result, error: body.error };
}
async function callCancelTrip(token, tripId = ids.trip) {
  const response = await fetch(cancelUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: ['Bearer ', token].join('') } : {}),
    },
    body: JSON.stringify({
      data: {
        tripId,
        cancellationReason: 'Vehicle Issue',
        cancellationDetails: 'Test cancellation',
      },
    }),
  });
  const body = await response.json();
  return { httpStatus: response.status, result: body.result, error: body.error };
}
function expectError(response, code) {
  assert.ok(response.error, `Expected ${code}, got ${JSON.stringify(response)}`);
  assert.equal(response.error.status, code);
}
function expectSuccess(response) {
  assert.equal(response.error, undefined, JSON.stringify(response.error));
  assert.equal(response.result?.success, true, JSON.stringify(response));
}
async function resetFixture(options = {}) {
  const {
    status = 'in_progress',
    requestIds = [ids.r1, ids.r2],
    order = requestIds,
    r1Status = 'in_progress',
    r2Status = 'in_progress',
  } = options;
  const driverId = tokens.driver.uid;
  await db.doc(`trips/${ids.trip}`).set({
    driverId, status, requestIds, optimizedDropoffOrder: order,
    pickupHubId: 'test_hub', totalPassengers: 2,
  });
  for (const [requestId, passengerId, requestStatus] of [
    [ids.r1, tokens.passenger1.uid, r1Status],
    [ids.r2, tokens.passenger2.uid, r2Status],
  ]) {
    await db.doc(`ride_requests/${requestId}`).set({
      passengerId, driverId, groupId: ids.trip, status: requestStatus,
      passengerCount: 1, pickupHubId: 'test_hub',
    });
  }
}
before(async () => {
  for (const key of ['driver', 'other', 'passenger1', 'passenger2']) {
    tokens[key] = await createUser(ids[key]);
    created.push(tokens[key].uid);
  }
});
beforeEach(async () => { await resetFixture(); });
after(async () => {
  await Promise.all([
    db.doc(`trips/${ids.trip}`).delete().catch(() => {}),
    db.doc(`ride_requests/${ids.r1}`).delete().catch(() => {}),
    db.doc(`ride_requests/${ids.r2}`).delete().catch(() => {}),
    db.doc(`users/${tokens.driver.uid}`).delete().catch(() => {}),
    db.doc(`driver_offer_locks/${tokens.driver.uid}`).delete().catch(() => {}),
  ]);
  // Auth test accounts remain in the local Auth emulator; no production accounts are created.
  await deleteApp(app);
});

test('66. Unauthenticated caller rejected', async () => {
  expectError(await callDropoff(null), 'UNAUTHENTICATED');
});
test('67. Unassigned driver rejected', async () => {
  expectError(await callDropoff(tokens.other.token), 'PERMISSION_DENIED');
});
test('68. Trip not in progress rejected', async () => {
  await resetFixture({ status: 'driver_arrived' });
  expectError(await callDropoff(tokens.driver.token), 'FAILED_PRECONDITION');
});
test('69. Booking outside trip rejected', async () => {
  expectError(await callDropoff(tokens.driver.token, ids.trip, 'unrelated_booking'), 'PERMISSION_DENIED');
});
test('70. Out-of-order drop-off rejected', async () => {
  expectError(await callDropoff(tokens.driver.token, ids.trip, ids.r2), 'FAILED_PRECONDITION');
});
test('71. Missing shared optimized order rejected', async () => {
  await resetFixture({ order: [] });
  expectError(await callDropoff(tokens.driver.token), 'FAILED_PRECONDITION');
});
test('72. First passenger drop-off succeeds and preserves review eligibility', async () => {
  const result = await callDropoff(tokens.driver.token);
  expectSuccess(result);
  assert.equal(result.result.tripCompleted, false);
  const first = (await db.doc(`ride_requests/${ids.r1}`).get()).data();
  const second = (await db.doc(`ride_requests/${ids.r2}`).get()).data();
  const trip = (await db.doc(`trips/${ids.trip}`).get()).data();
  assert.equal(first.status, 'drop_off_confirmed');
  assert.ok(first.droppedOffAt, 'droppedOffAt should exist');
  assert.ok(first.reviewPromptEligibleAt, 'reviewPromptEligibleAt should exist');
  assert.equal(second.status, 'in_progress');
  assert.equal(trip.status, 'in_progress');
});
test('73. Duplicate drop-off rejected', async () => {
  expectSuccess(await callDropoff(tokens.driver.token));
  expectError(await callDropoff(tokens.driver.token), 'FAILED_PRECONDITION');
});
test('74. Final drop-off completes the trip automatically', async () => {
  expectSuccess(await callDropoff(tokens.driver.token, ids.trip, ids.r1));
  const result = await callDropoff(tokens.driver.token, ids.trip, ids.r2);
  expectSuccess(result);
  assert.equal(result.result.tripCompleted, true);
  const first = (await db.doc(`ride_requests/${ids.r1}`).get()).data();
  const second = (await db.doc(`ride_requests/${ids.r2}`).get()).data();
  const trip = (await db.doc(`trips/${ids.trip}`).get()).data();
  assert.equal(first.status, 'drop_off_confirmed');
  assert.equal(second.status, 'drop_off_confirmed');
  assert.equal(trip.status, 'completed');
  assert.ok(trip.completedAt);
  assert.ok(first.reviewPromptEligibleAt);
  assert.ok(second.reviewPromptEligibleAt);
});
test('75. Trip completion waits until every passenger is dropped off', async () => {
  expectError(await callEndRide(tokens.driver.token), 'FAILED_PRECONDITION');
  expectSuccess(await callDropoff(tokens.driver.token, ids.trip, ids.r1));
  expectError(await callEndRide(tokens.driver.token), 'FAILED_PRECONDITION');
  const result = await callDropoff(tokens.driver.token, ids.trip, ids.r2);
  expectSuccess(result);
  assert.equal(result.result.tripCompleted, true);
  const first = (await db.doc(`ride_requests/${ids.r1}`).get()).data();
  const second = (await db.doc(`ride_requests/${ids.r2}`).get()).data();
  const trip = (await db.doc(`trips/${ids.trip}`).get()).data();
  assert.equal(first.status, 'drop_off_confirmed');
  assert.equal(second.status, 'drop_off_confirmed');
  assert.equal(trip.status, 'completed');
  assert.ok(trip.completedAt);
});
test('76. Solo drop-off completes the trip', async () => {
  await resetFixture({ requestIds: [ids.r1], order: [] });
  await db.doc(`users/${tokens.driver.uid}`).set({
    verificationStatus: 'approved',
    isAvailable: false,
  });
  const result = await callDropoff(tokens.driver.token, ids.trip, ids.r1);
  expectSuccess(result);
  assert.equal(result.result.tripCompleted, true);
  const booking = (await db.doc(`ride_requests/${ids.r1}`).get()).data();
  const completedTrip = (await db.doc(`trips/${ids.trip}`).get()).data();
  const driver = (await db.doc(`users/${tokens.driver.uid}`).get()).data();
  assert.equal(booking.status, 'drop_off_confirmed');
  assert.equal(completedTrip.status, 'completed');
  assert.ok(completedTrip.completedAt);
  assert.equal(driver.isAvailable, true);
});
test('77. Repeated final confirmation rejected', async () => {
  expectSuccess(await callDropoff(tokens.driver.token, ids.trip, ids.r1));
  expectSuccess(await callDropoff(tokens.driver.token, ids.trip, ids.r2));
  expectError(await callDropoff(tokens.driver.token, ids.trip, ids.r2), 'FAILED_PRECONDITION');
});

test('78. Driver cancellation releases pre-start trip for rematching', async () => {
  await resetFixture({
    status: 'driver_assigned',
    r1Status: 'driver_assigned',
    r2Status: 'driver_assigned',
  });
  await db.doc(`users/${tokens.driver.uid}`).set({
    verificationStatus: 'approved',
    isAvailable: false,
  });
  await db.doc(`driver_offer_locks/${tokens.driver.uid}`).set({
    tripId: ids.trip,
  });

  expectSuccess(await callCancelTrip(tokens.driver.token));
  const trip = (await db.doc(`trips/${ids.trip}`).get()).data();
  const first = (await db.doc(`ride_requests/${ids.r1}`).get()).data();
  const second = (await db.doc(`ride_requests/${ids.r2}`).get()).data();
  const driver = (await db.doc(`users/${tokens.driver.uid}`).get()).data();
  const lock = await db.doc(`driver_offer_locks/${tokens.driver.uid}`).get();
  assert.equal(trip.status, 'matching_driver');
  assert.equal(trip.driverId, null);
  assert.ok(trip.declinedDriverIds.includes(tokens.driver.uid));
  assert.equal(first.status, 'matching_driver');
  assert.equal(first.driverId, null);
  assert.equal(second.status, 'matching_driver');
  assert.equal(driver.isAvailable, true);
  assert.equal(lock.exists, false);
});

test('79. Driver cannot cancel a trip after it has started', async () => {
  expectError(await callCancelTrip(tokens.driver.token), 'FAILED_PRECONDITION');
});
