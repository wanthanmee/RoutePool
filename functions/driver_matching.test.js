const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(
  path.join(__dirname, 'index.js'),
  'utf8'
);

// Extract the actual driver selection function from index.js.
const start = source.indexOf(
  'async function findNearestEligibleDrivers('
);

const end = source.indexOf(
  'async function reserveDriverOffer(',
  start
);

if (start === -1 || end === -1) {
  throw new Error('Driver matching function not found.');
}

const driverMatchingCode = source.slice(start, end);

const now = Date.now();

function makeDriver({
  id = 'driver1',
  online = true,
  approved = true,
  vehicleApproved = true,
  vehicleActive = true,
  seats = 4,
  lat = 5.4141,
  lon = 100.3288,
  accuracy = 10,
  locationAgeMs = 10000,
} = {}) {
  return {
    id,
    user: {
      isAvailable: online,
      verificationStatus: approved ? 'approved' : 'pending',
    },
    vehicle: {
      verificationStatus: vehicleApproved
        ? 'approved'
        : 'pending',
      isActive: vehicleActive,
      seatCapacity: seats,
    },
    location: {
      lat,
      lon,
      accuracy,
      updatedAt: {
        toMillis: () => now - locationAgeMs,
      },
    },
  };
}

function makeTrip(passengers = 2) {
  return {
    pickupLat: 5.4141,
    pickupLon: 100.3288,
    totalPassengers: passengers,
  };
}

// Simulate Firestore reads without connecting to Firebase.
async function findDrivers(drivers, trip = makeTrip()) {
  const driverMap = new Map(
    drivers.map((driver) => [driver.id, driver])
  );

  const db = {
    collection(name) {
      if (name === 'users') {
        return {
          where() {
            return {
              async get() {
                return {
                  docs: drivers
                    .filter((d) => d.user.isAvailable)
                    .map((d) => ({
                      id: d.id,
                      data: () => d.user,
                    })),
                };
              },
            };
          },
        };
      }

      return {
        doc(id) {
          return {
            async get() {
              const driver = driverMap.get(id);

              if (!driver) return { exists: false };

              const data = name === 'vehicles'
                ? driver.vehicle
                : driver.location;

              return {
                exists: true,
                data: () => data,
              };
            },
          };
        },
      };
    },
  };

  const context = vm.createContext({
    db,
    Date,
    Number,
    MAX_PASSENGERS: 12,
    DRIVER_LOCATION_MAX_AGE_MS: 90000,
    DRIVER_MAX_ACCURACY_METERS: 100,
  });

  const distanceCode = source.slice(
    source.indexOf('function toRad('),
    source.indexOf('function roadDistanceKm(')
  );

  vm.runInContext(distanceCode, context);
  vm.runInContext(driverMatchingCode, context);

  const result = await vm.runInContext(
    `findNearestEligibleDrivers(${JSON.stringify(trip)})`,
    context
  );

  return Array.from(result, (driver) => driver.driverId);
}

// TEST 1: Offline driver is excluded
test('Test 1: Offline driver is excluded', async () => {
  const drivers = [
    makeDriver({ online: false }),
  ];

  const result = await findDrivers(drivers);

  assert.deepEqual(result, []);
});

// TEST 2: Unapproved driver is excluded
test('Test 2: Unapproved driver is excluded', async () => {
  const drivers = [
    makeDriver({ approved: false }),
  ];

  const result = await findDrivers(drivers);

  assert.deepEqual(result, []);
});

// TEST 3: Unapproved vehicle is excluded
test('Test 3: Unapproved vehicle is excluded', async () => {
  const drivers = [
    makeDriver({ vehicleApproved: false }),
  ];

  const result = await findDrivers(drivers);

  assert.deepEqual(result, []);
});

// TEST 4: Inactive vehicle is excluded
test('Test 4: Insufficient seat capacity is rejected', async () => {
  const drivers = [
    makeDriver({ seats: 3 }),
  ];

  const result = await findDrivers(
    drivers,
    makeTrip(4)
  );

  assert.deepEqual(result, []);
});

// TEST 5: Invalid GPS data excludes driver
test('Test 5: Invalid GPS data excludes driver', async () => {
  const scenarios = [
    makeDriver({ lat: 95 }),
    makeDriver({ locationAgeMs: 120000 }),
    makeDriver({ accuracy: 150 }),
  ];

  for (const driver of scenarios) {
    const result = await findDrivers([driver]);
    assert.deepEqual(result, []);
  }
});

// TEST 6: Nearest eligible driver is prioritized
test('Test 6: Nearest eligible driver is prioritized', async () => {
  const drivers = [
    makeDriver({
      id: 'farDriver',
      lat: 5.4500,
    }),
    makeDriver({
      id: 'nearDriver',
      lat: 5.4150,
    }),
  ];

  const result = await findDrivers(drivers);

  assert.deepEqual(result, [
    'nearDriver',
    'farDriver',
  ]);
});