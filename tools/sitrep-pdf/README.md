# SITREP → PDF

Renders a row of `muster.sitreps` as a client-ready PDF. It composes nothing:
every number, claim, finding, framework reference and hash on the page comes
from the stored SITREP, and the F/E citation scheme is carried through so a
reader can trace any sentence back to the evidence it was derived from.

## Use

```bash
pip install reportlab
psql "$MUSTER_DB_URL" -At -f export.sql -v sitrep_id=16 > sitrep-16.json
python3 render.py sitrep-16.json CavScope-SITREP.pdf
```

`export.sql` is the query; it takes `:sitrep_id` and emits the exact JSON shape
`render.py` expects. Run it however you reach the database — `psql`, the
Supabase SQL editor, or the MCP `execute_sql` tool — the script only needs the
resulting JSON on disk.

## Why the two steps are separate

The renderer never touches the database and holds no credentials. That keeps the
part which must run wherever a report is produced free of anything that has to
be kept secret, and it means the JSON is an auditable intermediate: the same
input always produces the same document.

## Notes for anyone editing the layout

- Do not use Unicode subscript or superscript characters. ReportLab's built-in
  fonts have no glyphs for them and they render as solid black boxes.
- `frameworks()` drops the `CUSTOM` key deliberately. It is the catalog's label
  for a reference outside the named frameworks, and its value already names the
  standard, so printing the key reads like a bug on a client page.
- The scope-and-limits section is not boilerplate. It states what the HTTP-native
  engine does not assess. Keep it accurate when the engine gains a capability.
