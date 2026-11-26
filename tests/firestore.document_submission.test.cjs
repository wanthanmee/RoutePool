const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require('@firebase/rules-unit-testing');

const {
  deleteField,
  doc,
  getDoc,
  runTransaction,
  setDoc,
  updateDoc,
} = require('firebase/firestore');

let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'routepool-document-submission-test',
    firestore: {
      host: '127.0.0.1',
      port: 8181,
      rules: fs.readFileSync(
        path.resolve(__dirname, '../firestore.rules'),
        'utf8',
      ),
    },
  });
});

beforeEach(async () => {
  await testEnv.clearFirestore();

  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'admins/admin1'), { role: 'admin' });
    await setDoc(doc(db, 'users/passenger1'), userData('passenger'));
    await setDoc(doc(db, 'users/passenger2'), userData('passenger'));
    await setDoc(doc(db, 'users/driver1'), userData('driver'));
  });
});

after(async () => {
  if (testEnv) await testEnv.cleanup();
});

function userData(role, attempts = 0, verificationStatus = 'pending') {
  return {
    name: 'Test User',
    email: 'test@example.com',
    phoneNo: '+60123456789',
    role,
    verificationStatus,
    phoneVerified: true,
    icPassport: '',
    documentSubmissionAttempts: attempts,
    profilePic: '',
    createdAt: new Date(),
    ...(role === 'driver' ? { driverApproved: false } : {}),
  };
}

function userDb(uid) {
  return testEnv.authenticatedContext(uid).firestore();
}

function identitySubmission(role, attempts) {
  return {
    icPassport: `https://storage.example/users/${role}/ic_passport.jpg`,
    icOcrText: 'Client-generated OCR is untrusted.',
    icNameMatches: true,
    icIdNumber: 'A1234567',
    documentSubmissionAttempts: attempts,
    verificationStatus: 'pending',
    rejectionReason: deleteField(),
    ...(role === 'driver'
      ? {
          licenseUrl: '',
          licenseDocumentType: '',
          licenseTemplateMatches: 0,
          licenseTemplateMatched: false,
          licenseOcrText: '',
          licenseNameMatches: false,
          licenseExpired: false,
          licenseExpiryDetected: null,
          licenseIdNumber: '',
        }
      : {}),
  };
}

async function submitIdentity(db, uid, role) {
  return runTransaction(db, async (transaction) => {
    const userRef = doc(db, 'users', uid);
    const snapshot = await transaction.get(userRef);
    const attempts = snapshot.data().documentSubmissionAttempts;
    transaction.update(userRef, identitySubmission(role, attempts + 1));
  });
}

function licenseSubmission() {
  return {
    licenseUrl: 'https://storage.example/users/driver1/driving_license.jpg',
    licenseDocumentType: 'Malaysia License',
    licenseTemplateMatches: 24,
    licenseTemplateMatched: true,
    licenseOcrText: 'Client-generated license OCR is untrusted.',
    licenseNameMatches: true,
    licenseExpired: false,
    licenseExpiryDetected: null,
    licenseIdNumber: 'D1234567',
  };
}

test('passenger can submit their own identity document', async () => {
  await assertSucceeds(
    submitIdentity(userDb('passenger1'), 'passenger1', 'passenger'),
  );
});

test('driver can submit identity and license in one counted attempt', async () => {
  const db = userDb('driver1');

  await assertSucceeds(submitIdentity(db, 'driver1', 'driver'));
  await assertSucceeds(
    updateDoc(doc(db, 'users/driver1'), licenseSubmission()),
  );
  const submittedLicense = await getDoc(doc(db, 'users/driver1'));
  assert.equal(submittedLicense.data().licenseUrl, licenseSubmission().licenseUrl);
  await assertFails(
    updateDoc(doc(db, 'users/driver1'), {
      licenseOcrText: 'A second license submission is not allowed.',
    }),
  );

  assert.equal(submittedLicense.data().documentSubmissionAttempts, 1);
});

test('driver can submit a license on the third and final attempt', async () => {
  const db = userDb('driver1');

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), 'users/driver1'), {
      documentSubmissionAttempts: 2,
      verificationStatus: 'rejected',
      rejectionReason: 'Resubmit both documents.',
      licenseUrl: 'https://storage.example/old-license.jpg',
      licenseDocumentType: 'Old license',
      licenseTemplateMatches: 12,
      licenseTemplateMatched: true,
      licenseOcrText: 'Old OCR',
      licenseNameMatches: true,
      licenseExpired: false,
      licenseExpiryDetected: null,
      licenseIdNumber: 'OLD123',
    });
  });

  await assertSucceeds(submitIdentity(db, 'driver1', 'driver'));
  await assertSucceeds(
    updateDoc(doc(db, 'users/driver1'), licenseSubmission()),
  );
});

test('users cannot submit identity documents to another account', async () => {
  await assertFails(
    submitIdentity(userDb('passenger2'), 'passenger1', 'passenger'),
  );
});

test('passenger cannot submit a driver license', async () => {
  await assertFails(
    updateDoc(
      doc(userDb('passenger1'), 'users/passenger1'),
      licenseSubmission(),
    ),
  );
});

test('users cannot set their status to approved or rejected', async () => {
  const db = userDb('passenger1');
  const userRef = doc(db, 'users/passenger1');

  await assertFails(updateDoc(userRef, { verificationStatus: 'approved' }));
  await assertFails(updateDoc(userRef, { verificationStatus: 'rejected' }));
  await assertFails(
    updateDoc(userRef, {
      ...identitySubmission('passenger', 1),
      verificationStatus: 'approved',
    }),
  );
});

test('attempt counter must increase by exactly one and cannot exceed three', async () => {
  const db = userDb('passenger1');
  const userRef = doc(db, 'users/passenger1');

  await assertFails(
    updateDoc(userRef, identitySubmission('passenger', 2)),
  );

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), 'users/passenger1'), {
      documentSubmissionAttempts: 2,
    });
  });

  await assertFails(
    updateDoc(userRef, identitySubmission('passenger', 1)),
  );
  await assertFails(
    updateDoc(userRef, identitySubmission('passenger', 4)),
  );
  await assertSucceeds(
    updateDoc(userRef, identitySubmission('passenger', 3)),
  );
  await assertFails(
    updateDoc(userRef, identitySubmission('passenger', 4)),
  );
});

test('unauthenticated users cannot submit documents', async () => {
  const db = testEnv.unauthenticatedContext().firestore();

  await assertFails(
    updateDoc(
      doc(db, 'users/passenger1'),
      identitySubmission('passenger', 1),
    ),
  );
});

test('administrator can still approve a submitted account', async () => {
  await assertSucceeds(submitIdentity(userDb('passenger1'), 'passenger1', 'passenger'));

  await assertSucceeds(
    updateDoc(doc(userDb('admin1'), 'users/passenger1'), {
      verificationStatus: 'approved',
    }),
  );
});

test('rejected passenger can resubmit documents without self-changing status', async () => {
  const db = userDb('passenger1');

  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), 'users/passenger1'), {
      documentSubmissionAttempts: 1,
      verificationStatus: 'rejected',
      rejectionReason: 'Please upload a clearer image.',
    });
  });

  await assertSucceeds(submitIdentity(db, 'passenger1', 'passenger'));

  const savedUser = await getDoc(doc(db, 'users/passenger1'));
  assert.equal(savedUser.data().documentSubmissionAttempts, 2);
  assert.equal(savedUser.data().verificationStatus, 'pending');
  assert.equal('rejectionReason' in savedUser.data(), false);
});
