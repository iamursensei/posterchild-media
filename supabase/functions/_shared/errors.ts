// supabase/functions/_shared/errors.ts
//
// Translates known Postgres error codes into safe, generic client-facing
// responses. Never returns SQL, constraint names, connection details, or
// stack traces to the caller. Server-side logs retain only a sanitized
// error code and a short context label -- never the raw error message,
// never request PII, never any secret.

export interface DomainErrorResponse {
  status: number;
  body: { error: string; message: string };
}

const PG_ERROR_MAP: Record<string, DomainErrorResponse> = {
  // exclusion_violation -- the resource_reservations overlap constraint
  "23P01": {
    status: 409,
    body: {
      error: "slot_unavailable",
      message: "The requested time is no longer available.",
    },
  },
  // unique_violation
  "23505": {
    status: 409,
    body: {
      error: "conflict",
      message: "This request conflicts with an existing record.",
    },
  },
  // foreign_key_violation
  "23503": {
    status: 422,
    body: {
      error: "invalid_reference",
      message: "One or more referenced records do not exist.",
    },
  },
  // check_violation
  "23514": {
    status: 422,
    body: {
      error: "invalid_request",
      message: "The request could not be processed as submitted.",
    },
  },
};

const GENERIC_ERROR: DomainErrorResponse = {
  status: 500,
  body: {
    error: "internal_error",
    message: "Something went wrong. Please try again.",
  },
};

/**
 * Maps a thrown error (expected to carry a Postgres `code` field when it
 * originates from a query run through _shared/db.ts) to a safe,
 * public-facing response. Any error without a recognized code -- or
 * without a `code` at all -- becomes the generic 500. Logs a sanitized
 * one-line summary server-side: code and context only, never the raw
 * message, never the connection string, never request PII.
 */
export function mapError(err: unknown, context: string): DomainErrorResponse {
  const code = (err as { code?: string } | null | undefined)?.code;
  const mapped = code ? PG_ERROR_MAP[code] : undefined;

  console.error(
    `[${context}] ${code ? `pg_error_code=${code}` : "unmapped_error"}`,
  );

  return mapped ?? GENERIC_ERROR;
}

export function jsonErrorResponse(
  domainError: DomainErrorResponse,
  extraHeaders: HeadersInit = {},
): Response {
  return new Response(JSON.stringify(domainError.body), {
    status: domainError.status,
    headers: { "Content-Type": "application/json", ...extraHeaders },
  });
}
