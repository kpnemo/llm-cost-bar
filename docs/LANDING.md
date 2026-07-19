# LLM Cost Bar — landing page content

Source content for the marketing mini-site. Everything a landing page needs:
copy, structure, links, and assets. Tone: developer-to-developer, concrete,
no hype.

---

## Hero

**Name:** LLM Cost Bar

**Tagline:** Know what your AI is costing you. Right now, in your menu bar.

**Subtitle:** One glance shows today's burn and month-to-date across
OpenRouter, Anthropic, and OpenAI — with live charts, credit balances, and
per-API-key breakdowns. Free, open source, no backend.

**Primary CTA button:** Download for macOS
→ `https://github.com/kpnemo/llm-cost-bar/releases/latest/download/LLMCostBar.dmg`

**Secondary CTA:** View on GitHub
→ `https://github.com/kpnemo/llm-cost-bar`

**Under the button:** Free · Open source (MIT) · macOS 14+ · Signed & notarized

**Download counter badge (live image, auto-updates):**
`https://img.shields.io/github/downloads/kpnemo/llm-cost-bar/total?label=downloads&color=2ea44f`

---

## The problem (one short paragraph)

You have API keys at three vendors, agents running overnight, and a credit
balance quietly draining. The vendor dashboards are three logins away and
none of them show *today*. By the time the invoice email arrives, the
interesting question — *what* burned the money — is a spreadsheet job.

## The answer (one line)

A menu bar number that's never more than a few minutes stale, and a dropdown
that answers "which vendor, which key, which day" in two clicks.

---

## Feature blocks (icon + heading + 1–2 sentences each)

1. **Today, live** — Not yesterday's report. A background daemon polls the
   vendor APIs on your schedule and shows today's spend as it happens,
   including a live delta for vendors whose activity feeds lag.

2. **Every vendor, one panel** — OpenRouter, Anthropic, and OpenAI cards with
   month-to-date, credits progress, and a 30-day bar chart. Hover any bar for
   that day's exact spend.

3. **Which key is burning?** — Per-key spend for each vendor: real dollars
   from OpenRouter and OpenAI, smart token-weighted estimates for Anthropic
   (which exposes no per-key cost API — the estimates always sum to the true
   total).

4. **Private by design** — No backend, no telemetry, no account. Keys live in
   the macOS Keychain; data flows straight from vendor APIs to a local SQLite
   file. The repo is open — check.

5. **Survives everything** — A launchd-supervised daemon keeps collecting
   through app crashes, restarts, and sleep. Every sync attempt lands in a
   Diagnostics view; nothing fails silently.

6. **Set up in a minute** — Paste one management/admin key per vendor and
   you're done. The app live-tests the key before storing it, with pointed
   error messages when a vendor hands you the wrong kind of key.

---

## Screenshots to capture (assets for the page)

1. **Hero shot:** dropdown open over a desktop — three vendor cards collapsed,
   header "Today $2.16 / MTD $73.33", vendor favicons visible.
2. **Expanded card:** Anthropic card with the 30-day chart mid-hover
   ("Jul 12 · $3.41" readout) and the per-key spend list.
3. **Menu bar close-up:** just the icon + today's number in the menu bar.
4. **Credits bar:** OpenRouter card showing the color-coded credits progress
   ("$9.47 left of $80.00 · 88% used").

---

## FAQ

**Is it really free?**
Yes. MIT-licensed, no paid tier, no account. You bring your own vendor API
keys.

**What keys does it need?**
Read-billing keys, not your inference keys: an OpenRouter *management key*, an
Anthropic *Admin API key* (team orgs — individual Console accounts can convert
to team in one click), an OpenAI *Admin API key* (org owner). The in-app setup
links to the exact page for each and tests the key before saving.

**Where does my data go?**
Nowhere. There's no server. Your Mac talks to the vendor APIs directly and
stores results in a local SQLite database. Keys are Keychain-only.
See PRIVACY.md in the repo.

**Why does macOS ask about Keychain access when I add a provider?**
The background daemon is a separate binary from the app, and macOS grants
Keychain access per item — so you approve each newly added key once. Click
"Always Allow" and you won't be asked again for that key.

**Gemini?**
Waiting on Google — AI Studio has spend dashboards but no API to read them.
The moment one exists, it's a provider away.

**Why not the Mac App Store?**
The sandbox is a poor fit for a launchd daemon reading org billing APIs. It's
distributed the way Alfred and Raycast are: a notarized, Developer ID-signed
DMG straight from GitHub Releases.

---

## Footer

- Download: `https://github.com/kpnemo/llm-cost-bar/releases/latest/download/LLMCostBar.dmg`
- GitHub: `https://github.com/kpnemo/llm-cost-bar`
- Privacy: `https://github.com/kpnemo/llm-cost-bar/blob/main/PRIVACY.md`
- License: MIT
- Made by Mike (kpnemo). Sibling app: [Polish My Writing](https://github.com/kpnemo/polish-my-writing).

---

## Design notes for the page builder

- Single page, dark theme first (the app is a dark menu bar dropdown — match
  it; accent color from the app's blue chart bars).
- The hero screenshot IS the product — make it large and real, not a stylized
  mockup.
- Keep the download button visible without scrolling; repeat it after the
  feature blocks.
- The shields.io downloads badge can sit small under the CTA as social proof.
- No email capture, no cookie banner needed (static page, no tracking —
  matches the app's privacy story).
