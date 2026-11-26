
const { test, before, after, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require("@firebase/rules-unit-testing");

const {
  doc,
  setDoc,
  updateDoc,
  getDoc,
  serverTimestamp,
  runTransaction,
} = require("firebase/firestore");

let testEnv;

const rulesPath = path.resolve(
  __dirname,
   "../firestore.rules"
);

const projectId = "routepool-authorization-test";

function userDb(uid, phoneNumber = "+60123456789") {
  return testEnv.authenticatedContext(uid, {
    phone_number: phoneNumber,
    email: "test@example.com",
  }).firestore();
}

function adminDb() {
  return userDb("admin1");
}

function registrationData(role, phoneNumber = "+60123456789") {
  return {
    name: "Test User",
    email: "test@example.com",
    phoneNo: phoneNumber,
    role,
    verificationStatus: "pending",
    phoneVerified: true,
    icPassport: "",
    documentSubmissionAttempts: 0,
    profilePic: "",
    ...(role === "driver" ? { driverApproved: false } : {}),
    createdAt: serverTimestamp(),
  };
}

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId,
    firestore: {
      host: "127.0.0.1",
      port: 8181,
      rules: fs.readFileSync(rulesPath, "utf8"),
    },
  });
});

beforeEach(async () => {
  await testEnv.clearFirestore();

  // Seed trusted test data without applying client security rules.
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();

    await setDoc(doc(db, "admins", "admin1"), {
      email: "admin@example.com",
    });

    await setDoc(doc(db, "users", "passenger1"),
      registrationData("passenger"));

    await setDoc(doc(db, "users", "driver1"),
      registrationData("driver"));

    await setDoc(doc(db, "vehicles", "driver1"), {
      verificationStatus: "pending",
      isActive: false,
    });
  });
});

after(async () => {
  if (testEnv) {
    await testEnv.cleanup();
  }
});

// TEST 1
test("Passenger cannot modify another passenger's profile", async () => {
  const db = userDb("passenger2");

  await assertFails(
    updateDoc(doc(db, "users", "passenger1"), {
      name: "Unauthorized Change",
    })
  );
});

// TEST 2
test("Passenger cannot approve their own registration", async () => {
  const db = userDb("passenger1");

  await assertFails(
    updateDoc(doc(db, "users", "passenger1"), {
      verificationStatus: "approved",
    })
  );
});

// TEST 3
test("Driver cannot approve their own vehicle", async () => {
  const db = userDb("driver1");

  await assertFails(
    updateDoc(doc(db, "vehicles", "driver1"), {
      verificationStatus: "approved",
      isActive: true,
    })
  );
});

// TEST 4
test("Administrator can approve passenger registration", async () => {
  const db = adminDb();

  await assertSucceeds(
    updateDoc(doc(db, "users", "passenger1"), {
      verificationStatus: "approved",
    })
  );
});

// TEST 5
test("Administrator can approve a driver's vehicle", async () => {
  const db = adminDb();

  await assertSucceeds(
    updateDoc(doc(db, "vehicles", "driver1"), {
      verificationStatus: "approved",
      isActive: true,
      approvedAt: new Date(),
      updatedAt: new Date(),
    })
  );
});


// TEST 6
test("New passenger can register with pending status", async () => {
  const db = userDb("newpassenger");

  await assertSucceeds(
    setDoc(doc(db, "users", "newpassenger"),
      registrationData("passenger"))
  );
});

// TEST 7
test("New driver can register with pending status", async () => {
  const db = userDb("newdriver");

  await assertSucceeds(
    setDoc(doc(db, "users", "newdriver"),
      registrationData("driver"))
  );
});

// TEST 8
test("User cannot register as already approved", async () => {
  const db = userDb("malicioususer");

  await assertFails(
    setDoc(doc(db, "users", "malicioususer"), {
      ...registrationData("passenger"),
      verificationStatus: "approved",
    })
  );
});

// TEST 9
test("Passenger cannot create an administrator account", async () => {
  const db = userDb("passenger1");

  await assertFails(
    setDoc(doc(db, "admins", "passenger1"), {
      email: "fakeadmin@example.com",
    })
  );
});

// TEST 10
test("Unauthenticated user cannot create a profile", async () => {
  const db = testEnv.unauthenticatedContext().firestore();

  await assertFails(
    setDoc(doc(db, "users", "anonymous"), {
      ...registrationData("passenger"),
    })
  );
});


function bookingData(passengerId) {
  return {
    passengerId,
    pickupHubId: "12001010",
    pickupName: "Test Pickup Hub",
    pickupAddress: "Penang",
    pickupLat: 5.4141,
    pickupLon: 100.3288,
    dropoffAddress: "Test Destination",
    dropoffLat: 5.33,
    dropoffLon: 100.29,
    departureTime: serverTimestamp(),
    passengerCount: 1,
    status: "searching",
    groupId: null,
    driverId: null,
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
  };
}

// TEST 11
test("Passenger can create their own booking", async () => {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(
      doc(context.firestore(), "users", "passenger1"),
      {
        verificationStatus: "approved",
      }
    );
  });

  const db = userDb("passenger1");

  await assertSucceeds(
    setDoc(
      doc(db, "ride_requests", "booking1"),
      bookingData("passenger1")
    )
  );
});

// TEST 12
test("Passenger cannot create a booking for another passenger", async () => {
  const db = userDb("passenger2");

  await assertFails(
    setDoc(
      doc(db, "ride_requests", "booking2"),
      bookingData("passenger1")
    )
  );
});

// TEST 13
test("Passenger cannot modify another passenger's booking", async () => {
  // Create an existing booking using trusted test setup.
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), "ride_requests", "booking3"),
      bookingData("passenger1")
    );
  });

  const db = userDb("passenger2");

  await assertFails(
    updateDoc(doc(db, "ride_requests", "booking3"), {
      dropoffAddress: "Unauthorized Destination",
    })
  );
});

// TEST 14
test("Passenger cannot directly change their booking status", async () => {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), "ride_requests", "booking4"),
      bookingData("passenger1")
    );
  });

  const db = userDb("passenger1");

  await assertFails(
    updateDoc(doc(db, "ride_requests", "booking4"), {
      status: "driver_assigned",
    })
  );
});

// TEST 15
test("Passenger cannot create a booking with a manipulated fare", async () => {
  const db = userDb("passenger1");

  await assertFails(
    setDoc(
      doc(db, "ride_requests", "booking5"),
      {
        ...bookingData("passenger1"),
        fareShareSen: 0,
      }
    )
  );
});

// TEST 16
test("Passenger can check their own nonexistent driver review", async () => {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), "ride_requests", "review-booking1"),
      {
        ...bookingData("passenger1"),
        status: "drop_off_confirmed",
      }
    );
  });

  const db = userDb("passenger1");

  const snapshot = await assertSucceeds(
    getDoc(doc(db, "reviews", "review-booking1"))
  );
  assert.equal(snapshot.exists(), false);
});

// TEST 17
test("Another passenger cannot check someone else's review", async () => {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), "ride_requests", "review-booking2"),
      {
        ...bookingData("passenger1"),
        status: "drop_off_confirmed",
      }
    );
  });

  const db = userDb("passenger2");

  await assertFails(getDoc(doc(db, "reviews", "review-booking2")));
});

// TEST 18
test("Passenger can read their own existing driver review", async () => {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();

    await setDoc(
      doc(db, "ride_requests", "review-booking3"),
      {
        ...bookingData("passenger1"),
        status: "completed",
      }
    );

    await setDoc(
      doc(db, "reviews", "review-booking3"),
      {
        requestId: "review-booking3",
        tripId: "trip-review3",
        passengerId: "passenger1",
        driverId: "driver1",
        rating: 5,
        tags: [],
        comment: "Good trip",
        createdAt: new Date(),
      }
    );
  });

  const db = userDb("passenger1");

  const snapshot = await assertSucceeds(
    getDoc(doc(db, "reviews", "review-booking3"))
  );

  assert.equal(snapshot.exists(), true);
  assert.equal(snapshot.data().rating, 5);
});

// TEST 19
test("Passenger can claim their own driver review prompt", async () => {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();

    await setDoc(doc(db, "ride_requests", "review-booking4"), {
      ...bookingData("passenger1"),
      status: "drop_off_confirmed",
      groupId: "trip-review4",
      driverId: "driver1",
      reviewPromptEligibleAt: new Date(),
    });

    await setDoc(doc(db, "trips", "trip-review4"), {
      passengerIds: ["passenger1"],
      requestIds: ["review-booking4"],
      driverId: "driver1",
      status: "completed",
    });
  });

  const db = userDb("passenger1");

  await assertSucceeds(
    runTransaction(db, async (transaction) => {
      const requestRef = doc(db, "ride_requests", "review-booking4");

      await transaction.get(requestRef);
      await transaction.get(doc(db, "reviews", "review-booking4"));

      transaction.update(requestRef, {
        reviewPromptState: {
          status: "showing",
          claimId: "test-claim-123",
          claimedAt: serverTimestamp(),
        },
      });
    })
  );
});