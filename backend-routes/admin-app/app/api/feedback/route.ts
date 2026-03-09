// admin-app/app/api/feedback/route.ts
//
// Copy to: admin-app/app/api/feedback/route.ts
//
// Receives Luma response ratings forwarded from the main app's
// /api/feedback proxy. Stores them in SQLite alongside tracking data.
// Auth pattern matches /api/tracking exactly.

import { NextRequest, NextResponse } from "next/server";
import { validateApiKey } from "../../lib/apiAuth";
import { getDatabase } from "../../lib/database";

export async function POST(request: NextRequest): Promise<NextResponse> {
  const authError = validateApiKey(request);
  if (authError) return authError;

  let body: {
    rating?: string;
    screen?: string;
    platform?: string;
    comment?: string;
  };

  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON" }, { status: 400 });
  }

  const { rating, screen, platform = "web", comment } = body;

  if (!rating || !["helpful", "unhelpful"].includes(rating)) {
    return NextResponse.json(
      { error: "rating must be 'helpful' or 'unhelpful'" },
      { status: 400 }
    );
  }

  try {
    const db = getDatabase();

    db.prepare(`
      INSERT INTO luma_feedback (rating, screen, platform, comment)
      VALUES (?, ?, ?, ?)
    `).run(rating, screen ?? null, platform, comment ?? null);

    console.log(
      `✅ Luma feedback stored: ${rating.toUpperCase()} | screen=${screen ?? "?"} platform=${platform}` +
        (comment ? `\n   comment: ${comment}` : "")
    );

    return NextResponse.json({ success: true });
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : "Unknown error";
    console.error("❌ Failed to store feedback:", message);
    return NextResponse.json(
      { error: "Failed to store feedback", details: message },
      { status: 500 }
    );
  }
}

export async function GET(request: NextRequest): Promise<NextResponse> {
  const authError = validateApiKey(request);
  if (authError) return authError;

  try {
    const db = getDatabase();

    const { searchParams } = new URL(request.url);
    const ratingFilter = searchParams.get("rating"); // ?rating=unhelpful
    const limit = Math.min(parseInt(searchParams.get("limit") ?? "100"), 500);

    const rows = ratingFilter
      ? db
          .prepare(
            `SELECT * FROM luma_feedback
             WHERE rating = ?
             ORDER BY created_at DESC LIMIT ?`
          )
          .all(ratingFilter, limit)
      : db
          .prepare(
            `SELECT * FROM luma_feedback ORDER BY created_at DESC LIMIT ?`
          )
          .all(limit);

    const summary = db
      .prepare(
        `SELECT
           rating,
           COUNT(*) as count,
           COUNT(comment) as with_comment
         FROM luma_feedback GROUP BY rating`
      )
      .all();

    return NextResponse.json({ summary, entries: rows });
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : "Unknown error";
    console.error("❌ Failed to fetch feedback:", message);
    return NextResponse.json(
      { error: "Failed to fetch feedback", details: message },
      { status: 500 }
    );
  }
}
