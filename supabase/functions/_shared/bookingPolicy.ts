// supabase/functions/_shared/bookingPolicy.ts
//
// Single canonical source of Stage 2 scheduling business policy: buffer
// minutes, minimum lead time, the booking horizon, and requested-duration
// validation. Every value here mirrors the Phase 2A Stage 2 LOCKED
// decisions exactly -- nothing here is invented or silently defaulted.
//
// Fail-closed by construction: an unrecognized service slug, or a known
// service with no buffer entry for a given resource role, returns an
// explicit failure rather than a 0-minute/no-op default. Guessing a
// buffer or lead time wrong is a real scheduling-safety risk, not a
// cosmetic one.
//
// Buffers are keyed by (service_slug, resource_role) rather than
// service_slug alone specifically so a future service that needs
// distinct buffers on two different resource roles in the SAME booking
// (e.g. a portrait session that also reserves the studio) can add a
// second entry under the same service slug without restructuring this
// module or its callers.
//
// Pure, DB-free logic lives here deliberately so it can be exercised by
// a future test suite without a live database connection.

import type postgres from "npm:postgres@3";

export const SCHEDULING_TIMEZONE = "America/New_York";
export const BOOKING_HORIZON_DAYS = 90;

export interface BufferMinutes {
  beforeMinutes: number;
  afterMinutes: number;
}

type BufferTable = Record<string, Record<string, BufferMinutes>>;

const BUFFER_POLICY: BufferTable = {
  "portraits-milestones": {
    photographer: { beforeMinutes: 0, afterMinutes: 30 },
  },
  "real-estate-media": {
    photographer: { beforeMinutes: 0, afterMinutes: 30 },
  },
  "events": {
    photographer: { beforeMinutes: 30, afterMinutes: 30 },
  },
  "corporate-commercial": {
    photographer: { beforeMinutes: 30, afterMinutes: 30 },
  },
  "studio-rental": {
    studio: { beforeMinutes: 0, afterMinutes: 15 },
  },
};

const LEAD_TIME_HOURS: Record<string, number> = {
  "portraits-milestones": 24,
  "studio-rental": 12,
  "events": 48,
  "corporate-commercial": 48,
  "real-estate-media": 24,
};

export type PolicyLookup<T> =
  | { ok: true; value: T }
  | { ok: false; reason: string };

/**
 * Fails closed when the service slug is not one of the five locked
 * services, or when that service has no buffer entry for the requested
 * resource role -- an unconfigured (service, role) pair is never
 * silently treated as a zero buffer.
 */
export function resolveBufferMinutes(
  serviceSlug: string,
  resourceRole: string,
): PolicyLookup<BufferMinutes> {
  const forService = BUFFER_POLICY[serviceSlug];
  if (!forService) {
    return { ok: false, reason: `unknown_service_slug:${serviceSlug}` };
  }
  const buffer = forService[resourceRole];
  if (!buffer) {
    return {
      ok: false,
      reason: `unconfigured_buffer_for_role:${serviceSlug}:${resourceRole}`,
    };
  }
  return { ok: true, value: buffer };
}

export function resolveLeadTimeHours(serviceSlug: string): PolicyLookup<number> {
  const hours = LEAD_TIME_HOURS[serviceSlug];
  if (hours === undefined) {
    return { ok: false, reason: `unknown_service_slug:${serviceSlug}` };
  }
  return { ok: true, value: hours };
}

/**
 * Expands a client-visible interval (already absolute instants in
 * milliseconds) by a resource role's buffer. Pure millisecond
 * arithmetic on an already-resolved instant -- no DST handling is
 * needed here (unlike constructing an instant FROM a naive local
 * date+time), since adding/subtracting minutes from an absolute instant
 * is correct regardless of calendar/timezone.
 */
export function applyBuffer(
  clientStartMs: number,
  clientEndMs: number,
  buffer: BufferMinutes,
): { effectiveStartMs: number; effectiveEndMs: number } {
  return {
    effectiveStartMs: clientStartMs - buffer.beforeMinutes * 60_000,
    effectiveEndMs: clientEndMs + buffer.afterMinutes * 60_000,
  };
}

/**
 * Day 1 = today (local America/New_York calendar date), Day 90 =
 * Day1+89 -- the exact horizon definition used to materialize Stage 1C's
 * available_window rows. Calendar-day arithmetic is done in Postgres
 * (AT TIME ZONE), not JS Date math, for the same DST-safety reasons as
 * the seed scripts -- this module never reimplements timezone-aware
 * calendar-date arithmetic in JS.
 */
export async function isWithinBookingHorizon(
  tx: postgres.TransactionSql,
  requestedStartIso: string,
): Promise<boolean> {
  const rows = await tx<{ day_offset: number }[]>`
    select (
      (${requestedStartIso}::timestamptz at time zone ${SCHEDULING_TIMEZONE})::date
      - (now() at time zone ${SCHEDULING_TIMEZONE})::date
    )::int as day_offset
  `;
  const dayOffset = rows[0].day_offset;
  return dayOffset >= 0 && dayOffset <= BOOKING_HORIZON_DAYS - 1;
}

/** Pure, DB-free lead-time check -- both timestamps are absolute instants (ms). */
export function isLeadTimeSatisfied(
  requestedStartMs: number,
  nowMs: number,
  leadTimeHours: number,
): boolean {
  return requestedStartMs >= nowMs + leadTimeHours * 3600_000;
}

export interface DurationValidationInput {
  pricingType: string;
  durationMinutesColumn: number | null; // service_packages.duration_minutes
  minimumUnits: number | null; // service_packages.minimum_units
  requestedDurationMs: number;
}

export type DurationValidationResult =
  | { ok: true; validatedHourUnits: number | null }
  | {
      ok: false;
      reason:
        | "duration_not_whole_minutes"
        | "exact_duration_mismatch"
        | "not_whole_hour_multiple"
        | "below_minimum_units"
        | "minimum_units_misconfigured";
      detail?: string;
    };

/**
 * Fixed/exact packages (duration_minutes set) require an exact match.
 * Hourly packages (pricing_type = 'hourly', duration_minutes null)
 * require a whole-hour multiple meeting minimum_units. A hourly package
 * with minimum_units unexpectedly NULL fails closed rather than silently
 * assuming 1 -- this is a catalog-configuration gap, not a client error.
 * Any other combination (e.g. a custom_quote package with neither) has
 * no duration constraint here.
 */
export function validateRequestedDuration(
  input: DurationValidationInput,
): DurationValidationResult {
  const { pricingType, durationMinutesColumn, minimumUnits, requestedDurationMs } = input;

  if (requestedDurationMs % 60_000 !== 0) {
    return { ok: false, reason: "duration_not_whole_minutes" };
  }
  const requestedMinutes = requestedDurationMs / 60_000;

  if (durationMinutesColumn !== null) {
    if (requestedMinutes !== durationMinutesColumn) {
      return {
        ok: false,
        reason: "exact_duration_mismatch",
        detail: `expected_minutes=${durationMinutesColumn}`,
      };
    }
    return { ok: true, validatedHourUnits: null };
  }

  if (pricingType === "hourly") {
    if (minimumUnits === null) {
      return { ok: false, reason: "minimum_units_misconfigured" };
    }
    if (requestedMinutes % 60 !== 0) {
      return { ok: false, reason: "not_whole_hour_multiple" };
    }
    const hours = requestedMinutes / 60;
    if (hours < minimumUnits) {
      return {
        ok: false,
        reason: "below_minimum_units",
        detail: `minimum_units=${minimumUnits}`,
      };
    }
    return { ok: true, validatedHourUnits: hours };
  }

  return { ok: true, validatedHourUnits: null };
}
