// Pure half of muster-set-password: password policy and the app_metadata
// merge. No network, no Deno, no secrets -- so tests/auth/set-password.test.ts
// exercises the real rules rather than a description of them.

export type PolicyVerdict =
  | { ok: true }
  | { ok: false; reason: string; message: string };

// bcrypt, which GoTrue uses, hashes only the first 72 BYTES and silently
// discards the rest. A 100-character passphrase would therefore be stored as
// its first 72 bytes, and the user would never be told. Reject instead: a
// truncation nobody is told about is worse than a refusal they can act on.
export const MAX_PASSWORD_BYTES = 72;

// Twelve, not eight. This is deliberately above the form's old floor, and
// there are no composition rules on purpose.
//
// Length is the only property that reliably costs an attacker anything.
// Mandatory symbol/digit/case rules push people toward Password1! and its
// family -- predictable substitutions that a cracking rule set expands for
// free -- while blocking the passphrases that actually resist a search. NIST
// SP 800-63B says the same: require length, screen against known-bad values,
// and drop composition rules. A product that audits other people's security
// posture should not ship the control it would write up as a finding.
export const MIN_PASSWORD_CHARS = 12;

// Not a leaked-password corpus -- that belongs in GoTrue's own "prevent use of
// leaked passwords" setting, which checks HaveIBeenPwned and is the right place
// for it. This is the short list of values a person actually types when they
// are being forced to change a password and resent it.
const OBVIOUS = new Set([
  "password", "password1", "password123", "passw0rd", "letmein",
  "changeme", "changeme123", "qwerty", "qwerty123", "iloveyou",
  "muster", "muster123", "musterpassword", "temppassword", "temporary",
  "welcome", "welcome1", "welcome123", "admin", "admin123", "administrator",
  "123456", "1234567", "12345678", "123456789", "1234567890", "abc123",
]);

function byteLength(s: string): number {
  return new TextEncoder().encode(s).length;
}

/**
 * The server-side password policy for a forced change. The browser enforces the
 * same floor for a friendlier message, but this is the copy that decides:
 * the browser's is advice, and anything can POST to this function directly.
 */
export function validateNewPassword(password: unknown, email: string): PolicyVerdict {
  if (typeof password !== "string" || password.length === 0) {
    return { ok: false, reason: "missing", message: "Enter a new password." };
  }
  // A leading or trailing space survives the paste and then does not survive
  // the next login attempt, because the sign-in form trims and this does not.
  // Refusing it here is kinder than a password that works exactly once.
  if (password !== password.trim()) {
    return {
      ok: false,
      reason: "whitespace_edges",
      message: "Remove the space at the start or end of the password.",
    };
  }
  if ([...password].length < MIN_PASSWORD_CHARS) {
    return {
      ok: false,
      reason: "too_short",
      message: `Use at least ${MIN_PASSWORD_CHARS} characters. Length beats punctuation.`,
    };
  }
  if (byteLength(password) > MAX_PASSWORD_BYTES) {
    return {
      ok: false,
      reason: "too_long",
      message: `That password is longer than ${MAX_PASSWORD_BYTES} bytes, and only the first ${MAX_PASSWORD_BYTES} would be stored. Shorten it.`,
    };
  }

  // Checked against the padding too, not just the literal value. Almost every
  // entry in OBVIOUS is shorter than the 12-character minimum, so a bare
  // membership test would be dead code: "password" cannot be submitted anyway.
  // What people actually do when a minimum forces them longer is pad --
  // password1234, Welcome123456, changeme!!! -- and the padding is worth
  // nothing to an attacker, because the rule sets that expand these bases try
  // exactly that. So strip the digits and punctuation off both ends and test
  // the stem as well. Four characters is the floor for a stem, so stripping
  // cannot reduce something unrelated to a coincidental match.
  const lower = password.toLowerCase();
  const stems = new Set([
    lower,
    lower.replace(/[^a-z]+$/, ""),
    lower.replace(/^[^a-z]+/, "").replace(/[^a-z]+$/, ""),
  ]);
  for (const stem of stems) {
    if (stem.length >= 4 && OBVIOUS.has(stem)) {
      return {
        ok: false,
        reason: "obvious",
        message: "That is one of the most-guessed passwords in existence, with or without the padding. Pick another.",
      };
    }
  }

  const addr = String(email || "").trim().toLowerCase();
  if (addr) {
    const local = addr.split("@")[0];
    if (lower === addr || (local.length >= 3 && lower === local)) {
      return {
        ok: false,
        reason: "is_email",
        message: "Your password cannot be your email address.",
      };
    }
  }

  return { ok: true };
}

/**
 * The app_metadata to write when the change succeeds.
 *
 * Merged from the existing object rather than replaced: `provider` and
 * `providers` live in the same bag, and GoTrue uses them to decide which
 * sign-in methods the account has. Dropping them would be a far worse bug than
 * the one this function exists to fix.
 *
 * The flag is set to false rather than deleted so the record still shows the
 * account was once forced, alongside when it was satisfied. A deleted key and a
 * key that was never set are indistinguishable afterwards.
 */
export function clearedAppMetadata(
  existing: Record<string, unknown> | null | undefined,
  nowIso: string,
): Record<string, unknown> {
  return {
    ...(existing && typeof existing === "object" ? existing : {}),
    force_password_change: false,
    force_password_change_cleared_at: nowIso,
  };
}

/**
 * True when the caller's own claims say a change is required. This is the same
 * predicate muster.password_change_required() applies in Postgres, and both
 * accept a JSON boolean or the string "true" because provisioning tools write
 * both. Kept in sync by tests/auth/set-password.test.ts.
 */
export function changeRequired(appMetadata: Record<string, unknown> | null | undefined): boolean {
  const v = appMetadata && typeof appMetadata === "object"
    ? (appMetadata as Record<string, unknown>)["force_password_change"]
    : undefined;
  if (v === true) return true;
  if (typeof v === "string") return ["true", "t", "1"].includes(v.toLowerCase());
  if (typeof v === "number") return v === 1;
  return false;
}
