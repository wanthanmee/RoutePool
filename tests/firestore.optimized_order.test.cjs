'use strict';
// Phase 4D: saveOptimizedDropoffOrder callable emulator tests.
const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { initializeApp, deleteApp } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');

const projectId = 'routepool-9405b';
const authBase = 'http://127.0.0.1:9199/identitytoolkit.googleapis.com/v1';
const callableUrl = `http://127.0.0.1:5101/${projectId}/asia-southeast1/saveOptimizedDropoffOrder`;
process.env.FIRESTORE_EMULATOR_HOST = '127.0.0.1:8181';
process.env.FIREBASE_AUTH_EMULATOR_HOST = '127.0.0.1:9199';
const app = initializeApp({ projectId }, 'optimized-order-test');
const db = getFirestore(app);
const runId = `optimized_${Date.now()}_${process.pid}`;
const ids = {
  driver: `${runId}_driver`, other: `${runId}_other`,
  passenger1: `${runId}_p1`, passenger2: `${runId}_p2`,
  trip: `${runId}_trip`, r1: `${runId}_r1`, r2: `${runId}_r2`,
};
const tokens = {};

async function authRequest(endpoint, data) {
  const response = await fetch(`${authBase}/accounts:${endpoint}?key=fake-api-key`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  });
  const result = await response.json();
  if (!response.ok) throw new Error(`Auth emulator: ${JSON.stringify(result)}`);
  return result;
}
async function createUser(uid) {
  const registered = await authRequest('signUp', {
    email: `${uid}@example.test`, password: 'test-password-12345',
    returnSecureToken: true,
  });
  return { uid: registered.localId, token: registered.idToken };
}
async function callSave(token, tripId = ids.trip, optimizedRequestIds = [ids.r2, ids.r1]) {
  const response = await fetch(callableUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify({ data: { tripId, optimizedRequestIds } }),
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
  const { status = 'in_progress', r1Status = 'in_progress',
    r2Status = 'in_progress', r1GroupId = ids.trip,
    r2GroupId = ids.trip, existingOrder } = options;
  const driverId = tokens.driver.uid;
  const trip = {
    driverId, status, requestIds: [ids.r1, ids.r2],
    pickupHubId: 'test_hub', totalPassengers: 2,
  };
  if (existingOrder !== undefined) trip.optimizedDropoffOrder = existingOrder;
  await db.doc(`trips/${ids.trip}`).set(trip);
  for (const [requestId, passengerId, requestStatus, groupId] of [
    [ids.r1, tokens.passenger1.uid, r1Status, r1GroupId],
    [ids.r2, tokens.passenger2.uid, r2Status, r2GroupId],
  ]) {
    await db.doc(`ride_requests/${requestId}`).set({
      passengerId, driverId, groupId, status: requestStatus,
      passengerCount: 1, pickupHubId: 'test_hub',
    });
  }
}
before(async () => {
  for (const key of ['driver', 'other', 'passenger1', 'passenger2']) {
    tokens[key] = await createUser(ids[key]);
  }
});
beforeEach(async () => { await resetFixture(); });
after(async () => {
  await Promise.all([
    db.doc(`trips/${ids.trip}`).delete().catch(() => {}),
    db.doc(`ride_requests/${ids.r1}`).delete().catch(() => {}),
    db.doc(`ride_requests/${ids.r2}`).delete().catch(() => {}),
  ]);
  await deleteApp(app);
});

test('76. Unauthenticated caller rejected', async () => {
  expectError(await callSave(null), 'UNAUTHENTICATED');
});
test('77. Unassigned driver rejected', async () => {
  expectError(await callSave(tokens.other.token), 'PERMISSION_DENIED');
});
test('78. Trip not in progress rejected', async () => {
  await resetFixture({ status: 'driver_arrived' });
  expectError(await callSave(tokens.driver.token), 'FAILED_PRECONDITION');
});
test('79. Booking outside the trip rejected', async () => {
  expectError(await callSave(tokens.driver.token, ids.trip, [ids.r1, 'unrelated_booking']), 'INVALID_ARGUMENT');
});
test('80. Duplicate booking IDs rejected', async () => {
  expectError(await callSave(tokens.driver.token, ids.trip, [ids.r1, ids.r1]), 'INVALID_ARGUMENT');
});
test('81. Missing passenger booking rejected', async () => {
  await db.doc(`ride_requests/${ids.r2}`).delete();
  expectError(await callSave(tokens.driver.token), 'FAILED_PRECONDITION');
});
test('82. Booking belongs to another trip rejected', async () => {
  await resetFixture({ r2GroupId: 'another_trip' });
  expectError(await callSave(tokens.driver.token), 'FAILED_PRECONDITION');
});
test('83. Booking not in progress rejected', async () => {
  await resetFixture({ r2Status: 'driver_assigned' });
  expectError(await callSave(tokens.driver.token), 'FAILED_PRECONDITION');
});
test('84. Valid optimized order saved successfully', async () => {
  const proposed = [ids.r2, ids.r1];
  const result = await callSave(tokens.driver.token, ids.trip, proposed);
  expectSuccess(result);
  assert.equal(result.result.tripId, ids.trip);
  assert.deepEqual(result.result.optimizedDropoffOrder, proposed);
  const trip = (await db.doc(`trips/${ids.trip}`).get()).data();
  assert.deepEqual(trip.optimizedDropoffOrder, proposed);
  assert.ok(trip.routeUpdatedAt, 'routeUpdatedAt should exist');
  assert.ok(trip.updatedAt, 'updatedAt should exist');
});
test('85. Attempt to overwrite saved order rejected', async () => {
  expectSuccess(await callSave(tokens.driver.token, ids.trip, [ids.r2, ids.r1]));
  expectError(await callSave(tokens.driver.token, ids.trip, [ids.r1, ids.r2]), 'ALREADY_EXISTS');
  const trip = (await db.doc(`trips/${ids.trip}`).get()).data();
  assert.deepEqual(trip.optimizedDropoffOrder, [ids.r2, ids.r1]);
});
