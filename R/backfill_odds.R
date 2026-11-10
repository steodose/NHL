#### One-time backfill of data/playoff_odds_history_<season>.csv ####
## Run locally from the project root: Rscript R/backfill_odds.R
## Reruns the model as of every past game date this season, using only the
## games and shots up to that date, so the odds-over-time charts start on
## opening night. Not part of CI: each daily render adds its own row.

source("R/helpers.R")
source("R/load_pbp.R")
source("R/sim_model.R")

pbp_full <- load_regular_pbp(keep_shootouts = TRUE)
sched <- load_nhl_schedule(nhl_season) %>% filter(game_type == "R")
preseason <- read_preseason()
divisions <- nhl_standings() %>%
  transmute(team = team_abbr, division = division_name, conference = conference_name)

dates <- sched %>%
  filter(game_state %in% c("OFF", "FINAL")) %>%
  distinct(d = as.Date(game_date)) %>%
  arrange(d) %>%
  pull(d)

for (i in seq_along(dates)) {
  pred <- predict_as_of(dates[i], sched, pbp_full, preseason, divisions,
                        n_sims = 2000, seed = 2027)
  update_odds_history(pred)
  message(dates[i], " done (", i, "/", length(dates), ")")
}
