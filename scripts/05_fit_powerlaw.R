## ---------------------------------------------------------------------------
## Puerto Rico gaps — fit a power law to one site's gap size distribution.
##
## Prototype, meant to be run line by line in RStudio (open pr-gaps.Rproj so the
## working directory is the repo root). Reads gaps_covariates.csv that
## scripts/04_gap_covariates.R writes:
##   $PR_GAPS_DATA/runs/canopy/<site>/gaps/<run>/threshold_<t>m/gaps_covariates.csv
## and fits a power law above an estimated lower bound (Clauset et al. 2009,
## via poweRlaw), then plots the complementary CDF with the fitted line.
##
## WHY a discrete power law for footprint area: canopy.py's 1 m voxels make
## footprint_area_m2 a whole number of m^2, and half the LFDP gaps are under
## ~10 m^2, where the continuous approximation is poor. gap_volume_m3 is not
## integer, so it gets the continuous form.
##
## Not done here (see docs/plan.md §2.7): edge-censored gaps, a block bootstrap,
## the rest of the candidate set. The bootstrap below resamples gaps
## independently, so its interval is too narrow for clustered gaps.
## ---------------------------------------------------------------------------

## install.packages("poweRlaw")   # once
library(poweRlaw)

options(pr_gaps.code_root = getwd())
source(file.path("R", "ingest", "00_config.R"))   # gl_data_root()

## --- Settings ---------------------------------------------------------------
SITE      <- "lfdp"
RUN       <- NULL                  # NULL = newest run for the site
THRESHOLD <- "2.0"                 # "2.0" or "5.0" (m)
SIZE_COL  <- "footprint_area_m2"   # or "gap_volume_m3"
N_BOOT    <- 500                   # 0 skips the bootstrap

## --- Read gaps --------------------------------------------------------------
gaps_dir <- file.path(gl_data_root(), "runs", "canopy", SITE, "gaps")
if (is.null(RUN)) {
  runs <- list.dirs(gaps_dir, recursive = FALSE)
  RUN  <- basename(runs[which.max(file.mtime(runs))])
}
csv <- file.path(gaps_dir, RUN, paste0("threshold_", THRESHOLD, "m"),
                 "gaps_covariates.csv")
gaps <- read.csv(csv)
x <- gaps[[SIZE_COL]]
x <- x[is.finite(x) & x > 0]
cat(length(x), "gaps from", csv, "\n")
summary(x)

## --- Fit --------------------------------------------------------------------
discrete <- all(abs(x - round(x)) < 1e-6)
m <- if (discrete) displ$new(round(x)) else conpl$new(x)

est <- estimate_xmin(m)            # xmin minimizing the KS distance
m$setXmin(est)
xmin   <- m$getXmin()
alpha  <- m$getPars()
n_tail <- sum(x >= xmin)
cat(sprintf("%s power law: xmin = %g, alpha = %.3f, n above xmin = %d of %d\n",
            if (discrete) "discrete" else "continuous",
            xmin, alpha, n_tail, length(x)))

## --- Uncertainty (gaps resampled independently, xmin re-estimated) ----------
if (N_BOOT > 0) {
  bs <- bootstrap(m, no_of_sims = N_BOOT, threads = 4, seed = 1)
  alpha_ci <- quantile(bs$bootstraps$pars, c(0.025, 0.975))
  xmin_ci  <- quantile(bs$bootstraps$xmin, c(0.025, 0.975))
  cat(sprintf("alpha 95%% CI: %.3f-%.3f; xmin 95%% CI: %g-%g\n",
              alpha_ci[1], alpha_ci[2], xmin_ci[1], xmin_ci[2]))
}

## --- Plot: complementary CDF, P(X >= x), with the fitted power law ----------
size_lab <- if (SIZE_COL == "footprint_area_m2") {
  expression("Gap footprint area" ~ (m^2))
} else {
  expression("Gap volume" ~ (m^3))
}
plot(m, pch = 16, cex = 0.6, col = "grey40",
     xlab = size_lab, ylab = expression(P(X >= x)),
     main = sprintf("%s, %s m threshold (run %s)", toupper(SITE), THRESHOLD,
                    substr(RUN, 1, 8)))
lines(m, col = "firebrick", lwd = 2)
abline(v = xmin, lty = 2, col = "grey60")
legend("bottomleft", bty = "n",
       legend = c(sprintf("alpha = %.2f", alpha),
                  sprintf("xmin = %g (n = %d of %d)", xmin, n_tail, length(x))),
       text.col = c("firebrick", "grey30"))

## --- Plot: KS distance against candidate xmin -------------------------------
## A flat or multi-dip curve means the lower bound is poorly determined.
## estimate_xmin() keeps only the winner, so refit at each candidate that
## leaves at least 50 gaps in the tail.
cand <- sort(unique(m$getDat()))
cand <- cand[vapply(cand, function(k) sum(x >= k), numeric(1)) >= 50]
ks   <- vapply(cand, function(k) estimate_xmin(m, xmins = k)$gof, numeric(1))
plot(cand, ks, type = "l", log = "x",
     xlab = "Candidate xmin", ylab = "KS distance",
     main = "Lower-bound selection")
abline(v = xmin, lty = 2, col = "firebrick")
