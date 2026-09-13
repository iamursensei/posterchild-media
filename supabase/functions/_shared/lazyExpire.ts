// supabase/functions/_shared/lazyExpire.ts
//
// Implements the locked lazy stale-hold expiration algorithm: lock stale
// parent booking_holds FIRST, then expire their hold-type
// resource_reservations by parent hold id membership -- never by the
// reservation's own expires_at -- then expire the holds themselves. All
// three steps happen inside one already-open transaction supplied by the
// caller (via withTransaction from _shared/db.ts), so this is never its
// own top-level transaction.
//
// Confirmed reservations are never touched: excluded both by the explicit
// reservation_type = 'hold' filter here, and structurally, because
// resource_reservations_expires_at_check (Migration 002) guarantees a
// confirmed row's expires_at is always NULL and could never satisfy
// `expires_at <= now()` even if this filter were mistakenly omitted.

import type postgres from "npm:postgres@3";

export interface LazyExpireResult {
  expiredHoldCount: number;
}

/**
 * Must be called with a transaction-scoped `sql` (i.e. the `tx` passed
 * into a withTransaction callback), so its writes are part of the same
 * atomic unit as whatever operation triggered the cleanup. Safe to call
 * from multiple concurrent lazy invocations, and safe to later run
 * unchanged from a scheduled worker as well -- FOR UPDATE SKIP LOCKED
 * means a concurrent caller skips rows this one has already claimed
 * rather than blocking or double-processing them.
 */
export async function lazyExpireStaleHolds(
  tx: postgres.TransactionSql,
): Promise<LazyExpireResult> {
  // 1. Lock stale parent holds FIRST. This id set is authoritative for
  //    every subsequent step in this function -- it is never re-derived
  //    from resource_reservations.expires_at.
  const staleHolds = await tx<{ id: string }[]>`
    select id
    from booking_holds
    where status = 'active'
      and expires_at <= now()
    for update skip locked
  `;

  if (staleHolds.length === 0) {
    // Nothing stale -- return cheaply, no writes issued.
    return { expiredHoldCount: 0 };
  }

  const staleHoldIds = staleHolds.map((h) => h.id);

  // 2. Expire hold-type reservations belonging to EXACTLY those locked
  //    hold ids, matched by booking_hold_id membership only. A
  //    reservation whose own expires_at happens not to match its
  //    parent's is still expired correctly, because the locked parent
  //    hold id -- not the reservation's own timestamp -- is
  //    authoritative here.
  await tx`
    update resource_reservations
    set status = 'expired', updated_at = now()
    where reservation_type = 'hold'
      and status = 'active'
      and booking_hold_id in ${tx(staleHoldIds)}
  `;

  // 3. Expire exactly those parent holds.
  await tx`
    update booking_holds
    set status = 'expired', updated_at = now()
    where id in ${tx(staleHoldIds)}
  `;

  return { expiredHoldCount: staleHoldIds.length };
}
