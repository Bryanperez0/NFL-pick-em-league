import { useEffect, useState } from "react";
import { rpc } from "../api.js";
import { formatKickoff } from "../time.js";
import { weekArgs } from "../weeks.js";
import WeekPicker from "../WeekPicker.jsx";

const STATUS_LABEL = {
  scheduled: "Waiting for result",
  in_progress: "In progress",
  final: "Final",
  postponed: "Postponed",
  canceled: "Canceled",
};

// Admin mode lasts 30 minutes. The token is kept in memory only, so reloading
// the app (or logging out) always asks for the PIN again.
let unlocked = { playerId: null, token: null };

export default function Admin({ token, me, weeks, week, setWeek }) {
  const [adminToken, setAdminToken] = useState(
    unlocked.playerId === me.player_id ? unlocked.token : null
  );

  function lock() {
    unlocked = { playerId: null, token: null };
    setAdminToken(null);
  }

  if (!adminToken) {
    return (
      <Unlock
        token={token}
        onUnlocked={(t) => {
          unlocked = { playerId: me.player_id, token: t };
          setAdminToken(t);
        }}
      />
    );
  }

  // Any "session expired" error sends the admin back to the PIN screen.
  async function adminRpc(name, args) {
    try {
      return await rpc(name, { p_admin_token: adminToken, ...args });
    } catch (err) {
      if (err.message.startsWith("Admin session expired")) lock();
      throw err;
    }
  }

  return (
    <section>
      <div className="section-head">
        <h2>Admin</h2>
        <button className="link" onClick={lock}>Lock admin</button>
      </div>
      <Players adminRpc={adminRpc} me={me} />
      <Results token={token} adminRpc={adminRpc} weeks={weeks} week={week} setWeek={setWeek} />
    </section>
  );
}

function Unlock({ token, onUnlocked }) {
  const [pin, setPin] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit(e) {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      const r = await rpc("admin_unlock", { p_token: token, p_pin: pin });
      onUnlocked(r.admin_token);
    } catch (err) {
      setError(err.message);
      setPin("");
    } finally {
      setBusy(false);
    }
  }

  return (
    <form className="card form" onSubmit={submit}>
      <h2>Admin</h2>
      <p className="muted tiny">Enter your PIN to open admin tools.</p>
      <label>
        Your PIN
        <input type="password" inputMode="numeric" maxLength={4} value={pin}
          onChange={(e) => setPin(e.target.value.replace(/\D/g, ""))} autoComplete="current-password" required />
      </label>
      {error && <p className="error">{error}</p>}
      <button className="primary" disabled={busy || pin.length !== 4}>
        {busy ? "Checking…" : "Unlock"}
      </button>
    </form>
  );
}

function Players({ adminRpc, me }) {
  const [players, setPlayers] = useState(null);
  const [resetting, setResetting] = useState(null);
  const [newPin, setNewPin] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  async function load() {
    try {
      setPlayers(await adminRpc("admin_list_players"));
    } catch (err) {
      setError(err.message);
    }
  }
  useEffect(() => {
    load();
  }, []);

  async function act(fn) {
    setError("");
    setMessage("");
    try {
      await fn();
      await load();
    } catch (err) {
      setError(err.message);
    }
  }

  function remove(p) {
    if (!window.confirm(`Remove ${p.display_name} and all their picks? This can't be undone.`)) return;
    act(async () => {
      await adminRpc("admin_remove_player", { p_player_id: p.player_id });
      setMessage(`${p.display_name} was removed.`);
    });
  }

  function savePin(p) {
    act(async () => {
      await adminRpc("admin_reset_pin", { p_player_id: p.player_id, p_new_pin: newPin });
      setMessage(`${p.display_name}'s PIN is now ${newPin}. Tell them privately.`);
      setResetting(null);
      setNewPin("");
    });
  }

  return (
    <div className="card">
      <h3>Players</h3>
      {message && <p className="ok">{message}</p>}
      {error && <p className="error">{error}</p>}
      {!players ? (
        <p className="muted">Loading…</p>
      ) : (
        players.map((p) => (
          <div key={p.player_id} className="admin-row">
            <div className="admin-row-main">
              <div>
                <strong>{p.display_name}</strong>
                {p.is_admin && <span className="badge">admin</span>}
                {p.locked && <span className="badge warn">locked out</span>}
                <div className="muted tiny">{p.picks_made} {p.picks_made === 1 ? "pick" : "picks"} made</div>
              </div>
              <div className="admin-actions">
                <button className="small-btn" onClick={() => { setResetting(p.player_id); setNewPin(""); }}>
                  Reset PIN
                </button>
                {p.player_id !== me.player_id && (
                  <button className="small-btn danger" onClick={() => remove(p)}>Remove</button>
                )}
              </div>
            </div>
            {resetting === p.player_id && (
              <div className="inline-form">
                <input type="text" inputMode="numeric" maxLength={4} placeholder="New 4-digit PIN"
                  value={newPin} onChange={(e) => setNewPin(e.target.value.replace(/\D/g, ""))} />
                <button className="small-btn" disabled={newPin.length !== 4} onClick={() => savePin(p)}>Save</button>
                <button className="small-btn" onClick={() => setResetting(null)}>Cancel</button>
              </div>
            )}
          </div>
        ))
      )}
      <p className="muted tiny">
        Resetting a PIN also unlocks the player and logs them out on their phone.
      </p>
    </div>
  );
}

function Results({ token, adminRpc, weeks, week, setWeek }) {
  const [games, setGames] = useState(null);
  const [edits, setEdits] = useState({});
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");

  async function load() {
    try {
      setGames(await rpc("get_week_games", { p_token: token, ...weekArgs(week) }));
    } catch (err) {
      setError(err.message);
    }
  }
  useEffect(() => {
    if (!week) return;
    setGames(null);
    setEdits({});
    load();
  }, [week]);

  function edit(id, side, value) {
    setEdits((e) => ({ ...e, [id]: { ...e[id], [side]: value.replace(/\D/g, "") } }));
  }

  async function save(g) {
    const e = edits[g.id] || {};
    const home = e.home ?? g.home_score ?? "";
    const away = e.away ?? g.away_score ?? "";
    setError("");
    setMessage("");
    try {
      await adminRpc("admin_set_result", {
        p_game_id: g.id,
        p_home_score: home === "" ? null : Number(home),
        p_away_score: away === "" ? null : Number(away),
      });
      setMessage(`Saved ${g.away_abbr} ${away} @ ${g.home_abbr} ${home}. Scores updated.`);
      setEdits((x) => ({ ...x, [g.id]: undefined }));
      load();
    } catch (err) {
      setError(err.message);
    }
  }

  async function undo(g) {
    setError("");
    setMessage("");
    try {
      await adminRpc("admin_clear_result", { p_game_id: g.id });
      setMessage(`${g.away_abbr} @ ${g.home_abbr} is back to the automatic result.`);
      load();
    } catch (err) {
      setError(err.message);
    }
  }

  if (!week) return null;
  const now = Date.now();

  return (
    <div className="card">
      <h3>Game results</h3>
      <p className="muted tiny">
        Results update automatically. Use this only if a score is wrong or missing. Your
        correction applies to this league only and the automatic sync won't overwrite it.
      </p>
      <WeekPicker weeks={weeks} week={week} onChange={setWeek} />
      {message && <p className="ok">{message}</p>}
      {error && <p className="error">{error}</p>}
      {!games ? (
        <p className="muted">Loading…</p>
      ) : (
        games.map((g) => {
          const started = new Date(g.kickoff_at).getTime() <= now;
          const e = edits[g.id] || {};
          return (
            <div key={g.id} className="admin-row">
              <div className="game-meta">
                <span>{formatKickoff(g.kickoff_at)}</span>
                <span>
                  {g.corrected ? "Corrected by admin" : started ? STATUS_LABEL[g.status] : "Not started"}
                </span>
              </div>
              {started ? (
                <div className="score-edit">
                  <label>
                    {g.away_abbr}
                    <input inputMode="numeric" maxLength={3} value={e.away ?? g.away_score ?? ""}
                      onChange={(ev) => edit(g.id, "away", ev.target.value)} />
                  </label>
                  <span className="at">@</span>
                  <label>
                    {g.home_abbr}
                    <input inputMode="numeric" maxLength={3} value={e.home ?? g.home_score ?? ""}
                      onChange={(ev) => edit(g.id, "home", ev.target.value)} />
                  </label>
                  <button className="small-btn" onClick={() => save(g)}>Save final</button>
                  {g.corrected && <button className="small-btn" onClick={() => undo(g)}>Undo</button>}
                </div>
              ) : (
                <p className="muted tiny">{g.away_abbr} @ {g.home_abbr}</p>
              )}
            </div>
          );
        })
      )}
    </div>
  );
}
