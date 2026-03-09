// /api/feedback/route.ts
// Drop this into src/app/api/feedback/route.ts in Amach-Website.
//
// Receives Luma response ratings. Stores rating + screen + platform,
// plus an optional free-text comment the user explicitly typed.
// No health chat content is included — only what the user writes here.
//
// CREATE TABLE luma_feedback (
//   id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
//   created_at timestamptz NOT NULL DEFAULT now(),
//   rating     text NOT NULL CHECK (rating IN ('helpful','unhelpful')),
//   screen     text,
//   platform   text NOT NULL DEFAULT 'web',
//   comment    text          -- user-written, null when not provided
// );
//
// Useful query:
//   SELECT screen,
//          COUNT(*) FILTER (WHERE rating='helpful')   AS helpful,
//          COUNT(*) FILTER (WHERE rating='unhelpful') AS unhelpful,
//          ROUND(
//            100.0 * COUNT(*) FILTER (WHERE rating='helpful') / COUNT(*), 1
//          ) AS pct_helpful
//   FROM luma_feedback
//   GROUP BY screen ORDER BY pct_helpful;

import { NextRequest, NextResponse } from "next/server";

interface FeedbackPayload {
  rating: "helpful" | "unhelpful";
  screen?: string;
  platform?: string;
  comment?: string;
}

export async function POST(req: NextRequest) {
  let body: FeedbackPayload;

  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ success: false, error: "Invalid JSON" }, { status: 400 });
  }

  const { rating, screen, platform = "web", comment } = body;

  if (!rating || !["helpful", "unhelpful"].includes(rating)) {
    return NextResponse.json(
      { success: false, error: "rating must be 'helpful' or 'unhelpful'" },
      { status: 400 }
    );
  }

  // Trim and cap comment length — user-provided text, so sanitise before storage
  const cleanComment = comment?.trim().slice(0, 500) || null;

  // ── Persist ─────────────────────────────────────────────────
  // Wire up your existing DB client here. Console-logs until then.
  // Example with a hypothetical `db` import:
  //
  // import { db } from "@/lib/db";
  // await db.lumaFeedback.create({ data: { rating, screen, platform, comment: cleanComment } });

  console.log(
    `[feedback] ${rating.toUpperCase()} | screen=${screen ?? "?"} platform=${platform}` +
      (cleanComment ? `\n  comment: ${cleanComment}` : "")
  );

  return NextResponse.json({ success: true });
}
