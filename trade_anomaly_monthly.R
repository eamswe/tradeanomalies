#' Monthly Irish-import trade-anomaly monitor + DFIN house-style email.
#' ---------------------------------------------------------------------------
#' Runs once a month. Uses a backward-looking ROLLING 3-month window (the last
#' three complete months in the Comext data) and flags any 6-digit HS code whose
#' imports are simultaneously:
#'   significant : YoY increase  > EUR 100m   (current 3m vs same 3m a year ago)
#'   sudden      : 3m-on-3m inc.  > EUR  50m   (current 3m vs previous 3m block)
#'   sharp       : YoY increase  > 50%
#' For every flagged category it reports three figures (last-3-months EUR, YoY
#' increase, most-recent-month EUR), draws a 12-month chart, and writes a styled
#' HTML email. New categories (not flagged last run) are tagged NEW.
#'
#' Source: Eurostat Comext DS-045409 (reporter IE, partner WORLD, imports).
#' ---------------------------------------------------------------------------

suppressMessages({library(jsonlite); library(dplyr); library(ggplot2); library(base64enc)})

# ---- config -----------------------------------------------------------------
WD        <- "/Users/eamonnsweeney/Documents/D:FIn/AI/core_me"
if (Sys.getenv("CI") == "") setwd(WD)   # local only; in CI use the checkout dir
THRESH    <- list(yoy_abs = 100e6, qoq_abs = 50e6, yoy_pct = 0.50)
MAIL_TO   <- Sys.getenv("DFIN_MAIL_TO", "")        # set to enable real sending
SOURCE    <- "Source: Eurostat Comext DS-045409 (reporter IE, partner WORLD, imports)."
BASE      <- "https://ec.europa.eu/eurostat/api/comext/dissemination/sdmx/2.1/data"

# ---- DFIN palette & chart theme --------------------------------------------
DG <- "#004D44"; SAGE <- "#66948F"; LSAGE <- "#B2C9C7"; GOLD <- "#A3915E"
LGOLD <- "#C8BD9E"; GRID <- "#BFBFBF"; BOX <- "#EFEFEF"
theme_dfin <- function() {
  theme_minimal(base_size = 11) +
    theme(
      text             = element_text(colour = DG),
      plot.title       = element_text(face = "bold", colour = DG, size = 12),
      plot.subtitle    = element_text(colour = DG, size = 8.5),
      plot.caption     = element_text(colour = DG, size = 7, hjust = 1),
      axis.text        = element_text(colour = DG, size = 7),
      axis.title       = element_blank(),
      axis.line        = element_line(colour = "black", linewidth = 0.25),
      axis.ticks       = element_line(colour = "black", linewidth = 0.25),
      panel.grid.major.y = element_line(colour = GRID, linewidth = 0.3, linetype = "22"),
      panel.grid.major.x = element_line(colour = GRID, linewidth = 0.2, linetype = "22"),
      panel.grid.minor = element_blank(),
      panel.background = element_blank(),
      plot.background  = element_rect(fill = "transparent", colour = NA),
      legend.background = element_rect(fill = "transparent", colour = NA),
      legend.key       = element_rect(fill = "transparent", colour = NA),
      legend.position  = "top", legend.title = element_blank(),
      legend.text      = element_text(colour = DG, size = 7.5),
      legend.key.size  = unit(0.4, "cm"))
}

# ---- 1. fetch all-products monthly imports for the years we need ------------
parse_year <- function(yr) {
  f <- sprintf("/tmp/anom_%d.json", yr)
  if (!file.exists(f) || file.size(f) < 1000) {
    url <- sprintf("%s/DS-045409/M.IE.WORLD..1.VALUE_IN_EUROS/?startPeriod=%d-01&endPeriod=%d-12&format=JSON",
                   BASE, yr, yr)
    system2("curl", c("-s", shQuote(url), "-o", shQuote(f)))
  }
  d <- fromJSON(f, simplifyVector = FALSE)
  if (!is.null(d$error)) stop("API error for ", yr)
  nt   <- d$size[[which(unlist(d$id) == "time")]]
  pcat <- d$dimension$product$category
  ppos <- setNames(names(pcat$index), unlist(pcat$index))
  plab <- unlist(pcat$label)
  tpos <- setNames(names(d$dimension$time$category$index),
                   unlist(d$dimension$time$category$index))
  keys <- as.integer(names(d$value)); vals <- as.numeric(unlist(d$value, use.names = FALSE))
  data.frame(code = ppos[as.character(keys %/% nt)],
             ym   = tpos[as.character(keys %% nt)],
             eur  = vals, desc = plab[ppos[as.character(keys %/% nt)]],
             stringsAsFactors = FALSE)
}
yr_now <- as.integer(format(Sys.Date(), "%Y"))
raw <- bind_rows(lapply((yr_now - 2):yr_now, parse_year)) |>
  filter(grepl("^[0-9]{6}$", code))                      # HS6 only

# ---- 2. define the rolling windows around the latest complete month ---------
raw <- raw |> mutate(mi = as.integer(substr(ym, 1, 4)) * 12 +
                          as.integer(substr(ym, 6, 7)) - 1)   # monotonic month index
t  <- max(raw$mi)                                              # latest data month
mdate  <- function(mi) as.Date(sprintf("%d-%02d-01", mi %/% 12, mi %% 12 + 1))
mlabel <- function(mi) format(mdate(mi), "%b-%y")
cur_set  <- (t - 2):t ; yoy_set <- (t - 14):(t - 12); prev_set <- (t - 5):(t - 3)
win_lbl  <- sprintf("%s to %s", mlabel(t - 2), mlabel(t))
labels   <- raw |> distinct(code, desc)

agg <- raw |>
  summarise(
    cur3   = sum(eur[mi %in% cur_set]),
    yoy3   = sum(eur[mi %in% yoy_set]),
    prev3  = sum(eur[mi %in% prev_set]),
    latest = sum(eur[mi == t]),
    .by = code) |>
  mutate(yoy_abs = cur3 - yoy3, qoq_abs = cur3 - prev3,
         yoy_pct = ifelse(yoy3 <= 0, Inf, yoy_abs / yoy3))

# ---- 3. apply the three tests, rank by YoY EUR ------------------------------
flagged <- agg |>
  filter(yoy_abs > THRESH$yoy_abs, qoq_abs > THRESH$qoq_abs, yoy_pct > THRESH$yoy_pct) |>
  left_join(labels, by = "code") |>
  arrange(desc(yoy_abs))

# ---- 4. NEW vs ongoing (state file) -----------------------------------------
state_f <- "trade_anomaly_state.csv"
prev_codes <- if (file.exists(state_f)) read.csv(state_f, colClasses = "character")$hs6 else character()
flagged$status <- ifelse(flagged$code %in% prev_codes, "ongoing", "NEW")
write.csv(data.frame(hs6 = flagged$code, window_end = mlabel(t)), state_f, row.names = FALSE)

short <- function(s) { s <- sub("\\s*[\\(“].*$", "", s); ifelse(nchar(s) > 60, paste0(substr(s,1,57),"..."), s) }
# full category name for the boxes: strip only the legal "(excl./incl. ...)" tail,
# keep the rest and let it wrap across lines.
name_clean <- function(s) trimws(sub("\\s*\\((?:excl|incl|other than|of)\\b.*$", "", s, perl = TRUE))
eurm  <- function(x) paste0("€", formatC(x/1e6, format="f", digits=1, big.mark=","), "m")
cat(sprintf("Latest month: %s | window: %s | flagged: %d (new: %d)\n",
            mlabel(t), win_lbl, nrow(flagged), sum(flagged$status=="NEW")))

# ---- 5. 12-month house-style chart (top 4 flagged categories) ---------------
chart_b64 <- ""
if (nrow(flagged) > 0) {
  topc <- head(flagged$code, 4)
  shortc <- function(s) { s <- sub("\\s*[\\(“].*$", "", s); s <- sub(",.*$", "", s)
                          ifelse(nchar(s) > 30, paste0(substr(s,1,28),"…"), s) }
  ser  <- raw |> filter(code %in% topc, mi %in% (t - 11):t) |>
    mutate(date = as.Date(sprintf("%d-%02d-01", mi %/% 12, mi %% 12 + 1)),
           name = factor(sprintf("%s %s", code, shortc(desc)),
                         levels = sprintf("%s %s", topc, shortc(labels$desc[match(topc, labels$code)]))))
  cols <- setNames(c(DG, SAGE, LSAGE, GOLD)[seq_along(topc)], levels(ser$name))
  lwd  <- setNames(c(1.1, 0.9, 0.8, 0.8)[seq_along(topc)], levels(ser$name))
  lty  <- setNames(c("solid","solid","solid","longdash")[seq_along(topc)], levels(ser$name))
  head_name <- levels(ser$name)[1]
  hd <- ser |> filter(name == head_name, mi == t)
  p <- ggplot(ser, aes(date, eur/1e6, colour = name, linewidth = name, linetype = name)) +
    geom_line() +
    geom_point(data = hd, shape = 21, fill = "white", colour = DG, stroke = 0.9, size = 2.4) +
    geom_text(data = hd, aes(label = round(eur/1e6)), colour = DG, fontface = "bold",
              size = 2.8, hjust = -0.25, show.legend = FALSE) +
    scale_colour_manual(values = cols) + scale_linewidth_manual(values = lwd, guide = "none") +
    scale_linetype_manual(values = lty, guide = "none") +
    scale_x_date(date_breaks = "1 month", date_labels = "%b-%y",
                 expand = expansion(mult = c(0.02, 0.08))) +
    guides(colour = guide_legend(nrow = 2)) +
    labs(title = "Flagged import categories, €m per month",
         subtitle = sprintf("Monthly Irish imports, last 12 months to %s", mlabel(t)),
         caption = SOURCE) +
    theme_dfin() + theme(axis.text.x = element_text(angle = 90, vjust = 0.5, hjust = 1))
  ggsave("trade_anomaly_email_chart.png", p, width = 7.2, height = 3.6, dpi = 150, bg = "transparent")
  chart_b64 <- base64enc::dataURI(file = "trade_anomaly_email_chart.png", mime = "image/png")
}

# ---- 6. build the HTML email -------------------------------------------------
# small house-style 12-month bar chart for a single category -> base64 data URI
mini_bar <- function(cd) {
  dd <- data.frame(mi = (t - 11):t) |>
    left_join(raw |> filter(code == cd) |> select(mi, eur), by = "mi") |>
    mutate(eur = coalesce(eur, 0), date = mdate(mi))
  g <- ggplot(dd, aes(date, eur/1e6)) +
    geom_col(fill = DG, width = 22) +
    scale_x_date(date_breaks = "1 month", date_labels = "%b-%y",
                 expand = expansion(mult = c(0.03, 0.03))) +
    scale_y_continuous(expand = expansion(mult = c(0, 0.10))) +
    labs(title = "Monthly imports, €m") +
    theme_dfin() +
    theme(axis.text.x = element_text(angle = 90, vjust = 0.5, hjust = 1, size = 6),
          axis.text.y = element_text(size = 6),
          panel.grid.major.x = element_blank(),
          plot.title = element_text(size = 8))
  f <- tempfile(fileext = ".png")
  ggsave(f, g, width = 6.4, height = 1.5, dpi = 150, bg = "transparent")
  base64enc::dataURI(file = f, mime = "image/png")
}

# top-3 partner countries for the most recent month, with % of that month's total
ym_t <- format(mdate(t), "%Y-%m")
AGG_PARTNERS <- c("EU", "EA", "QU", "QV", "QW", "QR", "QS", "QY", "QZ")  # non-country 2-letter codes
partners_top3 <- function(cd, total_eur) {
  f <- sprintf("/tmp/partner_%s_%d.json", cd, t)
  if (!file.exists(f) || file.size(f) < 400) {
    url <- sprintf("%s/DS-045409/M.IE..%s.1.VALUE_IN_EUROS/?startPeriod=%s&endPeriod=%s&format=JSON",
                   BASE, cd, ym_t, ym_t)
    system2("curl", c("-s", shQuote(url), "-o", shQuote(f)))
  }
  d <- tryCatch(fromJSON(f, simplifyVector = FALSE), error = function(e) NULL)
  if (is.null(d) || !is.null(d$error) || length(d$value) == 0) return("")
  ip <- which(unlist(d$id) == "partner"); np <- d$size[[ip]]
  sp <- prod(unlist(d$size)[(ip + 1):length(d$size)])     # stride below partner
  pcat <- d$dimension$partner$category
  ppos <- setNames(names(pcat$index), unlist(pcat$index)); plab <- unlist(pcat$label)
  keys <- as.integer(names(d$value)); vals <- as.numeric(unlist(d$value, use.names = FALSE))
  pc   <- ppos[as.character((keys %/% sp) %% np)]
  df   <- data.frame(pc = pc, v = vals) |>
    filter(grepl("^[A-Z]{2}$", pc), !pc %in% AGG_PARTNERS) |>
    arrange(desc(v)) |> head(3)
  if (nrow(df) == 0) return("")
  denom <- if (total_eur > 0) total_eur else sum(df$v)
  nm <- trimws(sub("\\s*\\(.*$", "", plab[df$pc]))        # drop "(incl. ...)" tails
  paste(sprintf('<b style="color:%s;">%s</b> <span style="color:%s;">%d%%</span>',
                DG, nm, SAGE, round(df$v / denom * 100)), collapse = " &nbsp;&middot;&nbsp; ")
}

box <- function(r) {
  tag <- if (r$status == "NEW")
    sprintf('<span style="background:%s;color:#fff;font:bold 10px Arial;padding:2px 7px;border-radius:2px;margin-left:8px;white-space:nowrap;">NEW</span>', GOLD)
  else sprintf('<span style="color:%s;font:italic 10px Arial;margin-left:8px;white-space:nowrap;">ongoing</span>', SAGE)
  cell <- function(lbl, val, sub = "") sprintf(
    '<td width="33%%" style="padding:10px 14px;border-left:3px solid %s;vertical-align:top;">
       <div style="font:11px Arial;color:#555;">%s</div>
       <div style="font:bold 19px Arial;color:%s;margin-top:3px;">%s</div>
       <div style="font:11px Arial;color:%s;">%s</div></td>', DG, lbl, DG, val, SAGE, sub)
  sprintf(
    '<table width="100%%" cellpadding="0" cellspacing="0" style="background:%s;margin:12px 0;border-collapse:collapse;">
       <tr><td colspan="3" style="padding:12px 14px 4px;">
         <span style="font:bold 14px/1.35 Arial;color:%s;">%s &mdash; %s</span>%s</td></tr>
       <tr>%s%s%s</tr>
       <tr><td colspan="3" style="padding:8px 14px 2px;font:12px Arial;color:%s;">
         <span style="color:#555;">Top partners (%s):</span> %s</td></tr>
       <tr><td colspan="3" style="padding:2px 12px 12px;">
         <img src="%s" width="612" style="display:block;width:100%%;max-width:612px;"/></td></tr></table>',
    BOX, DG, r$code, name_clean(r$desc), tag,
    cell(sprintf("Last 3 months (%s)", win_lbl), eurm(r$cur3)),
    cell("Year-on-year increase", paste0("+", eurm(r$yoy_abs)),
         ifelse(is.finite(r$yoy_pct), sprintf("+%d%% YoY", round(r$yoy_pct*100)), "from ~zero base")),
    cell(sprintf("Most recent month (%s)", mlabel(t)), eurm(r$latest)),
    DG, mlabel(t),
    { tp <- partners_top3(r$code, r$latest); if (nzchar(tp)) tp else "<span style=\"color:#888;\">not disclosed</span>" },
    mini_bar(r$code))
}
boxes <- if (nrow(flagged) > 0) paste(sapply(seq_len(nrow(flagged)), function(i) box(flagged[i,])), collapse = "") else
  sprintf('<div style="background:%s;padding:18px;font:14px Arial;color:%s;">No new trade anomalies were flagged this month.</div>', BOX, DG)
chart_html <- if (nzchar(chart_b64)) sprintf('<img src="%s" width="640" style="display:block;margin:8px 0;"/>', chart_b64) else ""

intro <- sprintf("Monitoring Irish goods imports at the 6-digit HS level. The %s window flagged <b>%d</b> categor%s (%d new) that rose by more than €100m year-on-year, more than €50m on the previous three months, and by more than 50%%.",
                 win_lbl, nrow(flagged), ifelse(nrow(flagged)==1,"y","ies"), sum(flagged$status=="NEW"))

html <- sprintf('<!DOCTYPE html><html><body style="margin:0;background:#fff;">
<table width="680" cellpadding="0" cellspacing="0" align="center" style="font-family:Arial,Helvetica,sans-serif;">
 <tr><td style="background:%s;padding:18px 22px;">
   <div style="font:bold 20px Arial;color:#fff;">Trade Anomaly Monitor</div>
   <div style="font:13px Arial;color:%s;margin-top:2px;">Anomalous Irish import surges &mdash; %s</div></td></tr>
 <tr><td style="padding:18px 22px 0;font:14px/1.5 Arial;color:#222;">%s</td></tr>
 <tr><td style="padding:6px 22px;">%s</td></tr>
 <tr><td style="padding:0 22px;">%s</td></tr>
 <tr><td style="padding:8px 22px 0;font:7pt Arial;color:%s;text-align:right;">%s</td></tr>
 <tr><td style="background:%s;padding:12px 22px;margin-top:14px;">
   <span style="font:12px Arial;color:#fff;">An Roinn Airgeadais &nbsp;|&nbsp; Department of Finance</span>
   <span style="font:11px Arial;color:%s;float:right;">Generated %s &middot; current prices &middot; HS6 codes are not industry-specific</span></td></tr>
</table></body></html>',
  DG, LSAGE, win_lbl, intro, chart_html, boxes, DG, SOURCE, DG, LGOLD, format(Sys.Date(), "%d %b %Y"))

writeLines(html, "trade_anomaly_email.html")
write.csv(flagged |> transmute(hs6 = code, category = desc, status,
            last_3m_eurm = round(cur3/1e6,1), yoy_incr_eurm = round(yoy_abs/1e6,1),
            yoy_pct = ifelse(is.finite(yoy_pct), round(yoy_pct*100), Inf),
            latest_month_eurm = round(latest/1e6,1)),
          "trade_anomaly_monthly.csv", row.names = FALSE)
cat("Wrote trade_anomaly_email.html, trade_anomaly_email_chart.png, trade_anomaly_monthly.csv\n")

# ---- 7. optional send (only if DFIN_MAIL_TO is set) -------------------------
if (nzchar(MAIL_TO)) {
  subj <- sprintf("Trade Anomaly Monitor - %s - %d flagged (%d new)",
                  win_lbl, nrow(flagged), sum(flagged$status=="NEW"))
  # macOS/Linux: pipe the HTML to sendmail with an HTML content-type header.
  msg <- sprintf("To: %s\nSubject: %s\nMIME-Version: 1.0\nContent-Type: text/html; charset=UTF-8\n\n%s",
                 MAIL_TO, subj, html)
  tf <- tempfile(); writeLines(msg, tf)
  status <- system2("/usr/sbin/sendmail", c("-t"), stdin = tf)
  cat(if (status == 0) sprintf("Email sent to %s\n", MAIL_TO) else "sendmail failed; HTML saved only.\n")
} else {
  cat("DFIN_MAIL_TO not set - email not sent (HTML file written for review).\n")
}
