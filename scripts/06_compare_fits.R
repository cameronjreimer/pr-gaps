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

## --- Tail data: unique sizes >= xmin with counts ----------------------------
make_tail <- function(x, xmin, discrete) {
  xt <- x[x >= xmin]
  r  <- rle(sort(xt))
  list(x = r$values, w = r$lengths, n = length(xt), xmin = xmin,
       lo = if (discrete) xmin - 0.5 else xmin, discrete = discrete)
}

## --- Models: each a log survival function, its log density, and a map from
##     unconstrained optimizer parameters q to named parameters -------------
logS_cutoff <- function(x, alpha, lambda) {
  ## S(x) = integral_x^Inf t^-alpha e^(-lambda t) dt = lambda^(alpha-1) Gamma(1-alpha, lambda x)
  (alpha - 1) * log(lambda) + log(gammainc(1 - alpha, lambda * x))
}

logS_piecewise <- function(x, a1, a2, b) {
  ## Density x^-a1 below b and b^(a2-a1) x^-a2 above, continuous at b.
  s   <- 1 - a1
  out <- (a2 - a1) * log(b) + (1 - a2) * log(x) - log(a2 - 1)
  below <- x < b
  if (any(below)) {
    L <- log(x[below]) - log(b)
    g <- if (abs(s) < 1e-8) L else expm1(s * L) / s   # (x^s - b^s) / (s b^s)
    out[below] <- s * log(b) + log(-g + 1 / (a2 - 1))
  }
  out
}

wmean <- function(v, w) sum(w * v) / sum(w)

models <- list(
  power_law = list(
    k = 1,
    start = function(t) log(t$n / sum(t$w * log(t$x / t$lo))),
    par   = function(q) c(alpha = 1 + exp(q[1])),
    logS  = function(x, p) (1 - p[["alpha"]]) * log(x),
    logf  = function(x, p) log(p[["alpha"]] - 1) - p[["alpha"]] * log(x)),
  cutoff = list(
    k = 2,
    start = function(t) c(1 + t$n / sum(t$w * log(t$x / t$lo)), log(0.1 / max(t$x))),
    par   = function(q) c(alpha = q[1], lambda = exp(q[2])),
    logS  = function(x, p) logS_cutoff(x, p[["alpha"]], p[["lambda"]]),
    logf  = function(x, p) -p[["alpha"]] * log(x) - p[["lambda"]] * x),
  lognormal = list(
    k = 2,
    start = function(t) { lx <- log(t$x)
      c(wmean(lx, t$w), log(sqrt(wmean((lx - wmean(lx, t$w))^2, t$w)))) },
    par   = function(q) c(meanlog = q[1], sdlog = exp(q[2])),
    logS  = function(x, p) plnorm(x, p[["meanlog"]], p[["sdlog"]],
                                  lower.tail = FALSE, log.p = TRUE),
    logf  = function(x, p) dlnorm(x, p[["meanlog"]], p[["sdlog"]], log = TRUE)),
  weibull = list(
    k = 2,
    start = function(t) c(log(0.5), log(wmean(t$x, t$w))),
    par   = function(q) c(shape = exp(q[1]), scale = exp(q[2])),
    logS  = function(x, p) -(x / p[["scale"]])^p[["shape"]],
    logf  = function(x, p) dweibull(x, p[["shape"]], p[["scale"]], log = TRUE)),
  exponential = list(
    k = 1,
    start = function(t) log(1 / wmean(t$x - t$lo, t$w)),
    par   = function(q) c(rate = exp(q[1])),
    logS  = function(x, p) -p[["rate"]] * x,
    logf  = function(x, p) dexp(x, p[["rate"]], log = TRUE))
)

piecewise_at <- function(b) list(
  k = 3,
  start = function(t) { a <- 1 + t$n / sum(t$w * log(t$x / t$lo)); c(a, log(a - 1)) },
  par   = function(q) c(a1 = q[1], a2 = 1 + exp(q[2]), b = b),
  logS  = function(x, p) logS_piecewise(x, p[["a1"]], p[["a2"]], p[["b"]]),
  logf  = function(x, p) ifelse(x < p[["b"]], -p[["a1"]] * log(x),
                                (p[["a2"]] - p[["a1"]]) * log(p[["b"]]) - p[["a2"]] * log(x)))

## --- Likelihood and fitting -------------------------------------------------
## Log-likelihood of each unique size (multiply by t$w for the total).
pointwise_ll <- function(mod, p, t) {
  if (t$discrete) {
    la <- mod$logS(t$x - 0.5, p); lb <- mod$logS(t$x + 0.5, p)
    la + log1p(-exp(lb - la)) - mod$logS(t$lo, p)   # log(S(a) - S(b)) - log S(lo)
  } else {
    mod$logf(t$x, p) - mod$logS(t$lo, p)
  }
}

fit_model <- function(mod, t) {
  nll <- function(q) {
    v <- -sum(t$w * suppressWarnings(pointwise_ll(mod, mod$par(q), t)))
    if (is.finite(v)) v else 1e100
  }
  q0 <- mod$start(t)
  o  <- if (length(q0) == 1) optim(q0, nll, method = "BFGS")
        else optim(optim(q0, nll, control = list(maxit = 5000))$par, nll, method = "BFGS")
  p  <- mod$par(o$par)
  list(par = p, logL = -o$value, k = mod$k, ll = pointwise_ll(mod, p, t),
       mod = mod, converged = o$convergence == 0)
}

## Piecewise: profile the breakpoint over a log grid between 2 x xmin and the
## size that leaves 20 gaps above it, fitting both exponents at each.
fit_piecewise <- function(t, n_grid = 30) {
  above <- rev(cumsum(rev(t$w)))
  b_max <- t$x[max(which(above >= 20))]
  if (b_max <= 2 * t$xmin) return(NULL)
  bs   <- exp(seq(log(2 * t$xmin), log(b_max), length.out = n_grid))
  fits <- lapply(bs, function(b) fit_model(piecewise_at(b), t))
  best <- fits[[which.max(vapply(fits, `[[`, numeric(1), "logL"))]]
  best$profile <- data.frame(b = bs, logL = vapply(fits, `[[`, numeric(1), "logL"))
  best
}

fit_all <- function(t) {
  fits <- lapply(models, fit_model, t = t)
  pw   <- fit_piecewise(t)
  if (!is.null(pw)) fits$piecewise <- pw
  fits
}

## --- Comparison table -------------------------------------------------------
compare_table <- function(fits, t) {
  ref <- fits$power_law
  tab <- do.call(rbind, lapply(names(fits), function(nm) {
    f  <- fits[[nm]]
    d  <- f$ll - ref$ll                       # per unique size
    mu <- wmean(d, t$w)
    sd <- sqrt(wmean((d - mu)^2, t$w))
    test <- switch(nm, power_law = "-", cutoff = "LR (boundary)",
                   piecewise = "none (use AIC)", "Vuong")
    p <- switch(test,
      "Vuong"         = if (sd > 0) 2 * pnorm(-abs(sqrt(t$n) * mu / sd)) else NA,
      "LR (boundary)" = 0.5 * pchisq(max(0, 2 * (f$logL - ref$logL)), 1, lower.tail = FALSE),
      NA)
    data.frame(model = nm, k = f$k, logL = f$logL, AIC = 2 * f$k - 2 * f$logL,
               ll_per_gap = mu, test = test, p = p, converged = f$converged)
  }))
  tab$dAIC   <- tab$AIC - min(tab$AIC)
  tab$weight <- exp(-tab$dAIC / 2) / sum(exp(-tab$dAIC / 2))
  tab[order(tab$AIC), c("model", "k", "logL", "dAIC", "weight",
                        "ll_per_gap", "test", "p", "converged")]
}

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
