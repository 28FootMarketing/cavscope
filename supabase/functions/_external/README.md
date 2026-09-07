# `_external/` — source for functions this repo does not own

Everything here was deployed to the shared Supabase project
(`mgtmqucaldkaxvxglguw`) from this session, for a subsystem that has **no
repository anywhere**. It is kept here so the source exists in version control
at all, not because MUSTER owns it.

`supabase/config.toml` does not declare these, and nothing in this repo deploys
them. Do not add them to a MUSTER deploy. If the owning brand ever gets a repo,
move the directory there and delete it from here.

| Function | Why it is here |
|---|---|
| `publish-due` | Audio hub. `list_repos` has no audio-hub repository; the deployed function was the only copy of its source. Fixed and redeployed 2026-09-07 (v13) — see the header comment in the file for what was wrong. |
