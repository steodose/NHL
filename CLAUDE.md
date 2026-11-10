# NHL Analytics site

R Markdown website published at <https://steodose.github.io/NHL>, a sibling of
the NFL site (`../NFL`, read its CLAUDE.md too: most of its gotchas apply here).
GitHub Pages serves the **root of `master`**, so rendered `.html`, `site_libs/`
and `*_files/` are committed on purpose. Live scores live in the separate
`../nhl-scores` site; this site does not show them.

Pages: `index.Rmd` (Summary: standings, the landing page), `Teams.Rmd` (charts),
`Predictions.Rmd` (season simulations), `Players.Rmd` (placeholder), `about.Rmd`. Shared setup is in `R/helpers.R` (themes, `nhl_season`,
`nhl_teams`), `source()`d by each page. `R/load_pbp.R` (pbp download with
retry, cached in `tempdir()` so render_site downloads it once; `build_shots()`)
is shared by Teams and Predictions.

## Rendering

`rmarkdown::render_site()` only. Never bare `rmarkdown::render()`: it ignores
`_site.yml`, goes self-contained, and deletes the page's `_files/`.

`render_site()` renders every page in **one R session**, so a package attached
by one page masks functions in the next. `reactablefmtr` (attached on
index) masks `gt::google_font`, `gt::html` and `ggplot2::margin`, which is why
those are called namespaced. Keep doing that.

## fastRhockey

- Needs **fastRhockey >= 1.0.0**, which loads from the `sportsdataverse-data`
  GitHub releases (refreshed daily around 08:00 UTC). 0.4.0 points at a dead
  repo. On R 4.4 the CRAN *binary* is stuck at 0.4.0; install with
  `type = "source"`.
- The `load_nhl_*()` loaders do **not** error when the GitHub release
  download fails (a 504 happened on 2026-11-08): they warn and return an
  empty table. Teams.Rmd retries `load_nhl_pbp()` 3 times, then `stop()`s with
  a clear message, so CI fails loudly and pushes nothing. Wrap any new loader
  the same way.
- Seasons are labelled by **end year** (2026-27 = 2027).
  `most_recent_nhl_season()` handles the rollover, so nothing is hardcoded.
- `load_nhl_pbp()` ships an `xg` column on GOAL / SHOT / MISSED_SHOT
  (unblocked attempts; blocked shots are NA). No need to call
  `helper_nhl_calculate_xg()`.
- **BLOCKED_SHOT rows credit `event_team_abbr` to the blocking team**
  (event_player_1 = shooter, event_player_2 = blocker). Teams.Rmd flips it to
  the shooting team. Forgetting this silently corrupts Corsi.
- `strength_state` is from the event team's perspective (5v4 = event team on
  the PP). 5v5 is symmetric so it doesn't matter there.
- 5v5 TOI is derived from gaps between consecutive events. **Order by
  `game_seconds` then `event_idx`**: `event_idx` alone is not chronological
  and produces negative gaps (and games with 5000+ 5v5 minutes).
- `espn_nhl_scoreboard(dates = "YYYYMMDD-YYYYMMDD")` errors. Only single dates
  work, so attendance is fetched per date and cached in
  `data/attendance.csv` (committed; each render fetches new dates plus the
  last 3). Delete the CSV to force a full refetch.
- `nhl_standings()` returns NHL SVG logos in `team_logo`; it is dropped and
  replaced by the ESPN PNG from `data/nhl_teams.csv`, which ggimage can draw.
  `nhl_teams.csv` maps NHL abbreviations to ESPN ones (LAK/LA, NJD/NJ, SJS/SJ,
  TBL/TB, UTA/UTAH).

## Predictions model (`R/sim_model.R`)

nflseedR is NFL-only, so the simulation is our own. Constants are in `sim_const`.

- Rating = goals/game above average: preseason prior from the points O/U
  (`(pts_ou - mean) / 0.33 / games`) blended with in-season
  `0.7 * xGD/GP + 0.3 * GD/GP`, in-season weight `GP / (GP + 40)`. Each sim
  draws its own strengths around the ratings (sd shrinks with GP).
- Games: Poisson goals; a share of one-goal games is turned into ties so the
  simulated OT rate matches the real one (~23%). Loser point for OT/SO.
- Standings are rebuilt from the schedule (scores) + pbp (OT/SO from period
  types), not `nhl_standings()`, so the "played" and "remaining" sets come
  from the same snapshot. The live NHL standings can be a game ahead of the
  schedule release; that's expected.
- `predict_as_of()` runs everything as of a date and `check_sim_sums()` fails
  the render unless playoffs sum to 16, divisions to 4, Cup/Presidents'/1st
  pick to 1, conference to 2, top-3 picks to 3.
- **R precedence trap:** `2 * !hw + x` parses as `2 * !(hw + x)`. The sim
  uses an explicit `aw <- !hw`; keep it that way.
- Playoff format (division bracket, better division winner plays WC2) and the
  lottery odds / 10-spot max jump are hardcoded in `simulate_season()` and
  `sim_const$lottery_odds`. Revisit if the NHL changes them.
- Odds history: every render writes the day's rows to
  `data/playoff_odds_history_<season>.csv` (same-date rows replaced), which
  CI commits. `R/backfill_odds.R` rebuilt the 2026-27 history from opening
  night (2,000 sims per date); it is a one-off, not run in CI.
- **Open idea (not done):** slide the in-season blend from xG toward actual
  goals as GP grows (actual goals become more reliable with sample size),
  instead of the fixed 70/30. Test it before switching: backtest a past
  season's mid-season ratings against rest-of-season results (e.g. log loss
  on game outcomes) with the fixed and the sliding weights.
- The odds-over-time charts are plain Plotly.js (`R/odds_chart.js`), loaded
  from jsDelivr with the data inlined as JSON. Don't switch to the R plotly
  package: it commits a 3.6 MB plotly.js into `site_libs/`. Charts in hidden
  tabs are drawn on the Bootstrap `shown.bs.tab` event.

## Styling

Charts and gt/reactable tables use **Outfit** (loaded via `header.html`, installed in CI); page text keeps the cosmo theme font, as on the NFL site.
`theme_custom()` is built on `theme_bw`, not `theme_minimal` (see the NFL
CLAUDE.md for why). Standings are laid out with a flexbox div rather than
`gtExtras::gt_two_column_layout()`, whose floats overflow the page column.

## External links

`header.html` sets `target="_blank"` on every link whose href is an absolute
`http(s)://` URL, on page load. Keep the site's own links relative (`Teams.html`,
not a full URL) or they will open in a new tab too. Don't switch the rule to a
host comparison: NHL Scores is on the same host (`steodose.github.io`).

## CI

`.github/workflows/refresh-site.yml` renders and commits daily at 11:00 UTC.
Packages install with `dependencies: '"hard"'`, so lazily loaded packages must
be listed explicitly (currently svglite, crosstalk, progressr, xgboost,
chromote). After adding code, diff `loadedNamespaces()` after a render against
the hard-dependency closure of the list.

If a workflow file is on GitHub but missing from the Actions tab (only
`pages-build-deployment` listed), GitHub didn't index it: the first push went
into a brand-new repo. Pushing any change to the workflow file re-registers it.

## Season rollover

`nhl_season` comes from `most_recent_nhl_season()`, so the data loads roll over
by themselves. The one manual step is the preseason odds: add a new
`data/<year>_preseason_odds.csv` (Hockey Reference: `Team`, `Stanley Cup Odds`,
`Pts. O/U`, full team names matching `nhl_teams$team_name`) and point the
`read_csv()` in Teams.Rmd's `expectations` chunk and the default path in
`read_preseason()` (R/sim_model.R) at it. The odds history file is per
season automatically; run `R/backfill_odds.R` again only if you want a
backfill. That chunk
`stopifnot()`s on 32 teams, so a name mismatch fails the render instead of
dropping a team. Also clear `data/attendance.csv`: its cache is per season.
If a team relocates or rebrands, update `data/nhl_teams.csv`.

`CLAUDE.html` is regenerated by every full render and is gitignored. Don't
commit it.
