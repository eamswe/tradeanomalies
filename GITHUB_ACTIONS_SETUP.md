# Deploying the trade-anomaly monitor on GitHub Actions

This is the checklist to get the monthly email running. Order matters: do the
one code change, push the repo, add the three secrets, then test with a manual
run before relying on the schedule.

---

## 1. Files that must be in the repo

| Path | What it is |
|------|------------|
| `trade_anomaly_monthly.R` | the job (already written) |
| `.github/workflows/trade-anomaly.yml` | the workflow (already written) |
| `trade_anomaly_state.csv` | NEW-vs-ongoing memory — committed by the job each run; fine if absent on first run |

The repo's **default branch must be `main`** (scheduled workflows only run from
the default branch).

---

## 2. One required code change (before first run)

`trade_anomaly_monthly.R` currently hard-codes a local macOS working directory:

```r
WD <- "/Users/eamonnsweeney/Documents/D:FIn/AI/core_me"
setwd(WD)
```

That path does not exist on a runner, so it must only apply locally. Change to:

```r
if (Sys.getenv("CI") == "") setwd("/Users/eamonnsweeney/Documents/D:FIn/AI/core_me")
```

GitHub sets `CI=true`, so in Actions the script just uses the checked-out repo
directory; locally it behaves exactly as before. (No other code change is
needed — `curl` is present on `ubuntu-latest`, and the script's own mail-send
path stays off because we don't set `DFIN_MAIL_TO` in the generate step.)

> Ask me and I'll make this edit for you.

---

## 3. Secrets to create

In GitHub: **repo → Settings → Secrets and variables → Actions → New repository secret.**
Create exactly these three names (values are not visible after saving):

| Secret name | Value | Notes |
|-------------|-------|-------|
| `SMTP_USERNAME` | your full Gmail address, e.g. `trade.monitor.test@gmail.com` | the test sender |
| `SMTP_PASSWORD` | the **16-character Gmail App Password** | NOT your normal Gmail login password |
| `DFIN_MAIL_TO`  | recipient address, e.g. your `tcd.ie` inbox or an Outlook inbox | comma-separate for multiple recipients |

**Never put these in the YAML or any committed file** — only in Secrets.
If the App Password leaks, delete it in Google → Security → App passwords and
create a new one; update `SMTP_PASSWORD`.

(Reminder of the Gmail side: personal `@gmail.com` account → turn on 2-Step
Verification → myaccount.google.com/apppasswords → create one named
"Trade Anomaly Monitor" → copy the 16 characters into `SMTP_PASSWORD`.)

---

## 4. Test it

1. Push the repo (with the §2 edit) to `main`.
2. GitHub → **Actions** tab → "Monthly trade-anomaly monitor" → **Run workflow**
   (this is the `workflow_dispatch` button).
3. Watch the run. The "Email the report" step should go green and the message
   should arrive at `DFIN_MAIL_TO`.
4. Check the email renders. **In Gmail/Apple Mail the inline charts display; in
   Outlook the in-body images are blocked** (Outlook refuses `data:` images).
   The overview chart is also sent as a normal attachment, so it's viewable
   either way. To make the in-body charts render in Outlook too, we switch from
   inline base64 to CID-attached images (the `blastula` refactor) — say the word.

---

## 5. Schedule behaviour

- Runs **08:00 UTC on the 5th** each month (`cron: "0 8 5 * *"`). Cron is UTC, no
  DST; scheduled runs can be delayed under GitHub load — immaterial for monthly.
- Each run commits `trade_anomaly_state.csv` back to the repo. That both
  preserves the NEW-vs-ongoing memory and counts as repo activity, which stops
  GitHub auto-disabling the schedule.

---

## 6. Going to production (later)

The Gmail sender is for testing only. For the real Departmental deployment,
swap the "Email the report" step to the Department's sender:

- **Microsoft 365 / Graph** `sendMail` with an app registration (works from
  hosted runners over HTTPS), or
- the **internal SMTP relay** — but if that relay is only reachable inside the
  Department network, a GitHub-hosted runner can't reach it and you'll need a
  **self-hosted runner** inside the network instead.

Either way it's a change to one workflow step plus swapping the secret values;
the rest of the pipeline is unchanged. Production mail should send from a
`finance.gov.ie` address with SPF/DKIM/DMARC so it isn't spam-filtered.
