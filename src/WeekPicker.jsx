import { weekLabel, sameWeek } from "./weeks.js";

// "‹ Week 6 ›" — step backward and forward through the season's weeks.
export default function WeekPicker({ weeks, week, onChange }) {
  const i = weeks.findIndex((w) => sameWeek(w, week));
  return (
    <div className="week-picker">
      <button aria-label="Previous week" disabled={i <= 0} onClick={() => onChange(weeks[i - 1])}>‹</button>
      <h2>{weekLabel(week)}</h2>
      <button aria-label="Next week" disabled={i < 0 || i >= weeks.length - 1} onClick={() => onChange(weeks[i + 1])}>›</button>
    </div>
  );
}
