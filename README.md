# Trade Anomaly Monitor

Monthly monitor of Irish goods imports (Eurostat Comext `DS-045409`) that flags
6-digit HS categories with a simultaneously **significant, sudden and sharp**
import surge and emails a Department-of-Finance house-style report.

A category is flagged when, over a backward-looking rolling 3-month window, it is:

- **significant** — year-on-year increase > €100m
- **sudden** — increase > €50m on the previous 3 months
- **sharp** — year-on-year increase > 50%

For each flagged category the email shows the last-3-months value, the YoY
increase, the most-recent-month value, the top-3 partner countries with shares,
and a 12-month bar chart. New categories (vs the previous run) are tagged **NEW**.

## How it runs

`.github/workflows/trade-anomaly.yml` runs `trade_anomaly_monthly.R` on the 5th
of each month (and on demand via the Actions "Run workflow" button), then emails
the report and commits the updated `trade_anomaly_state.csv` back to the repo.

## Setup

See **[GITHUB_ACTIONS_SETUP.md](GITHUB_ACTIONS_SETUP.md)**. In short, add three
repository secrets:

| Secret | Value |
|--------|-------|
| `SMTP_USERNAME` | sender email (Gmail address for testing) |
| `SMTP_PASSWORD` | Gmail 16-char App Password |
| `DFIN_MAIL_TO`  | recipient(s) |

## Files

| File | Purpose |
|------|---------|
| `trade_anomaly_monthly.R` | the job: fetch, detect, chart, build HTML email |
| `.github/workflows/trade-anomaly.yml` | monthly schedule + email + state commit |
| `GITHUB_ACTIONS_SETUP.md` | deployment checklist and secrets |
| `trade_anomaly_state.csv` | NEW-vs-ongoing memory (created/committed by the job) |

Source: Eurostat Comext `DS-045409` (reporter IE, partner WORLD, imports).
Values are current prices; HS codes are not industry-specific.
