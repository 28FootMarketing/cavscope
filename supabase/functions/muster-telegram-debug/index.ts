import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// Retired. This was a temporary diagnostic (getMe/getUpdates dump) used once
// on 2026-09-25 to confirm the new CavScope Telegram bot's identity and read a
// chat_id off a pending update. The Supabase MCP has no delete for edge
// functions, so it cannot be removed outright -- it is neutralized here
// instead so a guessable URL cannot keep echoing Telegram update contents
// (which included the account holder's messages and chat_id).

Deno.serve(() => new Response("gone", { status: 410 }));
