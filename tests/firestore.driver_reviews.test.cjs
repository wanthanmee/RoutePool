
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
  doc,
  setDoc,
  getDoc,
  getDocs,
  collection,
  query,
  where,
  updateDoc,
  deleteDoc,
  serverTimestamp,
  runTransaction,
} = require('firebase/firestore');

let env;

const passenger = 'passenger_1';
const driver = 'driver_1';
const requestId = 'request_1';
const tripId = 'trip_1';

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

  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();

    await setDoc(doc(db, `trips/${tripId}`), {
      requestIds: [requestId],
      passengerIds: [passenger],
      driverId: driver,
      status: 'in_progress',
    });

    await setDoc(doc(db, `ride_requests/${requestId}`), {
      passengerId: passenger,
      groupId: tripId,
      driverId: driver,
      status: 'drop_off_confirmed',
      reviewPromptEligibleAt: new Date(),
    });
  });
});

const db = (uid) => env.authenticatedContext(uid).firestore();

const review = (extra = {}) => ({
  tripId,
  requestId,
  driverId: driver,
  passengerId: passenger,
  rating: 5,
  tags: ['Friendly'],
  comment: 'Good ride',
  createdAt: serverTimestamp(),
  ...extra,
});

const create = (uid = passenger, extra = {}) =>
  setDoc(doc(db(uid), `reviews/${requestId}`), review(extra));
const createCanonical = (uid = passenger, extra = {}) =>
  setDoc(doc(db(uid), `reviews/${requestId}`), review(extra));

async function seedReview() {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(
      doc(ctx.firestore(), `reviews/${requestId}`),
      review({ createdAt: new Date() })
    );
  });
}

test('passenger creates review after confirmed drop-off', async () => {
  await assertSucceeds(create());
});

test('passenger creates canonical review at request ID', async () => {
  await assertSucceeds(createCanonical());
  await assertSucceeds(
    getDoc(doc(db(passenger), `reviews/${requestId}`))
  );
  await assertFails(createCanonical());
});

test('passenger can persist automatic prompt state for own confirmed ride', async () => {
  await assertSucceeds(
    updateDoc(doc(db(passenger), `ride_requests/${requestId}`), {
      reviewPromptState: {
        status: 'showing',
        claimId: 'test-claim',
        claimedAt: serverTimestamp(),
      },
    })
  );
  await assertSucceeds(
    updateDoc(doc(db(passenger), `ride_requests/${requestId}`), {
      reviewPromptState: {
        status: 'shown',
        shownAt: serverTimestamp(),
      },
    })
  );
});

test('passenger can claim a prompt using only their booking and canonical review', async () => {
  const passengerDb = db(passenger);
  const requestRef = doc(passengerDb, `ride_requests/${requestId}`);
  const reviewRef = doc(passengerDb, `reviews/${requestId}`);

  await assertSucceeds(
    runTransaction(passengerDb, async (transaction) => {
      const requestSnapshot = await transaction.get(requestRef);
      const reviewSnapshot = await transaction.get(reviewRef);
      if (!requestSnapshot.exists() || reviewSnapshot.exists()) {
        throw new Error('Review prompt fixture is invalid.');
      }
      transaction.update(requestRef, {
        reviewPromptState: {
          status: 'showing',
          claimId: 'transaction-claim',
          claimedAt: serverTimestamp(),
        },
      });
    })
  );
});

test('another passenger cannot persist automatic prompt state', async () => {
  await assertFails(
    updateDoc(doc(db('passenger_2'), `ride_requests/${requestId}`), {
      reviewPromptState: {
        status: 'shown',
        shownAt: serverTimestamp(),
      },
    })
  );
});

test('different passenger cannot impersonate reviewer', async () => {
  await assertFails(create('passenger_2'));
});

test('review cannot use incorrect driver ID', async () => {
  await assertFails(create(passenger, { driverId: 'driver_2' }));
});

test('rating below 1 is denied', async () => {
  await assertFails(create(passenger, { rating: 0 }));
});

test('rating above 5 is denied', async () => {
  await assertFails(create(passenger, { rating: 6 }));
});

test('oversized comment is denied', async () => {
  await assertFails(
    create(passenger, { comment: 'x'.repeat(501) })
  );
});

test('unexpected review field is denied', async () => {
  await assertFails(
    create(passenger, { adminApproved: true })
  );
});

test('cannot review before drop-off', async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await updateDoc(
      doc(ctx.firestore(), `ride_requests/${requestId}`),
      { status: 'in_progress' }
    );
  });

  await assertFails(create());
});

test('duplicate review is denied', async () => {
  await assertSucceeds(create());
  await assertFails(create());
});

test('passenger can read own review', async () => {
  await seedReview();
  await assertSucceeds(
    getDoc(doc(db(passenger), `reviews/${requestId}`))
  );
});

test('driver can read their review', async () => {
  await seedReview();
  await assertSucceeds(
    getDoc(doc(db(driver), `reviews/${requestId}`))
  );
});

test('unrelated driver cannot read review', async () => {
  await seedReview();
  await assertFails(
    getDoc(doc(db('driver_2'), `reviews/${requestId}`))
  );
});

test('driver can query own reviews', async () => {
  await seedReview();

  await assertSucceeds(
    getDocs(
      query(
        collection(db(driver), 'reviews'),
        where('driverId', '==', driver)
      )
    )
  );
});

test('driver cannot query another driver reviews', async () => {
  await seedReview();

  await assertFails(
    getDocs(
      query(
        collection(db('driver_2'), 'reviews'),
        where('driverId', '==', driver)
      )
    )
  );
});

test('passenger cannot list all reviews', async () => {
  await seedReview();

  await assertFails(
    getDocs(
      collection(db(passenger), 'reviews')
    )
  );
});

test('review cannot be edited', async () => {
  await seedReview();

  await assertFails(
    updateDoc(
      doc(db(passenger), `reviews/${requestId}`),
      { rating: 1 }
    )
  );
});

test('review cannot be deleted', async () => {
  await seedReview();

  await assertFails(
    deleteDoc(doc(db(passenger), `reviews/${requestId}`))
  );
});
