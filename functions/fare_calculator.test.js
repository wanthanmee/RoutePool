const test = require('node:test');
const assert = require('node:assert/strict');

const {
  soloFareSen,
  bookingFareSen,
  computeShares,
} = require('./fare_calculator');

// TEST 1: Zero Distance
test('Test 1: Zero Distance', () => {
  const result = soloFareSen(0);

  assert.equal(result, 600);
});

// TEST 2: Short Distance
test('Test 2: Short Distance', () => {
  const result = soloFareSen(1);

  assert.equal(result, 600);
});

// TEST 3: Long Distance
test('Test 3: Long Distance', () => {
  const result = soloFareSen(10);

  // RM3 + (10 × RM1.20) = RM15.00
  assert.equal(result, 1500);
});

// TEST 4: Fare Rounding
test('Test 4: Fare Rounding', () => {
  const result = soloFareSen(3.8);

  // RM3 + (3.8 × RM1.20) = RM7.56
  // Rounded to RM7.60
  assert.equal(result, 760);
});

// TEST 5: Multiple Passengers
test('Test 5: Multiple Passengers', () => {
  const soloFare = soloFareSen(10);

  const result = bookingFareSen(soloFare, 3);

  // RM15 × [1 + 0.5 × (3 - 1)]
  // RM15 × 2 = RM30
  assert.equal(result, 3000);
});

// TEST 6: Matched Fare Allocation
test('Test 6: Matched Fare Allocation', () => {
  const members = [
    {
      id: 'booking1',
      soloFareSen: 1500,
      passengerCount: 1,
    },
    {
      id: 'booking2',
      soloFareSen: 1500,
      passengerCount: 2,
    },
  ];

  const shares = computeShares(members);

  // Booking 1: RM15 × 0.8 = RM12
  assert.equal(shares.booking1, 1200);

  // Booking 2: RM22.50 × 0.8 = RM18
  assert.equal(shares.booking2, 1800);

  const totalFare = Object.values(shares)
    .reduce((sum, fare) => sum + fare, 0);

  // Total = RM30
  assert.equal(totalFare, 3000);
});