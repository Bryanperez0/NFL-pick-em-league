import { useEffect, useState } from "react";
import { rpc } from "../api.js";
import { weekArgs, weekLabel } from "../weeks.js";
import WeekPicker from "../WeekPicker.jsx";

export default function Leaderboard({ token, me, weeks, week, setWeek, onAuthError }) {
  const [data, setData] = useState(null);
  const [view, setView] = useState("season");
  const [error, setError] = useState("");

  useEffect(() => {
    setData(null);
    setError("");
    rpc("get_leaderboard", { p_token: token, ...weekArgs(week) })
      .then(setData)
      .catch((err) => (err.message === "Not logged in" ? onAuthError() : setError(err.message)));
  }, [week]);

  const rows = data ? data[view] : null;

  return (
    <section>
      <WeekPicker weeks={weeks} week={week} onChange={setWeek} />
      <div className="segmented">
        <button className={view === "season" ? "active" : ""} onClick={() => setView("season")}>
          Season
        </button>
        <button className={view === "weekly" ? "active" : ""} onClick={() => setView("weekly")}>
          {weekLabel(week)}
        </button>
      </div>
      <p className="muted tiny">
        {view === "season"
          ? `Season totals through ${weekLabel(week)}. Ties are broken by correct picks in ` +
            (data?.tiebreak_week ? weekLabel(data.tiebreak_week) : "the most recent week") +
            "."
          : "Points this week only. Ties share a rank."}{" "}
        1 point per correct pick; tie games score 0.
      </p>
      {error && <p className="error">{error}</p>}
      {!rows ? (
        <p className="muted">{error ? "" : "Loading leaderboard…"}</p>
      ) : (
        <table className="card board">
          <thead>
            <tr>
              <th>#</th>
              <th>Player</th>
              {view === "season" && <th className="num">TB</th>}
              <th className="num">Pts</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.player_id} className={r.player_id === me.player_id ? "mine" : ""}>
                <td>{r.rank}</td>
                <td>{r.display_name}</td>
                {view === "season" && <td className="num muted">{r.tiebreak}</td>}
                <td className="num"><strong>{r.points}</strong></td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {view === "season" && rows && <p className="muted tiny">TB = tiebreaker points.</p>}
    </section>
  );
}
