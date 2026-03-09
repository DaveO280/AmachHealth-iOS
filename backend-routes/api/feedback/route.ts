// /api/feedback/route.ts
// Drop this into src/app/api/feedback/route.ts in Amach-Website.
//
// Receives anonymized Luma response ratings from the iOS app and web.
// Payload contains only raw message text — no health metrics, no wallet data.
//
// Storage: appends to a simple feedback log in your database.
// If you're on Supabase, create the table with the SQL below.
// If you don't have DB access yet, the route still returns 200 and just logs.
//
// CREATE TABLE luma_feedback (
//   id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
//   created_at  timestamptz NOT NULL DEFAULT now(),
//   rating      text NOT NULL CHECK (rating IN ('helpful','unhelpful')),
//   user_msg    text,
//   assistant_msg text NOT NULL,
//   screen      text,
//   platform    text NOT NULL DEFAULT 'web'
// );

import { NextRequest, NextResponse } from "next/server";

interface FeedbackPayload {
  rating: "helpful" | "unhelpful";
  userMessage?: string;
  assistantMessage: string;
  screen?: string;
  platform?: string;
}

export async function POST(req: NextRequest) {
  let body: FeedbackPayload;

  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ success: false, error: "Invalid JSON" }, { status: 400 });
  }

  const { rating, userMessage, assistantMessage, screen, platform = "web" } = body;

  if (!rating || !["helpful", "unhelpful"].includes(rating)) {
    return NextResponse.json(
      { success: false, error: "rating must be 'helpful' or 'unhelpful'" },
      { status: 400 }
    );
  }

  if (!assistantMessage?.trim()) {
    return NextResponse.json(
      { success: false, error: "assistantMessage is required" },
      { status: 400 }
    );
  }

  // ── Persist ─────────────────────────────────────────────────
  // Swap in your DB client here. Supabase example below.
  // If SUPABASE_URL / SUPABASE_SERVICE_KEY are not set the route
  // still succeeds — the rating is just console-logged for now.

  const supabaseUrl = process.env.SUPABASE_URL;
  const supabaseKey = process.env.SUPABASE_SERVICE_KEY;

  if (supabaseUrl && supabaseKey) {
    try {
      const { createClient } = await import("@supabase/supabase-js");
      const supabase = createClient(supabaseUrl, supabaseKey);

      const { error } = await supabase.from("luma_feedback").insert({
        rating,
        user_msg: userMessage ?? null,
        assistant_msg: assistantMessage,
        screen: screen ?? null,
        platform,
      });

      if (error) {
        console.error("[feedback] Supabase insert error:", error.message);
        // Still return 200 — client doesn't need to know about storage failures
      }
    } catch (err) {
      console.error("[feedback] Supabase error:", err);
    }
  } else {
    // No DB configured — log for local dev / initial deploy
    console.log(
      `[feedback] ${rating.toUpperCase()} | platform=${platform} screen=${screen ?? "?"}\n` +
        `  user: ${userMessage?.slice(0, 120) ?? "(no user msg)"}\n` +
        `  luma: ${assistantMessage.slice(0, 120)}`
    );
  }

  return NextResponse.json({ success: true });
}
