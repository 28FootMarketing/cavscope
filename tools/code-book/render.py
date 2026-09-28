"""CavScope defect-code book: every rule the engine can raise, by audit area.

    python3 render.py codes.json CavScope-defect-codes.pdf

Composes nothing. Severity, category, title, plain English, remediation and
framework references all come from muster.scan_rules. The one derived field is
scope -- see export.sql for how it is decided and why it is not in the catalog.
"""
import sys, datetime
from reportlab.lib import colors
from reportlab.lib.pagesizes import LETTER
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.lib.enums import TA_LEFT
from reportlab.platypus import (BaseDocTemplate, PageTemplate, Frame, Paragraph, Spacer,
                                Table, TableStyle, KeepTogether, HRFlowable)
import json

SITE = "site"

# codes.json is produced by export.sql. The renderer never touches the database
# and holds no credential; the JSON in between is an auditable intermediate.
SRC = sys.argv[1]
OUT = sys.argv[2]
_D = json.load(open(SRC))
READ_AT = _D["read_at"]
PROJECT = _D["project"]
RULES = [(r["rule_id"], r["category"], r["severity"], r["scope"], r["title"],
          r["plain_english"], r["remediation"], r["frameworks"]) for r in _D["rules"]]

INK      = colors.HexColor("#0c1527")
INK_SOFT = colors.HexColor("#46587a")
INK_DIM  = colors.HexColor("#7d8ea9")
RULE     = colors.HexColor("#d5dde9")
BAND     = colors.HexColor("#eef2f8")
TEAL     = colors.HexColor("#0f8f7e")
SEV = {"critical": colors.HexColor("#a8112b"), "high": colors.HexColor("#c2410c"),
       "medium": colors.HexColor("#a06a06"), "low": colors.HexColor("#4a6280"),
       "info": colors.HexColor("#5b6b85")}
ORDER = ["critical", "high", "medium", "low", "info"]

AREA = [
    ("security",      "Security",       "Can someone break in, intercept, or impersonate."),
    ("availability",  "Availability",   "Is the site up, and fast enough to keep visitors."),
    ("accessibility", "Accessibility",  "Can people using assistive technology actually use it."),
    ("privacy",       "Privacy",        "Is visitor data handled and disclosed lawfully."),
    ("governance",    "Governance / AI readiness", "Can search engines and AI assistants read it correctly."),
    ("third_party",   "Third party",    "Whose code runs on your pages."),
]

def st(n, **kw):
    b = dict(fontName="Helvetica", fontSize=9.2, leading=13.2, textColor=INK, alignment=TA_LEFT)
    b.update(kw); return ParagraphStyle(n, **b)

S = {"title": st("t", fontName="Times-Bold", fontSize=23, leading=26),
     "sub": st("s", fontSize=10.5, leading=15, textColor=INK_SOFT),
     "kicker": st("k", fontName="Courier-Bold", fontSize=7.6, leading=11, textColor=TEAL),
     "h2": st("h2", fontName="Times-Bold", fontSize=14, leading=17),
     "h2sub": st("h2s", fontSize=8.8, leading=12, textColor=INK_SOFT),
     "body": st("b"), "dim": st("d", textColor=INK_SOFT),
     "small": st("sm", fontSize=7.9, leading=11, textColor=INK_SOFT),
     "cell": st("c", fontSize=8.3, leading=11.2),
     "cellsm": st("cs", fontSize=7.5, leading=10.2, textColor=INK_SOFT),
     "head": st("hd", fontName="Helvetica-Bold", fontSize=7.4, leading=10, textColor=colors.white)}

def esc(t): return str(t).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
def sevhex(s): return SEV[s].hexval().replace("0x", "#")

story = []; A = story.append

A(Paragraph("CavScope &#183; DEFECT CODE BOOK", S["kicker"]))
A(Spacer(1, 3))
A(Paragraph("Every code the engine can raise", S["title"]))
A(Paragraph(f"{len(RULES)} rules, all active &#183; read from <font face='Courier' size='9'>muster.scan_rules</font> "
            f"on {READ_AT}", S["sub"]))
A(Spacer(1, 7))
A(HRFlowable(width="100%", thickness=1.1, color=INK, spaceAfter=10))

# ---- how to read a code
A(Paragraph("How to read a code", S["h2"]))
A(Spacer(1, 4))
A(Paragraph(
    "A code names the rule; a finding is one instance of it. In a SITREP a finding is cited as "
    "<font face='Courier' size='8.5'>F&lt;id&gt;</font> and the evidence it was derived from as "
    "<font face='Courier' size='8.5'>E&lt;id&gt;</font>, so any sentence in a report can be traced "
    "back to the bytes it came from.", S["body"]))
A(Spacer(1, 8))

scope_tbl = Table([
    [Paragraph("<b>SITE</b>", S["cell"]),
     Paragraph("One verdict for the whole domain, however many pages are scanned. The HTTP&#8594;HTTPS "
               "probe, <font face='Courier' size='8'>robots.txt</font>, the sitemap, "
               "<font face='Courier' size='8'>security.txt</font>, and the SPF / DMARC / MX records.", S["cell"])],
    [Paragraph("<b>PAGE</b>", S["cell"]),
     Paragraph("One verdict per page: the response, its headers, its HTML. "
               "<font face='Courier' size='8'>website_scan_settings.max_pages</font> defaults to 1, so today "
               "every page-scoped rule reports on the homepage only.", S["cell"])],
], colWidths=[18*mm, 140*mm])
scope_tbl.setStyle(TableStyle([
    ("BACKGROUND", (0,0), (-1,-1), BAND), ("BOX", (0,0), (-1,-1), 0.7, RULE),
    ("LINEBEFORE", (0,0), (0,-1), 3.2, TEAL), ("VALIGN", (0,0), (-1,-1), "TOP"),
    ("INNERGRID", (0,0), (-1,-1), 0.4, RULE),
    ("TOPPADDING", (0,0), (-1,-1), 7), ("BOTTOMPADDING", (0,0), (-1,-1), 7),
    ("LEFTPADDING", (0,0), (-1,-1), 8), ("RIGHTPADDING", (0,0), (-1,-1), 8),
]))
A(scope_tbl)
A(Spacer(1, 9))
A(Paragraph("Severity is what an attacker or a regulator could do, not how hard the fix is. Two rules "
            "that leave a domain equally spoofable carry the same severity even when one of them looks "
            "like a near miss.", S["dim"]))
A(Spacer(1, 14))

# ---- summary grid
def counts(pred):
    return {s: sum(1 for r in RULES if r[2] == s and pred(r)) for s in ORDER}

rows = [[Paragraph("AUDIT AREA", S["head"])] + [Paragraph(s.upper(), S["head"]) for s in ORDER]
        + [Paragraph("SITE", S["head"]), Paragraph("PAGE", S["head"]), Paragraph("TOTAL", S["head"])]]
for key, label, _ in AREA:
    c = counts(lambda r, k=key: r[1] == k)
    tot = sum(c.values())
    site = sum(1 for r in RULES if r[1] == key and r[3] == SITE)
    rows.append([Paragraph(f"<b>{label}</b>", S["cell"])]
                + [Paragraph(f'<font color="{sevhex(s)}">{c[s] or "&#183;"}</font>', S["cell"]) for s in ORDER]
                + [Paragraph(str(site) if site else "&#183;", S["cell"]),
                   Paragraph(str(tot - site) if tot - site else "&#183;", S["cell"]),
                   Paragraph(f"<b>{tot}</b>", S["cell"])])
allc = counts(lambda r: True)
rows.append([Paragraph("<b>All</b>", S["cell"])]
            + [Paragraph(f"<b>{allc[s]}</b>", S["cell"]) for s in ORDER]
            + [Paragraph(f"<b>{sum(1 for r in RULES if r[3]==SITE)}</b>", S["cell"]),
               Paragraph(f"<b>{sum(1 for r in RULES if r[3]!=SITE)}</b>", S["cell"]),
               Paragraph(f"<b>{len(RULES)}</b>", S["cell"])])
t = Table(rows, colWidths=[41*mm] + [18*mm]*5 + [12*mm, 13*mm, 14*mm], repeatRows=1)
t.setStyle(TableStyle([
    ("BACKGROUND", (0,0), (-1,0), INK),
    ("ALIGN", (1,0), (-1,-1), "CENTER"), ("VALIGN", (0,0), (-1,-1), "MIDDLE"),
    ("LINEBELOW", (0,0), (-1,-1), 0.4, RULE),
    ("LINEABOVE", (0,-1), (-1,-1), 0.9, INK),
    ("LINEBEFORE", (6,0), (6,-1), 0.9, RULE),
    ("ROWBACKGROUNDS", (0,1), (-1,-2), [colors.white, colors.HexColor("#f7f9fc")]),
    ("TOPPADDING", (0,0), (-1,-1), 5), ("BOTTOMPADDING", (0,0), (-1,-1), 5),
    ("LEFTPADDING", (1,0), (-1,-1), 2), ("RIGHTPADDING", (1,0), (-1,-1), 2),
]))
A(t)
A(Spacer(1, 16))

# ---- the codes
for key, label, blurb in AREA:
    group = [r for r in RULES if r[1] == key]
    group.sort(key=lambda r: (ORDER.index(r[2]), r[0]))
    head = [Paragraph(f"{label} &#8212; {len(group)} rules", S["h2"]),
            Paragraph(esc(blurb), S["h2sub"]), Spacer(1, 6)]
    rows = [[Paragraph("CODE", S["head"]), Paragraph("SEV", S["head"]), Paragraph("SCOPE", S["head"]),
             Paragraph("WHAT IT MEANS", S["head"]), Paragraph("HOW TO CLEAR IT", S["head"]),
             Paragraph("MAPS TO", S["head"])]]
    for rid, _cat, sev, scope, title, plain, fix, refs in group:
        rows.append([
            Paragraph(f'<font face="Courier-Bold" size="7.6">{rid}</font>', S["cell"]),
            Paragraph(f'<font color="{sevhex(sev)}" size="6.8"><b>{sev.upper()}</b></font>', S["cell"]),
            Paragraph(f'<font size="6.8" color="#7d8ea9">{scope.upper()}</font>', S["cell"]),
            Paragraph(f"<b>{esc(title)}</b><br/>{esc(plain)}", S["cell"]),
            Paragraph(esc(fix), S["cellsm"]),
            Paragraph(f'<font size="7">{esc(refs)}</font>', S["cellsm"]),
        ])
    t = Table(rows, colWidths=[20*mm, 17*mm, 13*mm, 53*mm, 43*mm, 27*mm], repeatRows=1)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0,0), (-1,0), INK),
        ("VALIGN", (0,0), (-1,-1), "TOP"),
        ("LINEBELOW", (0,0), (-1,-1), 0.4, RULE),
        ("ROWBACKGROUNDS", (0,1), (-1,-1), [colors.white, colors.HexColor("#f7f9fc")]),
        ("TOPPADDING", (0,0), (-1,-1), 5), ("BOTTOMPADDING", (0,0), (-1,-1), 5),
        ("LEFTPADDING", (0,0), (-1,-1), 4.5), ("RIGHTPADDING", (0,0), (-1,-1), 4.5),
        ("LEFTPADDING", (1,0), (2,-1), 2), ("RIGHTPADDING", (1,0), (2,-1), 2),
    ]))
    A(KeepTogether(head + [t]) if len(group) <= 8 else Spacer(0, 0))
    if len(group) > 8:
        for f in head: A(f)
        A(t)
    A(Spacer(1, 14))

# ---- what is not checked
A(Paragraph("What no code covers", S["h2"]))
A(Paragraph("A prospect will ask. These are the gaps, stated rather than implied.", S["h2sub"]))
A(Spacer(1, 6))
gaps = [
    ("No browser engine", "Everything is HTTP-native and DNS-native. No rendering, no JavaScript "
     "execution, no computed styles. Contrast ratios, focus order, keyboard traps and live ARIA state "
     "are not assessed, so the accessibility area is a floor, not a WCAG audit."),
    ("One page by default", "<font face='Courier' size='8'>max_pages</font> defaults to 1. Every "
     "PAGE-scoped rule reports on the homepage until that is raised."),
    ("No authenticated crawl", "Only what an anonymous visitor sees. Nothing behind a login is assessed."),
    ("No DKIM, BIMI or MTA-STS", "SPF and DMARC are covered. A DKIM selector cannot be enumerated from "
     "outside, so reporting its absence would be a guess rather than a finding."),
    ("No TLS certificate inspection", "Expiry, chain and cipher suite are not assessed. HTTPS is checked "
     "for presence and redirect behaviour only."),
    ("No content or claims review", "The engine reads structure, not meaning. It cannot tell you whether "
     "what the page says is accurate or compliant."),
]
rows = [[Paragraph(f"<b>{g[0]}</b>", S["cell"]), Paragraph(g[1], S["cell"])] for g in gaps]
t = Table(rows, colWidths=[44*mm, 114*mm])
t.setStyle(TableStyle([("VALIGN", (0,0), (-1,-1), "TOP"),
    ("LINEBELOW", (0,0), (-1,-2), 0.4, RULE),
    ("TOPPADDING", (0,0), (-1,-1), 5), ("BOTTOMPADDING", (0,0), (-1,-1), 5),
    ("LEFTPADDING", (0,0), (-1,-1), 0)]))
A(t)
A(Spacer(1, 12))
A(Paragraph(
    f"Source of truth is <font face='Courier' size='8'>muster.scan_rules</font> on project "
    f"<font face='Courier' size='8'>{PROJECT}</font>, not this document. Severity shown is the rule's "
    "default; the engine lowers confidence, and in one case severity, on client-rendered pages where the "
    "HTTP engine can only see the initial HTML.", S["small"]))
A(Spacer(1, 6))
A(Paragraph("CavScope's SITREP is a technical assessment, not a compliance certification or legal opinion. "
            "Framework references indicate where a finding is relevant to a control, not that any "
            "certification has been achieved.", S["small"]))

def furniture(canvas, doc):
    canvas.saveState(); w, h = LETTER
    canvas.setStrokeColor(RULE); canvas.setLineWidth(0.6)
    canvas.line(20*mm, 15*mm, w - 20*mm, 15*mm)
    canvas.setFont("Helvetica", 7); canvas.setFillColor(INK_DIM)
    canvas.drawString(20*mm, 11*mm, f"CavScope defect code book  |  {len(RULES)} rules  |  {READ_AT}")
    canvas.drawRightString(w - 20*mm, 11*mm, f"Page {doc.page}")
    canvas.setFont("Helvetica", 6)
    canvas.drawString(20*mm, 7.6*mm, "CavScope by 28 Foot Systems (After Today, LLC)")
    canvas.restoreState()

doc = BaseDocTemplate(OUT, pagesize=LETTER, leftMargin=20*mm, rightMargin=20*mm,
                      topMargin=18*mm, bottomMargin=22*mm,
                      title=f"CavScope defect code book - {len(RULES)} rules",
                      author="CavScope by 28 Foot Systems (After Today, LLC)",
                      subject="Every defect code the CavScope scan engine can raise, by audit area")
doc.addPageTemplates([PageTemplate(id="m",
    frames=[Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id="f")], onPage=furniture)])
doc.build(story)
print("wrote", OUT)
