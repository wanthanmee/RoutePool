
const { test } = require('node:test');
const assert = require('node:assert/strict');

const { initializeApp } = require('firebase-admin/app');
const { getFirestore, Timestamp } = require('firebase-admin/firestore');

const PROJECT_ID = 'routepool-9405b';
const AUTH_URL = 'http://127.0.0.1:9199';
const FUNCTION_URL =
  `http://127.0.0.1:5101/${PROJECT_ID}/asia-southeast1/advanceDriverTrip`;

process.env.FIRESTORE_EMULATOR_HOST = '127.0.0.1:8181';
process.env.GCLOUD_PROJECT = PROJECT_ID;

const app = initializeApp({ projectId: PROJECT_ID });
const db = getFirestore(app);

async function createTestUser(label) {
  const email = `${label}-${Date.now()}-${Math.random().toString(36).slice(2)}@example.com`;

  const response = await fetch(
    `${AUTH_URL}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email,
        password: 'TestPassword123!',
        returnSecureToken: true,
      }),
    }
  );

  const data = await response.json();
  assert.equal(response.ok, true, JSON.stringify(data));
  return { uid: data.localId, token: data.idToken };
}

async function callFunction(token, tripId, nextStatus) {
  const response = await fetch(FUNCTION_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify({ data: { tripId, nextStatus } }),
  });

  return {
    httpStatus: response.status,
    body: await response.json(),
  };
}

test('Phase 4D - advanceDriverTrip security', async (t) => {
  const driver = await createTestUser('driver');
  const other = await createTestUser('unrelated');
  const passenger = await createTestUser('passenger');

  const tripId = `phase4d_${Date.now()}`;
  const requestId = `${tripId}_request`;

  const tripRef = db.collection('trips').doc(tripId);
  const requestRef = db.collection('ride_requests').doc(requestId);

  const fresh = () => Timestamp.fromDate(new Date());

  async function resetTrip(status = 'driver_assigned') {
    await tripRef.set({
      driverId: driver.uid,
      passengerIds: [passenger.uid],
      requestIds: [requestId],
      status,
      totalPassengers: 1,
    });

    await requestRef.set({
      passengerId: passenger.uid,
      driverId: driver.uid,
      groupId: tripId,
      status,
    });

    await tripRef.collection('live_locations').doc(driver.uid).set({
      userId: driver.uid,
      role: 'driver',
      lat: 5.4141,
      lon: 100.3288,
      updatedAt: fresh(),
    });

    await tripRef.collection('live_locations').doc(passenger.uid).set({
      userId: passenger.uid,
      role: 'passenger',
      lat: 5.4142,
      lon: 100.3289,
      updatedAt: fresh(),
    });
  }

  await resetTrip();

  await t.test('57. Unauthenticated caller rejected', async () => {
    const result = await callFunction(null, tripId, 'driver_arrived');
    assert.equal(result.body.error?.status, 'UNAUTHENTICATED');
  });

  await t.test('58. Unassigned driver rejected', async () => {
    const result = await callFunction(other.token, tripId, 'driver_arrived');
    assert.equal(result.body.error?.status, 'PERMISSION_DENIED');
  });

  await t.test('59. Invalid status transition rejected', async () => {
    const result = await callFunction(driver.token, tripId, 'in_progress');
    assert.equal(result.body.error?.status, 'FAILED_PRECONDITION');
  });

  await t.test('60. Invalid next status rejected', async () => {
    const result = await callFunction(driver.token, tripId, 'completed');
    assert.equal(result.body.error?.status, 'INVALID_ARGUMENT');
  });

  await t.test('61. Stale driver GPS rejected', async () => {
    await resetTrip();

    await tripRef.collection('live_locations').doc(driver.uid).update({
      updatedAt: Timestamp.fromMillis(Date.now() - 120000),
    });

    const result = await callFunction(driver.token, tripId, 'driver_arrived');
    assert.equal(result.body.error?.status, 'FAILED_PRECONDITION');
  });

  await t.test('62. Assigned driver can mark arrival', async () => {
    await resetTrip();

    const result = await callFunction(driver.token, tripId, 'driver_arrived');

    assert.equal(result.body.result?.success, true);
    assert.equal((await tripRef.get()).data().status, 'driver_arrived');
    assert.equal((await requestRef.get()).data().status, 'driver_arrived');
  });

  await t.test('63. Stale passenger GPS prevents trip start', async () => {
    await resetTrip('driver_arrived');

    await tripRef.collection('live_locations').doc(passenger.uid).update({
      updatedAt: Timestamp.fromMillis(Date.now() - 120000),
    });

    const result = await callFunction(driver.token, tripId, 'in_progress');
    assert.equal(result.body.error?.status, 'FAILED_PRECONDITION');
  });

  await t.test('64. Assigned driver can start trip', async () => {
    await resetTrip('driver_arrived');

    const result = await callFunction(driver.token, tripId, 'in_progress');

    assert.equal(result.body.result?.success, true);
    assert.equal((await tripRef.get()).data().status, 'in_progress');
    assert.equal((await requestRef.get()).data().status, 'in_progress');
  });

  await t.test('65. Completed transition cannot be repeated', async () => {
    const result = await callFunction(driver.token, tripId, 'in_progress');
    assert.equal(result.body.error?.status, 'FAILED_PRECONDITION');
  });

  await tripRef.collection('live_locations').doc(driver.uid).delete();
  await tripRef.collection('live_locations').doc(passenger.uid).delete();
  await requestRef.delete();
  await tripRef.delete();
});
