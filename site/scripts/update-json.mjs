// /update.json, the one file the app reads from the internet: at most once a
// day, and when the person chooses Check for Updates, it asks whether a newer
// version exists. Written at build time from release.json (nuxt.config.ts),
// which stays the single source of truth; no copy of it is committed.
//
//   { "version": "1.1", "minimumSystem": "26.0", "date": "2026-12-01" }
//
// While release.json has no date (no release published yet) the file is
// still written, with the empty date, and the app reads it as "nothing newer".

const DOTTED = /^[0-9]+(?:\.[0-9]+)*$/
const DATE = /^\d{4}-\d{2}-\d{2}$/

/**
 * The text of update.json for a release.json, or an error when a value has
 * the wrong shape (the build then fails).
 * @param {{ version: unknown, minimumSystem: unknown, date: unknown }} release
 * @returns {string}
 */
export function updateJson(release) {
  const { version, minimumSystem, date } = release
  if (typeof version !== 'string' || !DOTTED.test(version)) {
    throw new Error(`release.json: "version" is ${JSON.stringify(version)}; expected digits and dots, such as 1.0`)
  }
  if (typeof minimumSystem !== 'string' || !DOTTED.test(minimumSystem)) {
    throw new Error(`release.json: "minimumSystem" is ${JSON.stringify(minimumSystem)}; expected digits and dots, such as 26.0`)
  }
  if (typeof date !== 'string' || (date !== '' && !DATE.test(date))) {
    throw new Error(`release.json: "date" is ${JSON.stringify(date)}; expected YYYY-MM-DD, or empty while the release is not published`)
  }
  return `{ "version": ${JSON.stringify(version)}, "minimumSystem": ${JSON.stringify(minimumSystem)}, "date": ${JSON.stringify(date)} }\n`
}
