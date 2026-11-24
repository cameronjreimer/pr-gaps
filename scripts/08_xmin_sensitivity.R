## ---------------------------------------------------------------------------
## AGU draft, xmin sensitivity (docs/agu-analysis-plan.md, option 3 of
## 2026-11-24): does the ordering of the power-law alpha across forest types
## and gradient bins hold whatever lower bound is chosen?
##
##   module load R/4.5.2
##   Rscript scripts/08_xmin_sensitivity.R     # from the repo root
##
## Reads  analysis/gaps_3m.csv and fits/xmin.txt (07's KS estimate)
## Writes analysis/fits/xmin_sensitivity/:
##   alpha_stratum.csv/.png    alpha per stratum at each xmin
##   alpha_gradient.csv/.png   alpha per gradient quintile at each xmin
##
## Point estimates only: the 95% tile-bootstrap intervals are in 07's outputs
## for xmin = 5, 10 and the KS value. Gradient quintile breaks are taken from
## all gaps (not the tail at each xmin), so a bin is the same set of places at
## every xmin and only the lower bound changes.
## ---------------------------------------------------------------------------

suppressPackageStartupMessages({ library(data.table); library(ggplot2); library(expint) })
source(file.path("R", "fits", "size_models.R"))

RUN       <- Sys.getenv("PR_GAPS_ISLAND_RUN", "df81889aa38eecef")
DATA      <- Sys.getenv("PR_GAPS_DATA", "/ibstorage/cam/G-LiHT/data")
GRADIENTS <- c(elev_m = "Elevation (m)", ppt_mm = "Mean annual rainfall (mm)",
               slope_deg = "Slope (degrees)", chm_mean_m = "Pre-storm canopy height (m)")
STRATA    <- c("dry", "moist", "wet", "montane")

dir_in  <- file.path(DATA, "runs", "canopy", "island", RUN, "analysis")
dir_out <- file.path(dir_in, "fits", "xmin_sensitivity")
dir.create(dir_out, showWarnings = FALSE, recursive = TRUE)
ks_xmin <- as.numeric(readLines(file.path(dir_in, "fits", "xmin.txt")))
XMINS   <- sort(unique(c(5, 10, 25, 50, 100, ks_xmin)))

g <- fread(file.path(dir_in, "gaps_3m.csv"))
g[, size := round(footprint_area_m2)]

alpha_of <- function(sizes, xmin) {
  t <- make_tail(sizes, xmin, TRUE)
  if (t$n < 50) return(c(alpha = NA_real_, n_tail = t$n))
  c(alpha = fit_model(models$power_law, t)$par[["alpha"]], n_tail = t$n)
}

strat <- rbindlist(lapply(XMINS, function(xm) rbindlist(lapply(c("all", STRATA), function(s) {
  d <- if (s == "all") g else g[stratum == s]
  data.table(xmin = xm, stratum = s, t(alpha_of(d$size, xm)))
}))))
fwrite(strat, file.path(dir_out, "alpha_stratum.csv"))
print(dcast(strat, stratum ~ xmin, value.var = "alpha"), digits = 3)

grad <- rbindlist(lapply(names(GRADIENTS), function(v) {
  d <- g[is.finite(get(v))]
  d[, bin := cut(get(v), unique(quantile(d[[v]], seq(0, 1, 0.2))), include.lowest = TRUE)]
  med <- d[, .(median = median(get(v))), by = bin]
  rbindlist(lapply(XMINS, function(xm) d[, as.list(alpha_of(size, xm)), by = bin][
    , `:=`(gradient = v, xmin = xm)]))[med, on = "bin"]
}))
fwrite(grad, file.path(dir_out, "alpha_gradient.csv"))

lab <- function(x) ifelse(x == ks_xmin, sprintf("%g (KS)", x), sprintf("%g", x))
strat[, stratum := factor(stratum, levels = c("all", STRATA))]
p <- ggplot(strat, aes(xmin, alpha, colour = stratum)) + geom_line() + geom_point() +
  scale_x_log10(breaks = XMINS, labels = lab) +
  scale_colour_manual(values = c(all = "grey20", dry = "#eda100", moist = "#1baf7a",
                                 wet = "#2a78d6", montane = "#8a5cc2")) +
  labs(x = expression(x[min] ~ (m^2)), y = expression("Power-law exponent" ~ alpha),
       colour = NULL, title = "Gap size exponent by forest type and lower bound",
       subtitle = "3 m gaps in C-CAP forest; point estimates") + theme_bw(12)
ggsave(file.path(dir_out, "alpha_stratum.png"), p, width = 7, height = 4.5, dpi = 200)

grad[, gradient := factor(gradient, levels = names(GRADIENTS), labels = GRADIENTS)]
grad[, xmin_f := factor(lab(xmin), levels = lab(XMINS))]
p <- ggplot(grad, aes(median, alpha, colour = xmin_f)) + geom_line() + geom_point(size = 1.5) +
  facet_wrap(~gradient, scales = "free_x") + scale_colour_viridis_d(end = 0.9) +
  labs(x = "Bin median (quintiles of all gaps)", y = expression(alpha),
       colour = expression(x[min] ~ (m^2)),
       title = "Gap size exponent along gradients, by lower bound") + theme_bw(12)
ggsave(file.path(dir_out, "alpha_gradient.png"), p, width = 8.5, height = 6, dpi = 200)
cat("done:", dir_out, "\n")
