// supabase/functions/hold/index.ts
//
// Public, browser-callable. Creates a time-limited hold (booking_holds
// row) plus one buffer-expanded resource_reservations row per required
// resource, inside a single transaction. Never exposes resource
// identity, role, or internal reason codes to the caller.
//
// UNDEPLOYED (Stage 2 local implementation only). This is a write
// endpoint consuming a scarce, exclusive resource pool -- unlike the
// read-only availability endpoint, it MUST NOT go to public production
// without a real, durable rate-limiting mechanism in front of it. An
// in-memory per-IP counter in a serverless/Edge Function instance is
// not a durable global store (each cold instance starts a fresh
// counter, and concurrent instances don't share state), so none is
// implemented here -- inventing one and calling it production-safe
// would be worse than having none, since it would look like a
// mitigation without being one.
//
// DEPLOYMENT BLOCKER: do not deploy this function publicly until a real
// rate-limiting mechanism (provider/threshold TBD -- explicitly deferred
// per the Stage 2 lock) is in place in front of it.

import { corsHeaders, handlePreflight, isOriginAllowed } from "../_shared/cors.ts";
import { withTransaction } from "../_shared/db.ts";
import { jsonErrorResponse, mapError } from "../_shared/errors.ts";
import { lazyExpireStaleHolds } from "../_shared/lazyExpire.ts";
import { aggregateRequiredRoles, selectEligibleResourceIds } from "../_shared/availabilityResolver.ts";
import {
  applyBuffer,
  isLeadTimeSatisfied,
  isWithinBookingHorizon,
  resolveBufferMinutes,
  resolveLeadTimeHours,
  validateRequestedDuration,
} from "../_shared/bookingPolicy.ts";
import {
  buildAddonPricingSummary,
  buildPackagePricingSummary,
  type AddonPricingSummary,
  type CatalogPricingType,
  type PackagePricingInput,
  type PackagePricingSummary,
} from "../_shared/pricingSummary.ts";
import { parseStrictIsoTimestamp } from "../_shared/strictDatetime.ts";
import type postgres from "npm:postgres@3";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_REQUEST_DURATION_MS = 24 * 60 * 60 * 1000; // sanity bound only, not a business rule
const MAX_BODY_BYTES = 4096; // this payload is a handful of UUIDs + timestamps -- generous but conservative
const MAX_IDEMPOTENCY_KEY_LENGTH = 200; // sanity bound only, not a business rule
const ALLOWED_BODY_FIELDS = new Set([
  "service_package_id",
  "service_addon_ids",
  "requested_start_datetime",
  "requested_end_datetime",
  "idempotency_key",
]);

function badRequest(message: string, headers: HeadersInit): Response {
  return new Response(
    JSON.stringify({ error: "invalid_request", message }),
    { status: 422, headers: { "Content-Type": "application/json", ...headers } },
  );
}

function errorResponse(status: number, error: string, message: string, headers: HeadersInit): Response {
  return new Response(
    JSON.stringify({ error, message }),
    { status, headers: { "Content-Type": "application/json", ...headers } },
  );
}

interface PackageRow {
  id: string;
  service_id: string;
  service_slug: string;
  pricing_type: CatalogPricingType;
  retail_price_cents: number | null;
  currency: string;
  unit_label: string | null;
  duration_minutes: number | null;
  minimum_units: number | null;
  checkout_hold_minutes: number;
}

interface AddonRow {
  id: string;
  applicable_service_id: string | null;
  pricing_type: CatalogPricingType;
  retail_price_cents: number | null;
  currency: string;
  unit_label: string | null;
}

interface ExistingHoldRow {
  id: string;
  service_package_id: string;
  requested_start_datetime: Date;
  requested_end_datetime: Date;
  status: string;
  expires_at: Date;
}

/**
 * A stored idempotency key is treated as a safe replay ONLY when
 * service_package_id/start/end match exactly AND the current request
 * carries no add-ons. booking_holds does not persist which
 * service_addon_ids were part of the original request, so an add-on-
 * bearing retry can never be verified against it -- rather than
 * pretend otherwise, any such retry is rejected as a conflict.
 */
function idempotencyMatches(
  existing: ExistingHoldRow,
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

async function fetchPackagePricingFieldsUnfiltered(
  tx: postgres.TransactionSql,
  servicePackageId: string,
): Promise<Omit<PackagePricingInput, "validatedHourUnits">> {
  const rows = await tx<
    Pick<PackageRow, "pricing_type" | "retail_price_cents" | "currency" | "unit_label">[]
  >`
    select pricing_type, retail_price_cents, currency, unit_label
    from service_packages
    where id = ${servicePackageId}
  `;
  if (rows.length === 0) {
    // service_packages.id is ON DELETE RESTRICT from booking_holds, so
    // this should be unreachable -- fail loudly rather than guess.
    throw new Error(`internal_invariant_violated: package ${servicePackageId} missing for existing hold`);
  }
  const row = rows[0];
  // Mapped explicitly here (not spread) -- the DB row uses snake_case
  // column names, PackagePricingInput uses camelCase field names, and a
  // blind spread of one into the other type-checks as missing fields
  // rather than silently mismatching at runtime, which is exactly what
  // deno check caught during this validation pass.
  return {
    pricingType: row.pricing_type,
    retailPriceCents: row.retail_price_cents,
    currency: row.currency,
    unitLabel: row.unit_label,
  };
}

type TxOutcome =
  | { kind: "invalid_package" }
  | { kind: "invalid_addon" }
  | { kind: "duration_invalid"; reason: string; detail?: string }
  | { kind: "policy_misconfigured"; detail: string }
  | { kind: "outside_horizon" }
  | { kind: "lead_time_violation" }
  | { kind: "slot_unavailable" }
  | { kind: "idempotency_conflict" }
  | { kind: "idempotency_retired" }
  | {
      kind: "success";
      created: boolean;
      holdId: string;
      expiresAt: Date;
      requestedStart: string;
      requestedEnd: string;
      servicePackageId: string;
      // Built INSIDE the transaction (not after it resolves) so that if
      // pricing-summary construction ever throws -- e.g. a catalog
      // invariant violation -- the whole transaction rolls back instead
      // of leaving a committed hold the client was never told about.
      packagePricingSummary: PackagePricingSummary;
      addonPricingSummary: AddonPricingSummary[];
    };

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin");

  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  const headers = corsHeaders(origin);

  if (!isOriginAllowed(origin)) {
    return new Response(JSON.stringify({ error: "forbidden" }), {
      status: 403,
      headers: { "Content-Type": "application/json", ...headers },
    });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json", ...headers },
    });
  }

  let rawBody: ArrayBuffer;
  try {
    rawBody = await req.arrayBuffer();
  } catch {
    return badRequest("Request body could not be read.", headers);
  }
  if (rawBody.byteLength > MAX_BODY_BYTES) {
    return badRequest("Request body exceeds the maximum allowed size.", headers);
  }

  let body: unknown;
  try {
    body = JSON.parse(new TextDecoder().decode(rawBody));
  } catch {
    return badRequest("Request body must be valid JSON.", headers);
  }

  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return badRequest("Request body must be a JSON object.", headers);
  }
  const record = body as Record<string, unknown>;

  for (const key of Object.keys(record)) {
    if (!ALLOWED_BODY_FIELDS.has(key)) {
      return badRequest(`Unrecognized field: ${key}`, headers);
    }
  }

  const servicePackageId = record.service_package_id;
  if (typeof servicePackageId !== "string" || !UUID_RE.test(servicePackageId)) {
    return badRequest("service_package_id must be a valid UUID.", headers);
  }

  const serviceAddonIdsRaw = record.service_addon_ids;
  const serviceAddonIds = serviceAddonIdsRaw === undefined ? [] : serviceAddonIdsRaw;
  if (
    !Array.isArray(serviceAddonIds) ||
    !serviceAddonIds.every((v) => typeof v === "string" && UUID_RE.test(v))
  ) {
    return badRequest("service_addon_ids must be an array of UUIDs.", headers);
  }
  if (new Set(serviceAddonIds).size !== serviceAddonIds.length) {
    return badRequest("service_addon_ids must not contain duplicates.", headers);
  }

  const requestedStart = record.requested_start_datetime;
  const requestedEnd = record.requested_end_datetime;
  if (typeof requestedStart !== "string") {
    return badRequest(
      "requested_start_datetime must be ISO-8601 with an explicit timezone offset (Z or +HH:MM).",
      headers,
    );
  }
  if (typeof requestedEnd !== "string") {
    return badRequest(
      "requested_end_datetime must be ISO-8601 with an explicit timezone offset (Z or +HH:MM).",
      headers,
    );
  }
  const parsedStart = parseStrictIsoTimestamp(requestedStart);
  if (!parsedStart.ok) {
    return badRequest(
      "requested_start_datetime must be ISO-8601 with an explicit timezone offset (Z or +HH:MM).",
      headers,
    );
  }
  const parsedEnd = parseStrictIsoTimestamp(requestedEnd);
  if (!parsedEnd.ok) {
    return badRequest(
      "requested_end_datetime must be ISO-8601 with an explicit timezone offset (Z or +HH:MM).",
      headers,
    );
  }

  const startMs = parsedStart.ms;
  const endMs = parsedEnd.ms;
  if (endMs <= startMs) {
    return badRequest("requested_end_datetime must be after requested_start_datetime.", headers);
  }
  if (endMs - startMs > MAX_REQUEST_DURATION_MS) {
    return badRequest("Requested duration exceeds the maximum allowed.", headers);
  }

  const idempotencyKey = record.idempotency_key;
  if (typeof idempotencyKey !== "string" || idempotencyKey.length === 0) {
    return badRequest("idempotency_key is required and must be a non-empty string.", headers);
  }
  if (idempotencyKey.length > MAX_IDEMPOTENCY_KEY_LENGTH) {
    return badRequest("idempotency_key exceeds the maximum allowed length.", headers);
  }

  try {
    const outcome = await withTransaction<TxOutcome>(async (tx) => {
      await lazyExpireStaleHolds(tx);

      // --- Idempotency fast path -------------------------------------
      // Checked BEFORE package/add-on validation so that a genuine
      // replay is reported correctly regardless of any catalog change
      // that happened after the original hold was created -- a replay
      // reflects "what already happened," not "would this succeed if
      // attempted fresh right now."
      const existingRows = await tx<ExistingHoldRow[]>`
        select id, service_package_id, requested_start_datetime, requested_end_datetime, status, expires_at
        from booking_holds
        where idempotency_key = ${idempotencyKey}
      `;
      if (existingRows.length > 0) {
        const existing = existingRows[0];
        if (existing.status === "active") {
          if (idempotencyMatches(existing, servicePackageId, startMs, endMs, serviceAddonIds as string[])) {
            const pkgFields = await fetchPackagePricingFieldsUnfiltered(tx, existing.service_package_id);
            return {
              kind: "success",
              created: false,
              holdId: existing.id,
              expiresAt: existing.expires_at,
              requestedStart: existing.requested_start_datetime.toISOString(),
              requestedEnd: existing.requested_end_datetime.toISOString(),
              servicePackageId: existing.service_package_id,
              packagePricingSummary: buildPackagePricingSummary({ ...pkgFields, validatedHourUnits: null }),
              addonPricingSummary: [],
            };
          }
          return { kind: "idempotency_conflict" };
        }
        return { kind: "idempotency_retired" };
      }

      // --- Package validation ------------------------------------------
      const pkgRows = await tx<PackageRow[]>`
        select
          sp.id, sp.service_id, s.slug as service_slug, sp.pricing_type,
          sp.retail_price_cents, sp.currency, sp.unit_label, sp.duration_minutes,
          sp.minimum_units, sp.checkout_hold_minutes
        from service_packages sp
        join services s on s.id = sp.service_id
        where sp.id = ${servicePackageId}
          and sp.is_active = true
          and sp.is_bookable = true
      `;
      if (pkgRows.length === 0) {
        return { kind: "invalid_package" };
      }
      const pkg = pkgRows[0];

      // --- Add-on validation ---------------------------------------------
      let addons: AddonRow[] = [];
      if (serviceAddonIds.length > 0) {
        addons = await tx<AddonRow[]>`
          select id, applicable_service_id, pricing_type, retail_price_cents, currency, unit_label
          from service_addons
          where id in ${tx(serviceAddonIds as string[])}
            and is_active = true
            and is_bookable = true
        `;
        if (addons.length !== serviceAddonIds.length) {
          return { kind: "invalid_addon" };
        }
        const hasInapplicable = addons.some(
          (a) => a.applicable_service_id !== null && a.applicable_service_id !== pkg.service_id,
        );
        if (hasInapplicable) {
          return { kind: "invalid_addon" };
        }
      }

      // --- Duration validation ---------------------------------------
      const durationResult = validateRequestedDuration({
        pricingType: pkg.pricing_type,
        durationMinutesColumn: pkg.duration_minutes,
        minimumUnits: pkg.minimum_units,
        requestedDurationMs: endMs - startMs,
      });
      if (!durationResult.ok) {
        if (durationResult.reason === "minimum_units_misconfigured") {
          return {
            kind: "policy_misconfigured",
            detail: `hourly package ${pkg.id} has NULL minimum_units`,
          };
        }
        return { kind: "duration_invalid", reason: durationResult.reason, detail: durationResult.detail };
      }
      const validatedHourUnits = durationResult.validatedHourUnits;

      // --- Horizon validation ------------------------------------------
      const withinHorizon = await isWithinBookingHorizon(tx, requestedStart);
      if (!withinHorizon) {
        return { kind: "outside_horizon" };
      }

      // --- Lead-time validation ----------------------------------------
      const leadTimeLookup = resolveLeadTimeHours(pkg.service_slug);
      if (!leadTimeLookup.ok) {
        return { kind: "policy_misconfigured", detail: leadTimeLookup.reason };
      }
      const [{ db_now: dbNow }] = await tx<{ db_now: Date }[]>`select now() as db_now`;
      if (!isLeadTimeSatisfied(startMs, dbNow.getTime(), leadTimeLookup.value)) {
        return { kind: "lead_time_violation" };
      }

      // --- Requirement aggregation + deterministic resource resolution ---
      const requirements = await aggregateRequiredRoles(tx, servicePackageId, serviceAddonIds as string[]);
      if (requirements.length === 0) {
        return { kind: "slot_unavailable" };
      }

      const selections: {
        role: string;
        resourceIds: string[];
        effectiveStartIso: string;
        effectiveEndIso: string;
      }[] = [];

      for (const requirement of requirements) {
        const bufferLookup = resolveBufferMinutes(pkg.service_slug, requirement.resource_role);
        if (!bufferLookup.ok) {
          return { kind: "policy_misconfigured", detail: bufferLookup.reason };
        }
        const { effectiveStartMs, effectiveEndMs } = applyBuffer(startMs, endMs, bufferLookup.value);
        const effectiveStartIso = new Date(effectiveStartMs).toISOString();
        const effectiveEndIso = new Date(effectiveEndMs).toISOString();

        const eligible = await selectEligibleResourceIds(
          tx,
          requirement.resource_role,
          requirement.required_quantity,
          requestedStart,
          requestedEnd,
          effectiveStartIso,
          effectiveEndIso,
        );
        if (eligible.length < requirement.required_quantity) {
          return { kind: "slot_unavailable" };
        }
        selections.push({
          role: requirement.resource_role,
          resourceIds: eligible,
          effectiveStartIso,
          effectiveEndIso,
        });
      }

      // --- Create (or safely reuse, on a lost race) the hold ------------
      const insertedRows = await tx<{ id: string; expires_at: Date }[]>`
        insert into booking_holds (
          service_package_id, requested_start_datetime, requested_end_datetime,
          status, expires_at, idempotency_key
        ) values (
          ${servicePackageId}, ${requestedStart}::timestamptz, ${requestedEnd}::timestamptz,
          'active', now() + make_interval(mins => ${pkg.checkout_hold_minutes}), ${idempotencyKey}
        )
        on conflict (idempotency_key) do nothing
        returning id, expires_at
      `;

      // Built here, inside the transaction, from our OWN validated
      // package/add-ons -- reused by both the fresh-create and the
      // race-winner-match branches below (the latter requires our own
      // serviceAddonIds to have been empty for idempotencyMatches to
      // succeed at all, so `addons` is necessarily [] there too).
      const packagePricingSummary = buildPackagePricingSummary({
        pricingType: pkg.pricing_type,
        retailPriceCents: pkg.retail_price_cents,
        currency: pkg.currency,
        unitLabel: pkg.unit_label,
        validatedHourUnits,
      });
      const addonPricingSummary = addons.map((a) =>
        buildAddonPricingSummary({
          id: a.id,
          pricingType: a.pricing_type,
          retailPriceCents: a.retail_price_cents,
          currency: a.currency,
          unitLabel: a.unit_label,
        })
      );

      if (insertedRows.length === 0) {
        // Lost a concurrent race for this exact idempotency key. The
        // UNIQUE constraint guarantees exactly one row exists now --
        // INSERT ... ON CONFLICT DO NOTHING never raises 23505, so this
        // transaction is still fully valid and able to continue with
        // ordinary reads (no savepoint/subtransaction trickery needed).
        const raceRows = await tx<ExistingHoldRow[]>`
          select id, service_package_id, requested_start_datetime, requested_end_datetime, status, expires_at
          from booking_holds
          where idempotency_key = ${idempotencyKey}
        `;
        const winner = raceRows[0];
        if (
          winner.status === "active" &&
          idempotencyMatches(winner, servicePackageId, startMs, endMs, serviceAddonIds as string[])
        ) {
          // No resource_reservations are created here for OUR losing
          // attempt -- the winning transaction owns that.
          return {
            kind: "success",
            created: false,
            holdId: winner.id,
            expiresAt: winner.expires_at,
            requestedStart: winner.requested_start_datetime.toISOString(),
            requestedEnd: winner.requested_end_datetime.toISOString(),
            servicePackageId: winner.service_package_id,
            packagePricingSummary,
            addonPricingSummary,
          };
        }
        if (winner.status === "active") {
          return { kind: "idempotency_conflict" };
        }
        return { kind: "idempotency_retired" };
      }

      const hold = insertedRows[0];

      const reservationRows = selections.flatMap((selection) =>
        selection.resourceIds.map((resourceId) => ({
          resource_id: resourceId,
          role: selection.role,
          start_datetime: selection.effectiveStartIso,
          end_datetime: selection.effectiveEndIso,
          reservation_type: "hold",
          booking_hold_id: hold.id,
          booking_id: null,
          status: "active",
          expires_at: hold.expires_at,
        }))
      );

      // One bulk statement: if any row collides with the exclusion
      // constraint (23P01), the ENTIRE statement -- and therefore the
      // whole transaction, including the booking_holds insert above --
      // rolls back atomically. No partial hold, no partial resource set.
      await tx`
        insert into resource_reservations ${
          tx(
            reservationRows,
            "resource_id",
            "role",
            "start_datetime",
            "end_datetime",
            "reservation_type",
            "booking_hold_id",
            "booking_id",
            "status",
            "expires_at",
          )
        }
      `;

      return {
        kind: "success",
        created: true,
        holdId: hold.id,
        expiresAt: hold.expires_at,
        requestedStart,
        requestedEnd,
        servicePackageId,
        packagePricingSummary,
        addonPricingSummary,
      };
    });

    switch (outcome.kind) {
      case "invalid_package":
        return badRequest("service_package_id does not reference an active, bookable package.", headers);
      case "invalid_addon":
        return badRequest(
          "One or more service_addon_ids are invalid, inactive, or not applicable to the selected package.",
          headers,
        );
      case "duration_invalid":
        console.warn(`[hold] duration_invalid reason=${outcome.reason} detail=${outcome.detail ?? ""}`);
        return badRequest("The requested duration is not valid for this package.", headers);
      case "policy_misconfigured":
        // A catalog/policy gap, never the caller's fault -- logged
        // server-side with detail, reported to the client generically.
        console.error(`[hold] policy_misconfigured detail=${outcome.detail}`);
        return errorResponse(500, "internal_error", "Something went wrong. Please try again.", headers);
      case "outside_horizon":
        return errorResponse(
          422,
          "outside_booking_horizon",
          "The requested date is outside the bookable scheduling window.",
          headers,
        );
      case "lead_time_violation":
        return errorResponse(
          422,
          "lead_time_violation",
          "The requested time does not meet the minimum advance-booking notice for this service.",
          headers,
        );
      case "slot_unavailable":
        return errorResponse(409, "slot_unavailable", "The requested time is no longer available.", headers);
      case "idempotency_conflict":
        return errorResponse(
          409,
          "idempotency_key_conflict",
          "This idempotency key was already used for a different request. Use a new key for a new request.",
          headers,
        );
      case "idempotency_retired":
        return errorResponse(
          410,
          "idempotency_key_retired",
          "The hold originally created with this idempotency key is no longer active. Use a new key to create a new hold.",
          headers,
        );
      case "success": {
        return new Response(
          JSON.stringify({
            hold_id: outcome.holdId,
            expires_at: outcome.expiresAt.toISOString(),
            requested_start_datetime: outcome.requestedStart,
            requested_end_datetime: outcome.requestedEnd,
            service_package_id: outcome.servicePackageId,
            service_addon_ids: outcome.addonPricingSummary.map((a) => a.id),
            pricing_summary: {
              package: outcome.packagePricingSummary,
              addons: outcome.addonPricingSummary,
            },
          }),
          {
            status: outcome.created ? 201 : 200,
            headers: { "Content-Type": "application/json", ...headers },
          },
        );
      }
    }
    // Unreachable given TxOutcome's discriminated union above -- kept as
    // an explicit safety net rather than relying on switch-exhaustiveness
    // inference, which this environment cannot verify (no Deno/tsc
    // available to confirm the compiler agrees).
    throw new Error("internal_invariant_violated: unhandled hold outcome kind");
  } catch (err) {
    const mapped = mapError(err, "hold");
    return jsonErrorResponse(mapped, headers);
  }
});
