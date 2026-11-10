#### Regular-season play-by-play, shared by Teams.Rmd and Predictions.Rmd ####
## source()d after R/helpers.R.

# load_regular_pbp() returns this season's regular-season pbp with shootouts
# dropped. render_site() renders every page in one R session, so the result is
# cached in tempdir() and the second page doesn't download it again.
#
# load_nhl_pbp() does not error when the GitHub release download fails (e.g. a
# 504): it warns and returns an empty table, which later surfaces as a
# confusing "object 'game_id' not found". Retry, then fail loudly.
load_regular_pbp <- function(season = nhl_season, keep_shootouts = FALSE) {
  cache <- file.path(tempdir(), glue("nhl_pbp_{season}.rds"))
  if (file.exists(cache)) {
    pbp_raw <- readRDS(cache)
  } else {
    pbp_raw <- NULL
    for (attempt in 1:3) {
      pbp_raw <- suppressWarnings(load_nhl_pbp(season))
      if (nrow(pbp_raw) > 0) break
      Sys.sleep(30)
    }
    if (nrow(pbp_raw) == 0) {
      stop("load_nhl_pbp(", season, ") returned no rows after 3 attempts ",
           "(sportsdataverse-data release download failed).")
    }
    # Regular season only (game_id digits 5-6 = "02").
    pbp_raw <- filter(pbp_raw, substr(as.character(game_id), 5, 6) == "02")
    saveRDS(pbp_raw, cache)
  }
  # Shootout attempts are not shots in any stat sense; they are kept only for
  # working out how a game ended.
  if (keep_shootouts) pbp_raw else filter(pbp_raw, period_type != "SHOOTOUT")
}

# Shot attempts (Corsi). On BLOCKED_SHOT rows the NHL feed credits
# event_team_abbr to the BLOCKING team (event_player_1 is the shooter,
# event_player_2 the blocker), so flip it to the shooting team.
build_shots <- function(pbp) {
  pbp %>%
    filter(event_type %in% c("GOAL", "SHOT", "MISSED_SHOT", "BLOCKED_SHOT")) %>%
    mutate(
      other_team = if_else(event_team_abbr == home_abbr, away_abbr, home_abbr),
      shoot_team = if_else(event_type == "BLOCKED_SHOT", other_team, event_team_abbr),
      def_team   = if_else(event_type == "BLOCKED_SHOT", event_team_abbr, other_team),
      is_goal = event_type == "GOAL",
      is_sog  = event_type %in% c("GOAL", "SHOT"),
      xg = coalesce(xg, 0),
      is_5v5 = strength_state == "5v5" & !coalesce(empty_net, FALSE)
    )
}
