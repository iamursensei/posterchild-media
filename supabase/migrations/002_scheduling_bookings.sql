-- =====================================================================
-- Posterchild Media — Migration 002: Scheduling + Bookings
-- =====================================================================
-- Builds on the live Migration 001 foundation (clients, services,
-- service_packages, service_addons, service_package_resource_requirements,
-- products, product_variants, product_collection_items) — none of those
-- tables are touched, recreated, or altered here.
--
-- Scope: exactly the 6 tables approved for this migration —
--   resources, resource_availability_blocks, booking_inquiries,
--   booking_holds, bookings, resource_reservations
-- No commerce/payment/membership/notification/calendar table is created
-- here. Neither `booking_resources` nor `availability_dates` (the two
-- legacy concepts superseded by this design) is created.
--
-- No Edge Function, RPC, or scheduler is created in this migration. The
-- exclusion constraint below is the actual concurrency guarantee; the
-- multi-statement transactions that use it (hold creation, hold->booking
-- conversion, reschedule) are ordinary SQL transactions run by backend
-- code written in a later phase — no stored procedure is required for
-- their correctness, so none is added here.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------
-- Required for the resource_reservations exclusion constraint, which
-- mixes a plain equality column (resource_id) with a range-overlap
-- operator (&&) in the same GiST index -- btree_gist supplies the
-- equality operator class GiST needs for that.
create extension if not exists btree_gist;

-- =====================================================================
-- 1. resources — actual schedulable resources
-- =====================================================================
create table public.resources (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  -- Same role vocabulary as Migration 001's
  -- service_package_resource_requirements_role_check. Kept as an
  -- independently-maintained CHECK list (not a shared lookup table) --
  -- no genuine incompatibility exists to justify redesigning the
  -- Migration 001 table, per instruction.
  role        text not null,
  is_active   boolean not null default true,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint resources_role_check
    check (role in ('photographer', 'videographer', 'studio', 'drone_operator'))
);

comment on table public.resources is
  'Actual schedulable resources (a photographer, the studio, a future videographer or drone operator). role must stay compatible with service_package_resource_requirements.resource_role in Migration 001. Not exposed through any public view -- availability outcomes, not resource identities, are what a future client-facing RPC will return.';

create index resources_role_active_idx on public.resources (role, is_active);

create trigger trg_resources_set_updated_at
  before update on public.resources
  for each row execute function public.set_updated_at();

alter table public.resources enable row level security;
revoke all on public.resources from anon, authenticated;
-- No policies: service role only. Raw resource inventory is never
-- exposed publicly, per instruction.

-- =====================================================================
-- 2. resource_availability_blocks — explicit scheduling windows
-- =====================================================================
create table public.resource_availability_blocks (
  id              uuid primary key default gen_random_uuid(),
  resource_id     uuid not null references public.resources(id) on delete cascade,
  block_type      text not null,
  start_datetime  timestamptz not null,
  end_datetime    timestamptz not null,
  note            text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint resource_availability_blocks_type_check
    check (block_type in ('available_window', 'blackout')),
  constraint resource_availability_blocks_end_after_start_check
    check (end_datetime > start_datetime)
);

comment on table public.resource_availability_blocks is
  'Admin-defined windows a resource is explicitly open (available_window) or explicitly closed (blackout). Availability defaults CLOSED: a requested interval is eligible only when fully contained in an available_window and not overlapping any blackout for that resource -- no resource is implicitly available 24/7. Booked time is never stored here; it is derived live from resource_reservations. No recurrence engine is built in this migration -- concrete instant rows are compatible with either a future upstream generator or a later nullable recurrence_rule column without a breaking change. ON DELETE CASCADE from resources is deliberate: this is admin schedule configuration, not booking history, so it may be removed along with the resource it describes.';

create index resource_availability_blocks_resource_time_idx
  on public.resource_availability_blocks (resource_id, block_type, start_datetime, end_datetime);

create trigger trg_resource_availability_blocks_set_updated_at
  before update on public.resource_availability_blocks
  for each row execute function public.set_updated_at();

alter table public.resource_availability_blocks enable row level security;
revoke all on public.resource_availability_blocks from anon, authenticated;
-- No policies: internal to future availability-resolution logic only.

-- =====================================================================
-- 3. booking_inquiries — a prospective request; NEVER reserves time
-- =====================================================================
create table public.booking_inquiries (
  id                      uuid primary key default gen_random_uuid(),
  client_id               uuid references public.clients(id) on delete set null,
  first_name              text,
  last_name               text,
  email                   citext,
  phone                   text,
  source                  text,
  service_id              uuid references public.services(id) on delete set null,
  service_package_id      uuid references public.service_packages(id) on delete set null,
  requested_date          date,
  location                text,
  people_count            text,
  video_needed            text,
  vision_text             text,
  inspiration_text        text,
  -- Integer cents, consistent with Migration 001's money convention.
  -- An estimated customer budget for quote-oriented inquiry flows only
  -- -- never an authoritative price, never used to compute a real total.
  custom_budget_estimate_cents  integer,
  status                  text not null default 'new',
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),

  constraint booking_inquiries_status_check
    check (status in ('new', 'contacted', 'converted', 'archived')),
  constraint booking_inquiries_budget_estimate_non_negative_check
    check (custom_budget_estimate_cents is null or custom_budget_estimate_cents >= 0)
);

comment on table public.booking_inquiries is
  'A prospective booking/request captured from the current (or future) inquiry form. Deliberately has no relationship to resource_reservations -- no resource reservation is ever created merely because an inquiry exists. Contact fields are nullable to allow a genuinely incomplete/guest inquiry, distinct from the canonical clients table where they are required. client_id/service_id/service_package_id use ON DELETE SET NULL so the inquiry record survives a later client merge or catalog change.';

create index booking_inquiries_client_id_idx on public.booking_inquiries (client_id);
create index booking_inquiries_status_idx on public.booking_inquiries (status);

create trigger trg_booking_inquiries_set_updated_at
  before update on public.booking_inquiries
  for each row execute function public.set_updated_at();

alter table public.booking_inquiries enable row level security;
revoke all on public.booking_inquiries from anon, authenticated;
grant select on public.booking_inquiries to authenticated;

create policy booking_inquiries_select_own
  on public.booking_inquiries
  for select
  using (
    client_id is not null
    and client_id in (select id from public.clients where auth_user_id = auth.uid())
  );
-- No insert/update/delete policy for anon or authenticated -- writes
-- happen exclusively through backend/service-role logic (a later
-- phase), not a raw client INSERT, so validation stays server-side.

-- =====================================================================
-- 4. booking_holds — a time-limited claim on a slot during checkout
-- =====================================================================
create table public.booking_holds (
  id                         uuid primary key default gen_random_uuid(),
  -- Nullable by design: the approved flow selects date/time before
  -- customer details, so the hold must be creatable before identity is
  -- known. The backend associates client_id once it becomes available.
  client_id                  uuid references public.clients(id) on delete set null,
  booking_inquiry_id         uuid references public.booking_inquiries(id) on delete set null,
  service_package_id         uuid not null references public.service_packages(id) on delete restrict,
  requested_start_datetime   timestamptz not null,
  requested_end_datetime     timestamptz not null,
  status                     text not null default 'active',
  -- Default hold duration: 10 minutes. A future per-package override
  -- (service_packages.checkout_hold_minutes, already seeded in
  -- Migration 001) can be applied by the backend supplying an explicit
  -- expires_at at insert time instead of relying on this default.
  expires_at                 timestamptz not null default (now() + interval '10 minutes'),
  idempotency_key            text,
  created_at                 timestamptz not null default now(),
  updated_at                 timestamptz not null default now(),

  constraint booking_holds_status_check
    check (status in ('active', 'converted', 'expired', 'released')),
  constraint booking_holds_end_after_start_check
    check (requested_end_datetime > requested_start_datetime),
  -- Postgres UNIQUE treats NULL as distinct from every other value, so
  -- any number of holds with no supplied idempotency_key remains valid
  -- -- only a genuine duplicate key collides.
  constraint booking_holds_idempotency_key_unique unique (idempotency_key)
);

comment on table public.booking_holds is
  'A time-limited claim on a resource/time slot during checkout, before commerce/payment exists. expires_at passing does NOT itself release anything -- see resource_reservations for the actual blocking mechanism and the expiration model. service_package_id uses ON DELETE RESTRICT: a package with hold history should be deactivated (is_active=false in Migration 001), not deleted out from under an in-progress checkout.';

create index booking_holds_status_expires_idx on public.booking_holds (status, expires_at);
create index booking_holds_client_id_idx on public.booking_holds (client_id);
create index booking_holds_service_package_id_idx on public.booking_holds (service_package_id);

create trigger trg_booking_holds_set_updated_at
  before update on public.booking_holds
  for each row execute function public.set_updated_at();

alter table public.booking_holds enable row level security;
revoke all on public.booking_holds from anon, authenticated;
grant select on public.booking_holds to authenticated;

create policy booking_holds_select_own
  on public.booking_holds
  for select
  using (
    client_id is not null
    and client_id in (select id from public.clients where auth_user_id = auth.uid())
  );
-- No write policy: hold creation/conversion/expiry is exclusively a
-- backend/service-role transaction (planned, not built in this
-- migration) -- never a raw client INSERT/UPDATE.

-- =====================================================================
-- 5. bookings — the canonical scheduled engagement
-- =====================================================================
create table public.bookings (
  id                            uuid primary key default gen_random_uuid(),
  client_id                     uuid not null references public.clients(id) on delete restrict,
  service_package_id            uuid not null references public.service_packages(id) on delete restrict,
  booking_inquiry_id            uuid references public.booking_inquiries(id) on delete set null,
  -- Nullable (an admin-created booking may never have gone through a
  -- hold) but unique when populated: a specific hold may produce at
  -- most one booking. Postgres UNIQUE treats NULL as distinct from
  -- every other value, so any number of NULLs remains valid -- this is
  -- a DB-level idempotency/integrity seam on top of the backend's own
  -- SELECT ... FOR UPDATE transaction, not a replacement for it.
  booking_hold_id               uuid references public.booking_holds(id) on delete set null,
  rescheduled_from_booking_id   uuid references public.bookings(id) on delete set null,
  scheduled_start_datetime      timestamptz not null,
  scheduled_end_datetime        timestamptz not null,
  -- Payment status is NOT booking status. This migration never infers
  -- "payment succeeded" -> "confirmed" -- that transition belongs to a
  -- later payment/agreement migration. No payment-related column
  -- exists on this table at all.
  status                        text not null default 'pending',
  -- no_show is its own status value, NEVER a cancellation_type.
  cancellation_type             text,
  cancelled_at                  timestamptz,
  cancellation_note             text,
  created_at                    timestamptz not null default now(),
  updated_at                    timestamptz not null default now(),

  constraint bookings_status_check
    check (status in ('pending', 'confirmed', 'cancelled', 'completed', 'no_show')),
  constraint bookings_cancellation_type_check
    check (cancellation_type is null or cancellation_type in ('client_early', 'client_late', 'admin_override')),
  -- cancellation_type MAY stay NULL on a cancelled booking if the exact
  -- category isn't known/assigned -- only cancelled_at is required.
  constraint bookings_cancelled_requires_timestamp_check
    check (status <> 'cancelled' or cancelled_at is not null),
  -- Supersedes the narrower "cancellation_type requires cancelled"
  -- rule: a non-cancelled booking may carry neither cancellation field
  -- at all, cancellation_type included.
  constraint bookings_non_cancelled_forbids_cancellation_fields_check
    check (status = 'cancelled' or (cancelled_at is null and cancellation_type is null)),
  constraint bookings_end_after_start_check
    check (scheduled_end_datetime > scheduled_start_datetime),
  constraint bookings_booking_hold_id_unique unique (booking_hold_id)
);

comment on table public.bookings is
  'The canonical scheduled engagement, independent of payment state. status transitions to confirmed are owned by a later payment/agreement workflow -- nothing in Migration 002 performs that transition automatically. client_id and service_package_id use ON DELETE RESTRICT so booking history can never silently disappear because a client or package record is deleted -- deletion is blocked until the history is deliberately handled. booking_inquiry_id/booking_hold_id/rescheduled_from_booking_id use ON DELETE SET NULL since losing those traceability links does not destroy the booking''s own core facts (who, what, when).';

create index bookings_client_id_idx on public.bookings (client_id);
create index bookings_service_package_id_idx on public.bookings (service_package_id);
create index bookings_status_idx on public.bookings (status);
-- No separate booking_hold_id index: the UNIQUE constraint above
-- creates its own backing btree index, which already serves lookups.

create trigger trg_bookings_set_updated_at
  before update on public.bookings
  for each row execute function public.set_updated_at();

alter table public.bookings enable row level security;
revoke all on public.bookings from anon, authenticated;
grant select on public.bookings to authenticated;

create policy bookings_select_own
  on public.bookings
  for select
  using (client_id in (select id from public.clients where auth_user_id = auth.uid()));
-- No write policy: booking creation/confirmation/cancellation/reschedule
-- is exclusively a backend/service-role transaction (planned, not built
-- in this migration).

-- =====================================================================
-- 6. resource_reservations — canonical overlap-protection table
-- =====================================================================
create table public.resource_reservations (
  id                uuid primary key default gen_random_uuid(),
  resource_id       uuid not null references public.resources(id) on delete restrict,
  -- Snapshots the role this reservation fulfilled at the time it was
  -- made -- intentionally redundant with resources.role, since a
  -- resource's designation could change later and the reservation
  -- should still reflect what it was booked as.
  role              text not null,
  start_datetime    timestamptz not null,
  end_datetime      timestamptz not null,
  reservation_type  text not null,
  -- ON DELETE RESTRICT, not SET NULL: a hold row structurally requires
  -- booking_hold_id IS NOT NULL (resource_reservations_ownership_check
  -- below) -- SET NULL would violate that check on any still-active
  -- hold reservation, and even for a converted (confirmed) row this
  -- column is scheduling history, not a disposable pointer, so a
  -- referenced hold must not be silently deletable out from under it.
  booking_hold_id   uuid references public.booking_holds(id) on delete restrict,
  booking_id        uuid references public.bookings(id) on delete restrict,
  -- Local blocking state ONLY. This is the column the exclusion
  -- constraint's predicate depends on -- never bookings.status or
  -- booking_holds.status. A confirmed reservation stays 'active' until
  -- legitimately released; there is deliberately no 'converted' status
  -- value, since that would silently drop a confirmed reservation out
  -- of overlap protection.
  status            text not null default 'active',
  -- Required for hold rows (an active hold with no expiration could
  -- block a resource indefinitely and could never be found by the
  -- future expiration sweep -- see resource_reservations_expires_at_check
  -- below). Forbidden for confirmed rows, since expiry no longer has
  -- meaning once a reservation is converted -- the future
  -- hold-to-booking conversion transaction must clear this column in
  -- the same statement that sets reservation_type='confirmed'. NEVER
  -- referenced by the exclusion predicate.
  expires_at        timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint resource_reservations_role_check
    check (role in ('photographer', 'videographer', 'studio', 'drone_operator')),
  constraint resource_reservations_type_check
    check (reservation_type in ('hold', 'confirmed')),
  constraint resource_reservations_status_check
    check (status in ('active', 'released', 'expired')),
  constraint resource_reservations_end_after_start_check
    check (end_datetime > start_datetime),
  -- Ownership rule (deliberately not a strict XOR -- see comment below):
  --   hold reservation:      booking_hold_id IS NOT NULL, booking_id IS NULL
  --   confirmed reservation: booking_id IS NOT NULL, booking_hold_id MAY
  --                          remain populated to preserve which hold
  --                          produced the booking (the conversion audit
  --                          trail). A strict XOR would erase that trail
  --                          the moment a hold converts.
  constraint resource_reservations_ownership_check
    check (
      (reservation_type = 'hold' and booking_hold_id is not null and booking_id is null)
      or
      (reservation_type = 'confirmed' and booking_id is not null)
    ),
  -- A hold row must always carry an expiration (never indefinitely
  -- blocking, always findable by the future sweep); a confirmed row
  -- must never carry one (expiry has no meaning post-conversion).
  -- Deliberately no now() here -- this checks only that the column is
  -- populated/empty as appropriate for the row's type, not whether any
  -- particular instant has passed.
  constraint resource_reservations_expires_at_check
    check (
      (reservation_type = 'hold' and expires_at is not null)
      or
      (reservation_type = 'confirmed' and expires_at is null)
    )
);

comment on table public.resource_reservations is
  'The sole overlap-protection table. resource_id/booking_id/booking_hold_id all use ON DELETE RESTRICT so a resource, booking, or hold with reservation history can never be deleted out from under that history -- deactivate (resources.is_active) instead of deleting. booking_hold_id specifically must RESTRICT rather than SET NULL: a hold-type row requires booking_hold_id IS NOT NULL by resource_reservations_ownership_check, and even a converted (confirmed) row keeps it as genuine scheduling history, not a disposable pointer.';

-- The actual concurrency guarantee. Predicate depends ONLY on this
-- table's own status column -- never bookings.status, never
-- booking_holds.status, never a subquery, never now(). A Postgres
-- exclusion constraint compiles to an index-insertion-time check and
-- cannot safely evaluate external-table state; keeping the blocking
-- decision entirely local is what makes this correct under full MVCC
-- concurrency. Applies identically to INSERT and UPDATE, which is what
-- makes in-place rescheduling (moving start/end on an existing active
-- confirmed reservation) automatically re-validated for free.
alter table public.resource_reservations
  add constraint resource_reservations_no_overlap
  exclude using gist (
    resource_id with =,
    tstzrange(start_datetime, end_datetime, '[)') with &&
  )
  where (status = 'active');

create index resource_reservations_resource_id_idx on public.resource_reservations (resource_id);
create index resource_reservations_booking_hold_id_idx on public.resource_reservations (booking_hold_id);
create index resource_reservations_booking_id_idx on public.resource_reservations (booking_id);
-- Supports the stale-hold cleanup sweep:
-- WHERE status='active' AND reservation_type='hold' AND expires_at < now()
create index resource_reservations_status_type_expiry_idx
  on public.resource_reservations (status, reservation_type, expires_at);

create trigger trg_resource_reservations_set_updated_at
  before update on public.resource_reservations
  for each row execute function public.set_updated_at();

alter table public.resource_reservations enable row level security;
revoke all on public.resource_reservations from anon, authenticated;
-- No policies at all, including read: clients see their commitment
-- through bookings, the client-facing representation of the same
-- underlying reservation. resource_reservations itself is a purely
-- internal scheduling/overlap-protection mechanism.
