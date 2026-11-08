#### Shared helpers for the NHL Analytics site ####
## source()d at the top of every page.

suppressPackageStartupMessages({
  library(fastRhockey)
  library(tidyverse)
  library(glue)
})

options(scipen = 9999)

# fastRhockey labels seasons by their END year (2026-27 = 2027).
nhl_season <- fastRhockey::most_recent_nhl_season()
season_label <- glue("{nhl_season - 1}-{substr(nhl_season, 3, 4)}")

caption_btp <- "Data: fastRhockey | Plot: @steodosescu"

# One row per team. team_abbr is the NHL abbreviation (pbp, standings);
# espn_abbr differs for LAK/NJD/SJS/TBL/UTA and is what the ESPN scoreboard
# (attendance) uses. team_logo is ESPN's 500px PNG, which ggimage can draw;
# the NHL's own logos are SVG.
nhl_teams <- readr::read_csv("data/nhl_teams.csv", show_col_types = FALSE)

# Custom ggplot theme (inspired by Owen Phillips at the F5 substack blog).
# Built on theme_bw and stripped back to look like theme_minimal: under
# ggplot2 4.0 a theme_minimal base silently drops custom axis-text elements
# (see the NFL repo's CLAUDE.md). Keep it on theme_bw.
theme_custom <- function() {
  theme_bw(base_size = 11, base_family = "Outfit") %+replace%
    theme(
      panel.grid.minor = element_blank(),
      panel.background = element_blank(),
      panel.border = element_blank(),
      axis.ticks = element_blank(),
      legend.background = element_blank(),
      legend.key = element_blank(),
      strip.background = element_blank(),
      plot.background = element_rect(fill = "floralwhite", color = "floralwhite"),
      plot.title.position = "plot",
      plot.title = element_text(face = "bold", size = 20, hjust = 0.5,
                                margin = ggplot2::margin(b = 4)),
      plot.subtitle = ggtext::element_markdown(color = "grey40", size = 10,
                                               hjust = 0.5,
                                               margin = ggplot2::margin(b = 10)),
      plot.caption = element_text(color = "grey40", size = 8, hjust = 1)
    )
}

# Golden ratio, the aspect ratio for logo scatter plots.
asp_ratio <- 1.618

# Reactable theme (538 style), in Outfit.
theme_538 <- function() {
  reactable::reactableTheme(
    searchInputStyle = list(width = "31%", backgroundColor = "#F9F9F9"),
    style = list(fontFamily = "Outfit"),
    headerStyle = list(
      "&:hover[aria-sort]" = list(background = "hsl(0, 0%, 80%)"),
      "&[aria-sort='ascending'], &[aria-sort='descending']" = list(
        background = "#555", color = "#FFF"
      ),
      borderColor = "#333"
    ),
    borderColor = "#CDCDCD"
  )
}

my_color_pal <- c("#ffffff", "#f2fbd2", "#c9ecb4", "#93d3ab", "#35b0ab")
