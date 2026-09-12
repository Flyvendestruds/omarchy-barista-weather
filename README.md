# Barista Weather

Omarchy bar-widget weather plugin (`barista.weather`, cloned from stock
`omarchy.weather`): weather pill with detail popup.

## What's custom

- **Hourly strip** — next 12 hours with temp, rain chance + expected amount
  (`Rain 32% · 0.4mm`, mm or in following the temp unit), cloud-cover words,
  UV index.
- **PNG condition icons** (hero, hourly, daily) — user-supplied skeuomorphic
  set in `icons/`. Selection is driven by Open-Meteo `weather_code` plus
  `cloud_cover` with a 70% rule: rain/drizzle codes show `rainy.png` at
  ≥70% cloud else `drizzle-day/night.png`; code 3 shows `overcast.png` at
  ≥70% else `cloudy-day/night.png`. Snow/fog fall back to the Nerd Font
  glyphs. Bar pill stays a glyph.
- **Sky-tinted card** — background follows time of day (location-local via
  Open-Meteo `utc_offset_seconds`): flat day blue `#79b4e6`, flat night navy
  `#0b1322`, muted blue-grey `#527a99` peak in the ±60 min band around
  sunrise/sunset. Edge-to-edge via `padding: 0` + re-applied content margins.
- **Contrast-picked text** — white or near-black `#1a1a1a`, whichever clears
  WCAG AA 4.5:1 against the tint (verified across the full day curve).

## Layout

- `BarWidget.qml` — bar pill wiring (stock shape).
- `Panel.qml` — popup: hero, hourly strip, 3-day row, sky tint, location editor.
- `Model.js` — pure logic (unit-testable with `node --check` / `node -e
  require(...)`): location parsing, Open-Meteo normalization, icon/PNG
  selection, sky color + contrast, formatting.
- `icons/` — PNG set (RGBA, ~90–200px). Source of truth for artwork lives
  outside this repo; sync with `cp <artwork>/*.png icons/`.
- `manifest.json` — plugin manifest (`barista.weather`, `clonedFrom:
  omarchy.weather`).

## Install

Copy (or symlink) this directory to
`~/.config/omarchy/plugins/barista.weather/` and reshell / refresh the panel.
