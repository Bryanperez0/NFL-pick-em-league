import { useEffect, useState } from "react";
import { rpc } from "../api.js";
import { formatKickoff } from "../time.js";
import { weekArgs } from "../weeks.js";
import WeekPicker from "../WeekPicker.jsx";

const STATUS_LABEL = {
  in_progress: "In progress",
  final: "Final",
  postponed: "Postponed",
  canceled: "Canceled",
};

export default function Picks({ token, weeks, week, setWeek, onAuthError }) {
  const [games, setGames] = useState(null);
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(null);
  const [now, setNow] = useState(Date.now());

  async function load() {
    try {
      setGames(await rpc("get_week_games", { p_token: token, ...weekArgs(week) }));
    } catch (err) {
      if (err.message === "Not logged in") onAuthError();
      else setError(err.message);
    }
  }

  useEffect(() => {
    setGames(null);
    setError("");
    load();
    // Keep scores and locks fresh: tick every 30 seconds, reload every 2 minutes
    // and whenever the app comes back to the foreground.
    const tick = setInterval(() => setNow(Date.now()), 30000);
    const refresh = setInterval(load, 120000);
    const onVisible = () => document.visibilityState === "visible" && load();
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      clearInterval(tick);
      clearInterval(refresh);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [week]);

  async function pick(game, side) {
    setError("");
    setSaving(game.id);
    try {
      await rpc("submit_pick", { p_token: token, p_game_id: game.id, p_pick: side });
      setGames((gs) => gs.map((g) => (g.id === game.id ? { ...g, my_pick: side } : g)));
    } catch (err) {
      setError(err.message);
      load(); // refresh so locked games show as locked
    } finally {
      setSaving(null);
    }
  }

  const picked = games ? games.filter((g) => g.my_pick).length : 0;

  return (
    <section>
      <WeekPicker weeks={weeks} week={week} onChange={setWeek} />
      {games && (
        <p className="muted tiny center">
          {picked}/{games.length} picked · Tap a team to pick it. Each game locks at its kickoff.
        </p>
      )}
      {error && <p className="error">{error}</p>}
      {!games ? (
        <p className="muted">Loading games…</p>
      ) : games.length === 0 ? (
        <p className="muted">No games this week.</p>
      ) : (
        games.map((g) => {
          const locked = g.locked || new Date(g.kickoff_at).getTime() <= now;
          return (
            <article key={g.id} className={"card game" + (locked ? " locked" : "")}>
              <div className="game-meta">
                <span>{formatKickoff(g.kickoff_at)}</span>
                <span>
                  {STATUS_LABEL[g.status] || (locked ? "Locked" : "")}
                  {g.corrected && " · corrected"}
                </span>
              </div>
              <div className="matchup">
                <TeamButton game={g} side="away" locked={locked} saving={saving === g.id} onPick={pick} />
                <span className="at">@</span>
                <TeamButton game={g} side="home" locked={locked} saving={saving === g.id} onPick={pick} />
              </div>
              {g.status === "final" && <Result game={g} />}
              {g.picks && g.picks.length > 0 && <LeaguePicks game={g} />}
            </article>
          );
        })
      )}
    </section>
  );
}

function TeamButton({ game, side, locked, saving, onPick }) {
  const selected = game.my_pick === side;
  const score = side === "home" ? game.home_score : game.away_score;
  return (
    <button
      className={"team" + (selected ? " selected" : "")}
      disabled={locked || saving}
      onClick={() => onPick(game, side)}
      aria-pressed={selected}
    >
      <span className="abbr">{side === "home" ? game.home_abbr : game.away_abbr}</span>
      <span className="name">{side === "home" ? game.home_team : game.away_team}</span>
      {score !== null && <span className="score">{score}</span>}
    </button>
  );
}

function Result({ game }) {
  if (!game.my_pick) return <p className="result miss">No pick · 0 pts</p>;
  if (game.winner === "tie") return <p className="result miss">Tie game · 0 pts</p>;
  return game.my_pick === game.winner ? (
    <p className="result win">Correct · 1 pt</p>
  ) : (
    <p className="result miss">Wrong · 0 pts</p>
  );
}

// Everyone's picks, shown only after kickoff (the database hides them before).
function LeaguePicks({ game }) {
  const names = (side) => game.picks.filter((p) => p.pick === side).map((p) => p.name);
  const away = names("away");
  const home = names("home");
  return (
    <details className="league-picks">
      <summary>League picks: {game.away_abbr} {away.length} · {game.home_abbr} {home.length}</summary>
      <p><strong>{game.away_abbr}:</strong> {away.join(", ") || "nobody"}</p>
      <p><strong>{game.home_abbr}:</strong> {home.join(", ") || "nobody"}</p>
    </details>
  );
}
