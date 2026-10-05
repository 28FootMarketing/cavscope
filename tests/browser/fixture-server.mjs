// Local fixture sites for the browser engine, served over HTTP on localhost. Each scenario lives under
// its own path prefix and only links within it, so a scan of /clean/ never wanders into /ga/.
// A second server on 127.0.0.1 plays the third party (a different registrable "domain" to localhost).
import { createServer } from "node:http";

const CLEAN_CSP = "default-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; script-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'self'";
const CSS = `body{font-family:sans-serif;color:#111;background:#fff}.g{color:#F4B223;background:linear-gradient(135deg,#0A1F44,#1A3A6E);padding:8px;display:block}
input,button{font-size:16px}`;
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=", "base64");

const consent = (checked = false) => `
  <p><label for="phone">Mobile phone</label><input id="phone" name="phone" type="tel" autocomplete="tel"></p>
  <p><label for="email">Email</label><input id="email" name="email" type="email" autocomplete="email"></p>
  <p><input id="sms" name="sms_consent" type="checkbox"${checked ? " checked" : ""}><label for="sms">I agree to receive text messages from Clean Fixture</label></p>
  <p>Message and data rates may apply. Message frequency varies. Reply STOP to cancel or HELP for help. Consent is not a condition of purchase.
     See our <a href="PREFIX/privacy">Privacy Policy</a> and <a href="PREFIX/sms-terms">SMS Terms</a>.</p>`;

const page = ({ prefix, title = "Fixture", body, head = "" }) => `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${title}</title>
<link rel="stylesheet" href="${prefix}/s.css">${head}</head><body><main><h1>${title}</h1>${body}</main></body></html>`;

const SCENARIOS = {
  clean: {
    csp: CLEAN_CSP,
    body: (p) => `<p class="g">Gold text on a navy gradient</p><img src="${p}/p.png" alt="One pixel">
      <form id="contact" action="https://api.example.test/submit" method="post"><p>Athletes and parents: join our list.</p>
      <p><label for="name">Name</label><input id="name" name="name" type="text" autocomplete="name"></p>${consent(false).replaceAll("PREFIX", p)}
      <p>Under 18? A parent or guardian must complete this form.</p><button type="submit">Send</button></form>`,
  },
  prechecked: {
    body: (p) => `<form id="contact" action="https://api.example.test/submit" method="post">${consent(true).replaceAll("PREFIX", p)}<button type="submit">Send</button></form>`,
  },
  badaction: {
    body: () => `<form id="contact" action="#"><p><label for="e">Email</label><input id="e" name="email" type="email"></p><button type="submit">Send</button></form>`,
  },
  scriptform: {
    csp: "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' https://api.example.test",
    head: (p) => `<script src="${p}/form.js" defer></script>`,
    body: () => `<form id="contact" action="#"><p><label for="e">Email</label><input id="e" name="email" type="email"></p><button type="submit">Send</button></form>`,
  },
  scripthttp: {
    head: (p) => `<script src="${p}/form-http.js" defer></script>`,
    body: () => `<form id="contact" action="#"><p><label for="e">Email</label><input id="e" name="email" type="email"></p><button type="submit">Send</button></form>`,
  },
  noalt: {
    body: (p) => `<img src="${p}/p.png"><p>An image with no alt attribute.</p>`,
  },
  ga: {
    cookies: ["_ga=GA1.1.111.222; Path=/", "_gid=GA1.1.333.444; Path=/", "session=abc; Path=/; HttpOnly"],
    body: () => `<p>This page sets Google Analytics cookies on load.</p>`,
  },
  cspbreak: {
    csp: "default-src 'self'; script-src 'none'; style-src 'self'",
    head: (p) => `<script src="${p}/a.js"></script>`,
    body: () => `<p>A script this page's own policy forbids.</p>`,
  },
  thirdparty: {
    body: (_p, ctx) => `<img src="http://127.0.0.1:${ctx.thirdPartyPort}/x.png" alt="Remote pixel"><p>Loads one image from another host.</p>`,
  },
};

export async function startFixtures() {
  const third = createServer((req, res) => { res.writeHead(200, { "content-type": "image/png" }); res.end(PNG); });
  await new Promise((r) => third.listen(0, "127.0.0.1", r));
  const thirdPartyPort = third.address().port;

  const main = createServer((req, res) => {
    const url = new URL(req.url, "http://localhost");
    const m = /^\/([a-z]+)(\/.*)?$/.exec(url.pathname);
    const sc = m && SCENARIOS[m[1]];
    if (!sc) { res.writeHead(404, { "content-type": "text/plain" }); return res.end("not found"); }
    const prefix = `/${m[1]}`;
    const rest = m[2] ?? "/";
    const headers = { "content-type": "text/html; charset=utf-8" };
    if (sc.csp) headers["content-security-policy"] = sc.csp;
    if (sc.cookies) headers["set-cookie"] = sc.cookies;
    if (rest === "/s.css") { res.writeHead(200, { "content-type": "text/css" }); return res.end(CSS); }
    if (rest === "/p.png") { res.writeHead(200, { "content-type": "image/png" }); return res.end(PNG); }
    if (rest === "/form.js" || rest === "/form-http.js") {
      const target = rest === "/form.js" ? "https://api.example.test/submit" : "http://api.example.test/submit";
      res.writeHead(200, { "content-type": "text/javascript" });
      return res.end(`document.getElementById("contact").addEventListener("submit", function (e) { e.preventDefault(); fetch("${target}", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email: this.email.value }) }); });`);
    }
    if (rest === "/a.js") { res.writeHead(200, { "content-type": "text/javascript" }); return res.end("window.__fixtureScript = 1"); }
    if (rest === "/privacy" || rest === "/sms-terms") { res.writeHead(200, headers); return res.end(page({ prefix, title: rest.slice(1), body: "<p>Policy text.</p>" })); }
    if (rest === "/" || rest === "") {
      const ctx = { thirdPartyPort };
      res.writeHead(200, headers);
      return res.end(page({ prefix, title: m[1], body: sc.body(prefix, ctx), head: typeof sc.head === "function" ? sc.head(prefix) : "" }));
    }
    res.writeHead(404, { "content-type": "text/plain" }); res.end("not found");
  });
  await new Promise((r) => main.listen(0, "127.0.0.1", r));
  const port = main.address().port;
  return {
    url: (name) => `http://localhost:${port}/${name}/`,
    port, thirdPartyPort,
    close: () => Promise.all([new Promise((r) => main.close(r)), new Promise((r) => third.close(r))]),
  };
}
