#!/usr/bin/env python3
"""Send the trade-anomaly report as an HTML email with charts embedded inline.

Every chart referenced in trade_anomaly_email.html as <img src="cid:NAME"> is
attached as an inline Content-ID part (image NAME.png) inside a multipart/related
body, so it renders in Gmail and Outlook. (Inline base64 data: URIs do not — they
are stripped by both clients, which is why the per-category charts vanished.)

Config via environment:
  SMTP_USERNAME, SMTP_PASSWORD   sender + Gmail App Password
  DFIN_MAIL_TO                   recipient(s), comma/semicolon separated
  SMTP_HOST (default smtp.gmail.com), SMTP_PORT (default 587)
  MAIL_SUBJECT (optional)
  DRY_RUN=1                      build + save .eml, do not send (for local testing)
"""
import os, re, smtplib, sys
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.image import MIMEImage
from email.mime.application import MIMEApplication

HTML_FILE, CSV_FILE = "trade_anomaly_email.html", "trade_anomaly_monthly.csv"

host = os.environ.get("SMTP_HOST", "smtp.gmail.com")
port = int(os.environ.get("SMTP_PORT", "587"))
user = os.environ.get("SMTP_USERNAME", "")
pw   = os.environ.get("SMTP_PASSWORD", "")
to   = os.environ.get("DFIN_MAIL_TO", "")
subject = os.environ.get("MAIL_SUBJECT", "Trade Anomaly Monitor")
dry  = os.environ.get("DRY_RUN") == "1" or not (user and pw and to)

with open(HTML_FILE, encoding="utf-8") as f:
    html = f.read()

msg = MIMEMultipart("mixed")
msg["Subject"] = subject
msg["From"] = f"Trade Anomaly Monitor <{user or 'monitor@example.invalid'}>"
msg["To"] = to or "(dry-run)"

related = MIMEMultipart("related")
related.attach(MIMEText(html, "html", "utf-8"))

# attach each cid:NAME in the HTML as inline image NAME.png
seen = set()
for name in re.findall(r"cid:([A-Za-z0-9_\-]+)", html):
    if name in seen:
        continue
    seen.add(name)
    path = f"{name}.png"
    if not os.path.exists(path):
        print(f"WARNING: {path} referenced as cid but not found; skipping", file=sys.stderr)
        continue
    with open(path, "rb") as img:
        part = MIMEImage(img.read(), _subtype="png")
    part.add_header("Content-ID", f"<{name}>")
    part.add_header("Content-Disposition", "inline", filename=path)
    related.attach(part)
msg.attach(related)

if os.path.exists(CSV_FILE):                      # CSV as a normal download
    with open(CSV_FILE, "rb") as c:
        csv_part = MIMEApplication(c.read(), _subtype="csv")
    csv_part.add_header("Content-Disposition", "attachment", filename=CSV_FILE)
    msg.attach(csv_part)

recipients = [a.strip() for a in re.split(r"[,;]", to) if a.strip()]

if dry:
    with open("trade_anomaly_email.eml", "w", encoding="utf-8") as out:
        out.write(msg.as_string())
    print(f"DRY RUN: built message with {len(seen)} inline chart(s); "
          f"wrote trade_anomaly_email.eml (not sent).")
    sys.exit(0)

with smtplib.SMTP(host, port) as s:
    s.starttls()
    s.login(user, pw)
    s.sendmail(user, recipients, msg.as_string())
print(f"Sent '{subject}' to {recipients} with {len(seen)} inline chart(s).")
