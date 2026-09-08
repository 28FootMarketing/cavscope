# Defect code book

Every code the scan engine can raise, as a client-ready PDF: severity, scope,
what it means in plain English, how to clear it, and what it maps to.

```bash
pip install reportlab
python3 render.py codes.json MUSTER-defect-codes.pdf
```

`codes.json` is the catalog; `export.sql` regenerates its rule rows from
`muster.scan_rules`. As with `tools/sitrep-pdf`, the renderer never touches the
database and holds no credential.

## The one field that is not in the catalog

`scope` — whether a code produces **one verdict for the whole domain** or **one
per page**. It is a property of the engine, not of the rule row, and it is
derived from which step of `supabase/functions/muster-scan/index.ts` raises the
code. `export.sql` documents the mapping. Twelve are site-scoped, twenty-six are
page-scoped.

This matters more than it looks. `website_scan_settings.max_pages` defaults to
1, so today every page-scoped rule reports on the homepage only. Raise that and
page-scoped codes start reporting per page while site-scoped ones stay at one
finding each — so a code labelled wrongly here will either duplicate across a
crawl or silently under-report it.

## Keeping it honest

The counts in the summary grid are computed from the rules, not written down, so
the document cannot disagree with itself. When the catalog changes, re-run
`export.sql` and check the totals against:

```sql
select default_severity, count(*) from muster.scan_rules where active
group by default_severity;
```

Same layout notes as `tools/sitrep-pdf`: no Unicode sub/superscripts (ReportLab's
built-in fonts render them as black boxes), and the "What no code covers"
section is not boilerplate — it must stay true as the engine gains capabilities.
