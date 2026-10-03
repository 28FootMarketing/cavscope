// Pure half of cavscope-support-request: validation, the screenshot check and the email.
// index.ts does the I/O. Kept here so tests/support/ can run it without Deno.

export const CATEGORIES = {
  broken: "Something is broken",
  wrong_number: "A number or report looks wrong",
  how_to: "I need help using something",
  billing: "Billing or my plan",
  other: "Something else",
} as const;
export type Category = keyof typeof CATEGORIES;

export const MAX_MESSAGE = 4000;
// A JPEG of one viewport is a few hundred KB; this is generous without letting the form carry files.
export const MAX_SCREENSHOT_BYTES = 3_000_000;

export interface Valid {
  category: Category;
  message: string;
  pageUrl: string | null;
  userAgent: string | null;
  viewport: string | null;
  organizationId: number | null;
  screenshot: { bytes: Uint8Array; mime: "image/jpeg" | "image/png"; ext: "jpg" | "png" } | null;
}

const clip = (v: unknown, n: number): string | null =>
  typeof v === "string" && v.trim() ? v.trim().slice(0, n) : null;

export function decodeScreenshot(dataUrl: unknown): Valid["screenshot"] | "invalid" | null {
  if (dataUrl == null || dataUrl === "") return null;
  if (typeof dataUrl !== "string") return "invalid";
  const m = /^data:(image\/jpeg|image\/png);base64,([A-Za-z0-9+/=]+)$/.exec(dataUrl);
  if (!m) return "invalid";
  // base64 is 4 chars per 3 bytes; refuse before decoding something large.
  if (m[2].length > Math.ceil(MAX_SCREENSHOT_BYTES * 4 / 3) + 4) return "invalid";
  let bin: string;
  try { bin = atob(m[2]); } catch { return "invalid"; }
  const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
  if (bytes.byteLength === 0 || bytes.byteLength > MAX_SCREENSHOT_BYTES) return "invalid";
  // The declared type is the caller's word; the first bytes are the file's.
  const isJpeg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  const isPng = bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
  if (m[1] === "image/jpeg" && isJpeg) return { bytes, mime: "image/jpeg", ext: "jpg" };
  if (m[1] === "image/png" && isPng) return { bytes, mime: "image/png", ext: "png" };
  return "invalid";
}

export function validate(body: unknown): { ok: true; value: Valid } | { ok: false; error: string } {
  const b = (body ?? {}) as Record<string, unknown>;
  if (typeof b.category !== "string" || !(b.category in CATEGORIES)) return { ok: false, error: "Pick what this is about." };
  const message = typeof b.message === "string" ? b.message.trim() : "";
  if (!message) return { ok: false, error: "Tell us what happened." };
  if (message.length > MAX_MESSAGE) return { ok: false, error: `Keep the message under ${MAX_MESSAGE} characters.` };
  const shot = decodeScreenshot(b.screenshot);
  if (shot === "invalid") return { ok: false, error: "The screenshot could not be read. Send the message without it." };
  const org = Number(b.organization_id);
  return {
    ok: true,
    value: {
      category: b.category as Category,
      message,
      pageUrl: clip(b.page_url, 500),
      userAgent: clip(b.user_agent, 400),
      viewport: clip(b.viewport, 40),
      organizationId: Number.isSafeInteger(org) && org > 0 ? org : null,
      screenshot: shot,
    },
  };
}

export const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

export interface Route { address: string; forward_to: string[]; sender: string; subject_tag: string }

export function buildEmail(args: { id: number; route: Route; from: string; v: Valid; orgName?: string | null }) {
  const { id, route, from, v } = args;
  const label = CATEGORIES[v.category];
  const subject = `${route.subject_tag} #${id} ${label}: ${v.message.replace(/\s+/g, " ").slice(0, 60)}`.replace(/[\r\n]/g, " ");
  const meta: Array<[string, string]> = [
    ["From", from],
    ["Organization", args.orgName ?? (v.organizationId ? `#${v.organizationId}` : "none")],
    ["About", label],
    ["Page", v.pageUrl ?? "not sent"],
    ["Browser", v.userAgent ?? "not sent"],
    ["Window", v.viewport ?? "not sent"],
    ["Screenshot", v.screenshot ? "attached" : "none"],
  ];
  const text = `${v.message}\n\n---\n${meta.map(([k, val]) => `${k}: ${val}`).join("\n")}\nRequest: #${id}\n`;
  const html = `<p style="white-space:pre-wrap;font:14px/1.5 system-ui,sans-serif">${esc(v.message)}</p><hr><table style="font:12px system-ui,sans-serif;color:#555">${meta
    .map(([k, val]) => `<tr><td style="padding-right:12px"><b>${esc(k)}</b></td><td>${esc(val)}</td></tr>`).join("")}<tr><td><b>Request</b></td><td>#${id}</td></tr></table>`;
  const payload: Record<string, unknown> = {
    from: route.sender,
    to: route.forward_to,
    reply_to: from,
    subject,
    text,
    html,
  };
  if (v.screenshot) {
    let bin = "";
    for (const byte of v.screenshot.bytes) bin += String.fromCharCode(byte);
    payload.attachments = [{ filename: `screenshot-${id}.${v.screenshot.ext}`, content: btoa(bin) }];
  }
  return payload;
}
