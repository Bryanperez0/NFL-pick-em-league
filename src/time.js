// Kickoff times are stored in UTC and always shown in US Eastern time.
const fmt = new Intl.DateTimeFormat("en-US", {
  timeZone: "America/New_York",
  weekday: "short",
  month: "short",
  day: "numeric",
  hour: "numeric",
  minute: "2-digit",
});

export function formatKickoff(iso) {
  return fmt.format(new Date(iso)) + " ET";
}
