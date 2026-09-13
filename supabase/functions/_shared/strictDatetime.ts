// supabase/functions/_shared/strictDatetime.ts
//
// Strict ISO-8601-with-offset timestamp parsing that rejects
// calendar-impossible literals (2026-02-30, 2026-04-31, a non-leap-year
// Feb 29, hour 24, minute 60, ...) instead of letting them silently
// normalize to a different real date/time. Both native Date.parse and
// Postgres's parameter-bound ::timestamptz cast do exactly that silent
// normalization -- confirmed directly against this codebase's own
// connection path, not assumed -- which is unsafe for a scheduling
// system: a malformed client input must never turn into a booking for a
// day the client never actually requested.
//
// Validates the LITERAL local calendar/clock components encoded in the
// string BEFORE any timezone conversion. Comparing post-conversion UTC
// digits back against the input would be wrong, since a real, valid
// offset legitimately shifts the UTC calendar day/hour away from the
// local one (e.g. 2026-09-13T10:00:00+04:30 is a valid literal whose UTC
// date/time digits differ from 09-13/10:00).

const STRICT_ISO_RE =
  /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:\d{2})$/;

function isLeapYear(year: number): boolean {
  return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
}

const DAYS_IN_MONTH = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

function daysInMonth(year: number, month: number): number {
  return month === 2 && isLeapYear(year) ? 29 : DAYS_IN_MONTH[month - 1];
}

export type StrictTimestampResult = { ok: true; ms: number } | { ok: false };

/**
 * Parses an ISO-8601 timestamp with an explicit offset (Z or +/-HH:MM),
 * rejecting the string outright if its literal calendar/clock components
 * are not a real date and time -- rather than deferring to Date.parse's
 * (or Postgres's) silent rollover normalization. Returns the absolute
 * instant in milliseconds only when the literal is genuinely valid.
 */
export function parseStrictIsoTimestamp(input: string): StrictTimestampResult {
  const match = STRICT_ISO_RE.exec(input);
  if (!match) return { ok: false };

  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);

  if (month < 1 || month > 12) return { ok: false };
  if (day < 1 || day > daysInMonth(year, month)) return { ok: false };
  if (hour > 23) return { ok: false };
  if (minute > 59) return { ok: false };
  if (second > 59) return { ok: false };

  const ms = Date.parse(input);
  if (Number.isNaN(ms)) return { ok: false };
  return { ok: true, ms };
}
