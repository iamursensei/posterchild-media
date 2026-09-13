-- =====================================================================
-- Posterchild Media — Stage 1B Draft: Resource + Requirement Seed
-- =====================================================================
-- STATUS: DRAFT FOR REVIEW. NOT EXECUTED. NOT A MIGRATION.
--
-- This is operational/configuration seed data, not schema. It does not
-- alter any table, constraint, or RLS policy, and does not touch
-- supabase/migrations/001_foundation_catalog.sql or
-- supabase/migrations/002_scheduling_bookings.sql in any way.
--
-- It creates:
--   1. Two `resources` rows (photographer, studio)
--   2. Twelve `service_package_resource_requirements` rows, one per
--      already-approved physical package, resolved by slug (never a
--      hard-coded UUID)
--
-- It deliberately does NOT create:
--   - a videographer or drone_operator resource
--   - any requirement row for Creative Direction & Production (all 4
--     packages) or for any service_addon
--   - any resource_availability_blocks row (available_window/blackout)
--   - any bookings/holds/reservations
--
-- Consequence, expected and intentional: availability will still return
-- false for every package after this seed runs, because no
-- available_window exists for either resource yet. That is correct --
-- availability stays CLOSED until scheduling windows are separately
-- approved and inserted.
--
-- =====================================================================
-- IDEMPOTENCY NOTE -- READ BEFORE RUNNING
-- =====================================================================
-- Neither `resources` nor `service_package_resource_requirements` has a
-- unique constraint on any natural key (name+role, or
-- package+role/addon+role). No such constraint is invented here -- doing
-- so would be a schema change, out of scope for a seed script. This
-- script is therefore NOT truly idempotent at the database level: two
-- concurrent executions could both pass a NOT EXISTS check and both
-- insert, producing duplicates.
--
-- It IS structured to minimize duplicate risk for the realistic use
-- case (a human reviews this file, then runs it once, manually, via the
-- Supabase SQL editor or psql) -- every INSERT is guarded by a
-- WHERE NOT EXISTS clause matching on the same fields a real unique
-- constraint would likely use, so an accidental second manual run
-- produces zero additional rows rather than duplicates, as long as runs
-- do not race each other concurrently.
--
-- If recurring/automated re-seeding is ever wanted, the correct fix is
-- adding real unique constraints in a future migration -- not deeper
-- application-level guarding here.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Resources
-- ---------------------------------------------------------------------
-- IDENTITY DECISION NOT MADE HERE -- FLAGGED FOR OWNER REVIEW:
-- Whether the photographer resource should represent Jimmy Easton
-- specifically, or a generic Posterchild photographer capacity slot, is
-- a business decision this draft does not make silently. A neutral,
-- professional, non-personal name is used below pending that decision.
-- resources.name is never exposed through any public view or Edge
-- Function response regardless of what it is ultimately set to.
insert into public.resources (name, role, is_active)
select 'Posterchild Photographer', 'photographer', true
where not exists (
  select 1 from public.resources where name = 'Posterchild Photographer' and role = 'photographer'
);

insert into public.resources (name, role, is_active)
select 'Posterchild Studio', 'studio', true
where not exists (
  select 1 from public.resources where name = 'Posterchild Studio' and role = 'studio'
);

-- ---------------------------------------------------------------------
-- Portraits & Milestones -- 1 photographer each
-- ---------------------------------------------------------------------
insert into public.service_package_resource_requirements
  (service_package_id, resource_role, quantity, is_required)
select sp.id, 'photographer', 1, true
from public.service_packages sp
join public.services s on s.id = sp.service_id
where s.slug = 'portraits-milestones' and sp.slug = 'power-session'
  and not exists (
    select 1 from public.service_package_resource_requirements
    where service_package_id = sp.id and resource_role = 'photographer'
  );

insert into public.service_package_resource_requirements
  (service_package_id, resource_role, quantity, is_required)
select sp.id, 'photographer', 1, true
from public.service_packages sp
join public.services s on s.id = sp.service_id
where s.slug = 'portraits-milestones' and sp.slug = 'essential-portrait'
  and not exists (
    select 1 from public.service_package_resource_requirements
    where service_package_id = sp.id and resource_role = 'photographer'
  );

insert into public.service_package_resource_requirements
  (service_package_id, resource_role, quantity, is_required)
select sp.id, 'photographer', 1, true
from public.service_packages sp
join public.services s on s.id = sp.service_id
where s.slug = 'portraits-milestones' and sp.slug = 'signature-portrait'
  and not exists (
    select 1 from public.service_package_resource_requirements
    where service_package_id = sp.id and resource_role = 'photographer'
  );

insert into public.service_package_resource_requirements
  (service_package_id, resource_role, quantity, is_required)
select sp.id, 'photographer', 1, true
from public.service_packages sp
join public.services s on s.id = sp.service_id
where s.slug = 'portraits-milestones' and sp.slug = 'editorial-experience'
  and not exists (
    select 1 from public.service_package_resource_requirements
    where service_package_id = sp.id and resource_role = 'photographer'
  );

-- ---------------------------------------------------------------------
-- Studio Rental -- 1 studio each
-- ---------------------------------------------------------------------
insert into public.service_package_resource_requirements
  (service_package_id, resource_role, quantity, is_required)
select sp.id, 'studio', 1, true
from public.service_packages sp
join public.services s on s.id = sp.service_id
where s.slug = 'studio-rental' and sp.slug = 'hourly'
  and not exists (
    select 1 from public.service_package_resource_requirements
    where service_package_id = sp.id and resource_role = 'studio'
  );

insert into public.service_package_resource_requirements
  (service_package_id, resource_role, quantity, is_required)
select sp.id, 'studio', 1, true
from public.service_packages sp
join public.services s on s.id = sp.service_id
where s.slug = 'studio-rental' and sp.slug = 'half-day'
  and not exists (
    select 1 from public.service_package_resource_requirements
    where service_package_id = sp.id and resource_role = 'studio'
  );

insert into public.service_package_resource_requirements
  (service_package_id, resource_role, quantity, is_required)
select sp.id, 'studio', 1, true
from public.service_packages sp
join public.services s on s.id = sp.service_id
where s.slug = 'studio-rental' and sp.slug = 'full-day'
  and not exists (
    select 1 from public.service_package_resource_requirements
    where service_package_id = sp.id and resource_role = 'studio'
  );

-- ---------------------------------------------------------------------
-- Events -- 1 photographer
-- ---------------------------------------------------------------------
insert into public.service_package_resource_requirements
  (service_package_id, resource_role, quantity, is_required)
select sp.id, 'photographer', 1, true
from public.service_packages sp
join public.services s on s.id = sp.service_id
where s.slug = 'events' and sp.slug = 'hourly'
  and not exists (
    select 1 from public.service_package_resource_requirements
    where service_package_id = sp.id and resource_role = 'photographer'
  );

-- ---------------------------------------------------------------------
-- Corporate & Commercial -- 1 photographer each
-- ---------------------------------------------------------------------
insert into public.service_package_resource_requirements
  (service_package_id, resource_role, quantity, is_required)
select sp.id, 'photographer', 1, true
from public.service_packages sp
join public.services s on s.id = sp.service_id
where s.slug = 'corporate-commercial' and sp.slug = 'half-day'
  and not exists (
    select 1 from public.service_package_resource_requirements
    where service_package_id = sp.id and resource_role = 'photographer'
  );

insert into public.service_package_resource_requirements
  (service_package_id, resource_role, quantity, is_required)
select sp.id, 'photographer', 1, true
from public.service_packages sp
join public.services s on s.id = sp.service_id
where s.slug = 'corporate-commercial' and sp.slug = 'full-day'
  and not exists (
    select 1 from public.service_package_resource_requirements
    where service_package_id = sp.id and resource_role = 'photographer'
  );

-- ---------------------------------------------------------------------
-- Real Estate Media -- 1 photographer each
-- ---------------------------------------------------------------------
insert into public.service_package_resource_requirements
  (service_package_id, resource_role, quantity, is_required)
select sp.id, 'photographer', 1, true
from public.service_packages sp
join public.services s on s.id = sp.service_id
where s.slug = 'real-estate-media' and sp.slug = 'standard-property'
  and not exists (
    select 1 from public.service_package_resource_requirements
    where service_package_id = sp.id and resource_role = 'photographer'
  );

insert into public.service_package_resource_requirements
  (service_package_id, resource_role, quantity, is_required)
select sp.id, 'photographer', 1, true
from public.service_packages sp
join public.services s on s.id = sp.service_id
where s.slug = 'real-estate-media' and sp.slug = 'luxury-property'
  and not exists (
    select 1 from public.service_package_resource_requirements
    where service_package_id = sp.id and resource_role = 'photographer'
  );

-- ---------------------------------------------------------------------
-- Intentionally NOT configured in this draft:
--
--   Creative Direction & Production: hourly, half-day, full-day,
--   team-campaign -- the approved resource-role vocabulary
--   (photographer|videographer|studio|drone_operator) has no
--   creative_director role, and treating creative direction as
--   photographer labor has not been approved. These four packages
--   continue to fail closed (no_resource_requirements_configured).
--
--   service_addons: real-estate-videography, real-estate-drone,
--   real-estate-mic-audio -- none has retail pricing approved yet
--   (pricing_type='unpriced', is_bookable=false per Migration 001), and
--   none maps unambiguously to an already-approved role without a
--   business decision: videography would need a videographer resource
--   (none exists), drone would need a drone_operator resource (none
--   exists), and mic/audio does not clearly require a distinct resource
--   at all. Reported separately, not configured here.
-- ---------------------------------------------------------------------

-- =====================================================================
-- FAIL-FAST VALIDATION -- runs before commit, inside the same
-- transaction. This is a manually-controlled seed; silent partial
-- success (e.g. one slug pair failing to resolve while the rest commit
-- cleanly) is not acceptable. Every check below asserts the EXACT
-- intended state -- never a bare COUNT(*), which could pass with the
-- wrong mix of rows (duplicates masking a genuine gap). An uncaught
-- RAISE EXCEPTION here aborts and rolls back everything in this
-- transaction, including the inserts above -- nothing partial is left
-- behind either way.
-- =====================================================================
do $$
declare
  missing_mappings integer;
begin
  if not exists (
    select 1 from public.resources
    where name = 'Posterchild Photographer' and role = 'photographer' and is_active = true
  ) then
    raise exception 'Stage 1B seed validation failed: Posterchild Photographer (role=photographer) is missing or inactive after seeding.';
  end if;

  if not exists (
    select 1 from public.resources
    where name = 'Posterchild Studio' and role = 'studio' and is_active = true
  ) then
    raise exception 'Stage 1B seed validation failed: Posterchild Studio (role=studio) is missing or inactive after seeding.';
  end if;

  select count(*) into missing_mappings
  from (values
    ('portraits-milestones', 'power-session', 'photographer'),
    ('portraits-milestones', 'essential-portrait', 'photographer'),
    ('portraits-milestones', 'signature-portrait', 'photographer'),
    ('portraits-milestones', 'editorial-experience', 'photographer'),
    ('studio-rental', 'hourly', 'studio'),
    ('studio-rental', 'half-day', 'studio'),
    ('studio-rental', 'full-day', 'studio'),
    ('events', 'hourly', 'photographer'),
    ('corporate-commercial', 'half-day', 'photographer'),
    ('corporate-commercial', 'full-day', 'photographer'),
    ('real-estate-media', 'standard-property', 'photographer'),
    ('real-estate-media', 'luxury-property', 'photographer')
  ) as expected(service_slug, package_slug, resource_role)
  where not exists (
    select 1
    from public.service_package_resource_requirements req
    join public.service_packages sp on sp.id = req.service_package_id
    join public.services s on s.id = sp.service_id
    where s.slug = expected.service_slug
      and sp.slug = expected.package_slug
      and req.resource_role = expected.resource_role
      and req.is_required = true
  );

  if missing_mappings > 0 then
    raise exception 'Stage 1B seed validation failed: % of the 12 intended package/resource requirement mappings did not resolve.', missing_mappings;
  end if;
end $$;

commit;

-- =====================================================================
-- OPTIONAL, READ-ONLY -- for manual verification after running the
-- block above. Not part of the transaction; safe to run separately.
-- A clean result is exactly 2 rows from the first query and exactly 12
-- rows from the second, with no row in the second referencing
-- creative-direction-production (or any other unconfigured service) and
-- no service_addon-derived row (this query only ever shows
-- package-derived rows in the first place, since it joins through
-- service_packages, not service_addons).
-- =====================================================================
-- select r.name, r.role, r.is_active from public.resources r order by r.role;
--
-- select s.slug as service_slug, sp.slug as package_slug,
--        req.resource_role, req.quantity, req.is_required
-- from public.service_package_resource_requirements req
-- join public.service_packages sp on sp.id = req.service_package_id
-- join public.services s on s.id = sp.service_id
-- order by s.slug, sp.slug;
