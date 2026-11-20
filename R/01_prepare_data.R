# 01_prepare_data.R
# ------------------------------------------------------------------------------
# Build the analysis table: one row per player, with market values for
# 2021-2023, 2021-2023 performance totals, and the league-table rank of the
# player's club in each of those seasons.
#
# Inputs (CSV files from the Transfermarkt-based football dataset; not included
# in this repository, see README -> "Data"). Put them in data/raw/:
#   player_market_value.csv          player_id, date_unix, value
#   player_profiles.csv              one row per player (height, citizenship, ...)
#   team_competitions_seasons.csv    one row per club, competition and season
#   player_performances.csv          one row per player, season and competition
#
# Output:
#   data/processed/players_champion_perf_wide.csv   (4,801 rows when run on the
#   files the project used)
#
# Run from the repository root:
#   Rscript R/01_prepare_data.R                # reads data/raw, writes data/processed
#   Rscript R/01_prepare_data.R RAW_DIR OUT_DIR
# ------------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(tidyr)
  library(stringr)
  library(lubridate)
})

args    <- commandArgs(trailingOnly = TRUE)
raw_dir <- if (length(args) >= 1) args[1] else "data/raw"
out_dir <- if (length(args) >= 2) args[2] else "data/processed"
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# --- 1. Market values: keep 2021-2023, one value per player and year ----------
df <- read_csv(file.path(raw_dir, "player_market_value.csv"),
               show_col_types = FALSE) %>%
  mutate(
    date_unix = ymd(date_unix),
    year      = year(date_unix)
  )

df_2123 <- df %>% filter(year >= 2021 & year <= 2023)

# Keep players with a market-value record in at least 2 of the 3 years
valid_players <- df_2123 %>%
  group_by(player_id) %>%
  summarise(n_years = n_distinct(year), .groups = "drop") %>%
  filter(n_years >= 2) %>%
  pull(player_id)

# For each player-year keep the latest valuation of that calendar year
mv_clean <- df_2123 %>%
  filter(player_id %in% valid_players) %>%
  arrange(player_id, year, date_unix) %>%
  group_by(player_id, year) %>%
  slice_tail(n = 1) %>%
  ungroup()

# --- 2. Player attributes, one column per year of market value ----------------
profile <- read_csv(file.path(raw_dir, "player_profiles.csv"),
                    show_col_types = FALSE)

merged <- mv_clean %>%
  left_join(profile, by = "player_id") %>%
  relocate(current_club_name, .before = 1)

wide <- merged %>%
  select(player_id, current_club_name, year, value,
         height, citizenship, is_eu, main_position, foot) %>%
  pivot_wider(
    names_from   = year,
    values_from  = value,
    names_prefix = "value_"
  )

# --- 3. League-table rank of the club in 2021, 2022 and 2023 ------------------
# Ranks come from team_competitions_seasons.csv and are attached by club NAME.
# Every competition in that file counts (any division, youth and reserve
# leagues, play-offs); see README -> "Limitations".
team <- read_csv(file.path(raw_dir, "team_competitions_seasons.csv"),
                 show_col_types = FALSE)

team_ranks_wide <- team %>%
  filter(season_id %in% 2021:2023) %>%
  select(team_name, season_id, season_rank) %>%
  distinct(team_name, season_id, .keep_all = TRUE) %>%
  mutate(season_id = paste0("rank_", season_id)) %>%
  pivot_wider(names_from = season_id, values_from = season_rank)

players_with_ranks <- wide %>%
  left_join(team_ranks_wide, by = c("current_club_name" = "team_name"))

# Keep players whose club finished first in at least one of the three seasons
players_champion <- players_with_ranks %>%
  filter(if_any(starts_with("rank_"), ~ .x == 1))

# --- 4. Performance totals per player and season -------------------------------
perf <- read_csv(file.path(raw_dir, "player_performances.csv"),
                 show_col_types = FALSE)

# season_name looks like "21/22" or "2021"; year_start is the first calendar year
perf_yrs <- perf %>%
  mutate(
    year_start = case_when(
      str_detect(season_name, "^[0-9]{2}/[0-9]{2}$") ~
        2000 + as.numeric(str_sub(season_name, 1, 2)),
      str_detect(season_name, "^[0-9]{4}$") ~ as.numeric(season_name),
      TRUE ~ NA_real_
    )
  ) %>%
  filter(year_start %in% 2021:2023)

# Sum over all competitions the player appeared in that season
perf_summary <- perf_yrs %>%
  group_by(player_id, year_start) %>%
  summarise(
    across(
      c(nb_in_group, nb_on_pitch, goals, assists, own_goals, subed_in,
        subed_out, yellow_cards, second_yellow_cards, direct_red_cards,
        penalty_goals, minutes_played, goals_conceded, clean_sheets),
      ~ sum(.x, na.rm = TRUE)
    ),
    perf = goals + assists,
    .groups = "drop"
  )

players_champion_perf <- players_champion %>%
  left_join(perf_summary, by = "player_id") %>%
  relocate(year_start, goals, assists, perf, .after = player_id)

# --- 5. One row per player: statistics spread into <stat>_<year> columns ------
players_champion_perf_wide <- players_champion_perf %>%
  pivot_wider(
    id_cols = c(player_id, current_club_name, height, citizenship, is_eu,
                main_position, foot, starts_with("value_"), starts_with("rank_")),
    names_from  = year_start,
    values_from = c(goals, assists, nb_in_group, nb_on_pitch, own_goals,
                    subed_in, subed_out, yellow_cards, second_yellow_cards,
                    direct_red_cards, penalty_goals, minutes_played,
                    goals_conceded, clean_sheets),
    names_glue  = "{.value}_{year_start}"
  )

# goals_conceded is only meaningful for goalkeepers; *_NA columns come from
# players with no performance record in 2021-2023.
players_champion_perf_wide <- players_champion_perf_wide %>%
  select(-starts_with("goals_conceded_")) %>%
  select(-assists_NA) %>%
  select(-goals_NA)

out_file <- file.path(out_dir, "players_champion_perf_wide.csv")
write_csv(players_champion_perf_wide, out_file)
message("Wrote ", nrow(players_champion_perf_wide), " rows x ",
        ncol(players_champion_perf_wide), " columns to ", out_file)
