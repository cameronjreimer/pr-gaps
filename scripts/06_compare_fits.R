## ---------------------------------------------------------------------------
## Puerto Rico gaps — compare candidate distributions for gap size.
##
## Prototype, meant to be run line by line in RStudio (open pr-gaps.Rproj so the
## working directory is the repo root). Reads the same gaps_covariates.csv as
## scripts/05_fit_powerlaw.R and fits six candidates by maximum likelihood to
## the SAME gaps (size >= xmin), each normalized over x >= xmin:
##
##   power_law     f ~ x^-alpha                    scale-free           (k = 1)
##   cutoff        f ~ x^-alpha * exp(-lambda x)   scale-free up to a   (k = 2)
##                                                 characteristic size
##   lognormal                                     multiplicative       (k = 2)
##   weibull       stretched exponential           between the two      (k = 2)
##   exponential   f ~ exp(-rate x)                one characteristic   (k = 1)
##                                                 size, thin tail
##   piecewise     two power laws joined at b      two size regimes     (k = 3)
##
## WHY not poweRlaw for the fits: it has no cutoff or piecewise model, and no
## discrete Weibull. Every model here is written as a log survival function
## log S(x) = log P(X >= x), which makes them interchangeable:
##   - integer sizes (footprint_area_m2, whole 1 m cells) are treated as
##     rounded continuous values, so a gap of u m^2 has probability
##     S(u - 0.5) - S(u + 0.5), normalized by S(xmin - 0.5);
##   - non-integer sizes (gap_volume_m3) use the density f(x) / S(xmin).
## Gaps are collapsed to unique sizes with counts first (EV1: 60k gaps, 768
## sizes), so a likelihood evaluation costs the same at any n.
## The power-law alpha therefore differs slightly from 05's zeta-based discrete
## fit; the two are printed together as a check.
##
## HOW TO READ THE TABLE
##   dAIC          AIC minus the best model's. < 2: as good as the best;
##                 2-10: weaker; > 10: essentially no support. With tens of
##                 thousands of gaps dAIC grows large for tiny differences, so
##                 read it next to ll_per_gap.
##   weight        Akaike weight: relative support, sums to 1.
##   ll_per_gap    mean log-likelihood gain per gap over the power law
##                 (> 0 = fits better than the power law). Does not grow with n,
##                 so it says how different the fits really are: ~0.001 is
##                 negligible, ~0.01 or more is a visible difference in the tail.
##   test / p      vs the power law. Non-nested models (lognormal, weibull,
##                 exponential): Vuong test — p < 0.05 means the two fits really
##                 differ and the sign of ll_per_gap says which is better;
##                 p >= 0.05 means the data cannot tell them apart, which is a
##                 legitimate result, not a weak win. cutoff contains the power
##                 law (lambda = 0), so it gets a likelihood-ratio test with the
##                 p halved for the boundary. piecewise has no valid p (the
##                 breakpoint does not exist under the power law); use AIC.
## All p-values assume independent gaps. Gaps cluster in space, so they are too
## small; a block bootstrap by watershed is the honest version (plan §2.7).
##
## The comparison is decided by the tail, which is a handful of gaps. The
## sensitivity block at the end repeats it at higher xmin and without the
## largest gaps: a ranking that changes there is not a result.
## ---------------------------------------------------------------------------

## install.packages(c("poweRlaw", "expint"))   # once
library(poweRlaw)   # xmin estimate only
library(expint)     # incomplete gamma with negative shape, for the cutoff model

options(pr_gaps.code_root = getwd())
source(file.path("R", "ingest", "00_config.R"))   # gl_data_root()

## --- Settings ---------------------------------------------------------------
SITE      <- "lfdp"
RUN       <- NULL                  # NULL = newest run for the site
THRESHOLD <- "2.0"                 # "2.0" or "5.0" (m)
SIZE_COL  <- "footprint_area_m2"   # or "gap_volume_m3"
XMIN      <- NULL                  # NULL = power law's KS estimate; or a number
DROP_TOP  <- 0                     # drop the n largest gaps before everything

## --- Read gaps --------------------------------------------------------------
gaps_dir <- file.path(gl_data_root(), "runs", "canopy", SITE, "gaps")
csv_in <- function(run) file.path(gaps_dir, run, paste0("threshold_", THRESHOLD, "m"),
                                  "gaps_covariates.csv")
if (is.null(RUN)) {                # newest run that has covariates for THRESHOLD
  runs <- list.dirs(gaps_dir, recursive = FALSE)
  runs <- runs[file.exists(csv_in(basename(runs)))]
  RUN  <- basename(runs[which.max(file.mtime(runs))])
}
csv <- csv_in(RUN)
x <- read.csv(csv)[[SIZE_COL]]
x <- sort(x[is.finite(x) & x > 0], decreasing = TRUE)
if (DROP_TOP > 0) x <- x[-seq_len(DROP_TOP)]
discrete <- all(abs(x - round(x)) < 1e-6)
if (discrete) x <- round(x)
cat(length(x), "gaps from", csv, "\n")

## --- xmin: the power law's KS estimate, over a log-spaced grid --------------
## A grid instead of every size: ~7x faster, and xmin is not known to within a
## few units anyway (05's bootstrap interval for LFDP 2 m was 5-14 m^2).
if (is.null(XMIN)) {
  m <- if (discrete) displ$new(x) else conpl$new(x)
  cand <- exp(seq(log(min(x)), log(quantile(x, 0.99)), length.out = 40))
  cand <- unique(if (discrete) round(cand) else signif(cand, 3))
  est  <- suppressMessages(estimate_xmin(m, xmins = cand))
  XMIN <- est$xmin
  cat(sprintf("xmin = %g (poweRlaw alpha at this xmin: %.3f)\n", XMIN, est$pars))
}

## --- Models, likelihood, fitting and the comparison table ------------------
source(file.path("R", "fits", "size_models.R"))

## --- Fit and compare --------------------------------------------------------
tl   <- make_tail(x, XMIN, discrete)
fits <- fit_all(tl)
tab  <- compare_table(fits, tl)
cat(sprintf("\n%d gaps >= xmin = %g (%d distinct sizes)\n\n", tl$n, XMIN, length(tl$x)))
print(within(tab, { logL <- round(logL, 1); dAIC <- round(dAIC, 1)
                    weight <- signif(weight, 2); ll_per_gap <- signif(ll_per_gap, 2)
                    p <- signif(p, 2) }), row.names = FALSE)

## Absurd-looking lognormal (meanlog << 0, large sdlog) or Weibull (shape near 0)
## parameters are not a convergence failure: those are the limits in which each
## model imitates a power law above xmin, so the data have no curvature for
## them to use.
cat("\nParameters:\n")
for (nm in names(fits)) {
  p <- fits[[nm]]$par
  cat(sprintf("  %-12s %s\n", nm, paste(sprintf("%s = %.4g", names(p), p), collapse = ", ")))
}
## Weibull vs exponential is also nested (shape = 1): an ordinary LR test.
cat(sprintf("\nweibull vs exponential (nested, shape = 1): LR p = %.2g\n",
            pchisq(2 * (fits$weibull$logL - fits$exponential$logL), 1, lower.tail = FALSE)))

## --- Plot: P(X >= x | X >= xmin), data and every fitted model ---------------
## HOW TO READ IT: the models differ almost only in the tail, so look at the
## right-hand third. A model whose line leaves the points there is failing
## where it matters. A straight line on these axes is a power law; a line that
## bends down is a cutoff, lognormal, Weibull or exponential tail.
model_cols <- c(power_law = "#2a78d6", cutoff = "#eb6834", lognormal = "#1baf7a",
                weibull = "#eda100", exponential = "#e87ba4", piecewise = "#008300")
model_lty  <- c(power_law = 1, cutoff = 2, lognormal = 4, weibull = 5,
                exponential = 3, piecewise = 6)

ccdf_data <- data.frame(x = tl$x, p = rev(cumsum(rev(tl$w))) / tl$n)
size_lab <- if (SIZE_COL == "footprint_area_m2") {
  expression("Gap footprint area" ~ (m^2))
} else {
  expression("Gap volume" ~ (m^3))
}
plot(ccdf_data$x, ccdf_data$p, log = "xy", pch = 16, cex = 0.6, col = "grey40",
     ylim = c(min(ccdf_data$p) / 5, 1),
     xlab = size_lab, ylab = expression(P(X >= x ~ "|" ~ X >= x[min])),
     main = sprintf("%s, %s m threshold, xmin = %g (run %s)", toupper(SITE),
                    THRESHOLD, XMIN, substr(RUN, 1, 8)))
xs <- exp(seq(log(XMIN), log(max(tl$x)), length.out = 300))
if (discrete) xs <- unique(round(xs))
for (nm in names(fits)) {
  f  <- fits[[nm]]
  at <- if (discrete) xs - 0.5 else xs
  lines(xs, exp(f$mod$logS(at, f$par) - f$mod$logS(tl$lo, f$par)),
        col = model_cols[[nm]], lty = model_lty[[nm]], lwd = 2)
}
ord <- tab$model
legend("bottomleft", bty = "n", lwd = 2, col = model_cols[ord], lty = model_lty[ord],
       legend = sprintf("%-12s dAIC = %.1f", ord, tab$dAIC), text.col = "grey20")

## --- Plot: piecewise breakpoint profile -------------------------------------
## HOW TO READ IT: log-likelihood of the two-segment fit at each breakpoint.
## A sharp peak means a well-defined break; a flat or ragged curve means the
## data do not locate one. Compare the peak to the detection function before
## reading it as ecology (plan Q2): a break near the detection floor is an
## artifact.
if (!is.null(fits$piecewise)) {
  pr <- fits$piecewise$profile
  plot(pr$b, pr$logL - max(pr$logL), type = "l", log = "x",
       xlab = "Breakpoint b", ylab = "logL relative to best",
       main = sprintf("Piecewise breakpoint profile (best b = %.3g)",
                      fits$piecewise$par[["b"]]))
  abline(h = -1.92, lty = 3, col = "grey60")   # rough 95% profile interval
  if (which.max(pr$logL) %in% c(1, nrow(pr))) {
    message("Best breakpoint is at the edge of the search range: the break is ",
            "being placed by the smallest or the ~20 largest gaps, not located ",
            "by the data.")
  }
}

## --- Sensitivity: does the ranking survive a higher xmin or losing the
##     largest gaps? -----------------------------------------------------------
## HOW TO READ IT: dAIC per model under each scenario. If the same model is best
## (dAIC = 0) in every row, the ranking is robust. If it changes when xmin
## doubles or the top 5 gaps go, the comparison is being decided by a few
## gaps or by the lower bound, and should be reported as inconclusive.
scenarios <- expand.grid(xmin_mult = c(1, 2, 4), drop = c(0, 5))
sens <- do.call(rbind, lapply(seq_len(nrow(scenarios)), function(i) {
  s  <- scenarios[i, ]
  xs <- if (s$drop > 0) x[-seq_len(s$drop)] else x
  t  <- make_tail(xs, XMIN * s$xmin_mult, discrete)
  tb <- compare_table(fit_all(t), t)
  d  <- setNames(round(tb$dAIC, 1), tb$model)
  data.frame(xmin = t$xmin, dropped_top = s$drop, n_tail = t$n,
             as.list(d[c("power_law", "cutoff", "lognormal", "weibull",
                         "exponential", "piecewise")]))
}))
cat("\nSensitivity (dAIC by scenario):\n")
print(sens, row.names = FALSE)
