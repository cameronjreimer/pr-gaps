## ---------------------------------------------------------------------------
## Gap size-distribution models, shared by scripts/06_compare_fits.R and
## scripts/07_agu_fits.R. Moved unchanged from 06 (2026-11-23); see 06's header
## for the models and how to read the comparison table. Needs expint.
## ---------------------------------------------------------------------------

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

