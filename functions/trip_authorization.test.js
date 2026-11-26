
const { test, after } = require("node:test");
const assert = require("node:assert/strict");

const { initializeApp, deleteApp } = require("firebase/app");
const {
  getAuth,
  connectAuthEmulator,
  signInAnonymously,
  signOut,
} = require("firebase/auth");
const {
  getFunctions,
  connectFunctionsEmulator,
  httpsCallable,
} = require("firebase/functions");
const {
  initializeTestEnvironment,
} = require("@firebase/rules-unit-testing");
const { doc, setDoc, getDoc } = require("firebase/firestore");

const PROJECT_ID = "routepool-9405b";
const REGION = "asia-southeast1";

let testEnv;
const apps = [];

async function setup() {
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      host: "127.0.0.1",
      port: 8181,
    },
  });
}

async function createDriverApp(name) {
  const app = initializeApp(
    {
      apiKey: "fake-api-key",
      authDomain: `${PROJECT_ID}.firebaseapp.com`,
      projectId: PROJECT_ID,
      appId: `test-${name}`,
    },
    name
  );

  apps.push(app);

  const auth = getAuth(app);
  connectAuthEmulator(auth, "http://127.0.0.1:9199", {
    disableWarnings: true,
  });

  const credential = await signInAnonymously(auth);

  const functions = getFunctions(app, REGION);
  connectFunctionsEmulator(functions, "127.0.0.1", 5101);

  return {
    uid: credential.user.uid,
    auth,
    functions,
  };
}

async function seedTrip(driverId, tripId, approved) {
  const expiresAt = new Date(Date.now() + 10 * 60 * 1000);

  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();

    await setDoc(doc(db, "users", driverId), {
      role: "driver",
      verificationStatus: approved ? "approved" : "pending",
      isAvailable: true,
    });

    await setDoc(doc(db, "vehicles", driverId), {
      verificationStatus: "approved",
      isActive: true,
      seatCapacity: 4,
    });

    await setDoc(doc(db, "trips", tripId), {
      status: "matching_driver",
      driverId: null,
      offeredDriverId: driverId,
      offerExpiresAt: expiresAt,
      totalPassengers: 1,
      requestIds: ["request-" + tripId],
    });

    await setDoc(doc(db, "driver_offer_locks", driverId), {
      tripId,
      expiresAt,
    });

    await setDoc(doc(db, "ride_requests", "request-" + tripId), {
      passengerId: "test-passenger",
      groupId: tripId,
      status: "matching_driver",
      driverId: null,
    });
  });
}

async function expectCallableError(promise, expectedCode) {
  await assert.rejects(
    promise,
    (error) => {
      assert.equal(error.code, expectedCode);
      return true;
    }
  );
}

test("Test 4: Unapproved driver cannot accept a trip", async () => {
  await setup();

  const driver = await createDriverApp("unapproved-driver");
  const tripId = "trip-unapproved";

  await seedTrip(driver.uid, tripId, false);

  const acceptRideTrip = httpsCallable(
    driver.functions,
    "acceptRideTrip"
  );

  await expectCallableError(
    acceptRideTrip({ tripId }),
    "functions/failed-precondition"
  );

let tripData;

await testEnv.withSecurityRulesDisabled(async (context) => {
  const snapshot = await getDoc(
    doc(context.firestore(), "trips", tripId)
  );

  tripData = snapshot.data();
});

assert.ok(tripData, "Trip document should exist");
assert.equal(tripData.status, "matching_driver");
assert.equal(tripData.driverId, null);
});

test("Test 5: Driver cannot accept another driver's offer", async () => {
  const offeredDriver = await createDriverApp("offered-driver");
  const otherDriver = await createDriverApp("other-driver");

  const tripId = "trip-unauthorized";

  await seedTrip(offeredDriver.uid, tripId, true);

  const acceptRideTrip = httpsCallable(
    otherDriver.functions,
    "acceptRideTrip"
  );

  await expectCallableError(
    acceptRideTrip({ tripId }),
    "functions/failed-precondition"
  );
});

test("Test 6: Approved driver can accept their own valid trip offer", async () => {
  const driver = await createDriverApp("approved-driver");
  const tripId = "trip-approved";

  await seedTrip(driver.uid, tripId, true);

  const acceptRideTrip = httpsCallable(
    driver.functions,
    "acceptRideTrip"
  );

  const result = await acceptRideTrip({ tripId });

  assert.equal(result.data.success, true);

let tripData;

await testEnv.withSecurityRulesDisabled(async (context) => {
  const snapshot = await getDoc(
    doc(context.firestore(), "trips", tripId)
  );

  tripData = snapshot.data();
});

assert.ok(tripData, "Trip document should exist");
assert.equal(tripData.status, "driver_assigned");
assert.equal(tripData.driverId, driver.uid);
});

after(async () => {
  if (testEnv) {
    await testEnv.cleanup();
  }

  for (const app of apps) {
    await deleteApp(app);
  }
});
