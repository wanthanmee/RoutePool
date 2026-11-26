
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
  getDoc,
  updateDoc,
  serverTimestamp,
} = require('firebase/firestore');

let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
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

beforeEach(async () => {
  await testEnv.clearFirestore();
});

after(async () => {
  if (testEnv) {
    await testEnv.cleanup();
  }
});

function passengerProfile() {
  return {
    name: 'Test Passenger',
    email: 'passenger@example.com',
    phoneNo: '+60123456789',
    role: 'passenger',
    verificationStatus: 'pending',
    phoneVerified: true,
    icPassport: '',
    documentSubmissionAttempts: 0,
    profilePic: '',
    createdAt: serverTimestamp(),
  };
}

function passengerDb(uid = 'passenger_001') {
  return testEnv.authenticatedContext(uid, {
    email: 'passenger@example.com',
    phone_number: '+60123456789',
  }).firestore();
}

test('1. Passenger can create their own valid profile', async () => {
  const db = passengerDb();

  await assertSucceeds(
    setDoc(doc(db, 'users/passenger_001'), passengerProfile())
  );
});

test('2. Passenger cannot create another user profile', async () => {
  const db = passengerDb();

  await assertFails(
    setDoc(doc(db, 'users/another_user'), passengerProfile())
  );
});

test('3. Passenger cannot register as admin', async () => {
  const db = passengerDb();

  await assertFails(
    setDoc(doc(db, 'users/unauthorized_admin'), {
      ...passengerProfile(),
      role: 'admin',
    })
  );
});

test('4. Unauthenticated user cannot read private profiles', async () => {
  const db = testEnv.unauthenticatedContext().firestore();

  await assertFails(
    getDoc(doc(db, 'users/passenger_001'))
  );
});

test('5. Passenger cannot approve their own account', async () => {
  const db = passengerDb();

  await assertFails(
    updateDoc(doc(db, 'users/passenger_001'), {
      verificationStatus: 'approved',
    })
  );
});

test('6. Passenger cannot register as admin using their own UID', async () => {
  const db = passengerDb('admin_attempt_001');

  await assertFails(
    setDoc(doc(db, 'users/admin_attempt_001'), {
      ...passengerProfile(),
      role: 'admin',
    })
  );
});