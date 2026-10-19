import { useEffect, useState } from "react";
import { rpc } from "../api.js";
import { formatKickoff } from "../time.js";

const STATUS_LABEL = {
  in_progress: "In progress",
  final: "Final",
  postponed: "Postponed",
  canceled: "Canceled",
};

export default function Picks({ token, onAuthError }) {
  const [week, setWeek] = useState(null);
  const [games, setGames] = useState(null);
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(null);
  const [now, setNow] = useState(Date.now());

  async function load() {
    try {
      const current = await rpc("get_current_week");
      setWeek(current);
      if (!current) return setGames([]);
      setGames(
        await rpc("get_week_games", {
          p_token: token,
          p_season: current.season,
          p_season_type: current.season_type,
          p_week: current.week,
        })
      );
    } catch (err) {
      if (err.message === "Not logged in") onAuthError();
      else setError(err.message);
    }
  }

  useEffect(() => {
    load();
    // Tick every 30 seconds so games lock on screen at kickoff.
    const t = setInterval(() => setNow(Date.now()), 30000);
    return () => clearInterval(t);
  }, []);

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

  if (!games) return <p className="muted">{error || "Loading games…"}</p>;
  if (!week || games.length === 0) {
    return <p className="muted">No games loaded yet. The league admin needs to sync the schedule.</p>;
  }

  const picked = games.filter((g) => g.my_pick).length;

  return (
    <section>
      <div className="section-head">
        <h2>{week.season_type === 3 ? "Playoffs" : "Week"} {week.week}</h2>
        <span className="muted">{picked}/{games.length} picked</span>
      </div>
      <p className="muted tiny">Tap a team to pick it. Each game locks at its kickoff.</p>
      {error && <p className="error">{error}</p>}

      {games.map((g) => {
        const locked = g.locked || new Date(g.kickoff_at).getTime() <= now;
        return (
          <article key={g.id} className={"card game" + (locked ? " locked" : "")}>
            <div className="game-meta">
              <span>{formatKickoff(g.kickoff_at)}</span>
              <span>{STATUS_LABEL[g.status] || (locked ? "Locked" : "")}</span>
            </div>
            <div className="matchup">
              <TeamButton game={g} side="away" locked={locked} saving={saving === g.id} onPick={pick} />
              <span className="at">@</span>
              <TeamButton game={g} side="home" locked={locked} saving={saving === g.id} onPick={pick} />
            </div>
            {g.status === "final" && <Result game={g} />}
          </article>
        );
      })}
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
