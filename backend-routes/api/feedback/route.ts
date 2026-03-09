// /api/feedback/route.ts
// Drop this into src/app/api/feedback/route.ts in Amach-Website.
//
// Receives Luma response ratings. Stores only rating + screen + platform —
// NO message content. Health chat text never leaves the user's device for
// this purpose, consistent with "Your Data, Your Health".
//
// You can use your existing Next.js DB connection (Prisma, pg, etc.)
// or the lightweight in-app analytics pattern below. No Supabase needed.
//
// If you want a table:
//
// CREATE TABLE luma_feedback (
//   id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
//   created_at timestamptz NOT NULL DEFAULT now(),
//   rating     text NOT NULL CHECK (rating IN ('helpful','unhelpful')),
//   screen     text,
//   platform   text NOT NULL DEFAULT 'web'
// );
//
// Query to check Luma quality by screen:
//   SELECT screen,
//          COUNT(*) FILTER (WHERE rating='helpful')   AS helpful,
//          COUNT(*) FILTER (WHERE rating='unhelpful') AS unhelpful,
//          ROUND(
//            100.0 * COUNT(*) FILTER (WHERE rating='helpful') / COUNT(*), 1
//          ) AS pct_helpful
//   FROM luma_feedback
//   GROUP BY screen
//   ORDER BY pct_helpful;

import { NextRequest, NextResponse } from "next/server";

interface FeedbackPayload {
  rating: "helpful" | "unhelpful";
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

  const { rating, screen, platform = "web" } = body;

  if (!rating || !["helpful", "unhelpful"].includes(rating)) {
    return NextResponse.json(
      { success: false, error: "rating must be 'helpful' or 'unhelpful'" },
      { status: 400 }
    );
  }

  // ── Persist ─────────────────────────────────────────────────
  // Wire up your existing DB client here. Console-logs until then.
  // Example with a hypothetical `db` import:
  //
  // import { db } from "@/lib/db";
  // await db.lumaFeedback.create({ data: { rating, screen, platform } });

  console.log(`[feedback] ${rating.toUpperCase()} | screen=${screen ?? "?"} platform=${platform}`);

  return NextResponse.json({ success: true });
}
