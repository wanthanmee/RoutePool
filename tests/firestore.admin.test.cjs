
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
  collection,
  query,
  where,
  getDocs,
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

after(async () => {
  if (testEnv) await testEnv.cleanup();
});

beforeEach(async () => {
  await testEnv.clearFirestore();

  // Seed records using administrator-level test setup,
  // bypassing Firestore rules only during fixture creation.
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();

    await setDoc(doc(db, 'admins/admin_001'), {
      role: 'admin',
    });

    await setDoc(doc(db, 'users/passenger_001'), {
      name: 'Test Passenger',
      role: 'passenger',
      verificationStatus: 'pending',
    });

    await setDoc(doc(db, 'users/passenger_002'), {
      name: 'Another Passenger',
      role: 'passenger',
      verificationStatus: 'pending',
    });

    await setDoc(doc(db, 'vehicles/driver_001'), {
      verificationStatus: 'pending',
      isActive: false,
    });
  });
});

function adminDb() {
  return testEnv.authenticatedContext('admin_001').firestore();
}

function passengerDb() {
  return testEnv.authenticatedContext('passenger_001').firestore();
}

test('7. Passenger cannot approve their own account', async () => {
  const db = passengerDb();

  await assertFails(
    updateDoc(doc(db, 'users/passenger_001'), {
      verificationStatus: 'approved',
    })
  );
});

test('8. Passenger cannot approve another account', async () => {
  const db = passengerDb();

  await assertFails(
    updateDoc(doc(db, 'users/passenger_002'), {
      verificationStatus: 'approved',
    })
  );
});

test('9. Unauthenticated user cannot read admin records', async () => {
  const db = testEnv.unauthenticatedContext().firestore();

  await assertFails(
    getDoc(doc(db, 'admins/admin_001'))
  );
});

test('10. Authorized admin can approve a passenger', async () => {
  const db = adminDb();

  await assertSucceeds(
    updateDoc(doc(db, 'users/passenger_001'), {
      verificationStatus: 'approved',
    })
  );
});

test('11. Authorized admin can reject a vehicle', async () => {
  const db = adminDb();

  await assertSucceeds(
    updateDoc(doc(db, 'vehicles/driver_001'), {
      verificationStatus: 'rejected',
      isActive: false,
      rejectionReason: 'Document requires resubmission.',
      updatedAt: serverTimestamp(),
    })
  );
});

test('12. Passenger cannot create admin privileges', async () => {
  const db = passengerDb();

  await assertFails(
    setDoc(doc(db, 'admins/passenger_001'), {
      role: 'admin',
    })
  );
});

test('13. Authorized admin can view pending users', async () => {
  const db = adminDb();

  await assertSucceeds(
    getDocs(
      query(
        collection(db, 'users'),
        where('verificationStatus', '==', 'pending')
      )
    )
  );
});

test('14. Authorized admin can view pending vehicles', async () => {
  const db = adminDb();

  await assertSucceeds(
    getDocs(
      query(
        collection(db, 'vehicles'),
        where('verificationStatus', '==', 'pending')
      )
    )
  );
});

test('15. Passenger cannot view all pending applications', async () => {
  const db = passengerDb();

  await assertFails(
    getDocs(
      query(
        collection(db, 'users'),
        where('verificationStatus', '==', 'pending')
      )
    )
  );
});

test('16. Admin cannot change a passenger into an admin', async () => {
  const db = adminDb();

  await assertFails(
    updateDoc(doc(db, 'users/passenger_001'), {
      role: 'admin',
    })
  );
});
