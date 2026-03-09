// /api/feedback/route.ts
// Drop this into src/app/api/feedback/route.ts in Amach-Website.
//
// Receives Luma response ratings from iOS and web, then proxies them
// to the admin app at ADMIN_API_URL — same pattern as /api/tracking.
//
// To view feedback in the admin app, handle POST /api/feedback there
// and store/display it however you like alongside tracking data.

import { NextRequest, NextResponse } from "next/server";

interface FeedbackPayload {
  rating: "helpful" | "unhelpful";
  screen?: string;
  platform?: string;
  comment?: string;
}

export async function POST(req: NextRequest): Promise<NextResponse> {
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

  // Trim and cap comment — user-provided text
  const cleanComment = comment?.trim().slice(0, 500) || null;

  console.log(
    `📊 Luma feedback received: ${rating.toUpperCase()} | screen=${screen ?? "?"} platform=${platform}` +
      (cleanComment ? `\n  comment: ${cleanComment}` : "")
  );

  const adminApiUrl = process.env.ADMIN_API_URL || "http://localhost:3001/api";
  const apiKey = process.env.ADMIN_API_KEY;

  if (!apiKey) {
    console.error("❌ ADMIN_API_KEY not configured");
    return NextResponse.json({ error: "Server configuration error" }, { status: 500 });
  }

  try {
    const response = await fetch(`${adminApiUrl}/feedback`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": apiKey,
      },
      body: JSON.stringify({ rating, screen, platform, comment: cleanComment }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error(`❌ Admin feedback API error (${response.status}):`, errorText);
      throw new Error(`Admin feedback API responded with ${response.status}: ${errorText}`);
    }

    const data = await response.json();
    console.log("✅ Feedback forwarded to admin app");
    return NextResponse.json(data);
  } catch (error: unknown) {
    const errorMessage = error instanceof Error ? error.message : "Unknown error";
    console.error("❌ Failed to forward feedback:", errorMessage);
    return NextResponse.json(
      { error: "Failed to process feedback", details: errorMessage },
      { status: 500 }
    );
  }
}
