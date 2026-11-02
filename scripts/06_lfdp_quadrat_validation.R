## ---------------------------------------------------------------------------
## LFDP validation — gap area and volume against census damage, per quadrat.
##
## Gap side: python/quadrat_gaps.py, which sums every run of a sweep
## (python/sweep.py) into the LFDP 20 m and 40 m quadrats:
##   <sweep>/quadrats/q20_gaps.csv, q40_gaps.csv
##     gap_area_pct     share of the quadrat whose 1 m column holds a gap voxel
##     gap_volume_pct   gap voxels / 2017 vegetation voxels (cf. basal-area loss)
##     gap_volume_m3_per_m2
##
## Damage side: the LFDP post-Maria census (LFDP_complete.csv), with the
## definitions of c2c-validation-v2.R (stems DBH >= 20 with a status):
##   stem_loss   broken or uprooted (BU = B, B/U, U), or dead / not found with
##               no break recorded (BU blank, ADNF = D or NF)
##   pct_loss    stems lost / stems, %
##   balr        basal area of lost stems / basal area, %
## One deliberate change: BU and ADNF are trimmed first. One stem is recorded as
## " B", which `%in% c("B", ...)` in v2 does not count as broken.
##
## 40 m quadrats are built from stems, not by averaging 20 m percentages: each
## 20 m quadrat joins the 40 m quadrat holding its centroid (the 96 40 m
## quadrats cover rows 1-24; row 25 has no 40 m quadrat).
##
## Usage:
##   Rscript scripts/06_lfdp_quadrat_validation.R                 # newest LFDP sweep
##   Rscript scripts/06_lfdp_quadrat_validation.R --sweep thr-1-1.5-2-3-4-5-8_conn-26-6 \
##       --scatter 2,3,5 --min-stems 5
##   --field  folder with LFDP_complete.csv and LFDP_Quadrat_40m/
##            (default ~/OneDrive/Documents/EEB/GLIHT/data)
##
## Writes <sweep>/validation/:
##   quadrat_comparison.csv   one row per layer x quadrat x connectivity x threshold
##   fit_stats.csv            n, R^2, slope, intercept, Pearson r, Spearman rho per
##                            layer x connectivity x threshold x gap x damage metric
##   fit_r2.png               R^2 against threshold
##   scatter_q20.png, scatter_q40.png   quadrats at the --scatter thresholds
## ---------------------------------------------------------------------------

## --- Find the code (see 02_download.R) -------------------------------------
file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
repo <- if (length(file_arg)) {
  dirname(dirname(normalizePath(sub("^--file=", "", file_arg[1]),
                                winslash = "/", mustWork = FALSE)))
} else {
  getwd()
}
options(pr_gaps.code_root = repo)
for (f in sort(list.files(file.path(repo, "R", "ingest"), pattern = "[.]R$",
                          full.names = TRUE))) {
  source(f)                   # gl_data_root, gl_msg
}
suppressPackageStartupMessages({
  library(sf); library(dplyr); library(tidyr); library(ggplot2)
})

args <- commandArgs(trailingOnly = TRUE)
get_arg <- function(flag, default = NULL) {
  i <- match(flag, args)
  if (is.na(i) || i == length(args)) default else args[i + 1]
}
site <- get_arg("--site", "lfdp")
field <- get_arg("--field", file.path(path.expand("~"), "OneDrive", "Documents",
                                      "EEB", "GLIHT", "data"))
## On Windows, R's ~ is Documents; fall back to the user profile.
if (!dir.exists(field)) {
  field <- file.path(Sys.getenv("USERPROFILE"), "OneDrive", "Documents", "EEB",
                     "GLIHT", "data")
}
scatter_at <- as.numeric(strsplit(get_arg("--scatter", "2,3,5"), ",")[[1]])
scatter_conn <- as.integer(get_arg("--scatter-connectivity", "26"))
min_stems <- as.integer(get_arg("--min-stems", "1"))

sweeps <- file.path(gl_data_root(), "runs", "canopy", site, "sweeps")
sweep <- get_arg("--sweep")
if (is.null(sweep)) {
  found <- list.files(sweeps, pattern = "^runs[.]json$", recursive = TRUE,
                      full.names = TRUE)
  if (!length(found)) stop("no sweeps in ", sweeps, "; run python/sweep.py first")
  sweep <- basename(dirname(found[which.max(file.mtime(found))]))
}
sweep_dir <- file.path(sweeps, sweep)
out <- file.path(sweep_dir, "validation")
dir.create(out, showWarnings = FALSE)
gl_msg(sprintf("sweep %s; field data %s", sweep, field))

## --- Census damage per 20 m quadrat ----------------------------------------
stems <- read.csv(file.path(field, "LFDP_complete.csv")) |>
  mutate(BU = trimws(BU), ADNF = trimws(ADNF)) |>
  filter(DBH >= 20 & ADNF != "") |>
  mutate(
    stem_loss = BU %in% c("B", "B/U", "U") | (BU == "" & ADNF %in% c("D", "NF")),
    basal_area = 0.00007854 * DBH^2
  )

damage <- function(d, ...) {
  d |>
    group_by(...) |>
    summarise(
      n_stems = n(),
      n_lost = sum(stem_loss),
      pct_loss = 100 * mean(stem_loss),
      balr = 100 * sum(basal_area[stem_loss]) / sum(basal_area),
      .groups = "drop"
    )
}

## --- 20 m -> 40 m quadrats -----------------------------------------------------
quad_dir <- file.path(field, "LFDP_Quadrat_40m")
q20 <- st_read(file.path(quad_dir, "LFDP_window_20.shp"), quiet = TRUE)
q40 <- st_read(file.path(quad_dir, "LFDP_window_40.shp"), quiet = TRUE)
q20_to_q40 <- suppressWarnings(st_centroid(q20[, "ID_1"])) |>
  st_join(q40[, "quadrat_nu"], join = st_within) |>
  st_drop_geometry() |>
  filter(!is.na(quadrat_nu)) |>
  transmute(Q20 = ID_1, quadrat_id = quadrat_nu)

damage_q <- bind_rows(
  damage(stems, Q20) |> transmute(layer = "q20", quadrat_id = Q20, n_stems, n_lost,
                                   pct_loss, balr),
  stems |> inner_join(q20_to_q40, by = "Q20") |> damage(quadrat_id) |>
    mutate(layer = "q40")
)
gl_msg(sprintf("%d stems; %d 20 m and %d 40 m quadrats with stems",
               nrow(stems), sum(damage_q$layer == "q20"), sum(damage_q$layer == "q40")))

## --- Join gap summaries ----------------------------------------------------
gaps_q <- bind_rows(lapply(c("q20", "q40"), function(layer) {
  read.csv(file.path(sweep_dir, "quadrats", paste0(layer, "_gaps.csv")))
}))
comparison <- gaps_q |>
  inner_join(damage_q, by = c("layer", "quadrat_id")) |>
  filter(n_stems >= min_stems)
write.csv(comparison, file.path(out, "quadrat_comparison.csv"), row.names = FALSE)

## --- Fits --------------------------------------------------------------------
gap_metrics <- c(gap_area_pct = "Gap area (% of quadrat)",
                 gap_volume_pct = "Gap volume (% of 2017 vegetation)",
                 gap_volume_m3_per_m2 = "Gap volume (m3 per m2)")
damage_metrics <- c(pct_loss = "Stem loss (%)", balr = "Basal area loss (%)")
layer_labels <- c(q20 = "20 m quadrats", q40 = "40 m quadrats")
## Narrow panels in the scatter plots: short names, defined in the subtitle.
gap_short <- c(gap_area_pct = "Area %", gap_volume_pct = "Volume %")

long <- comparison |>
  pivot_longer(names(gap_metrics), names_to = "gap_metric", values_to = "gap") |>
  pivot_longer(names(damage_metrics), names_to = "damage_metric", values_to = "damage")

fit_one <- function(d) {
  fit <- lm(damage ~ gap, d)
  ok <- sd(d$gap) > 0 && sd(d$damage) > 0
  tibble(
    n = nrow(d),
    r2 = if (ok) summary(fit)$r.squared else NA_real_,
    slope = unname(coef(fit)[2]),
    intercept = unname(coef(fit)[1]),
    pearson_r = if (ok) cor(d$gap, d$damage) else NA_real_,
    spearman_rho = if (ok) cor(d$gap, d$damage, method = "spearman") else NA_real_,
    mean_gap = mean(d$gap),
    mean_damage = mean(d$damage)
  )
}
stats <- long |>
  group_by(layer, connectivity, threshold_m, gap_metric, damage_metric) |>
  group_modify(~ fit_one(.x)) |>
  ungroup() |>
  arrange(layer, damage_metric, gap_metric, desc(connectivity), threshold_m)
write.csv(stats, file.path(out, "fit_stats.csv"), row.names = FALSE)

best <- stats |>
  filter(gap_metric != "gap_volume_m3_per_m2") |>
  group_by(layer, damage_metric, gap_metric) |>
  slice_max(r2, n = 1, with_ties = FALSE) |>
  ungroup()
gl_msg("best R^2 per layer x damage x gap metric:")
print(as.data.frame(best |> select(layer, damage_metric, gap_metric, connectivity,
                                   threshold_m, n, r2, spearman_rho, slope)),
      digits = 3, row.names = FALSE)

## --- Figures -----------------------------------------------------------------
## Reference palette, categorical slots 1-2; shape repeats connectivity so it is
## never colour alone. Light chart surface, text in ink tokens, recessive grid.
series <- c("26" = "#2a78d6", "6" = "#eb6834")
ink <- "#2a2a28"; ink_muted <- "#6b6a63"; surface <- "#fcfcfb"
theme_chart <- theme_minimal(base_size = 11) +
  theme(
    plot.background = element_rect(fill = surface, colour = NA),
    panel.background = element_rect(fill = surface, colour = NA),
    panel.grid.minor = element_blank(),
    panel.grid.major = element_line(colour = "#e4e3de", linewidth = 0.3),
    text = element_text(colour = ink),
    axis.text = element_text(colour = ink_muted),
    strip.text = element_text(colour = ink, face = "bold"),
    legend.position = "top"
  )

plot_stats <- stats |>
  filter(gap_metric != "gap_volume_m3_per_m2") |>
  mutate(gap_label = factor(gap_metrics[gap_metric], gap_metrics),
         damage_label = factor(damage_metrics[damage_metric], damage_metrics),
         layer_label = layer_labels[layer],
         connectivity = factor(connectivity, c(26, 6)))
p <- ggplot(plot_stats, aes(threshold_m, r2, colour = connectivity, shape = connectivity,
                            linetype = layer_label)) +
  geom_line(linewidth = 0.7) +
  geom_point(size = 2.4) +
  scale_colour_manual(values = series, name = "Connectivity") +
  scale_shape_manual(values = c("26" = 16, "6" = 17), name = "Connectivity") +
  scale_linetype_manual(values = c("solid", "22"), name = NULL) +
  scale_x_continuous(breaks = sort(unique(stats$threshold_m))) +
  coord_cartesian(ylim = c(0, NA)) +
  facet_grid(damage_label ~ gap_label) +
  labs(x = "C2C threshold (m)", y = expression(R^2),
       title = "LFDP: census damage explained by gap metrics, per quadrat") +
  theme_chart
ggsave(file.path(out, "fit_r2.png"), p, width = 9, height = 6.5, dpi = 150)

for (layer_name in c("q20", "q40")) {
  d <- long |>
    filter(layer == layer_name, connectivity == scatter_conn,
           threshold_m %in% scatter_at, gap_metric != "gap_volume_m3_per_m2") |>
    mutate(gap_label = factor(gap_short[gap_metric], gap_short),
           damage_label = factor(damage_metrics[damage_metric], damage_metrics),
           threshold_label = factor(paste(threshold_m, "m"),
                                    paste(sort(scatter_at), "m")))
  if (!nrow(d)) next
  labels <- stats |>
    filter(layer == layer_name, connectivity == scatter_conn,
           threshold_m %in% scatter_at, gap_metric != "gap_volume_m3_per_m2") |>
    mutate(gap_label = factor(gap_short[gap_metric], gap_short),
           damage_label = factor(damage_metrics[damage_metric], damage_metrics),
           threshold_label = factor(paste(threshold_m, "m"),
                                    paste(sort(scatter_at), "m")),
           text = sprintf("R² %.2f\nρ %.2f", r2, spearman_rho))
  p <- ggplot(d, aes(gap, damage)) +
    geom_abline(slope = 1, intercept = 0, linetype = "22", colour = ink_muted,
                linewidth = 0.4) +
    geom_point(colour = series[as.character(scatter_conn)], alpha = 0.55, size = 1.8,
               stroke = 0) +
    geom_smooth(method = "lm", formula = y ~ x, se = FALSE, colour = ink,
                linewidth = 0.7) +
    geom_label(data = labels, aes(x = 0, y = 100, label = text), hjust = 0, vjust = 1,
               size = 3, colour = ink, lineheight = 0.95, fill = surface,
               linewidth = 0, label.padding = unit(0.15, "lines")) +
    coord_cartesian(xlim = c(0, 100), ylim = c(0, 100)) +
    facet_grid(damage_label ~ threshold_label + gap_label) +
    labs(x = "Gap metric (%)", y = "Census damage (%)",
         title = sprintf("LFDP %s, %d-connectivity: quadrat damage against gap metrics",
                         layer_labels[layer_name], scatter_conn),
         subtitle = paste("Area: gap columns, % of quadrat. Volume: gap voxels, % of 2017",
                         "vegetation voxels. Dashed: 1:1. Solid: least-squares fit.")) +
    theme_chart
  ggsave(file.path(out, sprintf("scatter_%s.png", layer_name)), p,
         width = 13, height = 6, dpi = 150)
}
gl_msg(sprintf("wrote %s", out))
