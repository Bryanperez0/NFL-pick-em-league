import { useEffect, useState } from "react";
import { rpc } from "../api.js";

export default function Leaderboard({ token, me }) {
  const [week, setWeek] = useState(null);
  const [rows, setRows] = useState(null);
  const [error, setError] = useState("");

  useEffect(() => {
    (async () => {
      try {
        const current = await rpc("get_current_week");
        setWeek(current);
        if (!current) return setRows([]);
        setRows(
          await rpc("get_leaderboard", {
            p_token: token,
            p_season: current.season,
            p_season_type: current.season_type,
            p_week: current.week,
          })
        );
      } catch (err) {
        setError(err.message);
      }
    })();
  }, []);

  if (!rows) return <p className="muted">{error || "Loading leaderboard…"}</p>;

  return (
    <section>
      <div className="section-head">
        <h2>Leaderboard</h2>
        {week && <span className="muted">Week {week.week}</span>}
      </div>
      <p className="muted tiny">1 point per correct pick. Ties score 0. Updates as games finish.</p>
      <table className="card board">
        <thead>
          <tr>
            <th>#</th>
            <th>Player</th>
            <th className="num">Week</th>
            <th className="num">Season</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={r.player_id} className={r.player_id === me.player_id ? "mine" : ""}>
              <td>{i + 1}</td>
              <td>{r.display_name}</td>
              <td className="num">{r.week_points}</td>
              <td className="num">{r.season_points}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
