import { useState } from "react";
import { rpc } from "../api.js";

const MODES = {
  login: { label: "Log In", button: "Log in" },
  join: { label: "Join", button: "Join league" },
  create: { label: "New League", button: "Create league" },
};

export default function JoinLogin({ onSignedIn }) {
  const [mode, setMode] = useState("login");
  const [code, setCode] = useState("");
  const [leagueName, setLeagueName] = useState("");
  const [name, setName] = useState("");
  const [pin, setPin] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit(e) {
    e.preventDefault();
    setError("");
    if (!/^\d{4}$/.test(pin)) return setError("PIN must be exactly 4 digits.");
    setBusy(true);
    try {
      let result;
      if (mode === "create") {
        result = await rpc("create_league", {
          p_league_name: leagueName,
          p_display_name: name,
          p_pin: pin,
        });
      } else {
        result = await rpc(mode === "join" ? "join_league" : "login", {
          p_code: code,
          p_display_name: name,
          p_pin: pin,
        });
      }
      onSignedIn(result);
    } catch (err) {
      setError(err.message);
      setPin("");
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="page narrow">
      <h1 className="brand">Sunday Picks</h1>
      <p className="muted">Pick every game. Beat your friends.</p>

      <div className="segmented">
        {Object.entries(MODES).map(([key, m]) => (
          <button
            key={key}
            type="button"
            className={mode === key ? "active" : ""}
            onClick={() => {
              setMode(key);
              setError("");
            }}
          >
            {m.label}
          </button>
        ))}
      </div>

      <form className="card form" onSubmit={submit}>
        {mode === "create" ? (
          <label>
            League name
            <input value={leagueName} onChange={(e) => setLeagueName(e.target.value)}
              maxLength={40} required />
          </label>
        ) : (
          <label>
            League code
            <input value={code} onChange={(e) => setCode(e.target.value.toUpperCase())}
              autoCapitalize="characters" autoComplete="off" maxLength={6} required />
          </label>
        )}
        <label>
          Your name
          <input value={name} onChange={(e) => setName(e.target.value)}
            autoComplete="nickname" maxLength={20} required />
        </label>
        <label>
          4-digit PIN
          <input type="password" inputMode="numeric" pattern="\d{4}" maxLength={4}
            value={pin} onChange={(e) => setPin(e.target.value.replace(/\D/g, ""))}
            autoComplete={mode === "login" ? "current-password" : "new-password"} required />
        </label>
        {mode !== "login" && (
          <p className="muted tiny">
            Remember your PIN. You'll need it to log in on another phone. Only the
            league admin can reset it.
          </p>
        )}
        {error && <p className="error">{error}</p>}
        <button className="primary" disabled={busy}>
          {busy ? "Please wait…" : MODES[mode].button}
        </button>
      </form>
    </main>
  );
}
