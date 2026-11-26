const BASE_FARE_SEN = 300;
const PER_KM_SEN = 120;
const MIN_FARE_SEN = 600;
const MAX_PASSENGERS = 12;

const ADDITIONAL_PASSENGER_RATE = 0.50;
const MATCHED_BOOKING_DISCOUNT = 0.20;

function soloFareSen(km) {
  const raw = BASE_FARE_SEN + PER_KM_SEN * km;

  return Math.max(
    MIN_FARE_SEN,
    Math.round(raw / 10) * 10
  );
}

function bookingFareSen(soloFare, passengerCount) {
  if (
    !Number.isInteger(passengerCount) ||
    passengerCount < 1 ||
    passengerCount > MAX_PASSENGERS
  ) {
    throw new Error('Invalid booking passenger count.');
  }

  const multiplier =
    1 + (passengerCount - 1) * ADDITIONAL_PASSENGER_RATE;

  const rawFare = soloFare * multiplier;

  return Math.round(rawFare / 10) * 10;
}

function computeShares(members) {
  if (members.length === 0) return {};

  const shares = {};

  for (const member of members) {
    const originalBookingFare = bookingFareSen(
      member.soloFareSen,
      member.passengerCount
    );

    const discountedFare =
      originalBookingFare * (1 - MATCHED_BOOKING_DISCOUNT);

    shares[member.id] =
      Math.round(discountedFare / 10) * 10;
  }

  return shares;
}

module.exports = {
  soloFareSen,
  bookingFareSen,
  computeShares,
};