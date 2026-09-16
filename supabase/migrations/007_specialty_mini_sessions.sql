-- =====================================================================
-- Posterchild Media — Migration 007: Specialty Mini Sessions
-- =====================================================================
-- DATA ONLY. No table, column, constraint, extension, index, function,
-- trigger, RLS policy, grant, or public view is created, dropped, or
-- altered here. Builds on the live Migration 001–006 foundation — none
-- of those is touched. No resource_reservations/booking_holds/bookings
-- row is touched, and no service_package_resource_requirements row is
-- added for either new package: live availability/hold integration for
-- them is explicitly deferred to a future stage, per instruction, so
-- wiring resource requirements now would be premature.
--
-- Scope: exactly two new service_packages rows under the existing
-- portraits-milestones service, using the same insert-by-natural-key
-- (service_id, slug) idiom Migration 001/006 already establish. Both
-- are ADDITIVE ONLY — no existing row (Little Moments, Professional
-- Presence, Mini Session, Prom Mini, Prom Experience, or anything else)
-- is read, referenced, or modified by this migration.
--
--   1. Little Moments Mini ($150 fixed, 30 minutes) — a shorter Kids &
--      Milestones session alongside the unchanged existing Little
--      Moments ($225, 60 minutes).
--   2. Headshot Mini ($150 fixed, 30 minutes) — a shorter Professional
--      / Headshots session alongside the unchanged existing
--      Professional Presence ($225, 60 minutes).
--
-- IMPORTANT: is_bookable = true at the catalog level means "selectable
-- through the booking experience" (per Migration 001's own definition),
-- NOT "availability/hold is ready." Both new packages require
-- service_package_resource_requirements mapping during Stage 3D before
-- live availability/hold may be exposed for them — see the STAGE 3D
-- PREREQUISITE note at the end of this file. Neither package is added
-- to service_package_resource_requirements here.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Little Moments Mini — Kids & Milestones. Deliberately minimal
--    deliverables (1 look, 3 edited images) with an explicit "not
--    specialized newborn posing, not multiple sets/looks" boundary in
--    the description, matching the approved positioning exactly rather
--    than implying more than what was approved.
-- ---------------------------------------------------------------------
insert into public.service_packages
  (service_id, slug, name, pricing_type, retail_price_cents, duration_minutes,
   is_active, is_bookable, sort_order, public_description)
select s.id, 'little-moments-mini', 'Little Moments Mini', 'fixed'::public.pricing_type, 15000, 30,
       true, true, 179,
       'A shorter portrait session for babies, kids, birthdays, and childhood milestones where a full one-hour session may not be necessary. 1 look, 3 edited images. Not specialized newborn posing, and does not include multiple sets, multiple looks, or elaborate set construction.'
from public.services s
where s.slug = 'portraits-milestones'
on conflict (service_id, slug) do update set
  name = excluded.name,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  duration_minutes = excluded.duration_minutes,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

-- ---------------------------------------------------------------------
-- 2. Headshot Mini — Professional / Headshots. Explicitly scoped to an
--    individual session in its own description, so it is never read as
--    company-wide/team headshot coverage (that remains Corporate &
--    Commercial, unchanged and untouched by this migration).
-- ---------------------------------------------------------------------
insert into public.service_packages
  (service_id, slug, name, pricing_type, retail_price_cents, duration_minutes,
   is_active, is_bookable, sort_order, public_description)
select s.id, 'headshot-mini', 'Headshot Mini', 'fixed'::public.pricing_type, 15000, 30,
       true, true, 129,
       'A streamlined individual headshot session for a quick professional, profile, résumé, casting, or personal-brand update. 1 professional look, 3 edited images. For company-wide, team, or corporate staff headshot projects, see Corporate & Commercial.'
from public.services s
where s.slug = 'portraits-milestones'
on conflict (service_id, slug) do update set
  name = excluded.name,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  duration_minutes = excluded.duration_minutes,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

-- =====================================================================
-- FAIL-FAST VALIDATION — runs after both inserts above, inside the same
-- implicit migration transaction. Confirms exact intended end-state,
-- not merely that the statements ran without error.
-- =====================================================================
do $$
declare
  lmm_price integer;
  lmm_duration integer;
  lmm_type public.pricing_type;
  lmm_active boolean;
  lmm_bookable boolean;
  hm_price integer;
  hm_duration integer;
  hm_type public.pricing_type;
  hm_active boolean;
  hm_bookable boolean;
begin
  select sp.retail_price_cents, sp.duration_minutes, sp.pricing_type, sp.is_active, sp.is_bookable
    into lmm_price, lmm_duration, lmm_type, lmm_active, lmm_bookable
  from public.service_packages sp
  join public.services s on s.id = sp.service_id
  where s.slug = 'portraits-milestones' and sp.slug = 'little-moments-mini';

  if lmm_price is distinct from 15000
     or lmm_duration is distinct from 30
     or lmm_type is distinct from 'fixed'::public.pricing_type
     or lmm_active is distinct from true
     or lmm_bookable is distinct from true
  then
    raise exception 'Migration 007 validation failed: little-moments-mini is price=% duration=% type=% active=% bookable=%, expected 15000 / 30 / fixed / true / true.',
      lmm_price, lmm_duration, lmm_type, lmm_active, lmm_bookable;
  end if;

  select sp.retail_price_cents, sp.duration_minutes, sp.pricing_type, sp.is_active, sp.is_bookable
    into hm_price, hm_duration, hm_type, hm_active, hm_bookable
  from public.service_packages sp
  join public.services s on s.id = sp.service_id
  where s.slug = 'portraits-milestones' and sp.slug = 'headshot-mini';

  if hm_price is distinct from 15000
     or hm_duration is distinct from 30
     or hm_type is distinct from 'fixed'::public.pricing_type
     or hm_active is distinct from true
     or hm_bookable is distinct from true
  then
    raise exception 'Migration 007 validation failed: headshot-mini is price=% duration=% type=% active=% bookable=%, expected 15000 / 30 / fixed / true / true.',
      hm_price, hm_duration, hm_type, hm_active, hm_bookable;
  end if;
end $$;

-- =====================================================================
-- STAGE 3D PREREQUISITE (not a schema limitation -- deliberately
-- deferred per instruction, not fixed here):
-- is_bookable = true above means "selectable through the booking
-- experience" only (Migration 001's own definition) -- it does NOT mean
-- availability/hold is ready for either package. Both
-- little-moments-mini and headshot-mini require
-- service_package_resource_requirements rows (mapping the correct
-- resource role, most likely 'photographer', matching how every other
-- Portraits & Milestones package is expected to be wired) before Stage
-- 3D can expose live availability/hold for them. Neither row is added
-- in this migration. This is in addition to, not a replacement for, the
-- Migration 006 Stage 3D prerequisites already on record (resource
-- requirements for all Migration 006 packages, Corporate & Commercial's
-- quote-only scheduling decision, and Closing's unresolved duration).
-- =====================================================================
