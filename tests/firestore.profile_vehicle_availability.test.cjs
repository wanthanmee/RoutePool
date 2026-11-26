
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
  serverTimestamp,
  writeBatch,
  deleteField,
} = require('firebase/firestore');

let env;

// =====================================================
// TEST ENVIRONMENT
// =====================================================

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'routepool-9405b',

    firestore: {
      host: '127.0.0.1',
      port: 8181,

      rules: fs.readFileSync(
        path.join(
          __dirname,
          '../firestore.rules'
        ),
        'utf8'
      ),
    },
  });
});

after(async () => {
  if (env) {
    await env.cleanup();
  }
});

// =====================================================
// TEST DATA
// =====================================================

beforeEach(async () => {
  await env.clearFirestore();

  await env.withSecurityRulesDisabled(async (context) => {
    const database = context.firestore();

    await setDoc(
      doc(database, 'admins/admin_001'),
      { role: 'admin' }
    );

    const users = [
      ['passenger_001', 'passenger', 'approved'],
      ['passenger_002', 'passenger', 'approved'],
      ['driver_001', 'driver', 'approved'],
      ['driver_002', 'driver', 'pending'],
      ['driver_003', 'driver', 'approved'],
    ];

    for (const [uid, role, status] of users) {
      await setDoc(doc(database, 'users', uid), {
        name: 'Test User',
        role: role,
        verificationStatus: status,
        isAvailable: false,
      });
    }

    await setDoc(
      doc(database, 'vehicles/driver_001'),
      vehicle('driver_001', 'approved', true)
    );

    await setDoc(
      doc(database, 'vehicles/driver_002'),
      vehicle('driver_002', 'approved', true)
    );

    await setDoc(
      doc(database, 'vehicles/driver_003'),
      vehicle('driver_003', 'pending', false)
    );
  });
});

function db(uid) {
  return env.authenticatedContext(uid).firestore();
}

function vehicle(
  uid,
  status = 'not_submitted',
  active = false
) {
  return {
    driverId: uid,
    vehicleMake: 'Perodua',
    vehicleModel: 'Myvi',
    vehicleColor: 'Silver',
    plateNumber: 'PSG2439',
    seatCapacity: 4,
    verificationStatus: status,
    isActive: active,
  };
}

function vehicleCreate(uid) {
  return {
    ...vehicle(uid),
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
  };
}

// =====================================================
// PROFILE SECURITY TESTING
// =====================================================

// TEST 17
test('17. Passenger can update own profile name', async () => {
  await assertSucceeds(
    updateDoc(
      doc(db('passenger_001'), 'users/passenger_001'),
      {
        name: 'New Name',
        updatedAt: serverTimestamp(),
      }
    )
  );
});

// TEST 18
test('18. Passenger cannot change role to admin', async () => {
  await assertFails(
    updateDoc(
      doc(db('passenger_001'), 'users/passenger_001'),
      {
        role: 'admin',
        updatedAt: serverTimestamp(),
      }
    )
  );
});

// TEST 19
test('19. Passenger cannot modify own verification status', async () => {
  await assertFails(
    updateDoc(
      doc(db('passenger_001'), 'users/passenger_001'),
      {
        verificationStatus: 'rejected',
        updatedAt: serverTimestamp(),
      }
    )
  );
});

// =====================================================
// VEHICLE REGISTRATION SECURITY TESTING
// =====================================================

// TEST 20
test('20. Driver can register own unapproved vehicle', async () => {
  // A driver cannot create a vehicle under another ID.
  await assertFails(
    setDoc(
      doc(db('driver_001'), 'vehicles/driver_new'),
      vehicleCreate('driver_001')
    )
  );

  // Create another driver for registration testing.
  await env.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), 'users/driver_004'),
      {
        name: 'New Driver',
        role: 'driver',
        verificationStatus: 'pending',
        isAvailable: false,
      }
    );
  });

  await assertSucceeds(
    setDoc(
      doc(db('driver_004'), 'vehicles/driver_004'),
      vehicleCreate('driver_004')
    )
  );
});

// TEST 21
test('21. Driver cannot approve own vehicle', async () => {
  await assertFails(
    updateDoc(
      doc(db('driver_003'), 'vehicles/driver_003'),
      {
        verificationStatus: 'approved',
        isActive: true,
        updatedAt: serverTimestamp(),
      }
    )
  );
});

// TEST 22
test('22. Driver cannot modify another driver vehicle', async () => {
  await assertFails(
    updateDoc(
      doc(db('driver_001'), 'vehicles/driver_003'),
      {
        vehicleColor: 'Blue',
        verificationStatus: 'pending',
        isActive: false,
        updatedAt: serverTimestamp(),
      }
    )
  );
});

// =====================================================
// DRIVER AVAILABILITY SECURITY TESTING
// =====================================================

// TEST 23
test('23. Approved driver with approved vehicle can go online', async () => {
  await assertSucceeds(
    updateDoc(
      doc(db('driver_001'), 'users/driver_001'),
      {
        isAvailable: true,
        updatedAt: serverTimestamp(),
      }
    )
  );
});

// TEST 24
test('24. Unapproved driver cannot go online', async () => {
  await assertFails(
    updateDoc(
      doc(db('driver_002'), 'users/driver_002'),
      {
        isAvailable: true,
        updatedAt: serverTimestamp(),
      }
    )
  );
});

// TEST 25
test('25. Driver with unapproved vehicle cannot go online', async () => {
  await assertFails(
    updateDoc(
      doc(db('driver_003'), 'users/driver_003'),
      {
        isAvailable: true,
        updatedAt: serverTimestamp(),
      }
    )
  );
});

// TEST 26
test('26. Approved driver can go offline', async () => {
  await assertSucceeds(
    updateDoc(
      doc(db('driver_001'), 'users/driver_001'),
      {
        isAvailable: false,
        updatedAt: serverTimestamp(),
      }
    )
  );
});

// =====================================================
// VEHICLE REAPPROVAL SECURITY TESTING
// =====================================================

// TEST 27
test('27. Vehicle changes reset approval and driver goes offline', async () => {
  const database = db('driver_001');
  const batch = writeBatch(database);

  batch.set(
    doc(database, 'vehicles/driver_001'),
    {
      vehicleColor: 'Blue',
      verificationStatus: 'pending',
      isActive: false,
      approvedAt: deleteField(),
      rejectionReason: deleteField(),
      updatedAt: serverTimestamp(),
    },
    { merge: true }
  );

  batch.set(
    doc(database, 'users/driver_001'),
    {
      isAvailable: false,
      name: 'Test User',
      updatedAt: serverTimestamp(),
    },
    { merge: true }
  );

  await assertSucceeds(batch.commit());
});

// TEST 28
test('28. Driver cannot retain approval after vehicle changes', async () => {
  await assertFails(
    updateDoc(
      doc(db('driver_001'), 'vehicles/driver_001'),
      {
        vehicleColor: 'Blue',
        updatedAt: serverTimestamp(),
      }
    )
  );
});
