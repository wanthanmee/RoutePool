const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

// Load the actual matching functions from index.js.
// Firebase triggers are NOT executed during these unit tests.
const source = fs.readFileSync(
  path.join(__dirname, 'index.js'),
  'utf8'
);

// Extract a named JavaScript function, including its body.
function extractFunction(name) {
  const start = source.indexOf(`function ${name}(`);

  if (start === -1) {
    throw new Error(`Function ${name} not found in index.js`);
  }

  const openingBrace = source.indexOf('{', start);
  let depth = 0;

  for (let i = openingBrace; i < source.length; i++) {
    if (source[i] === '{') depth++;
    if (source[i] === '}') depth--;

    if (depth === 0) {
      return source.slice(start, i + 1);
    }
  }

  throw new Error(`Could not extract ${name}`);
}

// Run the real matching logic in an isolated context.
const context = vm.createContext({
  MAX_PASSENGERS: 12,
  MAX_DROPOFF_DIFF_KM: 5,
});

for (const name of [
  'toRad',
  'haversineKm',
  'isValidRequest',
  'areRequestsCompatible',
  'canJoinGroup',
]) {
  vm.runInContext(extractFunction(name), context);
}

// Generate valid mock ride requests.
function makeRequest({
  passengerId = 'passengerA',
  dropoffLat = 5.4141,
  dropoffLon = 100.3288,
  passengerCount = 1,
} = {}) {
  return {
    passengerId,
    pickupHubId: '12001010',
    pickupName: 'Apartmen Taman Bendera',
    pickupLat: 5.4141,
    pickupLon: 100.3288,
    dropoffLat,
    dropoffLon,
    passengerCount,
    departureTime: {
      toMillis: () => Date.now(),
    },
  };
}

// TEST 3: Destination distance <= 5 km
test('Test 3: Destinations within 5 km are compatible', () => {
  const a = makeRequest({ passengerId: 'A' });

  const b = makeRequest({
    passengerId: 'B',
    dropoffLat: 5.4411,
  });

  assert.equal(context.areRequestsCompatible(a, b), true);
});

// TEST 4: Destination distance > 5 km
test('Test 4: Destinations beyond 5 km are incompatible', () => {
  const a = makeRequest({ passengerId: 'A' });

  const b = makeRequest({
    passengerId: 'B',
    dropoffLat: 5.4771,
  });

  assert.equal(context.areRequestsCompatible(a, b), false);
});

// TEST 5: Group capacity exceeds 12
test('Test 5: Group capacity exceeding 12 is rejected', () => {
  const existingMembers = [
    makeRequest({
      passengerId: 'A',
      passengerCount: 10,
    }),
  ];

  const candidate = makeRequest({
    passengerId: 'B',
    passengerCount: 3,
  });

  assert.equal(
    context.canJoinGroup(candidate, existingMembers, 12),
    false
  );
});

// TEST 6: Same passenger requests
test('Test 6: Same passenger cannot match with themselves', () => {
  const a = makeRequest({ passengerId: 'sameUser' });
  const b = makeRequest({ passengerId: 'sameUser' });

  assert.equal(context.areRequestsCompatible(a, b), false);
});