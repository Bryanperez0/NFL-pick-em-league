// sync-games — Supabase Edge Function
//
// Pulls the schedule and scores for one week from ESPN's public scoreboard
// feed and saves them into the "games" table.
//
// Call it with a POST request. The body is optional JSON:
//   {}                                         -> whatever week ESPN says is current
//   {"season": 2026, "season_type": 2, "week": 7}  -> a specific week
// season_type: 1 = preseason, 2 = regular season, 3 = postseason
//
// It must be called with the header  x-sync-secret: <your SYNC_SECRET>
// so random people can't trigger it.
//
// Secrets it reads (set in Supabase Dashboard > Edge Functions > Secrets):
//   SYNC_SECRET                — you choose this; any long random string
//   SUPABASE_URL               — provided by Supabase automatically
//   SUPABASE_SERVICE_ROLE_KEY  — provided by Supabase automatically

const ESPN_URL = "https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard";

type Game = {
  id: string;
  season: number;
  season_type: number;
  week: number;
  kickoff_at: string;
  home_team: string;
  home_abbr: string;
  away_team: string;
  away_abbr: string;
  home_score: number | null;
  away_score: number | null;
  status: "scheduled" | "in_progress" | "final" | "postponed" | "canceled";
  winner: "home" | "away" | "tie" | null;
};

// Turn ESPN's JSON into our game rows.
// deno-lint-ignore no-explicit-any
export function parseScoreboard(data: any): Game[] {
  const games: Game[] = [];
  for (const event of data?.events ?? []) {
    const comp = event.competitions?.[0];
    const home = comp?.competitors?.find((c: any) => c.homeAway === "home");
    const away = comp?.competitors?.find((c: any) => c.homeAway === "away");
    if (!home || !away) continue;

    const type = event.status?.type ?? comp.status?.type ?? {};
    let status: Game["status"];
    if (type.name === "STATUS_POSTPONED") status = "postponed";
    else if (type.name === "STATUS_CANCELED") status = "canceled";
    else if (type.state === "post" && type.completed) status = "final";
    else if (type.state === "in" || type.state === "post") status = "in_progress";
    else status = "scheduled";

    // ESPN shows "0" for games that haven't started; store no score instead.
    const started = status === "in_progress" || status === "final";
    const homeScore = started ? Number(home.score) : null;
    const awayScore = started ? Number(away.score) : null;

    let winner: Game["winner"] = null;
    if (status === "final" && homeScore !== null && awayScore !== null) {
      winner = homeScore > awayScore ? "home" : awayScore > homeScore ? "away" : "tie";
    }

    games.push({
      id: String(event.id),
      season: Number(event.season?.year ?? data.season?.year),
      season_type: Number(event.season?.type ?? data.season?.type),
      week: Number(event.week?.number ?? data.week?.number),
      kickoff_at: new Date(event.date).toISOString(), // always UTC
      home_team: home.team.displayName,
      home_abbr: home.team.abbreviation,
      away_team: away.team.displayName,
      away_abbr: away.team.abbreviation,
      home_score: homeScore,
      away_score: awayScore,
      status,
      winner,
    });
  }
  return games;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("SYNC_SECRET");
  if (!secret || req.headers.get("x-sync-secret") !== secret) {
    return json({ error: "Not allowed" }, 401);
  }

  let body: { season?: number; season_type?: number; week?: number } = {};
  try {
    body = await req.json();
  } catch {
    // no body is fine
  }

  const url = new URL(ESPN_URL);
  if (body.week) {
    url.searchParams.set("dates", String(body.season ?? new Date().getUTCFullYear()));
    url.searchParams.set("seasontype", String(body.season_type ?? 2));
    url.searchParams.set("week", String(body.week));
  }

  const espn = await fetch(url);
  if (!espn.ok) {
    return json({ error: `ESPN returned ${espn.status}` }, 502);
  }
  const games = parseScoreboard(await espn.json());

  // Save through the upsert_games database function using the service-role key.
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const headers: Record<string, string> = { apikey: key, "content-type": "application/json" };
  if (key.startsWith("eyJ")) headers.authorization = `Bearer ${key}`; // legacy JWT-style key
  const save = await fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/rpc/upsert_games`, {
    method: "POST",
    headers,
    body: JSON.stringify({ p_games: games }),
  });
  if (!save.ok) {
    return json({ error: "Saving to database failed", detail: await save.text() }, 500);
  }

  return json({ saved: games.length, source: url.toString() });
});
