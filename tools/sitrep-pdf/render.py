"""Render muster.sitreps row 16 as a PDF.

Faithful rendering only: every number, claim, finding and hash comes from the
stored SITREP. Nothing is composed here that the engine did not produce.
"""
import json, sys, datetime
from reportlab.lib import colors
from reportlab.lib.pagesizes import LETTER
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import mm
from reportlab.lib.enums import TA_LEFT
from reportlab.platypus import (BaseDocTemplate, PageTemplate, Frame, Paragraph, Spacer,
                                Table, TableStyle, KeepTogether, HRFlowable)

SRC = sys.argv[1]
OUT = sys.argv[2]
D = json.load(open(SRC))

INK      = colors.HexColor("#0c1527")
INK_SOFT = colors.HexColor("#46587a")
INK_DIM  = colors.HexColor("#7d8ea9")
RULE     = colors.HexColor("#d5dde9")
BAND     = colors.HexColor("#eef2f8")
TEAL     = colors.HexColor("#0f8f7e")
GREEN    = colors.HexColor("#1a7f4b")
AMBER    = colors.HexColor("#a06a06")

SEV = {
    "critical": colors.HexColor("#a8112b"),
    "high":     colors.HexColor("#c2410c"),
    "medium":   colors.HexColor("#a06a06"),
    "low":      colors.HexColor("#4a6280"),
    "info":     colors.HexColor("#5b6b85"),
}
BANDC = {"green": GREEN, "amber": AMBER, "red": colors.HexColor("#a8112b")}

ss = getSampleStyleSheet()
def st(name, **kw):
    base = dict(fontName="Helvetica", fontSize=9.2, leading=13.2, textColor=INK, alignment=TA_LEFT)
    base.update(kw)
    return ParagraphStyle(name, **base)

S = {
    "title":    st("title", fontName="Times-Bold", fontSize=23, leading=26, textColor=INK),
    "sub":      st("sub", fontSize=10.5, leading=15, textColor=INK_SOFT),
    "kicker":   st("kicker", fontName="Courier-Bold", fontSize=7.6, leading=11, textColor=TEAL),
    "h2":       st("h2", fontName="Times-Bold", fontSize=13.5, leading=16, textColor=INK, spaceBefore=2, spaceAfter=2),
    "h3":       st("h3", fontName="Helvetica-Bold", fontSize=9.8, leading=13, textColor=INK),
    "body":     st("body"),
    "bodydim":  st("bodydim", textColor=INK_SOFT),
    "small":    st("small", fontSize=7.9, leading=11, textColor=INK_SOFT),
    "mono":     st("mono", fontName="Courier", fontSize=7.4, leading=10, textColor=INK_SOFT),
    "monotiny": st("monotiny", fontName="Courier", fontSize=6.5, leading=8.6, textColor=INK_DIM),
    "cell":     st("cell", fontSize=8.4, leading=11.4),
    "cellhead": st("cellhead", fontName="Helvetica-Bold", fontSize=7.4, leading=10, textColor=colors.white),
    "score":    st("score", fontName="Times-Bold", fontSize=40, leading=42, textColor=GREEN),
}

def sevhex(sev):
    return SEV[sev].hexval().replace("0x", "#")

def frameworks(refs):
    out = []
    for k, v in refs.items():
        # CUSTOM is the catalog's key for a reference outside the named
        # frameworks; its value already names the standard ("RFC 7489 s6.6.3"),
        # so the key itself is noise on the page.
        out.append(v if k == "CUSTOM" else "%s %s" % (k.replace("_", " "), v))
    return ", ".join(out)

def esc(t):
    return (str(t).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))

def cite(finding_ids, evidence_ids):
    """The SITREP's own citation scheme: F<finding id>, E<evidence id>."""
    toks = [f"F{i}" for i in finding_ids] + [f"E{i}" for i in evidence_ids]
    return " ".join(toks) if toks else "&#8212;"

def when(iso):
    dt = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00"))
    return dt.strftime("%d %b %Y %H:%M UTC")

story = []
A = story.append

# ---------------------------------------------------------------- masthead
site = D["website"]; sr = D["sitrep"]; scan = D["scan"]; summ = scan["summary"]

A(Paragraph("MUSTER &#183; WEBSITE ASSURANCE SITREP", S["kicker"]))
A(Spacer(1, 3))
A(Paragraph(esc(site["name"]), S["title"]))
A(Paragraph(f'{esc(site["url"])} &#183; prepared for {esc(D["org"])}', S["sub"]))
A(Spacer(1, 7))
A(HRFlowable(width="100%", thickness=1.1, color=INK, spaceAfter=10))

# ---------------------------------------------------------------- posture
band = sr["posture_band"]
score_tbl = Table(
    [[Paragraph(f'{sr["posture_score"]}', ParagraphStyle("s", parent=S["score"], textColor=BANDC[band])),
      Paragraph(
        f'<b>Posture {sr["posture_score"]} / 100 &#183; {band.upper()}</b><br/>'
        f'{summ["open_by_severity"].get("critical",0)} critical &#183; '
        f'{summ["open_by_severity"].get("high",0)} high &#183; '
        f'{summ["open_by_severity"].get("medium",0)} medium &#183; '
        f'{summ["open_by_severity"].get("low",0)} low &#183; '
        f'{summ["open_by_severity"].get("info",0)} informational<br/>'
        f'<font color="#46587a">This scan resolved {summ["resolved"]} findings, added {summ["new"]}, '
        f'reopened {summ["reopened"]}.</font>', S["body"])]],
    colWidths=[26*mm, 132*mm])
score_tbl.setStyle(TableStyle([
    ("BACKGROUND", (0,0), (-1,-1), BAND),
    ("BOX", (0,0), (-1,-1), 0.7, RULE),
    ("LINEBEFORE", (0,0), (0,-1), 3.2, BANDC[band]),
    ("VALIGN", (0,0), (-1,-1), "MIDDLE"),
    ("LEFTPADDING", (0,0), (0,-1), 9), ("RIGHTPADDING", (0,0), (0,-1), 2),
    ("TOPPADDING", (0,0), (-1,-1), 9), ("BOTTOMPADDING", (0,0), (-1,-1), 9),
]))
A(score_tbl)
A(Spacer(1, 12))

# ---------------------------------------------------------------- scan facts
def kv_table(rows, w1=42*mm, w2=116*mm):
    t = Table([[Paragraph(f"<b>{esc(k)}</b>", S["cell"]), Paragraph(v, S["cell"])] for k, v in rows],
              colWidths=[w1, w2])
    t.setStyle(TableStyle([
        ("VALIGN", (0,0), (-1,-1), "TOP"),
        ("LINEBELOW", (0,0), (-1,-2), 0.4, RULE),
        ("TOPPADDING", (0,0), (-1,-1), 4), ("BOTTOMPADDING", (0,0), (-1,-1), 4),
        ("LEFTPADDING", (0,0), (-1,-1), 0),
    ]))
    return t

A(Paragraph("Scan of record", S["h2"]))
A(Spacer(1, 4))
A(kv_table([
    ("Scan", f'#{scan["scan_id"]}, finished {when(scan["finished_at"])}'),
    ("Requested URL", f'<font face="Courier" size="8">{esc(scan["target_url"])}</font>'),
    ("Resolved to", f'<font face="Courier" size="8">{esc(scan["final_url"])}</font> '
                    f'&#183; HTTP {scan["http_status"]} in {scan["response_ms"]} ms'),
    ("Engine", f'<font face="Courier" size="8">{esc(scan["engine_version"])}</font> '
               f'&#183; generator <font face="Courier" size="8">{esc(sr["generator"])}</font>'),
    ("SITREP", f'#{sr["id"]} v{sr["version"]} ({esc(sr["status"])}), generated {when(sr["generated_at"])}'),
    ("Evidence captured", f'{summ["evidence"]} artefacts, each hashed (index at the end of this report)'),
]))
A(Spacer(1, 14))

# ---------------------------------------------------------------- claims
A(Paragraph("Board report", S["h2"]))
A(Paragraph("Every claim below cites the findings (F) and evidence records (E) it was derived from. "
            "Nothing in this section is asserted without a citation to something the engine captured.",
            S["bodydim"]))
A(Spacer(1, 7))

rows = [[Paragraph("ID", S["cellhead"]), Paragraph("CLAIM", S["cellhead"]), Paragraph("CITES", S["cellhead"])]]
for c in D["claims"]:
    rows.append([Paragraph(f'<font face="Courier-Bold" size="8">{c["id"]}</font>', S["cell"]),
                 Paragraph(esc(c["text"]), S["cell"]),
                 Paragraph(f'<font face="Courier" size="7.2">{cite(c["finding_ids"], c["evidence_ids"])}</font>', S["cell"])])
t = Table(rows, colWidths=[11*mm, 119*mm, 28*mm], repeatRows=1)
t.setStyle(TableStyle([
    ("BACKGROUND", (0,0), (-1,0), INK),
    ("VALIGN", (0,0), (-1,-1), "TOP"),
    ("LINEBELOW", (0,0), (-1,-1), 0.4, RULE),
    ("ROWBACKGROUNDS", (0,1), (-1,-1), [colors.white, colors.HexColor("#f7f9fc")]),
    ("TOPPADDING", (0,0), (-1,-1), 5), ("BOTTOMPADDING", (0,0), (-1,-1), 5),
    ("LEFTPADDING", (0,0), (-1,-1), 5), ("RIGHTPADDING", (0,0), (-1,-1), 5),
]))
A(t)
A(Spacer(1, 14))

# ---------------------------------------------------------------- open findings
open_intro = [
    Paragraph(f'Open findings ({len(D["top_findings"])})', S["h2"]),
    Paragraph("Both are informational. MUSTER reports inventory and policy positions at this level: "
              "they describe a state of affairs, not a defect to remediate.", S["bodydim"]),
    Spacer(1, 7),
]
pending_intro = True

for f in D["top_findings"]:
    sev = f["severity"]
    head = Table([[
        Paragraph(f'<font face="Courier-Bold" size="8" color="#ffffff">{f["rule_id"]}</font>', S["cell"]),
        Paragraph(f'<b>{esc(f["title"])}</b>', S["cell"]),
        Paragraph(f'<font face="Courier" size="7.2" color="#5b6b85">{sev.upper()} &#183; '
                  f'{f["category"]} &#183; F{f["finding_id"]}</font>', S["cell"]),
    ]], colWidths=[22*mm, 92*mm, 44*mm])
    head.setStyle(TableStyle([
        ("BACKGROUND", (0,0), (0,0), SEV[sev]),
        ("BACKGROUND", (1,0), (-1,0), BAND),
        ("VALIGN", (0,0), (-1,-1), "MIDDLE"),
        ("ALIGN", (2,0), (2,0), "RIGHT"),
        ("TOPPADDING", (0,0), (-1,-1), 5), ("BOTTOMPADDING", (0,0), (-1,-1), 5),
        ("LEFTPADDING", (0,0), (-1,-1), 6), ("RIGHTPADDING", (0,0), (-1,-1), 6),
    ]))
    body = kv_table([
        ("What was found", esc(f["detail"])),
        ("Where", f'<font face="Courier" size="8">{esc(f["location"])}</font> on '
                  f'<font face="Courier" size="8">{esc(f["page_url"]) if "page_url" in f else esc(site["url"])}</font>'),
        ("Recommended action", esc(f["remediation"])),
        ("Confidence", esc(f["confidence"])),
        ("Maps to", esc(frameworks(f["framework_refs"]))),
        ("Evidence", f'<font face="Courier" size="7.6">{" ".join("E"+str(e) for e in f["evidence_ids"])}</font>'),
    ], w1=40*mm, w2=118*mm)
    block = [head, Spacer(1, 5), body, Spacer(1, 13)]
    if pending_intro:
        block = open_intro + block
        pending_intro = False
    A(KeepTogether(block))

# ---------------------------------------------------------------- plain english
A(Paragraph("In plain English", S["h2"]))
A(Spacer(1, 5))
for p in D["plain_english"]:
    t = Table([[Paragraph(f'<font face="Courier-Bold" size="7.6" color="#0f8f7e">{p["id"]}</font>', S["cell"]),
                Paragraph(esc(p["text"]), S["cell"])]], colWidths=[10*mm, 148*mm])
    t.setStyle(TableStyle([
        ("VALIGN", (0,0), (-1,-1), "TOP"),
        ("LEFTPADDING", (0,0), (-1,-1), 0),
        ("TOPPADDING", (0,0), (-1,-1), 3), ("BOTTOMPADDING", (0,0), (-1,-1), 7),
    ]))
    A(t)
A(Spacer(1, 10))

# ---------------------------------------------------------------- remediation record
A(Paragraph(f'Resolved this cycle ({len(D["resolved"])})', S["h2"]))
A(Paragraph("Each of these was open on an earlier scan of this site and is no longer reported. "
            "Resolution is decided by the engine on a later scan, not asserted by hand.", S["bodydim"]))
A(Spacer(1, 7))

rows = [[Paragraph("CODE", S["cellhead"]), Paragraph("SEV", S["cellhead"]),
         Paragraph("FINDING", S["cellhead"]), Paragraph("WHERE", S["cellhead"]),
         Paragraph("SCANS", S["cellhead"]), Paragraph("MAPS TO", S["cellhead"])]]
for r in D["resolved"]:
    rows.append([
        Paragraph(f'<font face="Courier-Bold" size="7.6">{r["rule_id"]}</font>', S["cell"]),
        Paragraph('<font color="%s" size="7.6"><b>%s</b></font>' % (sevhex(r["severity"]), r["severity"].upper()), S["cell"]),
        Paragraph(esc(r["title"]), S["cell"]),
        Paragraph(f'<font face="Courier" size="7">{esc(r["location"])}</font>', S["cell"]),
        Paragraph(f'<font size="7.6">{r["first_seen_scan_id"]}&#8211;{r["last_seen_scan_id"]}</font>', S["cell"]),
        Paragraph('<font size="7">%s</font>' % esc(frameworks(r["framework_refs"])), S["cell"]),
    ])
t = Table(rows, colWidths=[20*mm, 17*mm, 40*mm, 25*mm, 15*mm, 41*mm], repeatRows=1)
t.setStyle(TableStyle([
    ("BACKGROUND", (0,0), (-1,0), INK),
    ("VALIGN", (0,0), (-1,-1), "TOP"),
    ("LINEBELOW", (0,0), (-1,-1), 0.4, RULE),
    ("ROWBACKGROUNDS", (0,1), (-1,-1), [colors.white, colors.HexColor("#f7f9fc")]),
    ("TOPPADDING", (0,0), (-1,-1), 4.5), ("BOTTOMPADDING", (0,0), (-1,-1), 4.5),
    ("LEFTPADDING", (0,0), (-1,-1), 5), ("RIGHTPADDING", (0,0), (-1,-1), 5),
]))
A(t)
A(Spacer(1, 14))

# ---------------------------------------------------------------- trend
A(Paragraph("Posture over this engagement", S["h2"]))
A(Spacer(1, 6))
rows = [[Paragraph("SCAN", S["cellhead"]), Paragraph("FINISHED", S["cellhead"]),
         Paragraph("POSTURE", S["cellhead"]), Paragraph("BAND", S["cellhead"]),
         Paragraph("FIRST BYTE", S["cellhead"]), Paragraph("ENGINE", S["cellhead"])]]
for h in D["history"]:
    rows.append([
        Paragraph(f'<font size="8.4">#{h["scan_id"]}</font>', S["cell"]),
        Paragraph(f'<font size="8">{when(h["finished_at"])}</font>', S["cell"]),
        Paragraph(f'<b>{h["posture_score"]}/100</b>', S["cell"]),
        Paragraph('<font color="%s"><b>%s</b></font>' % (BANDC[h["posture_band"]].hexval().replace("0x", "#"), h["posture_band"].upper()), S["cell"]),
        Paragraph(f'<font size="8">{h["response_ms"]} ms</font>', S["cell"]),
        Paragraph(f'<font face="Courier" size="7">{esc(h["engine_version"])}</font>', S["cell"]),
    ])
t = Table(rows, colWidths=[15*mm, 44*mm, 22*mm, 20*mm, 24*mm, 33*mm], repeatRows=1)
t.setStyle(TableStyle([
    ("BACKGROUND", (0,0), (-1,0), INK),
    ("VALIGN", (0,0), (-1,-1), "MIDDLE"),
    ("LINEBELOW", (0,0), (-1,-1), 0.4, RULE),
    ("ROWBACKGROUNDS", (0,1), (-1,-1), [colors.white, colors.HexColor("#f7f9fc")]),
    ("TOPPADDING", (0,0), (-1,-1), 4.5), ("BOTTOMPADDING", (0,0), (-1,-1), 4.5),
    ("LEFTPADDING", (0,0), (-1,-1), 5), ("RIGHTPADDING", (0,0), (-1,-1), 5),
]))
A(t)
A(Spacer(1, 14))

# ---------------------------------------------------------------- evidence
A(Paragraph(f'Evidence index ({len(D["evidence_index"])})', S["h2"]))
A(Paragraph("Every artefact this scan captured, with the SHA-256 of the exact bytes assessed. "
            "The claims and findings above cite these by E-number.", S["bodydim"]))
A(Spacer(1, 7))
rows = [[Paragraph("ID", S["cellhead"]), Paragraph("KIND", S["cellhead"]),
         Paragraph("SOURCE", S["cellhead"]), Paragraph("HTTP", S["cellhead"]),
         Paragraph("SHA-256", S["cellhead"])]]
for e in D["evidence_index"]:
    rows.append([
        Paragraph(f'<font face="Courier-Bold" size="7.4">E{e["evidence_id"]}</font>', S["cell"]),
        Paragraph(f'<font face="Courier" size="7">{esc(e["kind"])}</font>', S["cell"]),
        Paragraph(f'<font face="Courier" size="6.6">{esc(e["url"])}</font>', S["cell"]),
        Paragraph(f'<font size="7.4">{e["http_status"] if e["http_status"] is not None else "&#8212;"}</font>', S["cell"]),
        Paragraph(f'<font face="Courier" size="5.9">{e["sha256"]}</font>', S["cell"]),
    ])
t = Table(rows, colWidths=[12*mm, 26*mm, 52*mm, 11*mm, 57*mm], repeatRows=1)
t.setStyle(TableStyle([
    ("BACKGROUND", (0,0), (-1,0), INK),
    ("VALIGN", (0,0), (-1,-1), "TOP"),
    ("LINEBELOW", (0,0), (-1,-1), 0.4, RULE),
    ("ROWBACKGROUNDS", (0,1), (-1,-1), [colors.white, colors.HexColor("#f7f9fc")]),
    ("TOPPADDING", (0,0), (-1,-1), 4), ("BOTTOMPADDING", (0,0), (-1,-1), 4),
    ("LEFTPADDING", (0,0), (-1,-1), 5), ("RIGHTPADDING", (0,0), (-1,-1), 5),
]))
A(t)
A(Spacer(1, 12))

# ---------------------------------------------------------------- scope
A(Paragraph("Scope and limits", S["h2"]))
A(Spacer(1, 4))
A(Paragraph(
    "This assessment is HTTP-native and DNS-native: response headers, parsed HTML, "
    "<font face='Courier' size='8'>robots.txt</font>, the sitemap, "
    "<font face='Courier' size='8'>/.well-known/security.txt</font>, and public SPF, DMARC and MX records. "
    "It renders no JavaScript and runs no browser, so contrast ratios, focus order, keyboard traps and live "
    "ARIA state are <b>not</b> assessed. It is unauthenticated and covers the homepage only. "
    "TLS certificate chain and cipher suite are not inspected. DKIM is not checked, because a DKIM selector "
    "cannot be enumerated from outside and reporting its absence would be a guess.", S["body"]))
A(Spacer(1, 8))
A(Paragraph(
    "MUSTER's SITREP is a technical assessment, not a compliance certification or legal opinion. It does not "
    "constitute legal advice; organizations remain solely responsible for their own legal and regulatory "
    "obligations. Framework references indicate where a finding is relevant to a control, not that any "
    "certification has been achieved.", S["small"]))

# ---------------------------------------------------------------- page furniture
def furniture(canvas, doc):
    canvas.saveState()
    w, h = LETTER
    canvas.setStrokeColor(RULE); canvas.setLineWidth(0.6)
    canvas.line(20*mm, 15*mm, w - 20*mm, 15*mm)
    canvas.setFont("Helvetica", 7)
    canvas.setFillColor(INK_DIM)
    canvas.drawString(20*mm, 11*mm,
        f'MUSTER SITREP #{sr["id"]} v{sr["version"]}  |  scan #{scan["scan_id"]}  |  {site["url"]}')
    canvas.drawRightString(w - 20*mm, 11*mm, f"Page {doc.page}")
    # The content hash goes on its own line. Centring it on the same baseline
    # ran it straight through the URL on the left.
    canvas.setFont("Courier", 5.8)
    canvas.setFillColor(INK_DIM)
    canvas.drawString(20*mm, 7.6*mm, f'SITREP content sha256 {sr["content_sha256"]}')
    canvas.restoreState()

doc = BaseDocTemplate(OUT, pagesize=LETTER,
                      leftMargin=20*mm, rightMargin=20*mm, topMargin=18*mm, bottomMargin=22*mm,
                      title=f'MUSTER SITREP - {site["name"]} - scan {scan["scan_id"]}',
                      author="MUSTER by 28 Foot Systems (After Today, LLC)",
                      subject=sr["headline"])
frame = Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id="f")
doc.addPageTemplates([PageTemplate(id="main", frames=[frame], onPage=furniture)])
doc.build(story)
print("wrote", OUT)
