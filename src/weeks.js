// Week labels and comparisons. season_type 2 = regular season, 3 = playoffs.
const PLAYOFF_NAMES = { 1: "Wild Card", 2: "Divisional", 3: "Conference Championships", 4: "Pro Bowl Week", 5: "Super Bowl" };

export function weekLabel(w) {
  if (!w) return "";
  return w.season_type === 3 ? PLAYOFF_NAMES[w.week] || `Playoffs ${w.week}` : `Week ${w.week}`;
}

export function sameWeek(a, b) {
  return a && b && a.season === b.season && a.season_type === b.season_type && a.week === b.week;
}

// Arguments the database functions expect for a week.
export function weekArgs(w) {
  return { p_season: w.season, p_season_type: w.season_type, p_week: w.week };
}
