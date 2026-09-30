// Pure half of cavscope-inbound-mail: parsing an email.received event and
// building the forward. No Deno globals, no database, no fetch, so
// tests/email/inbound-mail.test.ts runs this exact code.

export type Route = { address: string; forward_to: string[]; sender: string; subject_tag: string };

// The CavScope mail domains. A forward is never sent to one of these, which is
// what makes a loop impossible: the relay's own mail can never come back in.
export const OWN_MAIL_DOMAINS = ["mail.cavscope.28footsystems.com", "mail.muster.partners"];

/** "Name <a@b.c>", "a@b.c", {address}, {email} -> "a@b.c", lowercased. */
export function addressOf(value: unknown): string {
  if (typeof value === "string") {
    const angled = value.match(/<([^>]+)>/);
    return (angled ? angled[1] : value).trim().toLowerCase();
  }
  if (value && typeof value === "object") {
    const v = value as Record<string, unknown>;
    if (typeof v.address === "string") return v.address.trim().toLowerCase();
    if (typeof v.email === "string") return v.email.trim().toLowerCase();
  }
  return "";
}

export function recipients(value: unknown): string[] {
  const list = Array.isArray(value) ? value : value == null ? [] : [value];
  return [...new Set(list.map(addressOf).filter(Boolean))];
}

export function isOwnDomain(address: string): boolean {
  const domain = address.split("@")[1] || "";
  return OWN_MAIL_DOMAINS.includes(domain);
}

/** Every address a message was sent to, To and Cc, for the route lookup. */
export function addressedTo(data: Record<string, unknown>): string[] {
  return [...new Set([...recipients(data.to), ...recipients(data.cc)])];
}

/** Forward targets that are safe to send to: real, and not a CavScope mailbox. */
export function usableTargets(route: Route): string[] {
  return (route.forward_to || []).map(addressOf).filter((a) => a.includes("@") && !isOwnDomain(a));
}

export function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

export type ForwardInput = {
  route: Route;
  from: string;
  subject: string | null;
  text: string;
  html: string;
  attachments: number;
  bodyFetched: boolean;
};

/** The POST /emails body for one forward. Reply-To is the original sender. */
export function buildForward(input: ForwardInput): Record<string, unknown> {
  const { route, from, attachments } = input;
  const subject = (input.subject || "").trim() || "(no subject)";
  const notes: string[] = [];
  if (attachments > 0) {
    notes.push(`${attachments} attachment${attachments === 1 ? "" : "s"} not forwarded; open the message in Resend (Emails > Receiving) to get ${attachments === 1 ? "it" : "them"}.`);
  }
  if (!input.bodyFetched && !input.text && !input.html) {
    notes.push("The message body could not be read here; open it in Resend (Emails > Receiving).");
  }
  const header = [
    `From: ${from}`,
    `To: ${route.address}`,
    ...notes,
    `Reply to this email to answer ${from} directly.`,
  ].join("\n");
  const body: Record<string, unknown> = {
    from: route.sender,
    to: usableTargets(route),
    reply_to: from,
    subject: `${route.subject_tag} ${subject}`.slice(0, 250),
    text: `${header}\n\n---\n\n${input.text || "(no text body)"}`,
  };
  if (input.html) {
    body.html = `<div style="font:13px/1.5 -apple-system,Segoe UI,Roboto,Arial,sans-serif;color:#475467;border-bottom:1px solid #e4e7ec;padding:0 0 10px;margin:0 0 14px">`
      + header.split("\n").map(escapeHtml).join("<br>") + `</div>${input.html}`;
  }
  return body;
}

/** A send worth retrying: network, rate limit or a Resend 5xx. */
export function retryable(status: number): boolean {
  return status === 0 || status === 429 || status >= 500;
}
