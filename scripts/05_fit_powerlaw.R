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
SITE      <- "ev1"
RUN       <- NULL                  # NULL = newest run for the site
THRESHOLD <- "2.0"                 # "2.0" or "5.0" (m)
SIZE_COL  <- "footprint_area_m2"   # or "gap_volume_m3"
N_BOOT    <- 500                   # 0 skips the bootstrap and the alpha band
N_SIM     <- 1000                  # 0 skips the simulation envelope

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

## --- Band 1: confidence band for the fitted line (uncertainty in alpha) -----
## HOW TO READ IT: the range of power-law lines consistent with these data. If
## you resampled the gaps and refit, the line would fall inside the band about
## 95% of the time. It shows how precisely alpha is estimated; it says nothing
## about whether a power law is the right model — it assumes it is.
## The band is narrow near xmin and fans out to the right: on log-log axes the
## line is log P = -(alpha - 1) * log(x / xmin), so a given spread in alpha
## matters more the further x is from xmin.
## WHY xmin is held fixed: replicates with another xmin start their line at a
## different point, which mixes two uncertainties into one picture. This band
## is alpha's uncertainty given xmin; the bootstrap above gives xmin's.
## WHY two lines suffice: P(X >= x) falls monotonically with alpha at every
## x > xmin, so the pointwise 2.5% / 97.5% curves are the lines at alpha's
## 2.5% / 97.5% quantiles.
## Too narrow for clustered gaps: gaps are resampled independently.
if (N_BOOT > 0) {
  set.seed(1)
  tail_x <- m$getDat()[m$getDat() >= xmin]
  alpha_fix <- replicate(N_BOOT, {
    mb <- if (discrete) displ$new(sample(tail_x, replace = TRUE))
          else conpl$new(sample(tail_x, replace = TRUE))
    mb$setXmin(xmin)
    estimate_pars(mb)$pars
  })
  alpha_band <- quantile(alpha_fix, c(0.025, 0.975))
  cat(sprintf("alpha 95%% CI at fixed xmin = %g: %.3f-%.3f\n",
              xmin, alpha_band[1], alpha_band[2]))
  band_line <- function(a) { mb <- m$copy(); mb$setPars(a); lines(mb, draw = FALSE) }
  band_lo <- band_line(alpha_band[2])   # steeper line = lower curve
  band_hi <- band_line(alpha_band[1])
}

## --- Band 2: simulation envelope for the data points (goodness of fit) ------
## HOW TO READ IT: where the observed points would plausibly fall if gap sizes
## really came from the fitted power law (xmin and alpha as estimated, same
## number of gaps above xmin). Points inside it are consistent with the model;
## a stretch of points outside it is a deviation larger than chance — e.g.
## the bump above the line at ~1,000-5,000 m^2 on the LFDP 2 m run.
## Expect it tight in the body and very wide in the tail: with alpha < 2 the
## largest few gaps in a sample vary enormously between samples, so a single
## huge gap can sit comfortably inside the envelope.
## Where the lower edge stops, more than 2.5% of simulated samples had no gap
## that large at all (P = 0 cannot be drawn on a log axis).
## CAVEATS: the envelope is pointwise and neighbouring points are strongly
## correlated (one extra large gap lifts every point above it), so a run of
## points just outside is closer to one piece of evidence than many, and with
## many x values a few points outside are expected by chance. It is too narrow
## for clustered gaps, and it does not test the alternatives — a lognormal or
## truncated power law may sit inside it just as well.
if (N_SIM > 0) {
  set.seed(2)
  frac_tail <- n_tail / length(x)      # plot scale: P over all gaps, not the tail
  grid <- exp(seq(log(xmin), log(max(x)), length.out = 200))
  if (discrete) grid <- unique(round(grid))
  sim_ccdf <- replicate(N_SIM, {
    s <- sort(dist_rand(m, n_tail))
    frac_tail * (n_tail - findInterval(grid, s, left.open = TRUE)) / n_tail
  })
  env <- apply(sim_ccdf, 1, quantile, c(0.025, 0.975))
  env[env == 0] <- NA
}

## --- Plot: complementary CDF, P(X >= x), with the fitted power law ----------
## Grey points: the data. Red line: the fit. Red band: band 1. Dashed blue
## lines: band 2. Vertical dashed line: xmin.
size_lab <- if (SIZE_COL == "footprint_area_m2") {
  expression("Gap footprint area" ~ (m^2))
} else {
  expression("Gap volume" ~ (m^3))
}
pd <- plot(m, draw = FALSE)
plot(pd$x, pd$y, log = "xy", type = "n",
     xlab = size_lab, ylab = expression(P(X >= x)),
     main = sprintf("%s, %s m threshold (run %s)", toupper(SITE), THRESHOLD,
                    substr(RUN, 1, 8)))
if (N_BOOT > 0) {
  polygon(c(band_hi$x, rev(band_lo$x)), c(band_hi$y, rev(band_lo$y)),
          col = adjustcolor("firebrick", 0.25), border = NA)
}
if (N_SIM > 0) {
  lines(grid, env[1, ], lty = 2, col = "steelblue")
  lines(grid, env[2, ], lty = 2, col = "steelblue")
}
points(pd$x, pd$y, pch = 16, cex = 0.6, col = "grey40")
lines(m, col = "firebrick", lwd = 2)
abline(v = xmin, lty = 2, col = "grey60")
legend("bottomleft", bty = "n",
       legend = c(sprintf("alpha = %.2f", alpha),
                  sprintf("xmin = %g (n = %d of %d)", xmin, n_tail, length(x)),
                  if (N_BOOT > 0) "95% band for the line (alpha)",
                  if (N_SIM > 0) "95% envelope for the data"),
       text.col = c("firebrick", "grey30",
                    if (N_BOOT > 0) "grey30", if (N_SIM > 0) "grey30"),
       fill = c(NA, NA, if (N_BOOT > 0) adjustcolor("firebrick", 0.25),
                if (N_SIM > 0) NA),
       border = NA,
       lty = c(NA, NA, if (N_BOOT > 0) NA, if (N_SIM > 0) 2),
       col = c(NA, NA, if (N_BOOT > 0) NA, if (N_SIM > 0) "steelblue"))

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
