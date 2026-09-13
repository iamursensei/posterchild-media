// supabase/functions/_shared/availabilityResolver.ts
//
// Deterministic availability resolution against the actual Migration 001
// service_package_resource_requirements shape:
//   service_package_id uuid nullable  (strict XOR with service_addon_id)
//   service_addon_id   uuid nullable
//   resource_role      text  in ('photographer','videographer','studio','drone_operator')
//   quantity           integer
//   is_required        boolean
//
// This module assumes the caller (the endpoint) has already validated
// that service_package_id and every service_addon_id reference active,
// bookable, applicable records -- it performs no catalog-existence
// validation of its own, only resource-availability computation.
//
// [) range semantics used consistently, matching Migration 002's
// exclusion constraint.
//
// Stage 2 (hold creation) needs a distinction this module didn't
// originally have: a CLIENT-VISIBLE interval (checked only against
// available_window containment) versus an EFFECTIVE, buffer-expanded
// interval (checked against blackout and active-reservation overlap).
// `selectEligibleResourceIds` and `aggregateRequiredRoles` are exported
// so the hold endpoint can reuse this exact resource-selection logic
// with two different intervals, rather than duplicating it.
// `resolveAvailability` (used by the read-only availability endpoint,
// which has no buffer concept) passes the same interval for both,
// preserving its behavior unchanged.

import type postgres from "npm:postgres@3";

export interface ResolveAvailabilityInput {
  servicePackageId: string;
  serviceAddonIds: string[];
  requestedStart: string; // ISO-8601 with explicit offset
  requestedEnd: string;
}

export type AvailabilityOutcome =
  | { status: "available" }
  | { status: "unavailable"; internalReason: string };

export interface RoleRequirement {
  resource_role: string;
  required_quantity: number;
}

/**
 * Aggregates required resource roles from a package + selected add-ons,
 * is_required = true only. Branched rather than passed an empty/
 * placeholder array into IN(...): an untyped NULL parameter inside a
 * dynamic array is a no-op in practice (x = NULL is never true), but it
 * forces Postgres to infer the parameter's type from context rather than
 * being told explicitly -- branching avoids that inference entirely,
 * which is strictly safer and makes the "no add-ons selected" case
 * structurally unambiguous.
 */
export async function aggregateRequiredRoles(
  tx: postgres.TransactionSql,
  servicePackageId: string,
  serviceAddonIds: string[],
): Promise<RoleRequirement[]> {
  return serviceAddonIds.length > 0
    ? await tx<RoleRequirement[]>`
        select resource_role, sum(quantity)::int as required_quantity
        from service_package_resource_requirements
        where is_required = true
          and (
            service_package_id = ${servicePackageId}
            or service_addon_id in ${tx(serviceAddonIds)}
          )
        group by resource_role
      `
    : await tx<RoleRequirement[]>`
        select resource_role, sum(quantity)::int as required_quantity
        from service_package_resource_requirements
        where is_required = true
          and service_package_id = ${servicePackageId}
        group by resource_role
      `;
}

/**
 * Resolves whether the requested interval can be fully satisfied. Never
 * partially fulfills a role's required quantity, and never claims
 * availability for a package whose resource requirements could not be
 * determined at all (see the empty-requirements branch below) --
 * `internalReason` is for server-side logging only and must never be
 * forwarded to the browser as-is.
 */
export async function resolveAvailability(
  tx: postgres.TransactionSql,
  input: ResolveAvailabilityInput,
): Promise<AvailabilityOutcome> {
  const { servicePackageId, serviceAddonIds, requestedStart, requestedEnd } = input;

  const requirements = await aggregateRequiredRoles(tx, servicePackageId, serviceAddonIds);

  if (requirements.length === 0) {
    // No resource-requirement rows exist for this package/add-on
    // selection. This is structurally ambiguous: it could mean the
    // package is legitimately resource-free, or it could mean the
    // catalog simply has not been configured yet. Nothing in the current
    // schema distinguishes the two cases. Given that ambiguity, the safe
    // default is to refuse to claim availability rather than silently
    // treating an unconfigured package as bookable. See the Stage 1
    // catalog audit for which currently-seeded packages this affects.
    return { status: "unavailable", internalReason: "no_resource_requirements_configured" };
  }

  for (const requirement of requirements) {
    // No buffer concept on this endpoint: client-visible and effective
    // intervals are identical.
    const eligible = await selectEligibleResourceIds(
      tx,
      requirement.resource_role,
      requirement.required_quantity,
      requestedStart,
      requestedEnd,
      requestedStart,
      requestedEnd,
    );
    if (eligible.length < requirement.required_quantity) {
      // Insufficient resources for this role -- fail the whole request.
      // No partial fulfillment of one role while another is short.
      return { status: "unavailable", internalReason: "insufficient_resources" };
    }
  }

  return { status: "available" };
}

/**
 * Deterministic candidate selection for one resource role:
 *   - active resources of the given role
 *   - the COMPLETE client-visible interval contained in ONE INDIVIDUAL
 *     available_window row (no union of adjacent/overlapping windows)
 *   - zero overlap (any intersection) between the EFFECTIVE (buffer-
 *     expanded) interval and any blackout row
 *   - zero overlap between the EFFECTIVE interval and any active
 *     resource_reservations row
 *   - ordered created_at ASC, id ASC for a stable, repeatable pick
 *   - capped at `quantity` so at most the required number is ever
 *     returned, and each returned resource is distinct by construction
 *     (one row per resource in the underlying table)
 *
 * clientStart/clientEnd and effectiveStart/effectiveEnd are identical
 * for a caller with no buffer concept (the availability endpoint).
 */
export async function selectEligibleResourceIds(
  tx: postgres.TransactionSql,
  role: string,
  quantity: number,
  clientStart: string,
  clientEnd: string,
  effectiveStart: string,
  effectiveEnd: string,
): Promise<string[]> {
  const candidates = await tx<{ id: string }[]>`
    select r.id
    from resources r
    where r.role = ${role}
      and r.is_active = true
      and exists (
        select 1
        from resource_availability_blocks b
        where b.resource_id = r.id
          and b.block_type = 'available_window'
          and tstzrange(b.start_datetime, b.end_datetime, '[)')
              @> tstzrange(${clientStart}::timestamptz, ${clientEnd}::timestamptz, '[)')
      )
      and not exists (
        select 1
        from resource_availability_blocks b
        where b.resource_id = r.id
          and b.block_type = 'blackout'
          and tstzrange(b.start_datetime, b.end_datetime, '[)')
              && tstzrange(${effectiveStart}::timestamptz, ${effectiveEnd}::timestamptz, '[)')
      )
      and not exists (
        select 1
        from resource_reservations res
        where res.resource_id = r.id
          and res.status = 'active'
          and tstzrange(res.start_datetime, res.end_datetime, '[)')
              && tstzrange(${effectiveStart}::timestamptz, ${effectiveEnd}::timestamptz, '[)')
      )
    order by r.created_at asc, r.id asc
    limit ${quantity}
  `;
  return candidates.map((c) => c.id);
}
