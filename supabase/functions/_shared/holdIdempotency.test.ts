// supabase/functions/_shared/holdIdempotency.test.ts
//
// Regression coverage for the hold endpoint's idempotency-replay path,
// specifically the hourly-package defect where a replayed hold for an
// hourly package returned HTTP 500 because the replay branch passed
// validatedHourUnits: null into buildPackagePricingSummary() instead of
// deriving it from the existing hold's own persisted interval.
//
// Pure/DB-free: exercises the real exported functions from
// holdIdempotency.ts and pricingSummary.ts directly, with no network,
// no Deno.serve, and no database. Run with:
//   deno test --node-modules-dir=none supabase/functions/_shared/holdIdempotency.test.ts

import { assert, assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { deriveHourlyUnitsFromStoredInterval, idempotencyMatches } from "./holdIdempotency.ts";
import { buildPackagePricingSummary, type PackagePricingInput } from "./pricingSummary.ts";

const HOUR_MS = 3_600_000;
const PKG_ID = "d75a8942-f24e-40d7-9b66-7ee940a86a8d";
const OTHER_PKG_ID = "441d36af-a948-4a72-93ac-9f13aa5a0ca7";

function hourlyPkg(overrides: Partial<PackagePricingInput> = {}): PackagePricingInput {
  return {
    pricingType: "hourly",
    retailPriceCents: 15_000,
    currency: "USD",
    unitLabel: "hour",
    validatedHourUnits: null,
    ...overrides,
  };
}

function existingHold(startMs: number, endMs: number, servicePackageId = PKG_ID) {
  return {
    service_package_id: servicePackageId,
    requested_start_datetime: new Date(startMs),
    requested_end_datetime: new Date(endMs),
  };
}

// --- A. Hourly first-hold (fresh, non-replay) succeeds --------------------
// Sanity baseline: a fresh hourly booking (validatedHourUnits computed the
// normal way, as bookingPolicy.validateRequestedDuration would for a
// 1-hour request) prices correctly. This confirms the fix does not touch
// or regress the non-replay creation path at all.
Deno.test("A. hourly first-hold (fresh) prices correctly with an explicit validatedHourUnits", () => {
  const summary = buildPackagePricingSummary(hourlyPkg({ validatedHourUnits: 1 }));
  assertEquals(summary, {
    type: "hourly",
    currency: "USD",
    unit_price_cents: 15_000,
    unit_label: "hour",
    units: 1,
    total_cents: 15_000,
  });
});

// --- B. Exact replay returns same hold / correct pricing -------------------
// Simulates the replay branch's full logic: idempotencyMatches() confirms
// the replay corresponds to the stored hold, deriveHourlyUnitsFromStoredInterval()
// recovers units from ITS interval, and buildPackagePricingSummary() no
// longer throws. This is the exact reproduction of the Stage 2C.13 500.
Deno.test("B. exact replay of an hourly hold succeeds with correct pricing (regression for the 500 bug)", () => {
  const startMs = Date.UTC(2026, 8, 20, 18, 0, 0);
  const endMs = startMs + HOUR_MS;
  const existing = existingHold(startMs, endMs);

  const matches = idempotencyMatches(existing, PKG_ID, startMs, endMs, []);
  assert(matches, "idempotencyMatches should confirm the replay matches the stored hold");

  const unitsResult = deriveHourlyUnitsFromStoredInterval(
    existing.requested_start_datetime.getTime(),
    existing.requested_end_datetime.getTime(),
  );
  assert(unitsResult.ok, "a 1-hour stored interval must not fail closed");
  assertEquals(unitsResult.ok ? unitsResult.units : null, 1);

  const summary = buildPackagePricingSummary(
    hourlyPkg({ validatedHourUnits: unitsResult.ok ? unitsResult.units : null }),
  );
  assertEquals(summary, {
    type: "hourly",
    currency: "USD",
    unit_price_cents: 15_000,
    unit_label: "hour",
    units: 1,
    total_cents: 15_000,
  });
});

// --- C. 1-hour stored interval -> units=1 -----------------------------------
Deno.test("C. a 1-hour stored interval derives validatedHourUnits=1", () => {
  const startMs = Date.UTC(2026, 8, 20, 10, 0, 0);
  const result = deriveHourlyUnitsFromStoredInterval(startMs, startMs + HOUR_MS);
  assert(result.ok);
  assertEquals(result.ok ? result.units : null, 1);
});

// --- D. Multi-hour stored interval -> units match ---------------------------
Deno.test("D. a multi-hour stored interval derives matching validatedHourUnits", () => {
  const startMs = Date.UTC(2026, 8, 20, 10, 0, 0);
  for (const hours of [2, 3, 4, 8]) {
    const result = deriveHourlyUnitsFromStoredInterval(startMs, startMs + hours * HOUR_MS);
    assert(result.ok, `expected ${hours}h interval to derive cleanly`);
    assertEquals(result.ok ? result.units : null, hours);
  }
});

// --- E. Non-whole-hour interval -> fail closed ------------------------------
// This is the invariant-violation guard: a stored hourly hold whose
// interval is NOT an exact multiple of 3,600,000ms must never be silently
// rounded. It must fail closed (ok: false) rather than fabricate a unit
// count -- verified for a partial-hour overage, a partial-hour shortage,
// and a zero/negative duration.
Deno.test("E. a non-whole-hour stored interval fails closed instead of rounding", () => {
  const startMs = Date.UTC(2026, 8, 20, 10, 0, 0);

  const ninetyMinutes = deriveHourlyUnitsFromStoredInterval(startMs, startMs + 90 * 60_000);
  assertEquals(ninetyMinutes.ok, false);

  const oneMinuteOver = deriveHourlyUnitsFromStoredInterval(startMs, startMs + HOUR_MS + 60_000);
  assertEquals(oneMinuteOver.ok, false);

  const oneMinuteUnder = deriveHourlyUnitsFromStoredInterval(startMs, startMs + HOUR_MS - 60_000);
  assertEquals(oneMinuteUnder.ok, false);

  const zeroDuration = deriveHourlyUnitsFromStoredInterval(startMs, startMs);
  assertEquals(zeroDuration.ok, false);

  const negativeDuration = deriveHourlyUnitsFromStoredInterval(startMs, startMs - HOUR_MS);
  assertEquals(negativeDuration.ok, false);
});

Deno.test("E2. buildPackagePricingSummary still throws (fails closed) if validatedHourUnits is ever null for hourly", () => {
  assertThrows(() => buildPackagePricingSummary(hourlyPkg({ validatedHourUnits: null })));
});

// --- F. Fixed-price replay still works (never touches validatedHourUnits) --
Deno.test("F. a fixed-price package replay is unaffected by the hourly fix", () => {
  const summary = buildPackagePricingSummary({
    pricingType: "fixed",
    retailPriceCents: 45_000,
    currency: "USD",
    unitLabel: null,
    validatedHourUnits: null,
  });
  assertEquals(summary, { type: "fixed", currency: "USD", total_cents: 45_000 });
});

Deno.test("F2. starting_at and custom_quote package replays are unaffected by the hourly fix", () => {
  const startingAt = buildPackagePricingSummary({
    pricingType: "starting_at",
    retailPriceCents: 20_000,
    currency: "USD",
    unitLabel: null,
    validatedHourUnits: null,
  });
  assertEquals(startingAt, { type: "starting_at", currency: "USD", starting_at_cents: 20_000 });

  const customQuote = buildPackagePricingSummary({
    pricingType: "custom_quote",
    retailPriceCents: null,
    currency: "USD",
    unitLabel: null,
    validatedHourUnits: null,
  });
  assertEquals(customQuote, { type: "custom_quote" });
});

// --- G. Mismatched replay is still rejected ---------------------------------
// Confirms idempotencyMatches() -- the sole authority that a replay
// corresponds to the stored hold -- is completely untouched by this fix:
// a different package, a different start/end, or any add-on on the retry
// must still be rejected before deriveHourlyUnitsFromStoredInterval() is
// ever reached.
Deno.test("G. idempotencyMatches still rejects mismatched replays", () => {
  const startMs = Date.UTC(2026, 8, 20, 10, 0, 0);
  const endMs = startMs + HOUR_MS;
  const existing = existingHold(startMs, endMs);

  assertEquals(idempotencyMatches(existing, OTHER_PKG_ID, startMs, endMs, []), false, "different package");
  assertEquals(idempotencyMatches(existing, PKG_ID, startMs + 60_000, endMs, []), false, "different start");
  assertEquals(idempotencyMatches(existing, PKG_ID, startMs, endMs + 60_000, []), false, "different end");
  assertEquals(
    idempotencyMatches(existing, PKG_ID, startMs, endMs, ["some-addon-id"]),
    false,
    "add-ons present on retry",
  );
  assertEquals(idempotencyMatches(existing, PKG_ID, startMs, endMs, []), true, "exact match sanity check");
});
