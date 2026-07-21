# LLM Cost Bar — landing page content

Source content for the marketing mini-site. Everything a landing page needs:
copy, structure, links, and assets. Tone: developer-to-developer, concrete,
no hype.

---

## Application info (facts sheet)

| | |
| --- | --- |
| **Product** | LLM Cost Bar |
| **What it is** | macOS menu-bar app + background daemon that tracks LLM API spend and subscription limits across vendors |
| **Version** | 1.2.0 (see the [latest release](https://github.com/kpnemo/llm-cost-bar/releases/latest) for current) |
| **Platform** | macOS 14 (Sonoma) or newer, Apple Silicon & Intel |
| **Price** | Free |
| **License** | MIT (open source) |
| **Distribution** | Developer ID-signed, Apple-notarized DMG via GitHub Releases (not on the Mac App Store) |
| **Vendors supported** | API spend: OpenRouter, Anthropic, OpenAI. Subscription limits: Claude Pro/Max (via Claude Code), ChatGPT Plus/Pro (via Codex CLI). Gemini pending — Google has no spend API yet |
| **Requirements** | For API spend: your own vendor billing keys (OpenRouter management key, Anthropic Admin API key, OpenAI Admin API key). For subscription limits: no keys at all — just Claude Code and/or Codex CLI signed in on the same Mac |
| **Privacy** | No backend, no telemetry, no account; keys in the macOS Keychain, data in a local SQLite DB |
| **Author** | Mike (kpnemo) |

**All links:**

- Download (always the latest version): `https://github.com/kpnemo/llm-cost-bar/releases/latest/download/LLMCostBar.dmg`
- Releases page: `https://github.com/kpnemo/llm-cost-bar/releases`
- GitHub repo: `https://github.com/kpnemo/llm-cost-bar`
- Privacy policy: `https://github.com/kpnemo/llm-cost-bar/blob/main/PRIVACY.md`
- License: `https://github.com/kpnemo/llm-cost-bar/blob/main/LICENSE`
- Download counter badge (embeddable image): `https://img.shields.io/github/downloads/kpnemo/llm-cost-bar/total?color=2ea44f&label=downloads`
- Sibling app by the same author: `https://github.com/kpnemo/polish-my-writing`

---

## Hero

**Name:** LLM Cost Bar

**Tagline:** Your LLM spend *and* limits, live in your macOS menu bar.

**Subtitle:** Track today's API burn across OpenRouter, Anthropic, and OpenAI —
and your Claude Pro/Max and ChatGPT session/weekly limits with reset
countdowns. Live charts, credit balances, per-API-key breakdowns. Free, open
source, no backend.

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
balance draining quietly. Their dashboards are three logins away, and none
shows *today*. When the invoice email arrives, answering *what* burned the
money is a spreadsheet job. And if you're on Claude Max or ChatGPT Plus
instead, the question is worse: *how much of my week is left?* — answerable
only by typing `/usage` into a terminal.

## The answer (one line)

A menu bar number, never more than a few minutes stale, plus a dropdown that
answers "which vendor, which key, which day" — and "how close am I to the
cap, and when does it reset" — in two clicks.

---

## Feature blocks (icon + heading + 1–2 sentences each)

1. **Today, live** — Not yesterday's report. A background daemon polls vendor
   APIs on your schedule, showing today's spend as it happens. For vendors
   with lagging activity feeds, a live delta keeps the number current.

2. **Every vendor, one panel** — One panel holds OpenRouter, Anthropic, and
   OpenAI cards, each with month-to-date, credits progress, and a 30-day bar
   chart. Hover any bar for that day's exact spend.

3. **Which key is burning?** — Per-key spend for every vendor: real dollars
   from OpenRouter and OpenAI, and token-weighted estimates for Anthropic.
   Every key row shows three columns — today, month-to-date, trailing 30
   days — aligned under the vendor's own totals. Anthropic exposes no
   per-key cost API; its estimates always sum to the true total.

4. **Subscription limits, not just dollars** — On Claude Max or ChatGPT Plus?
   A second tab shows every rolling limit window — Claude's 5-hour session
   and weekly caps (per-model too), Codex's weekly window — as color-coded
   bars with exact reset times ("61% — resets Thu 09:00 · in 2d 3h").

5. **Zero-setup detection** — No keys to paste. If Claude Code or Codex CLI
   is signed in on your Mac, the app finds it and reuses that sign-in
   *read-only* (one click-approved Keychain grant for Claude, nothing for
   Codex). It never refreshes or touches the CLI's tokens, and it never asks
   from the background.

6. **Know before you hit the wall** — A macOS notification fires when any
   window crosses your threshold (default 80%, configurable), re-arming after
   each reset. A 7-day burn-rate sparkline shows whether the week's budget
   will last until Friday.

7. **Private by design** — No backend. No telemetry. No account. Keys stay in
   the macOS Keychain; data flows directly from vendor APIs to a local SQLite
   file. The repo is open — inspect it.

8. **Survives everything** — A launchd-supervised daemon keeps collecting
   through app crashes, restarts, and sleep. Every sync attempt appears in
   Diagnostics, so nothing fails silently.

9. **Set up in a minute** — Paste one management/admin key per vendor. The app
   live-tests each key before storing it and gives a pointed error when a
   vendor hands you the wrong kind. Subscriptions need no setup at all:
   they're auto-detected.

---

## Screenshots to capture (assets for the page)

1. **Hero shot:** dropdown open over a desktop — three vendor cards collapsed,
   header "Today $2.16 / MTD $73.33", vendor favicons and the
   "API Spend | Subscriptions" switcher visible.
2. **Subscriptions tab (co-hero for the subscriber audience):** popover on the
   Subscriptions tab — Claude card (Max badge, 5-hour + 7-day bars, one
   yellow/red bar, reset countdowns, sparkline) above the Codex card.
3. **Expanded card:** Anthropic card with the 30-day chart mid-hover
   ("Jul 12 · $3.41" readout) and the three-column per-key spend list
   (today | MTD | 30d).
4. **Menu bar close-up:** just the icon + today's number in the menu bar.
5. **Credits bar:** OpenRouter card showing the color-coded credits progress
   ("$9.47 left of $80.00 · 88% used").
6. **Threshold notification:** the macOS banner ("Claude 7-day window at 85%
   of limit").
7. **Settings → Accounts:** the "Subscriptions (auto-detected)" section with
   the Claude/Codex toggles.

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

**Why does macOS ask about Keychain access?**
Your keys live only in the macOS Keychain, and the background sync service is
a separate binary from the app — so macOS asks once before letting it read
them (click "Always Allow"). All keys share a single Keychain item, so adding
more providers never adds prompts. Connecting Claude limits asks once too —
and only when **you** click Connect. The app never prompts from the
background: if macOS revokes access (Claude Code rotates its sign-in
regularly, which resets consent), the Claude card keeps showing last-known
data with a Reconnect button, and the one prompt happens right after you
click it. Prefer zero prompts ever? Connect Claude with a `claude
setup-token` instead (Settings → Accounts).

**I don't use API keys, just Claude Max / ChatGPT Plus. Is this for me?**
Yes — that's exactly what the Subscriptions tab is for. Skip the API-key
setup entirely; if Claude Code or Codex CLI is signed in on your Mac, your
limits appear automatically.

**How does it read my Claude limits? Is that safe?**
It reuses the sign-in Claude Code already stores in your macOS Keychain —
read-only, never modified or refreshed, never sent anywhere except
Anthropic's own API (the same endpoint Claude Code's `/usage` command
calls). macOS asks once, when you click Connect; afterwards the app never
prompts on its own. If you'd rather not, one toggle turns the whole source
off. Honest caveat: the limit endpoints are
unofficial (the same ones the vendors' own CLIs use) — if a vendor changes
them, cards show last-known data marked stale until an app update; spend
tracking is unaffected.

**What are "windows" and why do the bars reset?**
Claude Pro/Max and ChatGPT meter usage in rolling windows (Claude: 5-hour
session + 7-day; ChatGPT/Codex: weekly). Each bar is one window: percent
used, plus exactly when it resets.

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
- Two audiences, one CTA: consider a split high on the page — "Pay per
  token?" → API spend blocks / "Pay monthly?" → subscription blocks —
  converging on the same download button.
- The subscription bars introduce green/yellow/red as semantic colors; use
  them only inside limit-bar imagery, keep the page accent blue.
- The hero screenshot IS the product — make it large and real, not a stylized
  mockup.
- Keep the download button visible without scrolling; repeat it after the
  feature blocks.
- The shields.io downloads badge can sit small under the CTA as social proof.
- No email capture, no cookie banner needed (static page, no tracking —
  matches the app's privacy story).
