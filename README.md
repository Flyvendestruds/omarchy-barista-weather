# omarchy-barista-weather

Omarchy bar-widget weather plugin (`barista.weather`): weather pill with
detail popup, styled to match the
[barista theme](https://github.com/Flyvendestruds/omarchy-barista-theme)
but installable on its own.

```
omarchy plugin add https://github.com/Flyvendestruds/omarchy-barista-weather.git --enable
```

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
  omarchy.weather` so enabling it swaps the stock weather widget in place).

## Install

Standalone (any theme):

```
omarchy plugin add https://github.com/Flyvendestruds/omarchy-barista-weather.git --enable
```

With barista, it is an optional add-on: the theme's `setup.sh` offers a
`weather` step that installs + enables this repo. Uninstall any time with
`omarchy plugin remove barista.weather` — the stock `omarchy.weather`
returns to the bar slot automatically.

## Development

Edit the installed copy at `~/.config/omarchy/plugins/barista.weather/`,
then copy back here (`BarWidget.qml`, `Panel.qml`, `Model.js`,
`manifest.json`, `icons/`). `Model.js` stays shell-free so logic can be
checked with `node --check` / `node -e require(...)`.
