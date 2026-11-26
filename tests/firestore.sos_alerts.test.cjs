'use strict';

const { test, before, after, beforeEach } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');

const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require('@firebase/rules-unit-testing');

const {
  deleteDoc,
  doc,
  GeoPoint,
  getDoc,
  serverTimestamp,
  setDoc,
  updateDoc,
} = require('firebase/firestore');

const projectId = 'routepool-9405b';
const tripId = 'sos_trip';
const passengerId = 'passenger_1';
const driverId = 'driver_1';
let env;

before(async () => {
  env = await initializeTestEnvironment({
    projectId,
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
    await setDoc(doc(context.firestore(), `trips/${tripId}`), {
      driverId,
      passengerIds: [passengerId],
      requestIds: ['request_1'],
      status: 'in_progress',
    });
  });
});

const db = (uid) => env.authenticatedContext(uid).firestore();
const report = (userId, overrides = {}) => ({
  userId,
  tripId,
  createdAt: serverTimestamp(),
  location: new GeoPoint(5.4, 100.3),
  locationAccuracyMeters: 8.5,
  ...overrides,
});

test('trip passenger and driver can create minimal SOS reports', async () => {
  await assertSucceeds(
    setDoc(doc(db(passengerId), 'sos_alerts/passenger_report'), report(passengerId))
  );
  await assertSucceeds(
    setDoc(doc(db(driverId), 'sos_alerts/driver_report'), report(driverId))
  );
});

test('SOS report can omit location but must include the null accuracy value', async () => {
  await assertSucceeds(
    setDoc(
      doc(db(passengerId), 'sos_alerts/no_location_report'),
      report(passengerId, {
        location: null,
        locationAccuracyMeters: null,
      })
    )
  );
});

test('nonparticipant cannot create an SOS report', async () => {
  await assertFails(
    setDoc(
      doc(db('unrelated_user'), 'sos_alerts/unauthorized_report'),
      report('unrelated_user')
    )
  );
});

test('SOS report must identify the authenticated user', async () => {
  await assertFails(
    setDoc(
      doc(db(passengerId), 'sos_alerts/forged_report'),
      report('another_user')
    )
  );
});

test('SOS report rejects private booking fields and client timestamps', async () => {
  await assertFails(
    setDoc(
      doc(db(passengerId), 'sos_alerts/private_data_report'),
      report(passengerId, { destinations: ['Private passenger address'] })
    )
  );
  await assertFails(
    setDoc(
      doc(db(passengerId), 'sos_alerts/client_time_report'),
      report(passengerId, { createdAt: new Date() })
    )
  );
});

test('SOS reports cannot be read, updated, or deleted by participants', async () => {
  const alertRef = doc(db(passengerId), 'sos_alerts/immutable_report');
  await assertSucceeds(setDoc(alertRef, report(passengerId)));
  await assertFails(getDoc(alertRef));
  await assertFails(updateDoc(alertRef, { tripId: 'another_trip' }));
  await assertFails(deleteDoc(alertRef));
});
