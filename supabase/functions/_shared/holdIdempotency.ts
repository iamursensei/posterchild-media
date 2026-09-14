// supabase/functions/_shared/holdIdempotency.ts
//
// Pure, DB-free helpers for the hold endpoint's idempotency-replay path.
// Split out of hold/index.ts (rather than left inline) for the same
// reason pricingSummary.ts and bookingPolicy.ts are separate modules:
// no Deno.serve/db.ts import chain, so these can be unit-tested directly.

/** The subset of a stored booking_holds row idempotencyMatches needs. */
export interface IdempotencyExistingHold {
  service_package_id: string;
  requested_start_datetime: Date;
  requested_end_datetime: Date;
}

/**
 * A stored idempotency key is treated as a safe replay ONLY when
 * service_package_id/start/end match exactly AND the current request
 * carries no add-ons. booking_holds does not persist which
 * service_addon_ids were part of the original request, so an add-on-
 * bearing retry can never be verified against it -- rather than
 * pretend otherwise, any such retry is rejected as a conflict.
 */
export function idempotencyMatches(
  existing: IdempotencyExistingHold,
  servicePackageId: string,
  startMs: number,
  endMs: number,
  serviceAddonIds: string[],
): boolean {
  if (serviceAddonIds.length > 0) return false;
  if (existing.service_package_id !== servicePackageId) return false;
  if (existing.requested_start_datetime.getTime() !== startMs) return false;
  if (existing.requested_end_datetime.getTime() !== endMs) return false;
  return true;
}

/**
 * Recovers the validated hour-unit count for an hourly package's replay
 * response from the EXISTING hold's own persisted interval -- never from
 * a newly supplied duration, since idempotencyMatches() above is the
 * sole authority that the replay request corresponds to this exact
 * stored hold. Fails closed rather than rounding if the stored interval
 * is somehow not an exact whole-hour multiple -- that would mean an
 * hourly hold was created with a non-whole-hour duration, which
 * validateRequestedDuration should already have prevented at creation
 * time; silently rounding here would mask that invariant violation
 * instead of surfacing it.
 */
export function deriveHourlyUnitsFromStoredInterval(
  startMs: number,
  endMs: number,
): { ok: true; units: number } | { ok: false; detail: string } {
  const durationMs = endMs - startMs;
  if (durationMs <= 0 || durationMs % 3_600_000 !== 0) {
    return {
      ok: false,
      detail: `stored hold interval is not an exact whole-hour multiple (durationMs=${durationMs})`,
    };
  }
  return { ok: true, units: durationMs / 3_600_000 };
}
