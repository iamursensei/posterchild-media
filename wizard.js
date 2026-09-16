// wizard.js
//
// Posterchild Media -- Stage 3C booking wizard shell.
//
// Drives the five-step #wizardForm in booking.html using the live public
// catalog from catalog.js (window.loadPosterchildCatalog()). This stage
// does NOT call the availability or hold Edge Functions and does NOT
// write to Supabase in any way -- it only reads the six public_* catalog
// views (via catalog.js) and still submits the final inquiry through the
// existing FormSubmit endpoint, exactly as booking.html always has.
//
// State is a single in-memory object, session-only -- nothing here is
// written to localStorage/sessionStorage, since it may contain the
// customer's contact details.

(function () {
  'use strict';

  const TOTAL_STEPS = 5;

  const wizardState = {
    catalog: null,
    catalogStatus: 'loading', // 'loading' | 'ready' | 'failed'
    currentStep: 1,
    maxStepReached: 1,
    submitting: false,
    pendingServiceName: null,
    contact: { firstName: '', lastName: '', email: '', phone: '', source: '' },
    selectedServiceId: null,
    // Slug list of the currently active "What are we creating?" /
    // "What are we covering?" category, or null when the selected
    // service has no category layer (every service except Portraits &
    // Milestones and Events) -- see SERVICE_CATEGORY_MAP below. This is
    // a Stage 3C UI-only concept; the catalog has no category column on
    // service_packages.
    selectedCategorySlugs: null,
    selectedPackageId: null,
    selectedHourlyUnits: null,
    selectedHourlyExtended: false,
    selectedAddonIds: [],
    date: '',
    time: '',
    location: '',
    people: '',
    vision: '',
    inspiration: '',
    serviceInterestFreetext: '',
    selectedProducts: {}, // productId -> quantity (purchasable products only)
  };

  // ---------------------------------------------------------------------
  // Formatting helpers -- pure, no DOM, no network.
  // ---------------------------------------------------------------------

  function formatMoney(cents) {
    if (cents === null || cents === undefined) return '';
    const dollars = cents / 100;
    const hasFraction = cents % 100 !== 0;
    return '$' + dollars.toLocaleString('en-US', {
      minimumFractionDigits: hasFraction ? 2 : 0,
      maximumFractionDigits: 2,
    });
  }

  // Never fabricates a number for custom_quote/unpriced, never presents
  // starting_at as a guaranteed total -- the wording itself carries that
  // distinction through to every place this label is displayed.
  function pricingLabel(pkgOrProduct) {
    switch (pkgOrProduct.pricing_type) {
      case 'fixed':
        return formatMoney(pkgOrProduct.retail_price_cents);
      case 'hourly':
        return formatMoney(pkgOrProduct.retail_price_cents) + '/hour';
      case 'starting_at':
        return 'Starting at ' + formatMoney(pkgOrProduct.retail_price_cents);
      case 'custom_quote':
        return 'Custom Quote';
      case 'per_unit':
        return formatMoney(pkgOrProduct.retail_price_cents) + (pkgOrProduct.unit_label ? '/' + pkgOrProduct.unit_label.replace(/^per /, '') : '');
      default:
        return '';
    }
  }

  // Only the exact durations actually seeded in the catalog get a named
  // phrase; anything else falls back to an honest generic phrase rather
  // than guessing a business-meaningful label that was never approved.
  function durationCopy(minutes) {
    if (minutes === null || minutes === undefined) return '';
    if (minutes === 60) return '60 Minutes';
    if (minutes === 90) return '90 Minutes';
    if (minutes === 120) return '2 Hours';
    if (minutes === 240) return '4-Hour Block';
    if (minutes === 480) return '8-Hour Block';
    if (minutes % 60 === 0) return (minutes / 60) + '-Hour Block';
    return minutes + ' Minutes';
  }

  function hourlyMinimumCopy(minimumUnits) {
    if (minimumUnits === null || minimumUnits === undefined) return '';
    const n = Number(minimumUnits);
    return (n === 1 ? '1-hour minimum' : n + '-hour minimum');
  }

  // Stage 3C.1: the offset-aware America/New_York datetime conversion
  // helper that used to live here was removed. `new Date(`${dateStr}T${timeStr}:00`)`
  // interprets that wall-clock string in the BROWSER's local timezone, not
  // Eastern -- a customer outside Eastern Time (or a date near a DST
  // transition) would silently get the wrong offset. Stage 3C only needs
  // to collect and visibly label the date/time as Eastern; the actual
  // conversion is Stage 3D's responsibility, to be designed and tested
  // alongside the real availability/hold integration it feeds.

  function esc(str) {
    return String(str == null ? '' : str).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }

  // ---------------------------------------------------------------------
  // Catalog-derived selectable sets
  // ---------------------------------------------------------------------

  function getBookableServices() {
    if (!wizardState.catalog) return [];
    const c = wizardState.catalog;
    return c.services
      .filter((s) => (c.packagesByServiceId[s.id] || []).some((p) => p.is_bookable === true))
      .sort((a, b) => a.sort_order - b.sort_order);
  }

  function getBookablePackages(serviceId) {
    if (!wizardState.catalog || !serviceId) return [];
    const pkgs = wizardState.catalog.packagesByServiceId[serviceId] || [];
    return pkgs.filter((p) => p.is_bookable === true).sort((a, b) => a.sort_order - b.sort_order);
  }

  function getPackageById(id) {
    return wizardState.catalog ? wizardState.catalog.servicePackages.find((p) => p.id === id) : null;
  }

  function getGeneralBookableAddons() {
    if (!wizardState.catalog) return [];
    return wizardState.catalog.generalAddons
      .filter((a) => a.is_bookable === true)
      .sort((a, b) => a.sort_order - b.sort_order);
  }

  function getAddonBySlug(slug) {
    if (!wizardState.catalog) return null;
    return wizardState.catalog.serviceAddons.find((a) => a.slug === slug) || null;
  }

  // ---------------------------------------------------------------------
  // Category layer ("What are we creating?" / "What are we covering?")
  // -- a Stage 3C UI-only grouping over packages. The catalog schema has
  // no category column on service_packages; these lists exist only here
  // and are matched against real catalog package slugs at render time
  // (a slug that doesn't resolve to a bookable package is silently
  // skipped, never fabricated). Only the two services with enough
  // packages to actually benefit from grouping get this layer -- every
  // other service (including the new Travel & Personal Creative) goes
  // straight to its package tiles, per instruction not to add
  // unnecessary UI hierarchy.
  // ---------------------------------------------------------------------

  const PORTRAIT_CATEGORIES = [
    { label: 'General Portrait', slugs: ['mini-session', 'power-session', 'essential-portrait', 'signature-portrait', 'editorial-experience'] },
    { label: 'Birthday', slugs: ['birthday-spotlight'] },
    { label: 'Graduate / Senior', slugs: ['graduate-senior-experience'] },
    { label: 'Professional / Headshots', slugs: ['headshot-mini', 'professional-presence'] },
    { label: 'Couples', slugs: ['couples-story', 'couples-experience'] },
    { label: 'Family', slugs: ['family-portrait', 'family-story', 'extended-family'] },
    { label: 'Prom', slugs: ['prom-mini', 'prom-experience'] },
    { label: 'Maternity', slugs: ['maternity-story'] },
    { label: 'Kids & Milestones', slugs: ['little-moments-mini', 'little-moments'] },
    { label: 'Holiday', slugs: ['holiday-mini', 'holiday-portrait-experience', 'holiday-family-experience', 'custom-holiday-story'] },
  ];

  const EVENT_CATEGORIES = [
    { label: 'General Event', slugs: ['hourly'] },
    { label: 'Wedding', slugs: ['intimate-wedding', 'signature-wedding', 'editorial-wedding', 'wedding-photo-film', 'custom-wedding-production'] },
  ];

  const SERVICE_CATEGORY_LAYER = {
    'portraits-milestones': { legend: 'What are we creating?', categories: PORTRAIT_CATEGORIES },
    'events': { legend: 'What are we covering?', categories: EVENT_CATEGORIES },
  };

  // ---------------------------------------------------------------------
  // Package-specific add-on interests (Kids & Milestones conditional
  // options, Wedding-specific add-ons). service_addons has no
  // package-level applicability column -- only applicable_service_id
  // (service-level) -- so this mapping is how the package-level
  // restriction the catalog can't express is enforced, entirely in the
  // UI, per instruction. Each entry is matched against real add-on
  // slugs at render time via getAddonBySlug(); an unresolved slug is
  // silently skipped, never fabricated.
  // ---------------------------------------------------------------------

  const WEDDING_ADDON_SLUGS = [
    'additional-wedding-coverage', 'second-photographer', 'engagement-session',
    'rehearsal-welcome-event-coverage', 'rush-wedding-gallery',
  ];

  // Additional Prom Person applies to either Prom package (Mini or
  // Experience) -- both keys point at the same single-slug list.
  const PROM_ADDON_SLUGS = ['additional-prom-person'];

  // Both Little Moments packages (Mini and standard) get the same Kids
  // & Milestones conditional options -- neither is exposed to any other
  // portrait package.
  const KIDS_ADDON_SLUGS = ['custom-color-background', 'seasonal-set-design', 'custom-set-design', 'smash-cake-birthday-cake', 'balloon-styling'];

  const PACKAGE_SPECIFIC_ADDONS = {
    'little-moments-mini': { legend: 'Optional Extras for Little Moments', slugs: KIDS_ADDON_SLUGS },
    'little-moments': { legend: 'Optional Extras for Little Moments', slugs: KIDS_ADDON_SLUGS },
    'prom-mini': { legend: 'Optional Extras for Prom', slugs: PROM_ADDON_SLUGS },
    'prom-experience': { legend: 'Optional Extras for Prom', slugs: PROM_ADDON_SLUGS },
    'intimate-wedding': { legend: 'Wedding Add-On Interests', slugs: WEDDING_ADDON_SLUGS },
    'signature-wedding': { legend: 'Wedding Add-On Interests', slugs: WEDDING_ADDON_SLUGS },
    'editorial-wedding': { legend: 'Wedding Add-On Interests', slugs: WEDDING_ADDON_SLUGS },
    'wedding-photo-film': { legend: 'Wedding Add-On Interests', slugs: WEDDING_ADDON_SLUGS },
    'custom-wedding-production': { legend: 'Wedding Add-On Interests', slugs: WEDDING_ADDON_SLUGS },
  };

  // ---------------------------------------------------------------------
  // Step navigation
  // ---------------------------------------------------------------------

  function renderStepNav() {
    document.querySelectorAll('.wiz-step-btn').forEach((btn) => {
      const step = Number(btn.dataset.step);
      btn.classList.toggle('active', step === wizardState.currentStep);
      btn.classList.toggle('done', step < wizardState.currentStep);
      btn.disabled = step > wizardState.maxStepReached;
      if (step === wizardState.currentStep) {
        btn.setAttribute('aria-current', 'step');
      } else {
        btn.removeAttribute('aria-current');
      }
    });
  }

  function goToStep(n) {
    if (n < 1 || n > TOTAL_STEPS) return;
    wizardState.currentStep = n;
    if (n > wizardState.maxStepReached) wizardState.maxStepReached = n;
    document.querySelectorAll('.wiz-panel').forEach((panel) => {
      panel.hidden = Number(panel.dataset.step) !== n;
    });
    renderStepNav();
    if (n === 3) updateStep3Requirements();
    if (n === 5) renderReview();
    document.getElementById('booking-form').scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  // Toggles native `required` on the date/time fields to match
  // packageIsSchedulable() for whatever package is currently selected,
  // and shows an honest note in place of asking for a date/time the
  // catalog doesn't yet support scheduling for (custom_quote, Real
  // Estate). Native `required` here is a convenience affordance only --
  // computeMissingRequirements() is what actually gates navigation.
  function updateStep3Requirements() {
    const pkg = getPackageById(wizardState.selectedPackageId);
    const schedulable = packageIsSchedulable(pkg);
    const dateInput = document.getElementById('wizDate');
    const timeInput = document.getElementById('wizTime');
    const note = document.getElementById('wizNoScheduleNote');
    dateInput.required = schedulable;
    timeInput.required = schedulable;
    if (note) note.hidden = schedulable;
  }

  // A package is only "schedulable" (i.e. date/time is meaningful to ask
  // for) when the catalog itself supplies a real duration concept for it
  // -- a known duration_minutes block, or an hourly package with a real
  // minimum_units. custom_quote (Team/Campaign) and the two Real Estate
  // packages currently have neither, so no duration is invented for them
  // and date/time is not required -- exactly the packages Stage 3A/3C
  // already flagged as not yet supportable by live availability/hold.
  function packageIsSchedulable(pkg) {
    if (!pkg) return true;
    if (pkg.duration_minutes) return true;
    if (pkg.pricing_type === 'hourly' && pkg.minimum_units) return true;
    return false;
  }

  const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

  // Single source of truth for "is the wizard's state complete enough to
  // reach step N," read directly from wizardState rather than the DOM --
  // this is deliberately independent of which panel happens to be
  // visible, so it stays correct even if the customer jumps between
  // already-reached steps via the step nav (where native reportValidity()
  // on a `hidden` panel would silently skip fields that are no longer
  // valid). Returns an array of {step, msg}, ordered by step.
  function computeMissingRequirements() {
    const missing = [];
    if (!wizardState.contact.firstName.trim()) missing.push({ step: 1, msg: 'Please enter your first name.' });
    if (!EMAIL_RE.test(wizardState.contact.email.trim())) missing.push({ step: 1, msg: 'Please enter a valid email address.' });

    if (wizardState.catalogStatus === 'loading') {
      missing.push({ step: 2, msg: 'Please wait a moment for services to finish loading.' });
    } else if (wizardState.catalogStatus === 'ready') {
      if (!wizardState.selectedServiceId) {
        missing.push({ step: 2, msg: 'Please select a service.' });
      } else if (!wizardState.selectedPackageId) {
        missing.push({ step: 2, msg: 'Please select a package.' });
      } else {
        const pkg = getPackageById(wizardState.selectedPackageId);
        if (pkg && pkg.pricing_type === 'hourly' && !wizardState.selectedHourlyExtended && !wizardState.selectedHourlyUnits) {
          missing.push({ step: 2, msg: 'Please choose a session length.' });
        }
      }
    } else if (wizardState.catalogStatus === 'failed') {
      if (!wizardState.serviceInterestFreetext.trim()) {
        missing.push({ step: 2, msg: "Please tell us what you're interested in." });
      }
    }

    if (wizardState.catalogStatus === 'ready' && wizardState.selectedPackageId) {
      const pkg = getPackageById(wizardState.selectedPackageId);
      if (packageIsSchedulable(pkg)) {
        if (!wizardState.date) missing.push({ step: 3, msg: 'Please choose a preferred date.' });
        if (!wizardState.time) missing.push({ step: 3, msg: 'Please choose a preferred start time.' });
      }
    }

    return missing;
  }

  function showValidationMessage(msg) {
    const el = document.getElementById('wizValidationMessage');
    if (!el) return;
    el.textContent = msg;
    el.hidden = false;
  }

  function clearValidationMessage() {
    const el = document.getElementById('wizValidationMessage');
    if (el) el.hidden = true;
  }

  // Returns the first unmet requirement at or before `uptoStepInclusive`,
  // or null if everything up to that point is satisfied.
  function firstBlockingIssue(uptoStepInclusive) {
    const missing = computeMissingRequirements().filter((m) => m.step <= uptoStepInclusive);
    return missing[0] || null;
  }

  // Governs every forward navigation action (Continue buttons and
  // step-nav jumps alike) -- moving backward is always allowed without
  // re-validation, since it can never make the wizard's state less valid.
  function tryAdvanceTo(targetStep) {
    if (targetStep <= wizardState.currentStep) {
      clearValidationMessage();
      goToStep(targetStep);
      return;
    }
    const blocking = firstBlockingIssue(targetStep - 1);
    if (blocking) {
      goToStep(blocking.step);
      showValidationMessage(blocking.msg);
      return;
    }
    clearValidationMessage();
    goToStep(targetStep);
  }

  // ---------------------------------------------------------------------
  // Step 2: Service & Package rendering
  // ---------------------------------------------------------------------

  function renderServiceTiles() {
    const wrap = document.getElementById('wizServiceTiles');
    const services = getBookableServices();
    wrap.innerHTML = services.map((s) => `
      <label class="wiz-tile" data-service-id="${esc(s.id)}">
        <input type="radio" name="wizServiceRadio" class="wiz-tile-input" value="${esc(s.id)}" required ${s.id === wizardState.selectedServiceId ? 'checked' : ''}>
        <span class="wiz-tile-body">
          <span class="wiz-tile-name">${esc(s.name)}</span>
          <span class="wiz-tile-check" aria-hidden="true">✓ Selected</span>
        </span>
      </label>
    `).join('');
    wrap.querySelectorAll('input[name="wizServiceRadio"]').forEach((input) => {
      input.addEventListener('change', () => {
        applyServiceSelection(input.value);
      });
    });
    syncTileSelectedClasses(wrap);
  }

  function syncTileSelectedClasses(scopeEl) {
    scopeEl.querySelectorAll('.wiz-tile').forEach((tile) => {
      const input = tile.querySelector('.wiz-tile-input');
      tile.classList.toggle('selected', !!(input && input.checked));
    });
  }

  function applyServiceSelection(serviceId) {
    wizardState.selectedServiceId = serviceId;
    // Package, category, and hourly-duration state are service-specific
    // and always cleared here -- a stale package ID from a previous
    // service could otherwise leak into Review (getPackageById has no
    // cross-check against the currently selected service).
    wizardState.selectedCategorySlugs = null;
    wizardState.selectedPackageId = null;
    wizardState.selectedHourlyUnits = null;
    wizardState.selectedHourlyExtended = false;
    // selectedAddonIds is deliberately NOT cleared here: every general
    // add-on (Photo Retouching/Skin & Beauty Retouching, Video Editing,
    // Additional Revisions, and the specialty creative edits) carries
    // applicable_service_id === null in the catalog, meaning they are
    // genuinely applicable to every service -- clearing a still-valid
    // interest on a service change would invent an applicability rule
    // the catalog doesn't express. Package-specific interests (Kids &
    // Milestones / Wedding) DO get cleared, in renderPackageAddonSection(),
    // since those are no longer relevant once the package itself changes.
    renderServiceTiles();
    renderCategoryTiles();
    renderPackageTiles();
    renderAddonSection();
    updateStep3Requirements();
  }

  // A category tile is only genuinely selectable when it currently
  // resolves to at least one LIVE bookable package. Before Migration 006
  // is applied to production, most category slug lists (all Stage 3C.2
  // additions) resolve to zero live packages -- rendering those as
  // ordinary selectable tiles was the root cause of the blocking "Select
  // a package" bug (see report): the customer could pick a category,
  // reach an empty package grid, and be stuck on a requirement with
  // nothing to satisfy it. This is a genuine pre-production catalog/wizard
  // coordination gap, not a filtering-logic error -- the filtering itself
  // was always correct, it just had no guard for "this category currently
  // has nothing behind it."
  function categoryHasLivePackages(serviceId, categorySlugs) {
    return getBookablePackages(serviceId).some((p) => categorySlugs.includes(p.slug));
  }

  function renderCategoryTiles() {
    const fieldset = document.getElementById('wizCategoryFieldset');
    const legend = document.getElementById('wizCategoryLegend');
    const wrap = document.getElementById('wizCategoryTiles');
    const service = wizardState.catalog && wizardState.selectedServiceId
      ? wizardState.catalog.servicesById[wizardState.selectedServiceId]
      : null;
    const layer = service ? SERVICE_CATEGORY_LAYER[service.slug] : null;

    if (!layer) {
      fieldset.hidden = true;
      wrap.innerHTML = '';
      return;
    }
    // A category the customer had selected can become unavailable out
    // from under them (e.g. this render is a reaction to a service
    // change) -- clear the selection rather than leave stale, now-dead
    // state in place.
    if (wizardState.selectedCategorySlugs && !categoryHasLivePackages(wizardState.selectedServiceId, wizardState.selectedCategorySlugs)) {
      wizardState.selectedCategorySlugs = null;
    }
    legend.textContent = layer.legend;
    wrap.innerHTML = layer.categories.map((cat, i) => {
      const available = categoryHasLivePackages(wizardState.selectedServiceId, cat.slugs);
      if (!available) {
        return `
          <span class="wiz-tile wiz-tile-unavailable" data-category-index="${i}" aria-disabled="true">
            <span class="wiz-tile-body">
              <span class="wiz-tile-name">${esc(cat.label)}</span>
              <span class="wiz-tile-meta">Coming soon</span>
            </span>
          </span>
        `;
      }
      return `
        <label class="wiz-tile" data-category-index="${i}">
          <input type="radio" name="wizCategoryRadio" class="wiz-tile-input" value="${i}" required ${wizardState.selectedCategorySlugs === cat.slugs ? 'checked' : ''}>
          <span class="wiz-tile-body">
            <span class="wiz-tile-name">${esc(cat.label)}</span>
            <span class="wiz-tile-check" aria-hidden="true">✓ Selected</span>
          </span>
        </label>
      `;
    }).join('');
    wrap.querySelectorAll('input[name="wizCategoryRadio"]').forEach((input) => {
      input.addEventListener('change', () => applyCategorySelection(layer.categories[Number(input.value)]));
    });
    syncTileSelectedClasses(wrap);
    fieldset.hidden = false;
  }

  function applyCategorySelection(category) {
    wizardState.selectedCategorySlugs = category.slugs;
    wizardState.selectedPackageId = null;
    wizardState.selectedHourlyUnits = null;
    wizardState.selectedHourlyExtended = false;
    renderCategoryTiles();
    renderPackageTiles();
    renderDurationBlock();
    renderPackageAddonSection();
    updateStep3Requirements();
  }

  // Owns the package fieldset's visibility entirely -- including the
  // "a category layer applies but no category has been chosen yet" case,
  // so dumping every Portraits/Events package into one grid before a
  // category is picked can never happen regardless of call order.
  function renderPackageTiles() {
    const fieldset = document.getElementById('wizPackageFieldset');
    const wrap = document.getElementById('wizPackageTiles');
    const service = wizardState.catalog && wizardState.selectedServiceId
      ? wizardState.catalog.servicesById[wizardState.selectedServiceId]
      : null;
    const layer = service ? SERVICE_CATEGORY_LAYER[service.slug] : null;
    if (!wizardState.selectedServiceId || (layer && !wizardState.selectedCategorySlugs)) {
      fieldset.hidden = true;
      wrap.innerHTML = '';
      return;
    }
    let packages = getBookablePackages(wizardState.selectedServiceId);
    if (wizardState.selectedCategorySlugs) {
      packages = packages.filter((p) => wizardState.selectedCategorySlugs.includes(p.slug));
    }
    wrap.innerHTML = packages.map((p) => {
      const metaParts = [];
      if (p.duration_minutes) {
        metaParts.push(durationCopy(p.duration_minutes));
      } else if (p.pricing_type === 'hourly' && p.minimum_units) {
        metaParts.push(hourlyMinimumCopy(p.minimum_units));
      }
      if (p.public_description) metaParts.push(p.public_description);
      return `
        <label class="wiz-tile" data-package-id="${esc(p.id)}">
          <input type="radio" name="wizPackageRadio" class="wiz-tile-input" value="${esc(p.id)}" required ${p.id === wizardState.selectedPackageId ? 'checked' : ''}>
          <span class="wiz-tile-body">
            <span class="wiz-tile-name">${esc(p.name)}</span>
            <span class="wiz-tile-price">${esc(pricingLabel(p))}</span>
            ${metaParts.length ? `<span class="wiz-tile-meta">${esc(metaParts.join(' · '))}</span>` : ''}
            <span class="wiz-tile-check" aria-hidden="true">✓ Selected</span>
          </span>
        </label>
      `;
    }).join('');
    wrap.querySelectorAll('input[name="wizPackageRadio"]').forEach((input) => {
      input.addEventListener('change', () => applyPackageSelection(input.value));
    });
    syncTileSelectedClasses(wrap);
    fieldset.hidden = false;
  }

  function applyPackageSelection(packageId) {
    wizardState.selectedPackageId = packageId;
    wizardState.selectedHourlyUnits = null;
    wizardState.selectedHourlyExtended = false;
    renderPackageTiles();
    renderDurationBlock();
    renderPackageAddonSection();
    updateStep3Requirements();
  }

  // Stage 3C rule: whole-hour quantities only, starting at the catalog's
  // own minimum_units (never a hardcoded minimum). The highest listed
  // choice is a UI convenience, not a represented policy maximum -- a
  // final "more time" option hands that case to the human follow-up in
  // project details rather than inventing a business ceiling.
  function renderDurationBlock() {
    const block = document.getElementById('wizDurationBlock');
    const select = document.getElementById('wizHourlyUnits');
    const label = document.getElementById('wizDurationLabel');
    const pkg = getPackageById(wizardState.selectedPackageId);
    if (!pkg || pkg.pricing_type !== 'hourly' || !pkg.minimum_units) {
      block.hidden = true;
      select.innerHTML = '';
      return;
    }
    const min = Number(pkg.minimum_units);
    const maxListed = min + 7;
    const options = [];
    for (let h = min; h <= maxListed; h++) {
      options.push(`<option value="${h}">${h} hour${h === 1 ? '' : 's'} (${formatMoney(pkg.retail_price_cents * h)})</option>`);
    }
    options.push(`<option value="more">More than ${maxListed} hours — I'll describe it in my project details</option>`);
    select.innerHTML = options.join('');
    label.textContent = `Session Length — ${hourlyMinimumCopy(min)}`;
    select.value = wizardState.selectedHourlyExtended ? 'more' : (wizardState.selectedHourlyUnits || min);
    if (!wizardState.selectedHourlyUnits && !wizardState.selectedHourlyExtended) {
      wizardState.selectedHourlyUnits = min;
    }
    select.onchange = () => {
      if (select.value === 'more') {
        wizardState.selectedHourlyExtended = true;
        wizardState.selectedHourlyUnits = null;
      } else {
        wizardState.selectedHourlyExtended = false;
        wizardState.selectedHourlyUnits = Number(select.value);
      }
    };
    block.hidden = false;
  }

  // Shared by both the general add-on list and the package-specific
  // (Kids & Milestones / Wedding) list -- identical checkbox behavior,
  // just a different source list and container.
  function renderAddonChecklistInto(wrap, addons) {
    wrap.innerHTML = addons.map((a) => `
      <label class="wiz-check" data-addon-id="${esc(a.id)}">
        <input type="checkbox" value="${esc(a.id)}" ${wizardState.selectedAddonIds.includes(a.id) ? 'checked' : ''}>
        <span class="wiz-check-body">
          <span class="wiz-check-name">${esc(a.name)}</span>
          <span class="wiz-check-meta">${esc(pricingLabel(a))}${a.public_description ? ' — ' + esc(a.public_description) : ''}</span>
        </span>
      </label>
    `).join('');
    wrap.querySelectorAll('input[type="checkbox"]').forEach((cb) => {
      cb.addEventListener('change', () => {
        const id = cb.value;
        if (cb.checked) {
          if (!wizardState.selectedAddonIds.includes(id)) wizardState.selectedAddonIds.push(id);
        } else {
          wizardState.selectedAddonIds = wizardState.selectedAddonIds.filter((x) => x !== id);
        }
        cb.closest('.wiz-check').classList.toggle('is-checked', cb.checked);
      });
      cb.closest('.wiz-check').classList.toggle('is-checked', cb.checked);
    });
  }

  function renderAddonSection() {
    const fieldset = document.getElementById('wizAddonFieldset');
    const wrap = document.getElementById('wizAddonChecks');
    const addons = getGeneralBookableAddons();
    const service = wizardState.catalog && wizardState.selectedServiceId
      ? wizardState.catalog.servicesById[wizardState.selectedServiceId]
      : null;

    document.getElementById('wizRealEstateNote').hidden = !(service && service.slug === 'real-estate-media');

    if (!wizardState.selectedServiceId || addons.length === 0) {
      fieldset.hidden = true;
      wrap.innerHTML = '';
      return;
    }
    renderAddonChecklistInto(wrap, addons);
    fieldset.hidden = false;
  }

  function allPackageSpecificAddonIds() {
    const ids = [];
    Object.values(PACKAGE_SPECIFIC_ADDONS).forEach((entry) => {
      entry.slugs.forEach((slug) => {
        const a = getAddonBySlug(slug);
        if (a) ids.push(a.id);
      });
    });
    return ids;
  }

  // Kids & Milestones / Wedding conditional interests -- the UI-level
  // enforcement of the package-level restriction the catalog schema
  // can't express (see the migration's SCHEMA LIMITATION comment).
  function renderPackageAddonSection() {
    const fieldset = document.getElementById('wizPackageAddonFieldset');
    const legend = document.getElementById('wizPackageAddonLegend');
    const wrap = document.getElementById('wizPackageAddonChecks');
    const pkg = getPackageById(wizardState.selectedPackageId);
    const entry = pkg ? PACKAGE_SPECIFIC_ADDONS[pkg.slug] : null;
    const relevantIds = entry
      ? entry.slugs.map((s) => getAddonBySlug(s)).filter(Boolean).map((a) => a.id)
      : [];

    // Drop any previously-selected package-specific interest that isn't
    // relevant to the package now selected (e.g. switching away from
    // Little Moments clears its background/cake/balloon selections).
    // General add-on selections never appear in this id set, so they
    // are never touched here.
    const allSpecificIds = allPackageSpecificAddonIds();
    wizardState.selectedAddonIds = wizardState.selectedAddonIds.filter(
      (id) => !allSpecificIds.includes(id) || relevantIds.includes(id),
    );

    if (!entry) {
      fieldset.hidden = true;
      wrap.innerHTML = '';
      return;
    }
    const addons = entry.slugs.map((s) => getAddonBySlug(s)).filter((a) => a && a.is_bookable);
    legend.textContent = entry.legend;
    renderAddonChecklistInto(wrap, addons);
    fieldset.hidden = addons.length === 0;
  }

  function renderStep2FromCatalog() {
    const loading = document.getElementById('wizCatalogLoading');
    const errorBlock = document.getElementById('wizCatalogError');
    const serviceFieldset = document.getElementById('wizServiceFieldset');
    if (wizardState.catalogStatus === 'loading') {
      loading.hidden = false;
      errorBlock.hidden = true;
      serviceFieldset.hidden = true;
      return;
    }
    loading.hidden = true;
    if (wizardState.catalogStatus === 'failed') {
      errorBlock.hidden = false;
      serviceFieldset.hidden = true;
      document.getElementById('wizCategoryFieldset').hidden = true;
      document.getElementById('wizPackageFieldset').hidden = true;
      document.getElementById('wizDurationBlock').hidden = true;
      document.getElementById('wizPackageAddonFieldset').hidden = true;
      document.getElementById('wizAddonFieldset').hidden = true;
      return;
    }
    errorBlock.hidden = true;
    serviceFieldset.hidden = false;
    renderServiceTiles();
    renderCategoryTiles();
    renderPackageTiles();
    renderAddonSection();
  }

  // ---------------------------------------------------------------------
  // Step 4: Prints & Keepsakes rendering
  // ---------------------------------------------------------------------

  // A browser-input sanity bound only -- prevents an accidental/absurd
  // typed value from producing a nonsensical state or payload. Not a
  // Posterchild purchasing policy and never presented to the customer as
  // one.
  const PRODUCT_QTY_SANITY_MAX = 50;

  const PRODUCT_CATEGORY_ORDER = [
    ['a_la_carte_print', 'À La Carte Prints'],
    ['print_collection', 'Print Collections'],
    ['wall_art', 'Wall Art'],
    ['photo_book', 'Photo Books'],
    ['book_addon', 'Book Add-Ons'],
  ];

  function collectionContentsLine(product) {
    const c = wizardState.catalog;
    const items = c.collectionItemsByCollectionProductId[product.id] || [];
    if (items.length === 0) return product.public_description || '';
    const parts = items
      .filter((i) => i.included_product_id)
      .map((i) => {
        const included = c.productsById[i.included_product_id];
        return included ? `${i.quantity}× ${included.name}` : null;
      })
      .filter(Boolean);
    return parts.length ? parts.join(', ') : (product.public_description || '');
  }

  function renderProductGroups() {
    const wrap = document.getElementById('wizProductGroups');
    const errorNote = document.getElementById('wizProductsError');
    if (wizardState.catalogStatus === 'failed') {
      errorNote.hidden = false;
      wrap.innerHTML = '';
      return;
    }
    errorNote.hidden = true;
    if (wizardState.catalogStatus !== 'ready') {
      wrap.innerHTML = '<p class="wiz-note">Loading products…</p>';
      return;
    }
    const c = wizardState.catalog;
    const groupsHtml = PRODUCT_CATEGORY_ORDER.map(([category, title]) => {
      const products = (c.productsByCategory[category] || []).slice().sort((a, b) => a.sort_order - b.sort_order);
      if (products.length === 0) return '';
      const rows = products.map((p) => {
        const isCollection = category === 'print_collection';
        const metaLine = isCollection ? collectionContentsLine(p) : (p.public_description || '');
        if (p.is_purchasable) {
          const qty = wizardState.selectedProducts[p.id] || 0;
          return `
            <div class="wiz-product-row" data-product-id="${esc(p.id)}">
              <div>
                <div class="wiz-product-name">${esc(p.name)}</div>
                ${metaLine ? `<div class="wiz-product-meta">${esc(metaLine)}</div>` : ''}
                <div class="wiz-product-price">${esc(pricingLabel(p))}</div>
              </div>
              <label>
                <span class="wiz-tz-badge" style="margin:0 0 4px;display:block;text-align:center">Qty</span>
                <input type="number" class="wiz-product-qty" min="0" max="${PRODUCT_QTY_SANITY_MAX}" step="1" inputmode="numeric" value="${qty}" aria-label="Quantity for ${esc(p.name)}">
              </label>
            </div>
          `;
        }
        return `
          <div class="wiz-product-row wiz-product-request" data-product-id="${esc(p.id)}">
            <div>
              <div class="wiz-product-name">${esc(p.name)}</div>
              ${metaLine ? `<div class="wiz-product-meta">${esc(metaLine)}</div>` : ''}
              <div class="wiz-product-price">${esc(pricingLabel(p))}</div>
            </div>
            <span class="wiz-product-request-badge">Available by Request</span>
          </div>
        `;
      }).join('');
      return `
        <div class="wiz-product-group">
          <div class="wiz-product-group-title">${esc(title)}</div>
          ${rows}
        </div>
      `;
    }).join('');
    wrap.innerHTML = groupsHtml;
    wrap.querySelectorAll('.wiz-product-qty').forEach((input) => {
      input.addEventListener('input', () => {
        const row = input.closest('.wiz-product-row');
        const id = row.dataset.productId;
        // parseInt truncates rather than rounds, so a fractional entry
        // like "2.7" already becomes the whole number 2; Math.max/min
        // then rejects negative and NaN input alike (NaN fails every
        // comparison, so both clamps fall through to 0). The sanity
        // ceiling below is a browser-input safety bound only, never
        // described to the customer as a purchasing limit.
        const parsed = parseInt(input.value, 10);
        const n = Math.min(PRODUCT_QTY_SANITY_MAX, Math.max(0, Number.isFinite(parsed) ? parsed : 0));
        input.value = String(n);
        if (n > 0) {
          wizardState.selectedProducts[id] = n;
        } else {
          delete wizardState.selectedProducts[id];
        }
      });
    });
  }

  // ---------------------------------------------------------------------
  // Step 5: Review rendering + pricing rules
  // ---------------------------------------------------------------------

  function computePackageSubtotalCents() {
    const pkg = getPackageById(wizardState.selectedPackageId);
    if (!pkg) return null;
    if (pkg.pricing_type === 'fixed') return pkg.retail_price_cents;
    if (pkg.pricing_type === 'hourly' && wizardState.selectedHourlyUnits && !wizardState.selectedHourlyExtended) {
      return pkg.retail_price_cents * wizardState.selectedHourlyUnits;
    }
    return null; // starting_at, custom_quote, or an un-finalized hourly duration
  }

  function computeProductsSubtotalCents() {
    const c = wizardState.catalog;
    if (!c) return 0;
    let total = 0;
    Object.entries(wizardState.selectedProducts).forEach(([id, qty]) => {
      const p = c.productsById[id];
      if (!p || !p.is_purchasable) return;
      if (p.pricing_type !== 'fixed' && p.pricing_type !== 'per_unit') return; // never sum a non-final price
      total += (p.retail_price_cents || 0) * qty;
    });
    return total;
  }

  function renderReview() {
    const c = wizardState.catalog;
    const out = document.getElementById('wizReviewSummary');
    const service = c && wizardState.selectedServiceId ? c.servicesById[wizardState.selectedServiceId] : null;
    const pkg = getPackageById(wizardState.selectedPackageId);

    const contactRows = [
      ['Name', [wizardState.contact.firstName, wizardState.contact.lastName].filter(Boolean).join(' ') || '—'],
      ['Email', wizardState.contact.email || '—'],
      ['Phone', wizardState.contact.phone || '—'],
    ];

    const serviceRows = [];
    if (service) {
      serviceRows.push(['Service', service.name]);
      if (pkg) {
        serviceRows.push(['Package', pkg.name]);
        serviceRows.push(['Pricing', pricingLabel(pkg)]);
        let durationText = '—';
        if (pkg.duration_minutes) {
          durationText = durationCopy(pkg.duration_minutes);
        } else if (pkg.pricing_type === 'hourly') {
          durationText = wizardState.selectedHourlyExtended
            ? 'More than the listed range — details in project notes'
            : (wizardState.selectedHourlyUnits ? `${wizardState.selectedHourlyUnits} hour${wizardState.selectedHourlyUnits === 1 ? '' : 's'}` : '—');
        }
        serviceRows.push(['Duration', durationText]);
      }
    } else if (wizardState.serviceInterestFreetext) {
      serviceRows.push(['Interested in', wizardState.serviceInterestFreetext]);
    }

    const dateRows = [
      ['Requested date', wizardState.date || '—'],
      ['Requested start time', wizardState.time ? `${wizardState.time} (Eastern Time)` : '—'],
    ];
    if (wizardState.location) dateRows.push(['Location', wizardState.location]);
    if (wizardState.people) dateRows.push(['People', wizardState.people]);

    // Searches the FULL add-on list, not just generalAddons -- a
    // selected id may belong to a package-specific (Kids & Milestones /
    // Wedding) interest, which carries a real (non-null)
    // applicable_service_id and would otherwise never resolve to a name.
    const addonNames = (c ? c.serviceAddons : []).filter((a) => wizardState.selectedAddonIds.includes(a.id)).map((a) => a.name);

    const selectedProductLines = Object.entries(wizardState.selectedProducts)
      .map(([id, qty]) => {
        const p = c && c.productsById[id];
        if (!p) return null;
        return `${qty}× ${p.name}`;
      })
      .filter(Boolean);

    const packageSubtotal = computePackageSubtotalCents();
    const productsSubtotal = computeProductsSubtotalCents();
    // "Fully calculable" means the package itself resolves to a single
    // real number (fixed, or hourly with a concrete whole-hour duration)
    // -- starting_at, custom_quote, and an un-finalized ("more hours")
    // hourly selection are never folded into a combined figure, so a
    // $750-starting package can never be visually reduced to "$40" just
    // because that's the only calculable line.
    const packageIsFullyCalculable = !!pkg && packageSubtotal !== null;

    function section(title, rows) {
      if (!rows.length) return '';
      return `
        <div class="wiz-summary-group">
          <div class="wiz-summary-group-title">${esc(title)}</div>
          ${rows.map(([k, v]) => `<div class="wiz-summary-row"><span>${esc(k)}</span><span>${esc(v)}</span></div>`).join('')}
        </div>
      `;
    }

    let html = '';
    html += section('Contact', contactRows);
    html += section('Service & Package', serviceRows);
    html += section('Date & Details', dateRows);
    if (wizardState.vision) html += section('Project Vision', [['Details', wizardState.vision]]);
    if (wizardState.inspiration) html += section('References', [['Inspiration', wizardState.inspiration]]);
    if (addonNames.length) html += section('Add-On Interests (not priced — see note below)', [['Interested in', addonNames.join(', ')]]);
    if (selectedProductLines.length) html += section('Prints & Keepsakes Selected', [['Selected', selectedProductLines.join(', ')]]);

    // Pricing block -- always separate lines, never a single figure that
    // could be misread as covering both the package and the products.
    const pricingRows = [];
    if (pkg) {
      if (packageIsFullyCalculable) {
        pricingRows.push(['Package selection', formatMoney(packageSubtotal)]);
      } else if (pkg.pricing_type === 'hourly' && wizardState.selectedHourlyExtended) {
        pricingRows.push(['Package', pricingLabel(pkg) + ' — duration to be confirmed']);
      } else {
        pricingRows.push(['Package', pricingLabel(pkg)]);
      }
    }
    if (productsSubtotal > 0) {
      pricingRows.push(['Selected products', formatMoney(productsSubtotal)]);
    }
    if (packageIsFullyCalculable) {
      pricingRows.push(['Estimated selections', formatMoney(packageSubtotal + productsSubtotal)]);
    } else if (pkg || productsSubtotal > 0) {
      pricingRows.push(['Final project pricing', 'To be confirmed']);
    }
    if (pricingRows.length) {
      html += section('Pricing', pricingRows);
      if (!packageIsFullyCalculable && pkg) {
        html += '<p class="wiz-note" style="margin-top:-4px">Add-on interests are never included in the figures above — they are not priced until confirmed with your project.</p>';
      }
    }

    html += `<p class="wiz-note">Availability will be confirmed before your date is held. Submitting this form sends an inquiry -- it does not create a hold or a booking yet.</p>`;

    out.innerHTML = html;
  }

  // ---------------------------------------------------------------------
  // Contact / date-details field wiring
  // ---------------------------------------------------------------------

  function wireStateInputs() {
    const bind = (id, path) => {
      const el = document.getElementById(id);
      if (!el) return;
      el.addEventListener('input', () => setPath(path, el.value));
      el.addEventListener('change', () => setPath(path, el.value));
    };
    function setPath(path, value) {
      const parts = path.split('.');
      let obj = wizardState;
      for (let i = 0; i < parts.length - 1; i++) obj = obj[parts[i]];
      obj[parts[parts.length - 1]] = value;
    }
    bind('wizFirstName', 'contact.firstName');
    bind('wizLastName', 'contact.lastName');
    bind('wizEmail', 'contact.email');
    bind('wizPhone', 'contact.phone');
    bind('wizSource', 'contact.source');
    bind('wizServiceInterest', 'serviceInterestFreetext');
    bind('wizDate', 'date');
    bind('wizTime', 'time');
    bind('wizLocation', 'location');
    bind('wizPeople', 'people');
    bind('wizVision', 'vision');
    bind('wizInspo', 'inspiration');
  }

  // ---------------------------------------------------------------------
  // Submission
  // ---------------------------------------------------------------------

  function buildEstimatedSelectionSummary() {
    const pkg = getPackageById(wizardState.selectedPackageId);
    const packageSubtotal = computePackageSubtotalCents();
    const productsSubtotal = computeProductsSubtotalCents();
    const packageIsFullyCalculable = !!pkg && packageSubtotal !== null;
    const parts = [];
    if (pkg) {
      parts.push(packageIsFullyCalculable ? `Package selection ${formatMoney(packageSubtotal)}` : `Package ${pricingLabel(pkg)}`);
    }
    if (productsSubtotal > 0) parts.push(`Selected products ${formatMoney(productsSubtotal)}`);
    if (packageIsFullyCalculable) {
      parts.push(`Estimated selections ${formatMoney(packageSubtotal + productsSubtotal)}`);
    } else if (pkg || productsSubtotal > 0) {
      parts.push('Final project pricing: To be confirmed');
    }
    return parts.length ? parts.join(' | ') : 'Not yet calculable';
  }

  function buildFormSubmitPayload() {
    const c = wizardState.catalog;
    const service = c && wizardState.selectedServiceId ? c.servicesById[wizardState.selectedServiceId] : null;
    const pkg = getPackageById(wizardState.selectedPackageId);
    // Searches the FULL add-on list, not just generalAddons -- a
    // selected id may belong to a package-specific (Kids & Milestones /
    // Wedding) interest, which carries a real (non-null)
    // applicable_service_id and would otherwise never resolve to a name.
    const addonNames = (c ? c.serviceAddons : []).filter((a) => wizardState.selectedAddonIds.includes(a.id)).map((a) => a.name);
    const productLines = Object.entries(wizardState.selectedProducts).map(([id, qty]) => {
      const p = c && c.productsById[id];
      return p ? `${qty}x ${p.name}` : null;
    }).filter(Boolean);

    let durationText = '';
    if (pkg && pkg.duration_minutes) durationText = durationCopy(pkg.duration_minutes);
    else if (pkg && pkg.pricing_type === 'hourly') {
      durationText = wizardState.selectedHourlyExtended
        ? 'More than listed range (see project details)'
        : (wizardState.selectedHourlyUnits ? `${wizardState.selectedHourlyUnits} hour(s)` : '');
    }

    return {
      _subject: 'New Posterchild Media Booking Inquiry',
      _template: 'table',
      _captcha: 'false',
      _autoresponse: 'Thank you for contacting Posterchild Media! We received your booking request and will reach out to discuss your vision, confirm availability, and reserve your session.',
      _next: window.location.href,
      submitted_at: new Date().toLocaleString(),
      first_name: wizardState.contact.firstName,
      last_name: wizardState.contact.lastName,
      email: wizardState.contact.email,
      phone: wizardState.contact.phone,
      source: wizardState.contact.source,
      service: service ? service.name : (wizardState.serviceInterestFreetext ? '(catalog unavailable — see interest note)' : ''),
      service_package: pkg ? pkg.name : '',
      service_package_id: pkg ? pkg.id : '',
      pricing_type: pkg ? pkg.pricing_type : '',
      pricing_label: pkg ? pricingLabel(pkg) : '',
      selected_duration: durationText,
      preferred_date: wizardState.date,
      preferred_time: wizardState.time,
      timezone: 'America/New_York (Eastern Time)',
      location: wizardState.location,
      people: wizardState.people,
      vision: wizardState.vision,
      inspiration: wizardState.inspiration,
      service_interest_freetext: wizardState.serviceInterestFreetext,
      selected_addons: addonNames.length ? addonNames.join(', ') : 'None',
      selected_products: productLines.length ? productLines.join(', ') : 'None',
      estimated_selection_summary: buildEstimatedSelectionSummary(),
    };
  }

  async function handleSubmit(e) {
    e.preventDefault();
    if (wizardState.submitting) return;
    // Re-checks the FULL wizard state, not just the currently visible
    // panel -- closes the gap where a customer could revisit an earlier
    // step via the step nav, change or clear a selection there, then jump
    // straight back to Review without any intermediate Continue click
    // re-validating that step.
    const blocking = firstBlockingIssue(TOTAL_STEPS);
    if (blocking) {
      goToStep(blocking.step);
      showValidationMessage(blocking.msg);
      return;
    }
    clearValidationMessage();

    const btn = document.getElementById('wizardSubmitBtn');
    const status = document.getElementById('wizSubmitStatus');
    wizardState.submitting = true;
    btn.disabled = true;
    const originalLabel = btn.textContent;
    btn.textContent = 'Submitting…';
    status.hidden = true;

    const data = buildFormSubmitPayload();

    try {
      const res = await fetch('https://formsubmit.co/ajax/amvlgam@gmail.com', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
        body: JSON.stringify(data),
      });
      // Fix for the pre-existing reliability bug: a resolved fetch is NOT
      // itself success -- only an HTTP-success response is. A non-2xx
      // response falls through to the same catch-driven fallback path as
      // a hard network failure.
      if (!res.ok) throw new Error('formsubmit_http_' + res.status);

      document.getElementById('formWrap').style.display = 'none';
      document.getElementById('formSuccess').classList.add('show');
      document.getElementById('booking-form').scrollIntoView({ behavior: 'smooth', block: 'start' });
    } catch (err) {
      // Every key/value is passed through encodeURIComponent as part of
      // the plain-text body BEFORE it's placed in the mailto URL, then the
      // whole assembled body is encoded again -- customer-entered text
      // may contain &, =, %, #, ?, line breaks, or Unicode/emoji, none of
      // which may leak into (or corrupt) the URL's own query structure.
      const bodyText = Object.entries(data).map(([k, v]) => `${k}: ${v || ''}`).join('\n');
      const mailtoUrl = `mailto:amvlgam@gmail.com`
        + `?subject=${encodeURIComponent('New Posterchild Media Booking Inquiry')}`
        + `&body=${encodeURIComponent(bodyText)}`;
      status.hidden = false;
      status.textContent = "We couldn't submit automatically. Opening your email client to send your request — if nothing happens, please email us directly at amvlgam@gmail.com.";
      window.location.href = mailtoUrl;
    } finally {
      wizardState.submitting = false;
      btn.disabled = false;
      btn.textContent = originalLabel;
    }
  }

  // ---------------------------------------------------------------------
  // ?service= compatibility + pricing-card CTA compatibility
  // ---------------------------------------------------------------------

  // Matches ONLY against the exact set of services actually offered in
  // the wizard (bookable services), by an exact, case-sensitive match on
  // the catalog's own `name` column -- the same string both booking.html's
  // pricing-card onclick handlers and index.html's `?service=` links are
  // hand-authored to already carry (e.g. "Real Estate Media"). No
  // fuzzy/partial/case-insensitive matching is performed, specifically to
  // avoid ever silently selecting the wrong service; an unmatched value
  // is ignored and the customer selects normally.
  function matchServiceByName(name) {
    const trimmed = (name || '').trim();
    if (!trimmed) return null;
    return getBookableServices().find((s) => s.name === trimmed) || null;
  }

  function requestServiceSelection(name) {
    if (wizardState.catalogStatus === 'ready') {
      const svc = matchServiceByName(name);
      if (!svc) return;
      applyServiceSelection(svc.id);
      goToStep(2);
      document.getElementById('booking-form').scrollIntoView({ behavior: 'smooth', block: 'start' });
    } else {
      wizardState.pendingServiceName = name;
    }
  }

  function applyPendingServiceSelectionIfAny() {
    if (!wizardState.pendingServiceName) return;
    const name = wizardState.pendingServiceName;
    wizardState.pendingServiceName = null;
    requestServiceSelection(name);
  }

  window.PosterchildWizard = {
    selectServiceByName: requestServiceSelection,
  };

  // ---------------------------------------------------------------------
  // Init
  // ---------------------------------------------------------------------

  function wireNav() {
    document.querySelectorAll('[data-next]').forEach((btn) => {
      btn.addEventListener('click', () => tryAdvanceTo(Number(btn.dataset.next)));
    });
    document.querySelectorAll('[data-prev]').forEach((btn) => {
      btn.addEventListener('click', () => { clearValidationMessage(); goToStep(Number(btn.dataset.prev)); });
    });
    document.querySelectorAll('.wiz-step-btn').forEach((btn) => {
      btn.addEventListener('click', () => {
        if (btn.disabled) return;
        tryAdvanceTo(Number(btn.dataset.step));
      });
    });
    document.getElementById('wizardForm').addEventListener('submit', handleSubmit);
  }

  async function init() {
    wireStateInputs();
    wireNav();

    const params = new URLSearchParams(window.location.search);
    const serviceParam = params.get('service');
    if (serviceParam) wizardState.pendingServiceName = serviceParam;

    renderStep2FromCatalog();
    renderProductGroups();

    const catalog = await window.loadPosterchildCatalog();
    if (catalog) {
      wizardState.catalog = catalog;
      wizardState.catalogStatus = 'ready';
    } else {
      wizardState.catalogStatus = 'failed';
    }
    renderStep2FromCatalog();
    renderProductGroups();
    applyPendingServiceSelectionIfAny();
  }

  init();
})();
