-- =====================================================================
-- Posterchild Media — Migration 008: Resource Mappings (Booking MVP)
-- =====================================================================
-- DATA ONLY. No table, column, constraint, extension, index, function,
-- trigger, RLS policy, grant, or public view is created, dropped, or
-- altered here. Builds on the live Migration 001–007 foundation — none
-- of those is touched.
--
-- PURPOSE: establishes the approved package -> resource-role requirement
-- state (service_package_resource_requirements rows) for the first
-- direct-booking rollout of the Booking MVP.
--
-- This migration does NOT create resources, resource_availability_blocks,
-- resource_reservations, booking_holds, bookings, or booking_inquiries.
-- Those are separate, already-provisioned concerns (resources and
-- availability windows already exist in production from an earlier,
-- undocumented seed) or separate future decisions -- inventing any of
-- them here would be out of scope for a resource-MAPPING migration.
--
-- IMPORTANT — THIS MIGRATION DESCRIBES INTENDED STATE, NOT A DELTA:
-- Production may already contain some of the 27 mappings below, applied
-- by an earlier, undocumented seed script that predates this migration
-- chain (see supabase/seed_stage1_resources.sql, itself marked
-- "DRAFT FOR REVIEW / NOT EXECUTED / NOT A MIGRATION" — its actual
-- execution against production was never captured as a migration, which
-- is precisely the gap this migration closes). Every insert below is
-- idempotent and guarded by an explicit WHERE NOT EXISTS on
-- (service_package_id, resource_role) — no unique constraint exists on
-- that pair to rely on instead, so ON CONFLICT is deliberately not used.
-- Re-running this migration, or applying it to a database that already
-- has some of these 27 rows, produces no duplicates and no changes to
-- rows that already match.
--
-- INTENTIONALLY EXCLUDED (do not add mappings for these; do not touch any
-- historical row that already references them):
--   - events/editorial-wedding      -- promise: lead + second photographer;
--                                       no second-photographer resource exists.
--   - events/wedding-photo-film     -- promise: photo team + videographer;
--                                       no videographer resource exists.
--   - events/custom-wedding-production -- custom_quote, inquiry-routed.
--   - real-estate-media/property-images-walkthrough-tour -- whether the
--                                       walkthrough-tour video component
--                                       requires a distinct videographer
--                                       resource is unresolved.
--   - real-estate-media/closing     -- no approved deterministic duration;
--                                       not inventing one here.
--   - real-estate-media/standard-property, luxury-property -- retired
--                                       (is_active=false since Migration 006).
--   - corporate-commercial/half-day, full-day -- custom_quote since
--                                       Migration 006, inquiry-routed.
--   - creative-direction-production (all packages) -- no creative_director
--                                       role exists in the schema; mapping
--                                       to photographer would misrepresent
--                                       the package promise.
--   - travel-personal-creative (all packages) -- no buffer/lead-time
--                                       policy entry exists for this
--                                       service in bookingPolicy.ts.
--   - portraits-milestones/extended-family, custom-holiday-story --
--                                       starting_at, inquiry-oriented.
--
-- NO CLEANUP: production is known to contain historical
-- service_package_resource_requirements rows for corporate-commercial's
-- half-day/full-day and for the retired real-estate-media
-- standard-property/luxury-property packages. This migration does not
-- delete, update, or otherwise alter those rows. Their disposition is a
-- separate future decision, not addressed here.
-- =====================================================================

-- =====================================================================
-- PRECONDITION VALIDATION — runs before any insert, inside the same
-- implicit migration transaction. Every one of the 27 targets is
-- resolved by (service slug, package slug), never a hard-coded UUID, and
-- must exist exactly once, be active, and be bookable. All deterministic
-- fixed-price targets represented by this migration -- the 21 portraits,
-- the two fixed weddings, and studio-rental's half-day/full-day -- are
-- checked against their approved exact duration_minutes value (never
-- invented, always matched against the known-approved value already
-- seeded by Migration 001/006/007). Hourly targets are checked against
-- their approved exact minimum_units value instead of a duration_minutes
-- value -- no duration is invented for an hourly package.
-- =====================================================================
do $$
declare
  target record;
  found_count integer;
  found_pricing_type public.pricing_type;
  found_duration integer;
  found_minimum_units numeric;
  found_active boolean;
  found_bookable boolean;
  duplicate_role_count integer;
begin
  -- ---- Fixed-duration targets (21 portraits + 2 fixed weddings +
  --      studio-rental half-day/full-day = 25 targets) ----
  for target in
    select v.service_slug, v.package_slug, v.expected_duration from (
      values
        ('portraits-milestones', 'mini-session', 30),
        ('portraits-milestones', 'power-session', 60),
        ('portraits-milestones', 'essential-portrait', 60),
        ('portraits-milestones', 'signature-portrait', 90),
        ('portraits-milestones', 'editorial-experience', 120),
        ('portraits-milestones', 'birthday-spotlight', 75),
        ('portraits-milestones', 'graduate-senior-experience', 90),
        ('portraits-milestones', 'headshot-mini', 30),
        ('portraits-milestones', 'professional-presence', 60),
        ('portraits-milestones', 'couples-story', 60),
        ('portraits-milestones', 'couples-experience', 90),
        ('portraits-milestones', 'family-portrait', 60),
        ('portraits-milestones', 'family-story', 90),
        ('portraits-milestones', 'prom-mini', 30),
        ('portraits-milestones', 'prom-experience', 60),
        ('portraits-milestones', 'maternity-story', 90),
        ('portraits-milestones', 'little-moments-mini', 30),
        ('portraits-milestones', 'little-moments', 60),
        ('portraits-milestones', 'holiday-mini', 30),
        ('portraits-milestones', 'holiday-portrait-experience', 60),
        ('portraits-milestones', 'holiday-family-experience', 75),
        ('events', 'intimate-wedding', 180),
        ('events', 'signature-wedding', 360),
        ('studio-rental', 'half-day', 240),
        ('studio-rental', 'full-day', 480)
    ) as v(service_slug, package_slug, expected_duration)
  loop
    select count(*) into found_count
    from public.service_packages sp
    join public.services s on s.id = sp.service_id
    where s.slug = target.service_slug and sp.slug = target.package_slug;

    if found_count <> 1 then
      raise exception 'Migration 008 failed: service_slug=% package_slug=% resolved to % rows, expected exactly 1.',
        target.service_slug, target.package_slug, found_count;
    end if;

    select sp.pricing_type, sp.duration_minutes, sp.is_active, sp.is_bookable
      into found_pricing_type, found_duration, found_active, found_bookable
    from public.service_packages sp
    join public.services s on s.id = sp.service_id
    where s.slug = target.service_slug and sp.slug = target.package_slug;

    if found_active is distinct from true or found_bookable is distinct from true then
      raise exception 'Migration 008 failed: %/% is active=% bookable=%, expected both true.',
        target.service_slug, target.package_slug, found_active, found_bookable;
    end if;

    if found_pricing_type <> 'fixed' then
      raise exception 'Migration 008 failed: %/% has pricing_type=%, expected fixed.',
        target.service_slug, target.package_slug, found_pricing_type;
    end if;

    if found_duration is distinct from target.expected_duration then
      raise exception 'Migration 008 failed: %/% has duration_minutes=%, expected %.',
        target.service_slug, target.package_slug, found_duration, target.expected_duration;
    end if;
  end loop;

  -- ---- Hourly targets: validate exact approved minimum_units, never
  --      invent a duration_minutes for an hourly package ----
  for target in
    select v.service_slug, v.package_slug, v.expected_minimum_units from (
      values
        ('events', 'hourly', 3::numeric),
        ('studio-rental', 'hourly', 1::numeric)
    ) as v(service_slug, package_slug, expected_minimum_units)
  loop
    select count(*) into found_count
    from public.service_packages sp
    join public.services s on s.id = sp.service_id
    where s.slug = target.service_slug and sp.slug = target.package_slug;

    if found_count <> 1 then
      raise exception 'Migration 008 failed: service_slug=% package_slug=% resolved to % rows, expected exactly 1.',
        target.service_slug, target.package_slug, found_count;
    end if;

    select sp.pricing_type, sp.minimum_units, sp.is_active, sp.is_bookable
      into found_pricing_type, found_minimum_units, found_active, found_bookable
    from public.service_packages sp
    join public.services s on s.id = sp.service_id
    where s.slug = target.service_slug and sp.slug = target.package_slug;

    if found_active is distinct from true or found_bookable is distinct from true then
      raise exception 'Migration 008 failed: %/% is active=% bookable=%, expected both true.',
        target.service_slug, target.package_slug, found_active, found_bookable;
    end if;

    if found_pricing_type <> 'hourly' then
      raise exception 'Migration 008 failed: %/% has pricing_type=%, expected hourly.',
        target.service_slug, target.package_slug, found_pricing_type;
    end if;

    if found_minimum_units is distinct from target.expected_minimum_units then
      raise exception 'Migration 008 failed: %/% has minimum_units=%, expected %.',
        target.service_slug, target.package_slug, found_minimum_units, target.expected_minimum_units;
    end if;
  end loop;

  -- ---- Duplicate-safety precondition: at most one existing requirement
  --      row per (target package, target role) is tolerated. Zero is
  --      valid (nothing to no-op against yet). Exactly one is valid
  --      (the idempotent insert below will no-op against it). More than
  --      one means an already-corrupt duplicate state that this
  --      migration must refuse to compound. ----
  for target in
    select v.service_slug, v.package_slug, v.resource_role from (
      values
        ('portraits-milestones', 'mini-session', 'photographer'),
        ('portraits-milestones', 'power-session', 'photographer'),
        ('portraits-milestones', 'essential-portrait', 'photographer'),
        ('portraits-milestones', 'signature-portrait', 'photographer'),
        ('portraits-milestones', 'editorial-experience', 'photographer'),
        ('portraits-milestones', 'birthday-spotlight', 'photographer'),
        ('portraits-milestones', 'graduate-senior-experience', 'photographer'),
        ('portraits-milestones', 'headshot-mini', 'photographer'),
        ('portraits-milestones', 'professional-presence', 'photographer'),
        ('portraits-milestones', 'couples-story', 'photographer'),
        ('portraits-milestones', 'couples-experience', 'photographer'),
        ('portraits-milestones', 'family-portrait', 'photographer'),
        ('portraits-milestones', 'family-story', 'photographer'),
        ('portraits-milestones', 'prom-mini', 'photographer'),
        ('portraits-milestones', 'prom-experience', 'photographer'),
        ('portraits-milestones', 'maternity-story', 'photographer'),
        ('portraits-milestones', 'little-moments-mini', 'photographer'),
        ('portraits-milestones', 'little-moments', 'photographer'),
        ('portraits-milestones', 'holiday-mini', 'photographer'),
        ('portraits-milestones', 'holiday-portrait-experience', 'photographer'),
        ('portraits-milestones', 'holiday-family-experience', 'photographer'),
        ('events', 'hourly', 'photographer'),
        ('events', 'intimate-wedding', 'photographer'),
        ('events', 'signature-wedding', 'photographer'),
        ('studio-rental', 'hourly', 'studio'),
        ('studio-rental', 'half-day', 'studio'),
        ('studio-rental', 'full-day', 'studio')
    ) as v(service_slug, package_slug, resource_role)
  loop
    select count(*) into duplicate_role_count
    from public.service_package_resource_requirements req
    join public.service_packages sp on sp.id = req.service_package_id
    join public.services s on s.id = sp.service_id
    where s.slug = target.service_slug
      and sp.slug = target.package_slug
      and req.resource_role = target.resource_role;

    if duplicate_role_count > 1 then
      raise exception 'Migration 008 failed: %/% already has % existing % requirement rows -- expected at most 1. Refusing to compound an already-duplicated state.',
        target.service_slug, target.package_slug, duplicate_role_count, target.resource_role;
    end if;
  end loop;
end $$;

-- =====================================================================
-- IDEMPOTENT INSERTS — each guarded by an explicit WHERE NOT EXISTS on
-- (service_package_id, resource_role), since no unique constraint on
-- that pair exists to let ON CONFLICT do this safely. A pre-existing
-- matching row (from the earlier undocumented seed, or a prior run of
-- this migration) is left completely untouched -- no UPDATE is ever
-- issued here, per instruction that this migration is additive/
-- idempotent, not corrective.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A. Photographer — Portraits & Milestones (21 packages)
-- ---------------------------------------------------------------------
insert into public.service_package_resource_requirements
  (service_package_id, resource_role, quantity, is_required)
select sp.id, 'photographer', 1, true
from public.service_packages sp
join public.services s on s.id = sp.service_id
join (values
  ('mini-session'),
  ('power-session'),
  ('essential-portrait'),
  ('signature-portrait'),
  ('editorial-experience'),
  ('birthday-spotlight'),
  ('graduate-senior-experience'),
  ('headshot-mini'),
  ('professional-presence'),
  ('couples-story'),
  ('couples-experience'),
  ('family-portrait'),
  ('family-story'),
  ('prom-mini'),
  ('prom-experience'),
  ('maternity-story'),
  ('little-moments-mini'),
  ('little-moments'),
  ('holiday-mini'),
  ('holiday-portrait-experience'),
  ('holiday-family-experience')
) as v(package_slug) on v.package_slug = sp.slug
where s.slug = 'portraits-milestones'
  and not exists (
    select 1 from public.service_package_resource_requirements existing
    where existing.service_package_id = sp.id
      and existing.resource_role = 'photographer'
  );

-- ---------------------------------------------------------------------
-- B. Photographer — Events (3 packages)
-- ---------------------------------------------------------------------
insert into public.service_package_resource_requirements
  (service_package_id, resource_role, quantity, is_required)
select sp.id, 'photographer', 1, true
from public.service_packages sp
join public.services s on s.id = sp.service_id
join (values
  ('hourly'),
  ('intimate-wedding'),
  ('signature-wedding')
) as v(package_slug) on v.package_slug = sp.slug
where s.slug = 'events'
  and not exists (
    select 1 from public.service_package_resource_requirements existing
    where existing.service_package_id = sp.id
      and existing.resource_role = 'photographer'
  );

-- ---------------------------------------------------------------------
-- C. Studio — Studio Rental (3 packages). Photographer is deliberately
--    NOT required for studio rental -- the package promise is the space
--    itself, not photography labor.
-- ---------------------------------------------------------------------
insert into public.service_package_resource_requirements
  (service_package_id, resource_role, quantity, is_required)
select sp.id, 'studio', 1, true
from public.service_packages sp
join public.services s on s.id = sp.service_id
join (values
  ('hourly'),
  ('half-day'),
  ('full-day')
) as v(package_slug) on v.package_slug = sp.slug
where s.slug = 'studio-rental'
  and not exists (
    select 1 from public.service_package_resource_requirements existing
    where existing.service_package_id = sp.id
      and existing.resource_role = 'studio'
  );

-- =====================================================================
-- POSTCONDITION VALIDATION — target-scoped only. This does NOT assert
-- anything about the total row count of service_package_resource_requirements
-- (production legitimately contains historical rows for
-- corporate-commercial and the retired real-estate-media packages,
-- outside this migration's 27-target scope, and this migration must
-- never fail because of rows it was never responsible for). Each of the
-- 27 intended (service, package, role) mappings must exist EXACTLY ONCE
-- with quantity=1 and is_required=true. A pre-existing target mapping
-- with an unexpected quantity/is_required value is a data problem this
-- migration refuses to silently fix -- it fails loudly instead.
-- =====================================================================
do $$
declare
  target record;
  found_count integer;
  found_quantity integer;
  found_is_required boolean;
begin
  for target in
    select v.service_slug, v.package_slug, v.resource_role from (
      values
        ('portraits-milestones', 'mini-session', 'photographer'),
        ('portraits-milestones', 'power-session', 'photographer'),
        ('portraits-milestones', 'essential-portrait', 'photographer'),
        ('portraits-milestones', 'signature-portrait', 'photographer'),
        ('portraits-milestones', 'editorial-experience', 'photographer'),
        ('portraits-milestones', 'birthday-spotlight', 'photographer'),
        ('portraits-milestones', 'graduate-senior-experience', 'photographer'),
        ('portraits-milestones', 'headshot-mini', 'photographer'),
        ('portraits-milestones', 'professional-presence', 'photographer'),
        ('portraits-milestones', 'couples-story', 'photographer'),
        ('portraits-milestones', 'couples-experience', 'photographer'),
        ('portraits-milestones', 'family-portrait', 'photographer'),
        ('portraits-milestones', 'family-story', 'photographer'),
        ('portraits-milestones', 'prom-mini', 'photographer'),
        ('portraits-milestones', 'prom-experience', 'photographer'),
        ('portraits-milestones', 'maternity-story', 'photographer'),
        ('portraits-milestones', 'little-moments-mini', 'photographer'),
        ('portraits-milestones', 'little-moments', 'photographer'),
        ('portraits-milestones', 'holiday-mini', 'photographer'),
        ('portraits-milestones', 'holiday-portrait-experience', 'photographer'),
        ('portraits-milestones', 'holiday-family-experience', 'photographer'),
        ('events', 'hourly', 'photographer'),
        ('events', 'intimate-wedding', 'photographer'),
        ('events', 'signature-wedding', 'photographer'),
        ('studio-rental', 'hourly', 'studio'),
        ('studio-rental', 'half-day', 'studio'),
        ('studio-rental', 'full-day', 'studio')
    ) as v(service_slug, package_slug, resource_role)
  loop
    select count(*) into found_count
    from public.service_package_resource_requirements req
    join public.service_packages sp on sp.id = req.service_package_id
    join public.services s on s.id = sp.service_id
    where s.slug = target.service_slug
      and sp.slug = target.package_slug
      and req.resource_role = target.resource_role;

    if found_count <> 1 then
      raise exception 'Migration 008 validation failed: %/% role=% has % requirement rows after migration, expected exactly 1.',
        target.service_slug, target.package_slug, target.resource_role, found_count;
    end if;

    select req.quantity, req.is_required into found_quantity, found_is_required
    from public.service_package_resource_requirements req
    join public.service_packages sp on sp.id = req.service_package_id
    join public.services s on s.id = sp.service_id
    where s.slug = target.service_slug
      and sp.slug = target.package_slug
      and req.resource_role = target.resource_role;

    if found_quantity is distinct from 1 or found_is_required is distinct from true then
      raise exception 'Migration 008 validation failed: %/% role=% has quantity=% is_required=%, expected 1 / true. This is a pre-existing data problem this migration will not silently correct.',
        target.service_slug, target.package_slug, target.resource_role, found_quantity, found_is_required;
    end if;
  end loop;
end $$;
