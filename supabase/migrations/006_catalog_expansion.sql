-- =====================================================================
-- Posterchild Media — Migration 006: Catalog Expansion
-- =====================================================================
-- DATA ONLY. No table, column, constraint, extension, index, function,
-- trigger, RLS policy, grant, or public view is created, dropped, or
-- altered here. Builds on the live Migration 001–005 foundation —
-- none of those is touched. No resource_reservations/booking_holds/
-- bookings row is touched, and no service_package_resource_requirements
-- row is added for any new package: live availability/hold integration
-- for these new packages is explicitly deferred to a future stage, per
-- instruction, so wiring resource requirements now would be premature.
--
-- Scope, in order:
--   1. Corrects two existing portraits-milestones package descriptions
--      (Power Session, Essential Portrait — "up to 2 looks").
--   2. Renames/reprices the existing "Photo Retouching" add-on to
--      "Skin & Beauty Retouching" at $25/image (was $40/image). The
--      slug (photo-retouching) is intentionally unchanged so any
--      existing reference to it by id/slug remains valid.
--   3. Adds a large set of new, already-approved Portraits & Milestones
--      packages (General Portrait extras, Birthday, Graduate/Senior,
--      Professional/Headshots, Couples, Family, Prom, Maternity,
--      Kids & Milestones, Holiday).
--   4. Adds five Wedding packages and five wedding-specific add-ons
--      under the EXISTING `events` service (weddings are not a new
--      top-level service, per instruction).
--   5. Adds five specialty creative-edit add-ons (general, i.e.
--      applicable_service_id IS NULL, same as the existing Photo
--      Retouching/Video Editing/Additional Revisions rows).
--   6. Adds five Kids & Milestones conditional add-ons, plus one
--      Prom-specific add-on (Additional Prom Person), all scoped to
--      portraits-milestones — see the SCHEMA LIMITATION note below.
--   7. Adds one new top-level service, "Travel & Personal Creative",
--      with five packages.
--   8. Retires Corporate & Commercial's preset Half Day/Full Day
--      pricing in favor of custom_quote (quote-only) — same names and
--      duration framing kept, only pricing_type/retail_price_cents move.
--   9. Deactivates the old Real Estate Standard/Luxury preset-pricing
--      packages (is_active = false, never deleted) and adds the two
--      newly approved Real Estate offerings (Property Images &
--      Walkthrough Tour, Closing).
--  10. Adds Prom Mini ($150 fixed, 30 minutes) alongside the unchanged
--      existing Prom Experience.
--
-- SCHEMA LIMITATION (reported, not fixed here, per instruction):
-- service_addons has no package-level applicability column — only
-- applicable_service_id (service-level). The five Kids & Milestones
-- add-ons below (background/set/cake/balloon options) are therefore
-- only as scoped as "applies somewhere under Portraits & Milestones"
-- at the DATABASE level; they are NOT restricted to the Little Moments
-- package by any constraint here. The Stage 3C wizard is responsible
-- for only presenting them when the customer has selected the Little
-- Moments package — see wizard.js. A future schema phase could add a
-- proper `service_package_id` (or a join table, for many-to-many)
-- column to service_addons if package-level restriction is ever needed
-- at the database layer itself; that is NOT implemented here, since
-- inventing it in a data-only migration was explicitly out of scope.
--
-- SCHEMA LIMITATION (reported, not fixed here, per instruction):
-- pricing_type has no percentage-of-subtotal concept. "Rush Wedding
-- Gallery" (+35% of the applicable package price) cannot be expressed
-- as a fixed retail_price_cents value without fabricating a number that
-- depends on which package/quantity it applies to. It is modeled as
-- pricing_type = 'custom_quote' (is_bookable = true, so it still
-- appears as a normal selectable interest — Stage 3C already renders
-- custom_quote as "Custom Quote" via the existing pricingLabel()
-- function, exactly matching the instruction to present it as an
-- interest/request rather than a computed line item), with the +35%
-- business rule documented in its public_description and
-- internal_notes for staff reference.
--
-- STAGE 3D PREREQUISITE (not a schema limitation):
-- Property Images & Walkthrough Tour (real-estate-media, hourly) is now
-- seeded with the approved minimum_units = 1 (a 1-hour minimum),
-- resolving the earlier gap where an hourly package with NULL
-- minimum_units would fail closed (policy_misconfigured, a 500) on any
-- hold attempt -- the exact defect Migration 003 corrected for Studio
-- Rental Hourly. minimum_units is therefore no longer what blocks
-- Stage 3D for this package; service_package_resource_requirements
-- (still unseeded for every new package in this migration, per
-- instruction) and the availability/hold resource-role policy for
-- real-estate-media remain the actual prerequisites.
-- Closing (fixed) is still seeded with duration_minutes = NULL, since no
-- duration has been approved; this is schema-legal (no CHECK constraint
-- requires a fixed package to carry a duration) but means no
-- exact-duration validation will apply to it once booking is wired up --
-- consistent with how Team/Campaign Production (custom_quote) already
-- behaves, not a new pattern. Left unchanged this pass, per instruction.
-- Corporate & Commercial's Half Day / Full Day are custom_quote
-- (quote-only) offerings and must not enter live availability/hold until
-- their Stage 3D scheduling behavior is deliberately decided -- a
-- custom_quote package CAN structurally receive a hold today (hold's
-- pricing logic already handles custom_quote with no computed price),
-- but nothing in this migration activates that for Corporate, and doing
-- so remains a distinct future decision, not an automatic consequence of
-- being quote-only.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Correct two existing portraits-milestones package descriptions
--    ("up to 2 looks") — same idempotent upsert idiom Migration 001
--    already uses for this exact table, so untouched fields are left
--    exactly as they are (matched via excluded.<column> on every column,
--    not just the two that actually change).
-- ---------------------------------------------------------------------
insert into public.service_packages
  (service_id, slug, name, pricing_type, retail_price_cents, duration_minutes,
   is_limited_release, is_active, is_bookable, sort_order, public_description)
select s.id, v.slug, v.name, v.pricing_type::public.pricing_type, v.retail_price_cents,
       v.duration_minutes, v.is_limited_release, true, true, v.sort_order, v.public_description
from public.services s
join (values
  ('power-session',      'Power Session',      'fixed', 15000, 60,  true,  10,
    'Photographer only, 1 location, up to 2 looks, 3 edited images, 72-hour delivery. Limited-release session.'),
  ('essential-portrait',  'Essential Portrait', 'fixed', 20000, 60,  false, 20,
    'Up to 2 looks, 1 location, 5 edited images.')
) as v(slug, name, pricing_type, retail_price_cents, duration_minutes, is_limited_release, sort_order, public_description)
  on true
where s.slug = 'portraits-milestones'
on conflict (service_id, slug) do update set
  name = excluded.name,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  duration_minutes = excluded.duration_minutes,
  is_limited_release = excluded.is_limited_release,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

-- ---------------------------------------------------------------------
-- 2. Rename + reprice the existing Photo Retouching add-on. Slug is
--    unchanged (photo-retouching) — only display name and price move.
-- ---------------------------------------------------------------------
insert into public.service_addons
  (slug, name, applicable_service_id, pricing_type, retail_price_cents, unit_label,
   production_cost_cents, requires_approval, is_active, is_bookable, sort_order, public_description)
values
  ('photo-retouching', 'Skin & Beauty Retouching', null, 'per_unit', 2500, 'per image', null, false, true, true, 10,
    'Detailed skin work, blemish removal, flyaways/minor cleanup, and polished beauty finishing. Standard editing included with your package already covers normal exposure, color correction, crop, and general finishing — this is separate, advanced retouching.')
on conflict (slug) do update set
  name = excluded.name,
  applicable_service_id = excluded.applicable_service_id,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  unit_label = excluded.unit_label,
  production_cost_cents = excluded.production_cost_cents,
  requires_approval = excluded.requires_approval,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

-- ---------------------------------------------------------------------
-- 3. New Portraits & Milestones packages — General Portrait extra,
--    Birthday, Graduate/Senior, Professional/Headshots, Prom,
--    Maternity, Kids & Milestones, Couples, Family, Holiday.
--    Holiday rows are ordinary rows using the existing is_active
--    column — no new seasonal-activation mechanism is introduced;
--    deactivating a holiday package later is simply is_active=false.
-- ---------------------------------------------------------------------
insert into public.service_packages
  (service_id, slug, name, pricing_type, retail_price_cents, duration_minutes,
   is_limited_release, is_active, is_bookable, sort_order, public_description)
select s.id, v.slug, v.name, v.pricing_type::public.pricing_type, v.retail_price_cents,
       v.duration_minutes, v.is_limited_release, true, true, v.sort_order, v.public_description
from public.services s
join (values
  ('mini-session', 'Mini Session', 'fixed', 10000, 30, true, 5,
    '1 look, 1 location, 2 edited images. Photographer only. Limited-release session.'),

  ('birthday-spotlight', 'Birthday Spotlight', 'fixed', 25000, 75, false, 110,
    'Up to 2 looks, 7 edited images.'),

  ('graduate-senior-experience', 'Graduate / Senior Experience', 'fixed', 27500, 90, false, 120,
    'Up to 3 looks, 8 edited images, 1 location. Suitable for high-school seniors and college graduates — cap/gown and personal looks may be used within the look allowance.'),

  ('professional-presence', 'Professional Presence', 'fixed', 22500, 60, false, 130,
    'Up to 2 professional looks, 1 location, 6 edited images. Headshot and personal-brand compositions for individuals — company-wide headshot projects are scoped under Corporate & Commercial.'),

  ('couples-story', 'Couples Story', 'fixed', 25000, 60, false, 140,
    '2 people, up to 2 looks, 1 location, 8 edited images.'),
  ('couples-experience', 'Couples Experience', 'fixed', 35000, 90, false, 141,
    '2 people, up to 3 looks, 1–2 nearby locations, 12 edited images. Enhanced creative direction.'),

  ('family-portrait', 'Family Portrait', 'fixed', 27500, 60, false, 150,
    'Up to 5 people, up to 2 coordinated looks, 1 location, 8 edited images.'),
  ('family-story', 'Family Story', 'fixed', 37500, 90, false, 151,
    'Up to 8 people, up to 2 looks, 12 edited images. Expanded individual/group combinations.'),
  ('extended-family', 'Extended Family', 'starting_at', 45000, null, false, 152,
    '90+ minutes. 9+ people, 15+ edited images. Custom planning based on group size.'),

  ('prom-mini', 'Prom Mini', 'fixed', 15000, 30, false, 159,
    '30 minutes.'),
  ('prom-experience', 'Prom Experience', 'fixed', 22500, 60, false, 160,
    'Up to 2 looks, 6 edited images. Individual or couple — larger groups require additional or custom scope.'),

  ('maternity-story', 'Maternity Story', 'fixed', 30000, 90, false, 170,
    'Up to 3 looks, 10 edited images. Partner/immediate-family participation may be accommodated. Specialty styling, gowns, and florals are not automatically included.'),

  ('little-moments', 'Little Moments', 'fixed', 22500, 60, false, 180,
    'Up to 2 looks, 6 edited images. Intended for kids, babies, birthdays, and childhood milestones.'),

  ('holiday-mini', 'Holiday Mini', 'fixed', 12500, 30, false, 190,
    '1 seasonal set/look, up to 5 people, 3 edited images.'),
  ('holiday-portrait-experience', 'Holiday Portrait Experience', 'fixed', 25000, 60, false, 191,
    'Up to 2 seasonal looks/sets, up to 6 people, 8 edited images.'),
  ('holiday-family-experience', 'Holiday Family Experience', 'fixed', 32500, 75, false, 192,
    'Up to 2 seasonal looks/sets, up to 10 people, 12 edited images.'),
  ('custom-holiday-story', 'Custom Holiday Story', 'starting_at', 45000, null, false, 193,
    '90+ minutes. Custom concept/set, 15+ edited images, enhanced creative direction.')
) as v(slug, name, pricing_type, retail_price_cents, duration_minutes, is_limited_release, sort_order, public_description)
  on true
where s.slug = 'portraits-milestones'
on conflict (service_id, slug) do update set
  name = excluded.name,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  duration_minutes = excluded.duration_minutes,
  is_limited_release = excluded.is_limited_release,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

-- ---------------------------------------------------------------------
-- 4a. Wedding packages — under the EXISTING `events` service, not a
--     new top-level service. duration_minutes on the four `fixed`
--     packages follows the exact same "fixed price + block length in
--     duration_minutes, described as 'up to N hours'" idiom Migration
--     001 already uses for Half-Day/Full-Day Studio Rental. The two
--     open-ended items (Custom Wedding Production) carry no duration.
-- ---------------------------------------------------------------------
insert into public.service_packages
  (service_id, slug, name, pricing_type, retail_price_cents, duration_minutes,
   is_active, is_bookable, sort_order, public_description)
select s.id, v.slug, v.name, v.pricing_type::public.pricing_type, v.retail_price_cents,
       v.duration_minutes, true, true, v.sort_order, v.public_description
from public.services s
join (values
  ('intimate-wedding', 'Intimate Wedding', 'fixed', 75000, 180, 20,
    'Up to 3 hours. 1 photographer. Ceremony and portraits. 75+ edited images. Planning consultation.'),
  ('signature-wedding', 'Signature Wedding', 'fixed', 150000, 360, 30,
    'Up to 6 hours. 1 photographer. Getting-ready, ceremony, portraits, and reception coverage as timeline permits. 175+ edited images. Planning and timeline consultation.'),
  ('editorial-wedding', 'Editorial Wedding', 'fixed', 225000, 480, 40,
    'Up to 8 hours. Lead and second photographer. Editorial creative direction for fuller wedding-day storytelling. 300+ edited images. Engagement session included. Planning and timeline consultation. Optional aerial/drone coverage — subject to location, airspace, weather, venue restrictions, safety conditions, and operator availability.'),
  ('wedding-photo-film', 'Wedding Photo + Film', 'fixed', 325000, 480, 50,
    'Up to 8 hours. Photography team plus videographer. 300+ edited images. Highlight film. Engagement session. Planning and timeline consultation. Optional aerial/drone footage — subject to location, airspace, weather, venue restrictions, safety conditions, and operator availability.'),
  ('custom-wedding-production', 'Custom Wedding Production', 'custom_quote', null, null, 60,
    'Destination, multi-day, or large-production weddings. Custom crew. Photo/video/production scope determined by proposal.')
) as v(slug, name, pricing_type, retail_price_cents, duration_minutes, sort_order, public_description)
  on true
where s.slug = 'events'
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
-- 4b. Wedding-specific add-ons, scoped to the `events` service via
--     applicable_service_id (the finest-grained applicability this
--     schema supports — see the package-level SCHEMA LIMITATION note
--     above; these are not further restricted to only the five Wedding
--     packages at the database level, only at the database's
--     service-level granularity. The Stage 3C wizard only surfaces them
--     when a Wedding package is selected).
-- ---------------------------------------------------------------------
insert into public.service_addons
  (slug, name, applicable_service_id, pricing_type, retail_price_cents, unit_label,
   requires_approval, is_active, is_bookable, sort_order, public_description, internal_notes)
select v.slug, v.name, s.id, v.pricing_type::public.pricing_type, v.retail_price_cents, v.unit_label,
       v.requires_approval, true, v.is_bookable, v.sort_order, v.public_description, v.internal_notes
from public.services s
join (values
  ('additional-wedding-coverage', 'Additional Wedding Coverage', 'hourly', 20000, 'per hour', false, true, 40,
    'Coverage time beyond your package''s included hours.', null),
  ('second-photographer', 'Second Photographer', 'starting_at', 50000, null, false, true, 50,
    'Starting at $500 — final scope depends on coverage length and timeline.', null),
  ('engagement-session', 'Engagement Session', 'fixed', 30000, null, false, true, 60,
    'A dedicated engagement session.', null),
  ('rehearsal-welcome-event-coverage', 'Rehearsal / Welcome Event Coverage', 'starting_at', 50000, null, false, true, 70,
    'Starting at $500 — rehearsal dinner or welcome-event coverage.', null),
  ('rush-wedding-gallery', 'Rush Wedding Gallery', 'custom_quote', null, null, false, true, 80,
    'Rush turnaround for your wedding gallery — typically +35% of the applicable package price, confirmed with your project.',
    'Business rule: +35% of the applicable package subtotal. Modeled as custom_quote because service_packages/service_addons.retail_price_cents cannot express a percentage-of-subtotal modifier — see Migration 006 header comment.')
) as v(slug, name, pricing_type, retail_price_cents, unit_label, requires_approval, is_bookable, sort_order, public_description, internal_notes)
  on true
where s.slug = 'events'
on conflict (slug) do update set
  name = excluded.name,
  applicable_service_id = excluded.applicable_service_id,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  unit_label = excluded.unit_label,
  requires_approval = excluded.requires_approval,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description,
  internal_notes = excluded.internal_notes;

-- ---------------------------------------------------------------------
-- 5. Specialty creative-edit add-ons — general (applicable_service_id
--    IS NULL), matching the existing Photo Retouching / Video Editing /
--    Additional Revisions rows. Starting_at is never presented as a
--    guaranteed total by the existing pricingLabel()/buildAddonPricingSummary
--    logic already audited in Stage 3.
-- ---------------------------------------------------------------------
insert into public.service_addons
  (slug, name, applicable_service_id, pricing_type, retail_price_cents, unit_label,
   requires_approval, is_active, is_bookable, sort_order, public_description)
values
  ('poster-treatment', 'Poster Treatment', null, 'per_unit', 7500, 'per image', false, true, true, 40,
    'High-impact poster/cover treatment — typography, graphic elements, and enhanced color treatment.'),
  ('fantasy-edit', 'Fantasy Edit', null, 'per_unit', 12500, 'per image', false, true, true, 50,
    'High-fantasy/whimsical treatment — compositing, magical effects, stylized atmosphere and environments.'),
  ('cyber-edit', 'Cyber Edit', null, 'per_unit', 12500, 'per image', false, true, true, 60,
    'Futuristic/cyber aesthetic — lighting effects, digital/HUD-style elements, compositing.'),
  ('gameworld-edit', 'Gameworld Edit', null, 'per_unit', 15000, 'per image', false, true, true, 70,
    'Video-game-inspired character/key-art treatment — elaborate compositing, effects, and environmental design.'),
  ('custom-art-composite', 'Custom Art Composite', null, 'starting_at', 17500, 'per image', false, true, true, 80,
    'Starting at $175/image. Advanced custom compositing/manipulation — custom-built environments or complex concepts.')
on conflict (slug) do update set
  name = excluded.name,
  applicable_service_id = excluded.applicable_service_id,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  unit_label = excluded.unit_label,
  requires_approval = excluded.requires_approval,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

-- ---------------------------------------------------------------------
-- 6. Kids & Milestones conditional add-ons — scoped to
--    portraits-milestones (see SCHEMA LIMITATION note above; the
--    Little-Moments-only restriction is enforced in the Stage 3C
--    wizard, not the database).
-- ---------------------------------------------------------------------
insert into public.service_addons
  (slug, name, applicable_service_id, pricing_type, retail_price_cents, unit_label,
   requires_approval, is_active, is_bookable, sort_order, public_description)
select v.slug, v.name, s.id, v.pricing_type::public.pricing_type, v.retail_price_cents, v.unit_label,
       v.requires_approval, true, true, v.sort_order, v.public_description
from public.services s
join (values
  ('custom-color-background', 'Custom Color Background', 'starting_at', 3500, null, true, 10,
    'Starting at $35. Requires advance notice and is subject to availability.'),
  ('seasonal-set-design', 'Seasonal Set Design', 'starting_at', 7500, null, true, 20,
    'Starting at $75. Requires advance notice and is subject to availability.'),
  ('custom-set-design', 'Custom Set Design', 'starting_at', 15000, null, true, 30,
    'Starting at $150. Requires advance notice and is subject to availability.'),
  ('smash-cake-birthday-cake', 'Smash Cake / Birthday Cake', 'starting_at', 5000, null, true, 40,
    'Starting at $50. Requires advance notice and is subject to availability. Custom/perishable purchased items may become non-refundable once purchased.'),
  ('balloon-styling', 'Balloon Styling', 'starting_at', 4000, null, true, 50,
    'Starting at $40. Requires advance notice and is subject to availability. Custom/perishable purchased items may become non-refundable once purchased.')
) as v(slug, name, pricing_type, retail_price_cents, unit_label, requires_approval, sort_order, public_description)
  on true
where s.slug = 'portraits-milestones'
on conflict (slug) do update set
  name = excluded.name,
  applicable_service_id = excluded.applicable_service_id,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  unit_label = excluded.unit_label,
  requires_approval = excluded.requires_approval,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

-- ---------------------------------------------------------------------
-- 6b. Prom-specific add-on — same service-level scoping limitation as
--     6 above (see SCHEMA LIMITATION note). requires_approval = false
--     since, unlike the Kids & Milestones set/cake/balloon options,
--     adding a person on set needs no special advance sourcing.
-- ---------------------------------------------------------------------
insert into public.service_addons
  (slug, name, applicable_service_id, pricing_type, retail_price_cents, unit_label,
   requires_approval, is_active, is_bookable, sort_order, public_description)
select 'additional-prom-person', 'Additional Prom Person', s.id, 'per_unit'::public.pricing_type, 5000,
       'per additional person', false, true, true, 60,
       'If friends want to join the client''s Prom photos while already on set, they may be added for $50 per additional person.'
from public.services s
where s.slug = 'portraits-milestones'
on conflict (slug) do update set
  name = excluded.name,
  applicable_service_id = excluded.applicable_service_id,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  unit_label = excluded.unit_label,
  requires_approval = excluded.requires_approval,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

-- ---------------------------------------------------------------------
-- 7a. New top-level service: Travel & Personal Creative.
-- ---------------------------------------------------------------------
insert into public.services (slug, name, is_active, is_bookable, sort_order)
values
  ('travel-personal-creative', 'Travel & Personal Creative', true, true, 70)
on conflict (slug) do update set
  name = excluded.name,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order;

-- ---------------------------------------------------------------------
-- 7b. Travel & Personal Creative packages. All modeled as starting_at
--     (never fixed/hourly): each is a creative/production DAY rate
--     explicitly excluding separate travel costs (airfare, lodging,
--     ground transport, permits, visas, meals/per diem, etc. — none of
--     which are seeded here, since no amount has been approved for
--     any of them, per instruction), so the true final total for any
--     booking always depends on trip length and those unseeded costs.
--     unit_label documents the day-rate framing without introducing a
--     new pricing_type or a per-day duration/quantity mechanism the
--     booking engine doesn't otherwise support.
-- ---------------------------------------------------------------------
insert into public.service_packages
  (service_id, slug, name, pricing_type, retail_price_cents, unit_label, duration_minutes,
   is_active, is_bookable, sort_order, public_description)
select s.id, v.slug, v.name, v.pricing_type::public.pricing_type, v.retail_price_cents,
       v.unit_label, v.duration_minutes, true, true, v.sort_order, v.public_description
from public.services s
join (values
  ('travel-day-coverage', 'Travel Day Coverage', 'starting_at', 75000, 'per day', null::integer, 10,
    'Personal/travel photography and content coverage. Creative fee per day, plus travel.'),
  ('travel-creative-experience', 'Travel Creative Experience', 'starting_at', 125000, 'per day', null::integer, 20,
    'Photography, active creative direction, and content planning. Creative fee per day, plus travel.'),
  ('personal-photographer', 'Personal Photographer', 'starting_at', 150000, 'per day', null::integer, 30,
    'Dedicated full-day personal/talent coverage with priority availability. Creative fee per day, plus travel.'),
  ('tour-multi-day-creative', 'Tour / Multi-Day Creative', 'starting_at', 350000, null, null::integer, 40,
    'For 3+ day assignments, tours, campaigns, or destination projects. Plus travel.'),
  ('creative-residency-retainer', 'Creative Residency / Retainer', 'custom_quote', null, null, null::integer, 50,
    'Recurring travel for entertainers/talent, travel brands/agents, or an ongoing creative partnership.')
) as v(slug, name, pricing_type, retail_price_cents, unit_label, duration_minutes, sort_order, public_description)
  on true
where s.slug = 'travel-personal-creative'
on conflict (service_id, slug) do update set
  name = excluded.name,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  unit_label = excluded.unit_label,
  duration_minutes = excluded.duration_minutes,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

-- ---------------------------------------------------------------------
-- 8. Corporate & Commercial — retire preset pricing, quote-only.
--    Half Day / Full Day are kept as named offerings (their duration
--    framing still helps inquiry intake) but move to pricing_type =
--    'custom_quote' with retail_price_cents cleared to NULL -- the same
--    pattern Migration 001 already uses for Team/Campaign Production
--    under Creative Direction & Production. duration_minutes is left
--    populated (240/480): nothing in the schema ties duration_minutes
--    to pricing_type, and the block-length framing ("up to 4/8 hours")
--    remains accurate and useful regardless of whether the price is
--    preset or quoted -- this is the cleanest minimal treatment; no
--    slug/name change or new package split is needed.
-- ---------------------------------------------------------------------
insert into public.service_packages
  (service_id, slug, name, pricing_type, retail_price_cents, duration_minutes,
   is_active, is_bookable, sort_order, public_description)
select s.id, v.slug, v.name, v.pricing_type::public.pricing_type, v.retail_price_cents,
       v.duration_minutes, true, true, v.sort_order, v.public_description
from public.services s
join (values
  ('half-day', 'Half Day', 'custom_quote', null::integer, 240, 10,
    'Up to 4 hours. Custom quote -- scope varies by production needs, crew, usage/licensing, location, project duration, and deliverables. Commercial usage/licensing quoted separately.'),
  ('full-day', 'Full Day', 'custom_quote', null::integer, 480, 20,
    'Up to 8 hours. Custom quote -- scope varies by production needs, crew, usage/licensing, location, project duration, and deliverables. Commercial usage/licensing quoted separately.')
) as v(slug, name, pricing_type, retail_price_cents, duration_minutes, sort_order, public_description)
  on true
where s.slug = 'corporate-commercial'
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
-- 9a. Real Estate — retire the old Standard/Luxury preset-pricing rows.
--     Deactivated (is_active = false, is_bookable = false), never
--     deleted -- Migration 001's historical row text is left completely
--     untouched; this only changes their CURRENT catalog-visibility
--     state via the same upsert-by-natural-key idiom used throughout
--     this migration. public_service_packages already filters on
--     is_active, so a deactivated row simply stops appearing to
--     customers/the wizard without erasing its history.
-- ---------------------------------------------------------------------
insert into public.service_packages
  (service_id, slug, name, pricing_type, retail_price_cents, is_active, is_bookable, sort_order, public_description)
select s.id, v.slug, v.name, v.pricing_type::public.pricing_type, v.retail_price_cents,
       false, false, v.sort_order, v.public_description
from public.services s
join (values
  ('standard-property', 'Standard Property', 'starting_at', 35000, 10,
    'Retired -- superseded by Property Images & Walkthrough Tour and Closing.'),
  ('luxury-property',   'Luxury Property',   'starting_at', 65000, 20,
    'Retired -- superseded by Property Images & Walkthrough Tour and Closing.')
) as v(slug, name, pricing_type, retail_price_cents, sort_order, public_description)
  on true
where s.slug = 'real-estate-media'
on conflict (service_id, slug) do update set
  name = excluded.name,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

-- ---------------------------------------------------------------------
-- 9b. Real Estate — approved new packages. Property Images &
--     Walkthrough Tour now carries the approved 1-hour minimum
--     (minimum_units = 1), matching Studio Rental Hourly's own
--     resolved minimum -- this closes the earlier gap where an hourly
--     package with NULL minimum_units would fail closed
--     (policy_misconfigured) on any hold attempt. Closing still has no
--     approved duration, so duration_minutes remains NULL (schema-legal
--     for a fixed package; left unspecified rather than fabricated).
-- ---------------------------------------------------------------------
insert into public.service_packages
  (service_id, slug, name, pricing_type, retail_price_cents, unit_label, duration_minutes, minimum_units,
   is_active, is_bookable, sort_order, public_description)
select s.id, v.slug, v.name, v.pricing_type::public.pricing_type, v.retail_price_cents,
       v.unit_label, v.duration_minutes, v.minimum_units, true, true, v.sort_order, v.public_description
from public.services s
join (values
  ('property-images-walkthrough-tour', 'Property Images & Walkthrough Tour', 'hourly', 7500, 'per hour', null::integer, 1::numeric, 10,
    'Real estate/property photography and walkthrough-tour video coverage. 1-hour minimum.'),
  ('closing', 'Closing', 'fixed', 15000, null, null::integer, null::numeric, 20,
    'Real-estate closing coverage.')
) as v(slug, name, pricing_type, retail_price_cents, unit_label, duration_minutes, minimum_units, sort_order, public_description)
  on true
where s.slug = 'real-estate-media'
on conflict (service_id, slug) do update set
  name = excluded.name,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  unit_label = excluded.unit_label,
  duration_minutes = excluded.duration_minutes,
  minimum_units = excluded.minimum_units,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

-- =====================================================================
-- FAIL-FAST VALIDATION — runs after all inserts/updates above, inside
-- the same implicit migration transaction. Confirms exact intended
-- end-state counts, not merely that the statements ran without error.
-- =====================================================================
do $$
declare
  portraits_pkg_count integer;
  events_pkg_count integer;
  travel_pkg_count integer;
  travel_service_count integer;
  new_addon_count integer;
  retouch_name text;
  retouch_price integer;
  corp_quote_count integer;
  re_retired_count integer;
  re_active_count integer;
  prom_mini_price integer;
  prom_mini_duration integer;
  prom_person_price integer;
  prom_person_type public.pricing_type;
  re_hourly_price integer;
  re_hourly_min numeric;
  re_closing_price integer;
  re_closing_duration integer;
begin
  select count(*) into portraits_pkg_count
  from public.service_packages sp
  join public.services s on s.id = sp.service_id
  where s.slug = 'portraits-milestones';
  if portraits_pkg_count <> 21 then
    raise exception 'Migration 006 validation failed: portraits-milestones has % packages, expected 21 (4 original + 1 mini-session + 15 prior new + 1 prom-mini).', portraits_pkg_count;
  end if;

  select count(*) into events_pkg_count
  from public.service_packages sp
  join public.services s on s.id = sp.service_id
  where s.slug = 'events';
  if events_pkg_count <> 6 then
    raise exception 'Migration 006 validation failed: events has % packages, expected 6 (1 original Event Coverage + 5 Wedding).', events_pkg_count;
  end if;

  select count(*) into travel_service_count from public.services where slug = 'travel-personal-creative';
  if travel_service_count <> 1 then
    raise exception 'Migration 006 validation failed: travel-personal-creative service missing.';
  end if;

  select count(*) into travel_pkg_count
  from public.service_packages sp
  join public.services s on s.id = sp.service_id
  where s.slug = 'travel-personal-creative';
  if travel_pkg_count <> 5 then
    raise exception 'Migration 006 validation failed: travel-personal-creative has % packages, expected 5.', travel_pkg_count;
  end if;

  select count(*) into new_addon_count
  from public.service_addons
  where slug in (
    'poster-treatment','fantasy-edit','cyber-edit','gameworld-edit','custom-art-composite',
    'additional-wedding-coverage','second-photographer','engagement-session',
    'rehearsal-welcome-event-coverage','rush-wedding-gallery',
    'custom-color-background','seasonal-set-design','custom-set-design',
    'smash-cake-birthday-cake','balloon-styling','additional-prom-person'
  );
  if new_addon_count <> 16 then
    raise exception 'Migration 006 validation failed: % of the 16 expected new add-ons were found.', new_addon_count;
  end if;

  select name, retail_price_cents into retouch_name, retouch_price
  from public.service_addons where slug = 'photo-retouching';
  if retouch_name is distinct from 'Skin & Beauty Retouching' or retouch_price is distinct from 2500 then
    raise exception 'Migration 006 validation failed: photo-retouching row is name=% price=%, expected "Skin & Beauty Retouching" / 2500.', retouch_name, retouch_price;
  end if;

  -- Corporate & Commercial: both packages must now be custom_quote with
  -- no preset price.
  select count(*) into corp_quote_count
  from public.service_packages sp
  join public.services s on s.id = sp.service_id
  where s.slug = 'corporate-commercial'
    and sp.slug in ('half-day', 'full-day')
    and sp.pricing_type = 'custom_quote'
    and sp.retail_price_cents is null;
  if corp_quote_count <> 2 then
    raise exception 'Migration 006 validation failed: expected 2 corporate-commercial packages as custom_quote with no price, found %.', corp_quote_count;
  end if;

  -- Real Estate: old Standard/Luxury must be deactivated (never
  -- deleted), and exactly the two new packages must be active.
  select count(*) into re_retired_count
  from public.service_packages sp
  join public.services s on s.id = sp.service_id
  where s.slug = 'real-estate-media'
    and sp.slug in ('standard-property', 'luxury-property')
    and sp.is_active = false;
  if re_retired_count <> 2 then
    raise exception 'Migration 006 validation failed: expected both old real-estate-media packages deactivated, found % deactivated.', re_retired_count;
  end if;

  select count(*) into re_active_count
  from public.service_packages sp
  join public.services s on s.id = sp.service_id
  where s.slug = 'real-estate-media' and sp.is_active = true;
  if re_active_count <> 2 then
    raise exception 'Migration 006 validation failed: real-estate-media has % active packages, expected exactly 2 (Property Images & Walkthrough Tour, Closing).', re_active_count;
  end if;

  -- Property Images & Walkthrough Tour: $75/hour, 1-hour minimum.
  select retail_price_cents, minimum_units into re_hourly_price, re_hourly_min
  from public.service_packages sp
  join public.services s on s.id = sp.service_id
  where s.slug = 'real-estate-media' and sp.slug = 'property-images-walkthrough-tour';
  if re_hourly_price is distinct from 7500 or re_hourly_min is distinct from 1::numeric then
    raise exception 'Migration 006 validation failed: property-images-walkthrough-tour is price=% minimum_units=%, expected 7500 / 1.', re_hourly_price, re_hourly_min;
  end if;

  -- Closing: $150 fixed, no duration approved (must stay NULL, never fabricated).
  select retail_price_cents, duration_minutes into re_closing_price, re_closing_duration
  from public.service_packages sp
  join public.services s on s.id = sp.service_id
  where s.slug = 'real-estate-media' and sp.slug = 'closing';
  if re_closing_price is distinct from 15000 or re_closing_duration is not null then
    raise exception 'Migration 006 validation failed: closing is price=% duration=%, expected 15000 / NULL.', re_closing_price, re_closing_duration;
  end if;

  -- Prom Mini: $150 fixed, 30 minutes.
  select retail_price_cents, duration_minutes into prom_mini_price, prom_mini_duration
  from public.service_packages sp
  join public.services s on s.id = sp.service_id
  where s.slug = 'portraits-milestones' and sp.slug = 'prom-mini';
  if prom_mini_price is distinct from 15000 or prom_mini_duration is distinct from 30 then
    raise exception 'Migration 006 validation failed: prom-mini is price=% duration=%, expected 15000 / 30.', prom_mini_price, prom_mini_duration;
  end if;

  -- Additional Prom Person: $50 per_unit.
  select retail_price_cents, pricing_type into prom_person_price, prom_person_type
  from public.service_addons where slug = 'additional-prom-person';
  if prom_person_price is distinct from 5000 or prom_person_type is distinct from 'per_unit'::public.pricing_type then
    raise exception 'Migration 006 validation failed: additional-prom-person is price=% type=%, expected 5000 / per_unit.', prom_person_price, prom_person_type;
  end if;
end $$;
