// admin-app/lib/database-migration.ts
//
// DO NOT copy this file as-is. Instead, add the CREATE TABLE block below
// into your existing admin-app/lib/database.ts, alongside the other
// CREATE TABLE statements in the db initialisation function.
//
// ─────────────────────────────────────────────────────────────────────
// Add this inside the function that initialises / migrates your SQLite DB
// (look for the block that calls db.exec() with other CREATE TABLE statements):

/*
  db.exec(`
    CREATE TABLE IF NOT EXISTS luma_feedback (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      created_at TEXT    NOT NULL DEFAULT (datetime('now')),
      rating     TEXT    NOT NULL CHECK (rating IN ('helpful', 'unhelpful')),
      screen     TEXT,
      platform   TEXT    NOT NULL DEFAULT 'web',
      comment    TEXT
    );
  `);
*/

// ─────────────────────────────────────────────────────────────────────
// If the DB is already running and you don't want to wipe it, you can
// run this one-off migration instead (e.g. in init-db/route.ts or a
// standalone script):

/*
  db.exec(`
    CREATE TABLE IF NOT EXISTS luma_feedback (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      created_at TEXT    NOT NULL DEFAULT (datetime('now')),
      rating     TEXT    NOT NULL CHECK (rating IN ('helpful', 'unhelpful')),
      screen     TEXT,
      platform   TEXT    NOT NULL DEFAULT 'web',
      comment    TEXT
    );
  `);
*/

// Useful queries once data is flowing:
//
//   -- All unhelpful with comments:
//   SELECT created_at, screen, platform, comment
//   FROM luma_feedback
//   WHERE rating = 'unhelpful' AND comment IS NOT NULL
//   ORDER BY created_at DESC;
//
//   -- Summary by screen:
//   SELECT
//     screen,
//     COUNT(*) FILTER (WHERE rating='helpful')   AS helpful,
//     COUNT(*) FILTER (WHERE rating='unhelpful') AS unhelpful,
//     ROUND(
//       100.0 * COUNT(*) FILTER (WHERE rating='helpful') / COUNT(*), 1
//     ) AS pct_helpful
//   FROM luma_feedback
//   GROUP BY screen ORDER BY pct_helpful;

export {};
