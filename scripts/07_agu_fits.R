## ---------------------------------------------------------------------------
## AGU draft, steps 2-4 (docs/agu-analysis-plan.md): gap size distributions of
## the island's 3 m gap objects in C-CAP forest.
##
##   module load R/4.5.2
##   Rscript scripts/07_agu_fits.R            # from the repo root
##
## Reads  runs/canopy/island/<run>/analysis/gaps_3m.csv  (python/agu_table.py table)
## Writes runs/canopy/island/<run>/analysis/fits/:
##   xmin.txt                 the island-wide lower bound (KS, poweRlaw)
##   compare_<scenario>.csv   step 2: six models, same gaps >= xmin (06's code)
##   ccdf_<scenario>.png      step 2: CCDF with every fitted model
##   alpha_stratum.csv/.png   step 3: power-law alpha per stratum
##   alpha_gradient.csv/.png  step 4: alpha per quintile of each gradient
## Scenarios: all gaps; without the >= 25 ha objects (ADR 009 Outcome); without
## gaps touching a coverage edge (sensitivity: their sizes are truncated).
##
## WHY xmin is fixed island-wide in steps 3-4: alpha depends on xmin, so groups
## fitted above different lower bounds are not comparable. Each group's own
## xmin is reported as a check.
## WHY the bootstrap resamples 1 km tiles: gaps cluster, so resampling single
## gaps gives intervals that are too narrow (plan §2.7). Tiles are those of the
## gap's volume centroid; N_BOOT replicates, percentile intervals.
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(data.table); library(ggplot2); library(poweRlaw); library(expint)
})
source(file.path("R", "fits", "size_models.R"))   # make_tail, models, fit_model, fit_all, compare_table

RUN       <- Sys.getenv("PR_GAPS_ISLAND_RUN", "df81889aa38eecef")
DATA      <- Sys.getenv("PR_GAPS_DATA", "/ibstorage/cam/G-LiHT/data")
SIZE_COL  <- "footprint_area_m2"
N_BOOT    <- as.integer(Sys.getenv("AGU_N_BOOT", "200"))
GRADIENTS <- c(elev_m = "Elevation (m)", ppt_mm = "Mean annual rainfall (mm)",
               slope_deg = "Slope (degrees)", chm_mean_m = "Pre-storm canopy height (m)")
STRATA    <- c("dry", "moist", "wet", "montane")
set.seed(20170920)

dir_in  <- file.path(DATA, "runs", "canopy", "island", RUN, "analysis")
dir_out <- file.path(dir_in, "fits")
dir.create(dir_out, showWarnings = FALSE, recursive = TRUE)
say <- function(...) cat(format(Sys.time(), "[%H:%M:%S] "), sprintf(...), "\n", sep = "")

g <- fread(file.path(dir_in, "gaps_3m.csv"))
g[, size := round(get(SIZE_COL))]
say("%d gaps (C-CAP forest >= 0.5), %d >= 25 ha", nrow(g), sum(g$is_largest))

## --- xmin, island-wide ------------------------------------------------------
estimate_xmin_grid <- function(x) {
  m <- displ$new(x)
  cand <- unique(round(exp(seq(log(min(x)), log(quantile(x, 0.99)), length.out = 40))))
  suppressMessages(estimate_xmin(m, xmins = cand))$xmin
}
XMIN <- estimate_xmin_grid(g$size)
writeLines(as.character(XMIN), file.path(dir_out, "xmin.txt"))
say("island xmin = %g m2; %d gaps above it", XMIN, sum(g$size >= XMIN))

## --- Step 2: model comparison -----------------------------------------------
model_cols <- c(power_law = "#2a78d6", cutoff = "#eb6834", lognormal = "#1baf7a",
                weibull = "#eda100", exponential = "#e87ba4", piecewise = "#008300")
compare_scenario <- function(x, name, title) {
  t <- make_tail(x, XMIN, TRUE)
  fits <- fit_all(t)
  tab <- compare_table(fits, t)
  tab$n_tail <- t$n
  tab$params <- vapply(tab$model, function(nm) {
    p <- fits[[nm]]$par; paste(sprintf("%s=%.4g", names(p), p), collapse = "; ") }, "")
  fwrite(tab, file.path(dir_out, sprintf("compare_%s.csv", name)))
  say("step 2 [%s]: %d gaps >= xmin; best = %s", name, t$n, tab$model[1])
  print(tab[, c("model", "dAIC", "weight", "ll_per_gap", "test", "p")], row.names = FALSE)

  ccdf <- data.table(x = t$x, p = rev(cumsum(rev(t$w))) / t$n)
  xs <- unique(round(exp(seq(log(XMIN), log(max(t$x)), length.out = 300))))
  curves <- rbindlist(lapply(names(fits), function(nm) {
    f <- fits[[nm]]
    data.table(model = nm, x = xs, p = exp(f$mod$logS(xs - 0.5, f$par) - f$mod$logS(t$lo, f$par)))
  }))
  curves[, model := factor(model, levels = tab$model,
                           labels = sprintf("%s (dAIC %.0f)", tab$model, tab$dAIC))]
  cols <- setNames(model_cols[tab$model], levels(curves$model))
  p <- ggplot() +
    geom_point(data = ccdf, aes(x, p), colour = "grey45", size = 0.6) +
    geom_line(data = curves, aes(x, p, colour = model), linewidth = 0.8) +
    scale_x_log10() + scale_y_log10() + scale_colour_manual(values = cols, name = NULL) +
    labs(x = expression("Gap area" ~ (m^2)), y = expression(P(X >= x ~ "|" ~ X >= x[min])),
         title = title, subtitle = sprintf("%s gaps >= xmin = %g m2", format(t$n, big.mark = ","), XMIN)) +
    theme_bw(12) + theme(legend.position = c(0.02, 0.02), legend.justification = c(0, 0))
  ggsave(file.path(dir_out, sprintf("ccdf_%s.png", name)), p, width = 7, height = 5.5, dpi = 200)
  tab
}
invisible(compare_scenario(g$size, "all", "All 3 m gaps in C-CAP forest"))
invisible(compare_scenario(g[is_largest == FALSE]$size, "no_largest", "Without gaps >= 25 ha"))
invisible(compare_scenario(g[touches_coverage_edge == FALSE]$size, "no_edge", "Without gaps touching a coverage edge"))

## --- Power-law alpha with a tile bootstrap ----------------------------------
alpha_of <- function(sizes) {
  t <- make_tail(sizes, XMIN, TRUE)
  if (t$n < 50) return(NA_real_)
  fit_model(models$power_law, t)$par[["alpha"]]
}
alpha_boot <- function(d) {
  ## d: data.table(size, tile) of one group's gaps >= XMIN
  by_tile <- split(d$size, d$tile)
  tiles <- names(by_tile)
  reps <- vapply(seq_len(N_BOOT), function(i) {
    alpha_of(unlist(by_tile[sample(tiles, length(tiles), replace = TRUE)], use.names = FALSE))
  }, numeric(1))
  c(alpha = alpha_of(d$size), lo = unname(quantile(reps, 0.025, na.rm = TRUE)),
    hi = unname(quantile(reps, 0.975, na.rm = TRUE)), n_tail = nrow(d), n_tiles = length(tiles))
}
tail_g <- g[size >= XMIN]

## --- Step 3: alpha by stratum -----------------------------------------------
strat <- rbindlist(lapply(c("all", STRATA), function(s) {
  d <- if (s == "all") tail_g else tail_g[stratum == s]
  own <- tryCatch(estimate_xmin_grid(g[if (s == "all") TRUE else stratum == s]$size), error = function(e) NA)
  r <- alpha_boot(d)
  say("step 3: %-8s alpha = %.3f [%.3f, %.3f], n = %d, own xmin = %s", s, r[["alpha"]], r[["lo"]],
      r[["hi"]], r[["n_tail"]], own)
  data.table(stratum = s, t(r), own_xmin = own)
}))
fwrite(strat, file.path(dir_out, "alpha_stratum.csv"))
strat[, stratum := factor(stratum, levels = rev(c("all", STRATA)))]
p <- ggplot(strat, aes(alpha, stratum)) +
  geom_vline(xintercept = strat[stratum == "all"]$alpha, linetype = 3, colour = "grey50") +
  geom_errorbar(aes(xmin = lo, xmax = hi), width = 0.2, orientation = "y") + geom_point(size = 2.5) +
  geom_text(aes(label = format(n_tail, big.mark = ",")), vjust = -1, size = 3, colour = "grey40") +
  labs(x = expression("Power-law exponent" ~ alpha ~ "(95% tile bootstrap)"), y = NULL,
       title = "Gap size exponent by forest type", subtitle = sprintf("3 m gaps >= %g m2", XMIN)) +
  theme_bw(12)
ggsave(file.path(dir_out, "alpha_stratum.png"), p, width = 6.5, height = 4, dpi = 200)

## --- Step 4: alpha along gradients ------------------------------------------
grad <- rbindlist(lapply(names(GRADIENTS), function(v) {
  d <- tail_g[is.finite(get(v))]
  breaks <- unique(quantile(d[[v]], seq(0, 1, 0.2)))
  d[, bin := cut(get(v), breaks, include.lowest = TRUE)]
  rbindlist(lapply(levels(d$bin), function(b) {
    db <- d[bin == b]
    r <- alpha_boot(db)
    data.table(gradient = v, bin = b, median = median(db[[v]]), t(r))
  }))
}))
fwrite(grad, file.path(dir_out, "alpha_gradient.csv"))
say("step 4: %d gradient bins fitted", nrow(grad))
grad[, gradient := factor(gradient, levels = names(GRADIENTS), labels = GRADIENTS)]
p <- ggplot(grad, aes(median, alpha)) +
  geom_hline(yintercept = strat[stratum == "all"]$alpha, linetype = 3, colour = "grey50") +
  geom_errorbar(aes(ymin = lo, ymax = hi), width = 0) + geom_point(size = 2) + geom_line() +
  facet_wrap(~gradient, scales = "free_x") +
  labs(x = "Bin median", y = expression(alpha ~ "(95% tile bootstrap)"),
       title = "Gap size exponent along environmental gradients",
       subtitle = sprintf("Quintiles of 3 m gaps >= %g m2", XMIN)) +
  theme_bw(12)
ggsave(file.path(dir_out, "alpha_gradient.png"), p, width = 8, height = 6, dpi = 200)
say("done: %s", dir_out)
