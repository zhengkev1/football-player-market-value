# 02_analysis.R
# ------------------------------------------------------------------------------
# Regression analysis: does a player's 2021 performance (and whether his club
# finished first in 2021) relate to how his market value changed from 2021 to
# 2022?
#
# Input : data/processed/players_champion_perf_wide.csv  (from 01_prepare_data.R)
# Output: results/*.csv, results/model_summaries.txt, figures/*.png
#
# Run from the repository root:   Rscript R/02_analysis.R [path/to/wide.csv]
# Requires: tidyverse (readr, dplyr, ggplot2), leaps
# ------------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(tidyr)
  library(ggplot2)
  library(leaps)
})

args <- commandArgs(trailingOnly = TRUE)
in_file <- if (length(args) >= 1) args[1] else "data/processed/players_champion_perf_wide.csv"

dir.create("results", showWarnings = FALSE)
dir.create("figures", showWarnings = FALSE)

df_raw <- read_csv(in_file, show_col_types = FALSE)

# --- Response variables --------------------------------------------------------
# pct_change_mp : simple percent change (value_2022 - value_2021) / value_2021.
#                 This is the response used in the submitted analysis.
# log_change_mp : log(value_2022) - log(value_2021). The first definition the
#                 team wrote before replacing it with the simple percent change;
#                 kept here as a robustness check.
# Both need a positive value in both years.
# champion_2021 : 1 if the player's club has rank 1 in the 2021 table.
df_change <- df_raw %>%
  mutate(
    pct_change_mp = if_else(value_2021 > 0 & value_2022 > 0,
                            (value_2022 - value_2021) / value_2021, NA_real_),
    log_change_mp = if_else(value_2021 > 0 & value_2022 > 0,
                            log(value_2022) - log(value_2021), NA_real_),
    champion_2021 = if_else(rank_2021 == 1, 1L, 0L)
  ) %>%
  filter(is.finite(pct_change_mp)) %>%
  mutate(
    champion_2021 = factor(champion_2021),
    main_position = factor(main_position),
    foot          = factor(foot),
    is_eu         = factor(is_eu)
  )

sink("results/model_summaries.txt")   # everything printed below is saved
cat("Players with a positive value in 2021 and 2022:", nrow(df_change), "\n\n")
cat("Distribution of pct_change_mp:\n")
print(summary(df_change$pct_change_mp))
cat("\nNumber of players whose value rose by more than 1,000%:",
    sum(df_change$pct_change_mp > 10), "\n")
cat("Largest percent changes:", paste(tail(sort(df_change$pct_change_mp), 5),
                                      collapse = ", "), "\n\n")

# --- 1. Best-subsets screening of the 2021 performance variables --------------
df_screen <- df_change %>%
  select(
    pct_change_mp,
    goals_2021, assists_2021, nb_in_group_2021, nb_on_pitch_2021,
    own_goals_2021, subed_in_2021, subed_out_2021, yellow_cards_2021,
    second_yellow_cards_2021, direct_red_cards_2021, penalty_goals_2021,
    minutes_played_2021, clean_sheets_2021,
    foot, is_eu
  ) %>%
  na.omit()

cat("=== Best subsets (exhaustive), response = pct_change_mp; n =",
    nrow(df_screen), "===\n")
best.mods <- regsubsets(pct_change_mp ~ ., data = df_screen,
                        nvmax = ncol(df_screen) - 1, method = "exhaustive")
best.sum <- summary(best.mods)
print(best.sum)
subset_table <- tibble(
  n_predictors = seq_along(best.sum$adjr2),
  adj_r2       = best.sum$adjr2,
  bic          = best.sum$bic,
  cp           = best.sum$cp
)
cat("\nBest adjusted R^2 by model size:\n")
print(as.data.frame(subset_table))
write_csv(subset_table, "results/best_subsets_criteria.csv")

png("figures/best_subsets_adjr2.png", width = 1400, height = 900, res = 130)
par(mar = c(9, 5, 3, 1))
plot(best.mods, scale = "adjr2", main = "Best subsets (response: percent change in market value)",
     cex.axis = 0.7, las = 2)
dev.off()

# --- 2. Models ----------------------------------------------------------------
df_model <- df_change %>%
  select(pct_change_mp, log_change_mp, goals_2021, subed_out_2021,
         penalty_goals_2021, champion_2021) %>%
  drop_na(pct_change_mp, goals_2021, subed_out_2021, penalty_goals_2021, champion_2021)

cat("\n\n=== Models on n =", nrow(df_model), "players ===\n")

mod_reduced <- lm(pct_change_mp ~ goals_2021 + subed_out_2021 + penalty_goals_2021,
                  data = df_model)
mod_full    <- lm(pct_change_mp ~ goals_2021 + subed_out_2021 + penalty_goals_2021 +
                    champion_2021, data = df_model)

cat("\n--- Reduced model ---\n");  print(summary(mod_reduced))
cat("\n--- Full model (adds champion_2021) ---\n"); print(summary(mod_full))
cat("\n--- F-test: does champion_2021 add anything? ---\n")
print(anova(mod_reduced, mod_full))

# --- 3. Robustness checks (added when preparing this repository) --------------
# (a) the team's earlier log-change response, (b) dropping the 5 largest
# percent changes. Same predictors as the full model.
df_log <- df_model %>% filter(is.finite(log_change_mp))
mod_log_full <- lm(log_change_mp ~ goals_2021 + subed_out_2021 + penalty_goals_2021 +
                     champion_2021, data = df_log)
cutoff <- sort(df_model$pct_change_mp, decreasing = TRUE)[5]
df_trim <- df_model %>% filter(pct_change_mp < cutoff)
mod_trim_full <- lm(pct_change_mp ~ goals_2021 + subed_out_2021 + penalty_goals_2021 +
                      champion_2021, data = df_trim)

cat("\n\n=== Robustness: log-change response (n =", nrow(df_log), ") ===\n")
print(summary(mod_log_full))
cat("\n=== Robustness: percent change, 5 largest values dropped (n =",
    nrow(df_trim), ") ===\n")
print(summary(mod_trim_full))
sink()

# Coefficient table for the README
tidy_lm <- function(m, label) {
  s <- summary(m)
  cf <- as.data.frame(coef(s))
  tibble(model = label, term = rownames(cf),
         estimate = cf[[1]], std_error = cf[[2]], t_value = cf[[3]], p_value = cf[[4]],
         n = nobs(m), r_squared = s$r.squared, adj_r_squared = s$adj.r.squared)
}
coef_table <- bind_rows(
  tidy_lm(mod_reduced,   "pct change: reduced"),
  tidy_lm(mod_full,      "pct change: + champion_2021"),
  tidy_lm(mod_log_full,  "log change: + champion_2021"),
  tidy_lm(mod_trim_full, "pct change, top 5 dropped: + champion_2021")
)
write_csv(coef_table, "results/model_coefficients.csv")

# --- 4. Diagnostics and descriptive plots -------------------------------------
df_model$resid  <- resid(mod_reduced)
df_model$fitted <- fitted(mod_reduced)
df_model$order  <- seq_len(nrow(df_model))

p1 <- ggplot(df_model, aes(fitted, resid)) +
  geom_point(alpha = .6) +
  geom_hline(yintercept = 0, color = "red", linetype = "dashed") +
  labs(title = "Residuals vs fitted (reduced model)",
       x = "Fitted percent change", y = "Residuals") + theme_bw()
ggsave("figures/residuals_vs_fitted.png", p1, width = 6, height = 4, dpi = 150)

p2 <- ggplot(df_model, aes(sample = resid)) +
  stat_qq(alpha = .7) + stat_qq_line(color = "red") +
  labs(title = "Normal Q-Q plot (reduced model)") + theme_bw()
ggsave("figures/qq_plot.png", p2, width = 6, height = 4, dpi = 150)

p3 <- ggplot(df_change, aes(x = goals_2021, y = pct_change_mp)) +
  geom_point(alpha = 0.5) +
  geom_smooth(method = "lm", se = FALSE, color = "red", linewidth = 1) +
  labs(title = "Goals in 2021 vs percent change in market value (2021 to 2022)",
       x = "Goals (2021 season)", y = "Percent change in market value") + theme_bw()
ggsave("figures/goals_vs_value_change.png", p3, width = 6.5, height = 4, dpi = 150)

p4 <- ggplot(df_change, aes(x = subed_out_2021, y = pct_change_mp)) +
  geom_point(alpha = 0.5) +
  geom_smooth(method = "lm", se = FALSE, color = "blue", linewidth = 1) +
  labs(title = "Times substituted out in 2021 vs percent change in market value",
       x = "Times subbed out (2021)", y = "Percent change in market value") + theme_bw()
ggsave("figures/subbed_out_vs_value_change.png", p4, width = 6.5, height = 4, dpi = 150)

message("Done. See results/ and figures/.")
