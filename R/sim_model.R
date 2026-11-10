#### Season simulation model for Predictions.Rmd (and R/backfill_odds.R) ####
## source()d after R/helpers.R and R/load_pbp.R.
##
## nflseedR is NFL-only, so this is a small Monte Carlo of our own:
##   1. Rate every team in goals per game above average: a preseason prior
##      (points over/under) blended with this season's expected-goal and
##      actual goal differential.
##   2. Play out every remaining regular-season game n_sims times
##      (Poisson goals, overtime/shootout for ties, loser point).
##   3. Seed the playoffs (top 3 per division + 2 wild cards per conference),
##      play the bracket in best-of-7 series, and run the draft lottery.

sim_const <- list(
  prior_games    = 40,    # in-season weight = GP / (GP + prior_games)
  xg_weight      = 0.7,   # in-season rating = 70% xGD/GP + 30% GD/GP
  pts_per_goal   = 0.33,  # ~6 goals of differential = 1 win = 2 points
  talent_sd      = 0.20,  # rating uncertainty (goals/game) before any games
  hia_prior      = 0.15,  # home-ice advantage, goals per game
  hia_prior_n    = 600,   # games of weight on hia_prior
  ot_rate_prior  = 0.23,  # share of games that reach overtime
  ot_prior_n     = 300,   # games of weight on ot_rate_prior
  ot_tilt        = 0.15,  # OT/SO win prob = 0.5 + ot_tilt * rating edge
  # Draft lottery odds for the 16 non-playoff teams, worst first (2022 format:
  # two draws, a team may move up at most 10 spots).
  lottery_odds   = c(18.5, 13.5, 11.5, 9.5, 8.5, 7.5, 6.5, 6.0,
                     5.0, 3.5, 3.0, 2.5, 2.0, 1.5, 0.5, 0.5) / 100
)

# Final regular-season games with how they ended. The schedule has scores
# (including the shootout winner's goal) but no OT/SO flag; that comes from
# the pbp period types. pbp needs shootout rows kept (keep_shootouts = TRUE).
game_results <- function(sched, pbp_full) {
  ends <- pbp_full %>%
    group_by(game_id) %>%
    summarise(end = case_when(any(period_type == "SHOOTOUT") ~ "SO",
                              any(period_type == "OVERTIME") ~ "OT",
                              TRUE ~ "REG"), .groups = "drop")
  sched %>%
    filter(game_type == "R", game_state %in% c("OFF", "FINAL")) %>%
    transmute(game_id, game_date = as.Date(game_date),
              home = home_team_abbr, away = away_team_abbr,
              hs = home_score, as = away_score) %>%
    left_join(ends, by = "game_id") %>%
    # A game whose pbp hasn't landed yet: a 2+ goal margin is certainly
    # regulation; a 1-goal one is assumed to be (the usual case).
    mutate(end = coalesce(end, "REG"))
}

# Standings (points, wins, regulation wins, GP) from game results.
standings_from_results <- function(results, teams) {
  long <- bind_rows(
    results %>% transmute(team = home, gf = hs, ga = as, end),
    results %>% transmute(team = away, gf = as, ga = hs, end)
  ) %>%
    mutate(win = gf > ga,
           pts = 2 * win + (!win & end != "REG"),
           rw = win & end == "REG")
  tibble(team = teams) %>%
    left_join(long %>% group_by(team) %>%
                summarise(gp = n(), pts = sum(pts), w = sum(win), rw = sum(rw),
                          gf = sum(gf), ga = sum(ga)),
              by = "team") %>%
    mutate(across(-team, ~ coalesce(.x, 0L)))
}

# Team ratings in goals per game above average, with uncertainty.
# preseason: team_abbr, pts_ou. shots: build_shots() rows for the games in
# `results` only (so a backfill as of a past date uses no later information).
team_ratings <- function(results, shots, preseason, teams, games_per_team,
                         k = sim_const) {
  std <- standings_from_results(results, teams)
  xg <- full_join(
    shots %>% group_by(team = shoot_team) %>% summarise(xgf = sum(xg)),
    shots %>% group_by(team = def_team) %>% summarise(xga = sum(xg)),
    by = "team")

  std %>%
    left_join(xg, by = "team") %>%
    left_join(select(preseason, team = team_abbr, pts_ou), by = "team") %>%
    mutate(
      across(c(xgf, xga), ~ coalesce(.x, 0)),
      prior = (pts_ou - mean(pts_ou)) / k$pts_per_goal / games_per_team,
      in_season = if_else(gp > 0,
                          (k$xg_weight * (xgf - xga) + (1 - k$xg_weight) * (gf - ga)) / gp,
                          0),
      wt = gp / (gp + k$prior_games),
      rating = wt * in_season + (1 - wt) * prior,
      rating = rating - mean(rating),
      sd = k$talent_sd * sqrt(k$prior_games / (gp + k$prior_games))
    ) %>%
    select(team, gp, prior, in_season, wt, rating, sd)
}

# League scoring environment from results: goals per team per game (shootout
# winner's goal removed), home-ice advantage and OT rate, each shrunk toward a
# long-run prior while the sample is small.
league_env <- function(results, k = sim_const) {
  n <- nrow(results)
  so <- sum(results$end == "SO")
  list(
    base = if (n > 0) (sum(results$hs + results$as) - so) / (2 * n) else 3.05,
    hia = (sum(results$hs - results$as) + k$hia_prior * k$hia_prior_n) /
      (n + k$hia_prior_n),
    ot_rate = (sum(results$end != "REG") + k$ot_rate_prior * k$ot_prior_n) /
      (n + k$ot_prior_n)
  )
}

# P(home team wins) for vectors of Poisson goal means, OT included.
p_home_win <- function(lh, la, p_ot) {
  win <- 0; tie <- 0
  for (g in 0:20) {
    pa <- dpois(g, la)
    win <- win + pa * ppois(g, lh, lower.tail = FALSE)
    tie <- tie + pa * dpois(g, lh)
  }
  win + tie * p_ot
}

ot_home_prob <- function(edge, k = sim_const) pmin(pmax(0.5 + k$ot_tilt * edge, 0.3), 0.7)

# The simulation. standings: from standings_from_results(). remaining: the
# unplayed regular-season games (home, away). ratings: from team_ratings().
# divisions: team, division, conference.
simulate_season <- function(standings, remaining, ratings, divisions, env,
                            n_sims = 10000, seed = 2027, k = sim_const) {
  set.seed(seed)
  N <- n_sims
  tm <- standings$team
  nt <- length(tm)
  rt <- ratings[match(tm, ratings$team), ]
  dv <- divisions[match(tm, divisions$team), ]
  stopifnot(!anyNA(rt$rating), !anyNA(dv$division))

  # Each simulation draws its own team strengths around the ratings.
  R <- matrix(rnorm(N * nt, rep(rt$rating, each = N), rep(rt$sd, each = N)), N, nt)

  pts <- matrix(standings$pts, N, nt, byrow = TRUE)
  w   <- matrix(standings$w,   N, nt, byrow = TRUE)
  rw  <- matrix(standings$rw,  N, nt, byrow = TRUE)

  h <- match(remaining$home, tm)
  a <- match(remaining$away, tm)
  G <- length(h)
  game_home_wp <- numeric(G)

  if (G > 0) {
    # Independent Poisson goals produce too few ties (about 17% vs the NHL's
    # ~23%: late empty-net goals and score effects pull margins apart). Turn
    # a share q of one-goal games into ties so the OT rate matches.
    d0 <- rt$rating[h] - rt$rating[a]
    lh0 <- pmax(env$base + d0 / 2 + env$hia / 2, 0.5)
    la0 <- pmax(env$base - d0 / 2 - env$hia / 2, 0.5)
    p0 <- p1 <- 0
    for (g in 0:20) {
      p0 <- p0 + mean(dpois(g, lh0) * dpois(g, la0))
      p1 <- p1 + mean(dpois(g, lh0) * dpois(g + 1, la0) + dpois(g + 1, lh0) * dpois(g, la0))
    }
    q <- min(max((env$ot_rate - p0) / p1, 0), 1)

    for (j in seq_len(G)) {
      d <- R[, h[j]] - R[, a[j]]
      gh <- rpois(N, pmax(env$base + d / 2 + env$hia / 2, 0.5))
      ga <- rpois(N, pmax(env$base - d / 2 - env$hia / 2, 0.5))
      df <- gh - ga
      tie <- df == 0 | (abs(df) == 1 & runif(N) < q)
      hw <- ifelse(tie, runif(N) < ot_home_prob(d + env$hia, k), df > 0)
      # aw as its own variable: in R, `2 * !hw + x` parses as `2 * !(hw + x)`.
      aw <- !hw
      pts[, h[j]] <- pts[, h[j]] + 2 * hw + (tie & aw)
      pts[, a[j]] <- pts[, a[j]] + 2 * aw + (tie & hw)
      w[, h[j]] <- w[, h[j]] + hw
      w[, a[j]] <- w[, a[j]] + aw
      rw[, h[j]] <- rw[, h[j]] + (hw & !tie)
      rw[, a[j]] <- rw[, a[j]] + (aw & !tie)
      game_home_wp[j] <- mean(hw)
    }
  }

  # Ranking key: points, then regulation wins, then wins, then a coin flip.
  key <- pts * 1e6 + rw * 1e3 + w + matrix(runif(N * nt), N, nt)
  rank_rows <- function(m) t(apply(-m, 1, rank, ties.method = "first"))

  div_rank <- matrix(NA_integer_, N, nt)
  for (d in unique(dv$division)) {
    idx <- which(dv$division == d)
    div_rank[, idx] <- rank_rows(key[, idx])
  }
  top3 <- div_rank <= 3

  made <- top3
  champ <- matrix(0L, N, nt)  # 1 = reached Cup Final, 2 = won Cup
  conf_champ <- list()
  rows <- seq_len(N)
  col_of <- function(mask, idx) idx[max.col(mask, ties.method = "first")]
  rating_of <- function(t) R[cbind(rows, t)]
  key_of <- function(t) key[cbind(rows, t)]

  # Best-of-7, home ice to the higher regular-season finisher (2-2-1-1-1).
  # Playing all seven games and taking whoever wins four gives the same winner
  # as stopping early, so it can be drawn as two binomials.
  series <- function(t1, t2) {
    hi <- ifelse(key_of(t1) >= key_of(t2), t1, t2)
    lo <- ifelse(hi == t1, t2, t1)
    edge <- rating_of(hi) - rating_of(lo)
    p_home <- p_home_win(env$base + edge / 2 + env$hia / 2,
                         env$base - edge / 2 - env$hia / 2,
                         ot_home_prob(edge + env$hia, k))
    p_away <- 1 - p_home_win(env$base - edge / 2 + env$hia / 2,
                             env$base + edge / 2 - env$hia / 2,
                             ot_home_prob(-edge + env$hia, k))
    hi_wins <- rbinom(N, 4, p_home) + rbinom(N, 3, p_away) >= 4
    ifelse(hi_wins, hi, lo)
  }

  for (cf in unique(dv$conference)) {
    cidx <- which(dv$conference == cf)
    ckey <- key[, cidx]
    ckey[top3[, cidx]] <- -Inf
    wc_rank <- rank_rows(ckey)
    wc1 <- col_of(wc_rank == 1, cidx)
    wc2 <- col_of(wc_rank == 2, cidx)
    made[cbind(rows, wc1)] <- TRUE
    made[cbind(rows, wc2)] <- TRUE

    divs <- unique(dv$division[cidx])
    seeds <- lapply(divs, function(d) {
      idx <- which(dv$division == d)
      lapply(1:3, function(s) col_of(div_rank[, idx] == s, idx))
    })
    # The better division winner plays the second wild card.
    first_better <- key_of(seeds[[1]][[1]]) > key_of(seeds[[2]][[1]])
    opp1 <- ifelse(first_better, wc2, wc1)
    opp2 <- ifelse(first_better, wc1, wc2)

    side1 <- series(series(seeds[[1]][[1]], opp1), series(seeds[[1]][[2]], seeds[[1]][[3]]))
    side2 <- series(series(seeds[[2]][[1]], opp2), series(seeds[[2]][[2]], seeds[[2]][[3]]))
    conf_champ[[cf]] <- series(side1, side2)
  }
  cup <- series(conf_champ[[1]], conf_champ[[2]])

  # Draft lottery among the 16 non-playoff teams, worst record first.
  odds <- k$lottery_odds
  first_pick <- top3_pick <- integer(nt)
  for (i in rows) {
    out <- which(!made[i, ])
    out <- out[order(key[i, out])]
    slot <- rep(NA_integer_, length(out))
    w1 <- sample.int(length(out), 1, prob = odds)
    slot[w1] <- if (w1 <= 11) 1L else w1 - 10L
    rest <- setdiff(seq_along(out), w1)
    w2 <- rest[sample.int(length(rest), 1, prob = odds[rest])]
    s2 <- if (w2 <= 12) 2L else w2 - 10L
    while (s2 %in% slot) s2 <- s2 + 1L
    slot[w2] <- s2
    free <- setdiff(seq_along(out), slot)
    slot[is.na(slot)] <- free
    first_pick[out[slot == 1]] <- first_pick[out[slot == 1]] + 1L
    t3 <- out[slot <= 3]
    top3_pick[t3] <- top3_pick[t3] + 1L
  }

  pres <- max.col(key, ties.method = "first")
  reached_final <- c(conf_champ[[1]], conf_champ[[2]])

  team_odds <- tibble(
    team = tm,
    proj_pts = colMeans(pts),
    pts_lo = apply(pts, 2, quantile, 0.1),
    pts_hi = apply(pts, 2, quantile, 0.9),
    make_playoffs = colMeans(made),
    win_div = colMeans(div_rank == 1),
    presidents = tabulate(pres, nt) / N,
    win_conf = tabulate(reached_final, nt) / N,
    win_cup = tabulate(cup, nt) / N,
    first_pick = first_pick / N,
    top3_pick = top3_pick / N
  )

  list(team_odds = team_odds,
       games = remaining %>%
         mutate(home_wp = game_home_wp,
                home_xg = pmax(env$base + (rt$rating[h] - rt$rating[a]) / 2 + env$hia / 2, 0.5),
                away_xg = pmax(env$base - (rt$rating[h] - rt$rating[a]) / 2 - env$hia / 2, 0.5)),
       env = env)
}

# Sum checks: every simulated season crowns exactly these many teams.
check_sim_sums <- function(odds) {
  s <- function(x) round(sum(x), 6)
  stopifnot(
    s(odds$make_playoffs) == 16, s(odds$win_div) == 4, s(odds$win_conf) == 2,
    s(odds$presidents) == 1, s(odds$win_cup) == 1, s(odds$first_pick) == 1,
    s(odds$top3_pick) == 3
  )
  invisible(TRUE)
}

# Everything the model needs, as of the end of `as_of` (a date): results and
# shots up to that date only, every later game treated as unplayed. Used for
# the live page (as_of = latest final game) and for R/backfill_odds.R.
predict_as_of <- function(as_of, sched, pbp_full, preseason, divisions,
                          n_sims = 10000, seed = 2027) {
  sched <- filter(sched, game_type == "R")
  games_per_team <- 2 * nrow(sched) / n_distinct(sched$home_team_abbr)

  results <- game_results(sched, pbp_full) %>% filter(game_date <= as_of)
  remaining <- sched %>%
    filter(!game_id %in% results$game_id) %>%
    transmute(game_id, game_date = as.Date(game_date),
              home = home_team_abbr, away = away_team_abbr)
  shots <- pbp_full %>%
    filter(game_id %in% results$game_id, period_type != "SHOOTOUT") %>%
    build_shots()

  standings <- standings_from_results(results, divisions$team)
  ratings <- team_ratings(results, shots, preseason, divisions$team, games_per_team)
  sim <- simulate_season(standings, remaining, ratings, divisions,
                         league_env(results), n_sims = n_sims, seed = seed)
  check_sim_sums(sim$team_odds)

  sim$team_odds <- sim$team_odds %>%
    left_join(select(standings, team, gp, pts), by = "team")
  c(sim, list(ratings = ratings, standings = standings, as_of = as_of,
              games_per_team = games_per_team))
}

# Preseason points O/U keyed by NHL abbreviation. The CSV is per season (see
# CLAUDE.md, season rollover); Teams.Rmd's expectations chunk reads it too.
read_preseason <- function(path = "data/2026_preseason_odds.csv") {
  pre <- readr::read_csv(path, show_col_types = FALSE) %>%
    rename(team_name = Team, cup_odds = `Stanley Cup Odds`, pts_ou = `Pts. O/U`) %>%
    inner_join(select(nhl_teams, team_name, team_abbr), by = "team_name")
  stopifnot(nrow(pre) == 32)  # a name mismatch would silently drop a team
  pre
}

# Playoff odds history: one row per team per date, same-date rows replaced.
odds_history_path <- function(season = nhl_season) {
  glue("data/playoff_odds_history_{season}.csv")
}

update_odds_history <- function(pred, path = odds_history_path()) {
  new <- pred$team_odds %>%
    transmute(date = pred$as_of, team, make_playoffs, win_div, win_cup,
              proj_pts = round(proj_pts, 1)) %>%
    mutate(across(c(make_playoffs, win_div, win_cup), ~ round(.x, 4)))
  old <- if (file.exists(path)) {
    readr::read_csv(path, show_col_types = FALSE, col_types = "Dcdddd")
  } else NULL
  hist <- bind_rows(filter(old %||% new[0, ], date != pred$as_of), new) %>%
    arrange(date, team)
  readr::write_csv(hist, path)
  hist
}
