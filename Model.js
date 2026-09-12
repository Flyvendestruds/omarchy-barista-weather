// weather.json holds {"name": ..., "latitude": ..., "longitude": ...} (see
// omarchy-weather-location, which owns the format). Missing, blank, or
// unparseable means the location is auto-detected from the IP address.
function parseLocationFile(raw) {
  var unset = { name: "", latitude: null, longitude: null }
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return unset

    var latitude = parseFloat(data.latitude)
    var longitude = parseFloat(data.longitude)
    var hasCoordinates = !isNaN(latitude) && !isNaN(longitude)
    return {
      name: typeof data.name === "string" ? data.name.replace(/^\s+|\s+$/g, "") : "",
      latitude: hasCoordinates ? latitude : null,
      longitude: hasCoordinates ? longitude : null
    }
  } catch (e) {
    return unset
  }
}

// wttr.in path segment for a configured location: exact coordinates when
// both are present, the URL-encoded name as a fallback (hand-edited
// weather.loc files may only carry a name), empty for IP auto-detect.
function wttrLocationQuery(location, latitude, longitude) {
  var lat = parseFloat(String(latitude))
  var lon = parseFloat(String(longitude))
  if (!isNaN(lat) && !isNaN(lon)) return lat + "," + lon

  var name = String(location || "").replace(/^\s+|\s+$/g, "")
  return name === "" ? "" : encodeURIComponent(name)
}

// Open-Meteo geocoding response → suggestion rows for the location picker.
function parseGeocodingResults(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var results = data.results
    if (!results || !results.length) return []

    var out = []
    for (var i = 0; i < results.length; i++) {
      var r = results[i]
      if (!r || !r.name || r.latitude === undefined || r.longitude === undefined) continue
      var region = [r.admin1, r.country].filter(function(part) { return !!part }).join(", ")
      out.push({
        name: String(r.name),
        description: region,
        latitude: r.latitude,
        longitude: r.longitude
      })
    }
    return out
  } catch (e) {
    return []
  }
}

function locationCommit(text, suggestions, selectedIndex) {
  var name = String(text || "").replace(/^\s+|\s+$/g, "")
  if (name === "") return { name: "", latitude: null, longitude: null }

  var choices = suggestions || []
  var index = Math.max(0, Math.min(parseInt(selectedIndex, 10) || 0, choices.length - 1))
  var suggestion = choices[index]
  if (suggestion) return suggestion

  return { name: name, latitude: null, longitude: null }
}

function isFutureForecastDate(dateString, todayString) {
  if (!dateString) return false
  return String(dateString).slice(0, 10) > String(todayString || "")
}

function roundedTemp(value) {
  if (value === undefined || value === null || value === "") return ""
  var n = parseFloat(String(value))
  return isNaN(n) ? "" : String(Math.round(n))
}

function celsiusToFahrenheit(value) {
  if (value === undefined || value === null || value === "") return ""
  var n = parseFloat(String(value))
  return isNaN(n) ? "" : (n * 9 / 5) + 32
}

function formatTemp(value, useImperial) {
  if (value === undefined || value === null || value === "") return ""
  return value + "°" + (useImperial ? "F" : "C")
}

// Wind display: metric uses whole m/s, imperial keeps mph.
function formatWind(current, useImperial) {
  if (!current) return ""
  if (useImperial) return (current.windspeedMiles || "") + " mph"
  if (current.windspeedMs !== undefined && current.windspeedMs !== null && current.windspeedMs !== "")
    return current.windspeedMs + " m/s"
  // wttr.in path: only km/h available, convert to whole m/s.
  var kmh = parseFloat(String(current.windspeedKmph || ""))
  return isNaN(kmh) ? "" : String(Math.round(kmh / 3.6)) + " m/s"
}

function normalizedUnit(value) {
  return String(value || "").replace(/^\s+|\s+$/g, "").toLowerCase()
}

function localeUsesImperial(localeName) {
  var name = String(localeName || "").replace(".", "_")
  return /^en[_-]US($|[_.-])/.test(name) || /^en[_-]LR($|[_.-])/.test(name) || /^my($|[_.-])/.test(name)
}

function countryUsesImperial(countryName) {
  var country = String(countryName || "")
    .replace(/^\s+|\s+$/g, "")
    .replace(/[._-]+/g, " ")
    .toLowerCase()
  if (!country) return null
  if (country === "us" || country === "usa" || country === "united states" || country === "united states of america") return true
  if (country === "liberia" || country === "myanmar" || country === "burma") return true
  return false
}

function shouldUseImperial(unitOverride, localeName, countryName) {
  var unit = normalizedUnit(unitOverride)
  if (unit === "imperial") return true
  if (unit === "metric") return false

  var countryPreference = countryUsesImperial(countryName)
  if (countryPreference !== null) return countryPreference

  return localeUsesImperial(localeName)
}

function dayName(dateString, formatter) {
  if (!dateString) return ""
  var d = new Date(dateString + "T12:00:00")
  if (isNaN(d.getTime())) return ""
  if (formatter) return formatter(d)
  return ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][d.getDay()]
}

function openMeteoForecastDays(dailyForecastReport, todayString) {
  var daily = dailyForecastReport && dailyForecastReport.daily ? dailyForecastReport.daily : null
  if (!daily || !daily.time) return []

  var result = []
  for (var i = 0; i < daily.time.length && result.length < 3; ++i) {
    var date = daily.time[i]
    if (!isFutureForecastDate(date, todayString)) continue

    var maxC = daily.temperature_2m_max ? daily.temperature_2m_max[i] : ""
    var minC = daily.temperature_2m_min ? daily.temperature_2m_min[i] : ""
    result.push({
      date: date,
      maxtempC: roundedTemp(maxC),
      mintempC: roundedTemp(minC),
      maxtempF: roundedTemp(celsiusToFahrenheit(maxC)),
      mintempF: roundedTemp(celsiusToFahrenheit(minC)),
      openMeteoWeatherCode: daily.weather_code ? daily.weather_code[i] : null,
      cloudCover: daily.cloud_cover_mean ? daily.cloud_cover_mean[i] : null
    })
  }
  return result
}

// Open-Meteo bundles current conditions with the daily forecast request and
// answers far faster than wttr.in. Normalize them to wttr's
// current_condition shape so the panel can use either source
// interchangeably. Open-Meteo reports metric (°C, km/h).
function openMeteoCurrentCondition(dailyForecastReport) {
  var current = dailyForecastReport && dailyForecastReport.current ? dailyForecastReport.current : null
  if (!current || current.temperature_2m === undefined || current.temperature_2m === null) return null
  return {
    temp_C: roundedTemp(current.temperature_2m),
    temp_F: roundedTemp(celsiusToFahrenheit(current.temperature_2m)),
    FeelsLikeC: roundedTemp(current.apparent_temperature),
    FeelsLikeF: roundedTemp(celsiusToFahrenheit(current.apparent_temperature)),
    windspeedKmph: roundedTemp(current.wind_speed_10m),
    windspeedMs: roundedTemp(current.wind_speed_10m / 3.6),
    windspeedMiles: roundedTemp(current.wind_speed_10m * 0.621371),
    humidity: roundedTemp(current.relative_humidity_2m),
    openMeteoWeatherCode: current.weather_code,
    isDay: current.is_day
  }
}

// Today's sunrise/sunset, normalized to 24h "HH:MM". Prefers Open-Meteo
// daily (location-local via timezone=auto), falls back to wttr.in astronomy.
function wttrClockTo24h(value) {
  var s = String(value || "").replace(/^\s+|\s+$/g, "")
  if (s === "") return ""
  var m = s.match(/^(\d{1,2}):(\d{2})\s*([AP])\.?\s*M\.?$/i)
  if (!m) return s
  var h = parseInt(m[1], 10)
  var suffix = m[3].toUpperCase()
  if (suffix === "P" && h < 12) h += 12
  if (suffix === "A" && h === 12) h = 0
  return ("0" + h).slice(-2) + ":" + m[2]
}

function openMeteoSunTimes(dailyForecastReport) {
  var daily = dailyForecastReport && dailyForecastReport.daily ? dailyForecastReport.daily : null
  if (!daily || !daily.time || !daily.sunrise || !daily.sunset) return null
  // Anchor on the location-local current.time so a searched remote city
  // picks its own today, not the viewer's.
  var anchor = dailyForecastReport.current && dailyForecastReport.current.time
    ? String(dailyForecastReport.current.time).slice(0, 10) : ""
  var idx = 0
  if (anchor !== "") {
    for (var i = 0; i < daily.time.length; i++) {
      if (String(daily.time[i]).slice(0, 10) === anchor) { idx = i; break; }
    }
  }
  if (idx >= daily.sunrise.length || idx >= daily.sunset.length) return null
  return {
    sunrise: String(daily.sunrise[idx]).slice(11, 16),
    sunset: String(daily.sunset[idx]).slice(11, 16)
  }
}

function wttrSunTimes(report) {
  var day = report && report.weather && report.weather[0] ? report.weather[0] : null
  var astro = day && day.astronomy && day.astronomy[0] ? day.astronomy[0] : null
  if (!astro) return null
  return { sunrise: wttrClockTo24h(astro.sunrise), sunset: wttrClockTo24h(astro.sunset) }
}

function sunTimes(report, dailyForecastReport) {
  return openMeteoSunTimes(dailyForecastReport) || wttrSunTimes(report) || { sunrise: "", sunset: "" }
}

// Sky-tinted panel background. The day factor runs 0 (night) .. 1 (midday),
// driven by location-local time vs sunrise/sunset ("HH:MM" 24h). Night hours
// return 0; null when sun times are unknown (caller falls back to theme).
function parseHM(value) {
  var m = String(value || "").match(/^(\d{1,2}):(\d{2})$/)
  if (!m) return null
  var h = parseInt(m[1], 10), min = parseInt(m[2], 10)
  if (h < 0 || h > 23 || min < 0 || min > 59) return null
  return h * 60 + min
}

// Location-local "minutes since midnight". Open-Meteo answers in the
// location's timezone (timezone=auto) and reports utc_offset_seconds, so
// shift UTC wall-clock by the offset. Without an offset (wttr-only path),
// fall back to the viewer's clock as an approximation.
function locationNowMinutes(utcOffsetSeconds, nowMs) {
  var t = Number(nowMs)
  if (!isFinite(t)) t = Date.now()
  var off = Number(utcOffsetSeconds)
  if (isFinite(off)) {
    var d = new Date(t + off * 1000)
    return d.getUTCHours() * 60 + d.getUTCMinutes()
  }
  var local = new Date(t)
  return local.getHours() * 60 + local.getMinutes()
}

var SKY_NIGHT = "#0b1322"
var SKY_DAY = "#79b4e6"
// Muted blue-grey at rise/set. Peaks exactly at sunrise/sunset, fading to
// day blue on the day side and night navy on the night side. Kept close to
// the day color on purpose: real sky overhead barely shifts, only the
// horizon glows, and this card is a flat fill.
var SKY_DUSK = "#527a99"
// Half-width of the transition band around sunrise/sunset, in minutes.
// Outside the band the sky sits flat on day/night; inside it blends
// day -> dusk -> night (evening) or night -> dusk -> day (morning).
var SKY_TWILIGHT_HALF = 60

function skyDayFactor(nowMinutes, sunrise, sunset) {
  var rise = parseHM(sunrise), set = parseHM(sunset)
  if (rise === null || set === null) return null
  var len = set - rise
  if (!(len > 0)) return null
  var now = Number(nowMinutes)
  if (!isFinite(now)) return null
  if (now < rise || now > set) return 0
  var elev = Math.sin(Math.PI * (now - rise) / len)
  if (!(elev > 0)) return 0
  return Math.pow(elev, 0.8)
}

function skySmooth(t) {
  t = Math.max(0, Math.min(1, Number(t)))
  if (!isFinite(t)) return 0
  return t * t * (3 - 2 * t)
}

// Minutes from a to b on a 24h clock, wrapped to [-720, 720).
function skyDeltaMinutes(a, b) {
  var d = Number(b) - Number(a)
  if (!isFinite(d)) return 0
  d = ((d % 1440) + 1440) % 1440
  if (d > 720) d -= 1440
  return d
}

// Full sky color for a location-local time: flat SKY_DAY deep in the day,
// flat SKY_NIGHT deep in the night, warm SKY_DUSK peaking at rise/set.
// Returns "" when sun times are unknown.
function skyColorForTime(nowMinutes, sunrise, sunset, nightHex, dayHex, duskHex, halfWidth) {
  var rise = parseHM(sunrise), set = parseHM(sunset)
  if (rise === null || set === null) return ""
  var now = Number(nowMinutes)
  if (!isFinite(now)) return ""
  var night = nightHex || SKY_NIGHT
  var day = dayHex || SKY_DAY
  var dusk = duskHex || SKY_DUSK
  var w = Number(halfWidth)
  if (!isFinite(w) || w <= 0) w = SKY_TWILIGHT_HALF
  var dayLen = set - rise
  var nightLen = 1440 - dayLen
  if (!(dayLen > 0) || !(nightLen > 0)) return ""
  w = Math.min(w, dayLen / 2, nightLen / 2)

  var dRise = skyDeltaMinutes(rise, now)
  var dSet = skyDeltaMinutes(set, now)
  if (Math.abs(dRise) <= w && Math.abs(dRise) <= Math.abs(dSet)) {
    if (dRise < 0) return mixHex(night, dusk, skySmooth((dRise + w) / w))
    return mixHex(dusk, day, skySmooth(dRise / w))
  }
  if (Math.abs(dSet) <= w) {
    if (dSet < 0) return mixHex(day, dusk, skySmooth((dSet + w) / w))
    return mixHex(dusk, night, skySmooth(dSet / w))
  }
  if (now > rise && now < set) return day
  return night
}

function mixHex(a, b, t) {
  var pa = parseInt(String(a).replace("#", ""), 16)
  var pb = parseInt(String(b).replace("#", ""), 16)
  var r = Math.round(((pa >> 16) & 255) + ((((pb >> 16) & 255) - ((pa >> 16) & 255)) * t))
  var g = Math.round(((pa >> 8) & 255) + ((((pb >> 8) & 255) - ((pa >> 8) & 255)) * t))
  var bl = Math.round((pa & 255) + (((pb & 255) - (pa & 255)) * t))
  function hx(n) { var s = Math.max(0, Math.min(255, n)).toString(16); return s.length < 2 ? "0" + s : s }
  return "#" + hx(r) + hx(g) + hx(bl)
}

function skyColorHex(factor, nightHex, dayHex) {
  var f = Number(factor)
  if (!isFinite(f)) return nightHex || SKY_NIGHT
  f = Math.max(0, Math.min(1, f))
  return mixHex(nightHex || SKY_NIGHT, dayHex || SKY_DAY, f)
}

// WCAG relative luminance + contrast ratio, for picking a readable text
// color on top of the sky tint. Threshold 4.5 = WCAG AA normal text.
function hexLuminance(hex) {
  var v = parseInt(String(hex || "").replace("#", ""), 16)
  if (!isFinite(v)) return 0
  function lin(c) {
    c = c / 255
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
  }
  return 0.2126 * lin((v >> 16) & 255) + 0.7152 * lin((v >> 8) & 255) + 0.0722 * lin(v & 255)
}

function contrastRatio(a, b) {
  var l1 = hexLuminance(a), l2 = hexLuminance(b)
  var hi = Math.max(l1, l2), lo = Math.min(l1, l2)
  return (hi + 0.05) / (lo + 0.05)
}

// "": theme default (tint hidden). Otherwise white unless white fails
// WCAG AA 4.5:1, in which case near-black. Blends sit exactly on the
// threshold, so bias both candidates toward higher contrast: pick whichever
// of white/near-black has the better ratio, as long as it clears 4.5.
var SKY_TEXT_LIGHT = "#ffffff";
var SKY_TEXT_DARK = "#1a1a1a";

function skyTextHex(skyHex, minRatio) {
  if (!skyHex) return ""
  var need = Number(minRatio)
  if (!isFinite(need) || need <= 0) need = 4.5
  var lightR = contrastRatio(SKY_TEXT_LIGHT, skyHex)
  var darkR = contrastRatio(SKY_TEXT_DARK, skyHex)
  var lightOk = lightR >= need, darkOk = darkR >= need
  if (lightOk && darkOk) return lightR >= darkR ? SKY_TEXT_LIGHT : SKY_TEXT_DARK
  if (lightOk) return SKY_TEXT_LIGHT
  if (darkOk) return SKY_TEXT_DARK
  return lightR >= darkR ? SKY_TEXT_LIGHT : SKY_TEXT_DARK
}

function currentIcon(current, fallback) {
  if (!current) return fallback || ""
  if (current.openMeteoWeatherCode !== undefined && current.openMeteoWeatherCode !== null)
    return iconForOpenMeteoCode(current.openMeteoWeatherCode, Number(current.isDay) === 0)
  if (current.weatherCode !== undefined && current.weatherCode !== null)
    return iconForCode(current.weatherCode, false)
  return fallback || ""
}

// wttr.in has no day/night flag. Use its icon only to fill an empty initial
// state, never to replace a day/night-aware icon resolved by Open-Meteo.
function provisionalCurrentIcon(current, resolvedIcon) {
  return resolvedIcon || currentIcon(current, "")
}

function weatherResponseCompletesSave(hasConfiguredCoordinates, source) {
  return hasConfiguredCoordinates ? source === "open-meteo" : source === "wttr"
}

// Next N hours from Open-Meteo's hourly arrays. The response uses the
// location's local time (timezone=auto), so anchor on current.time rather
// than the viewer's clock — they differ when a remote city is searched.
function openMeteoHourlyForecast(dailyForecastReport, maxCount) {
  var hourly = dailyForecastReport && dailyForecastReport.hourly ? dailyForecastReport.hourly : null
  if (!hourly || !hourly.time || !hourly.time.length) return []

  var count = maxCount || 12
  var times = hourly.time
  var anchor = dailyForecastReport.current && dailyForecastReport.current.time
    ? String(dailyForecastReport.current.time) : ""
  var anchorHour = anchor.slice(0, 13)

  var start = 0
  if (anchorHour !== "") {
    for (var i = 0; i < times.length; i++) {
      if (String(times[i]).slice(0, 13) >= anchorHour) { start = i; break; }
    }
  }

  var out = []
  for (var j = start; j < times.length && out.length < count; j++) {
    var t = String(times[j])
    out.push({
      time: t,
      hourLabel: t.slice(11, 16),
      tempC: roundedTemp(hourly.temperature_2m ? hourly.temperature_2m[j] : ""),
      tempF: roundedTemp(celsiusToFahrenheit(hourly.temperature_2m ? hourly.temperature_2m[j] : "")),
      precip: hourly.precipitation_probability ? hourly.precipitation_probability[j] : null,
      precipMm: hourly.precipitation ? hourly.precipitation[j] : null,
      cloud: hourly.cloud_cover ? hourly.cloud_cover[j] : null,
      uv: hourly.uv_index ? hourly.uv_index[j] : null,
      openMeteoWeatherCode: hourly.weather_code ? hourly.weather_code[j] : null,
      isDay: hourly.is_day ? hourly.is_day[j] : 1
    })
  }
  return out
}

// wttr.in fallback (3-hour steps) while Open-Meteo is still in flight.
// Times are location-local "0".."2100"; filter to upcoming entries by the
// viewer's clock as an approximation.
function wttrHourLabel(raw) {
  var n = parseInt(String(raw || "0"), 10)
  if (isNaN(n)) n = 0
  var padded = ("0000" + n).slice(-4)
  return padded.slice(0, 2) + ":" + padded.slice(2, 4)
}

function wttrHourlyForecast(report, maxCount, nowHour) {
  var days = report && report.weather ? report.weather : []
  if (!days.length) return []

  var count = maxCount || 12
  var nowHM = (nowHour !== undefined && nowHour !== null) ? nowHour : -1

  var flat = []
  for (var d = 0; d < days.length; d++) {
    var entries = days[d].hourly || []
    for (var h = 0; h < entries.length; h++) {
      var e = entries[h]
      flat.push({
        time: String((days[d].date || "") + " " + wttrHourLabel(e.time)),
        hourLabel: wttrHourLabel(e.time),
        sortKey: parseInt(String(e.time || "0"), 10),
        dayIndex: d,
        tempC: roundedTemp(e.tempC),
        tempF: roundedTemp(e.tempF),
        precip: e.chanceofrain,
        precipMm: e.precipMM,
        cloud: e.cloudcover,
        uv: e.uvIndex,
        weatherCode: e.weatherCode,
        isDay: 1
      })
    }
  }

  var out = []
  for (var k = 0; k < flat.length && out.length < count; k++) {
    if (flat[k].dayIndex === 0 && nowHM >= 0 && flat[k].sortKey < nowHM) continue
    out.push(flat[k])
  }
  return out
}

function buildHourlyForecast(report, dailyForecastReport, todayString, maxCount, nowHour) {
  var hours = openMeteoHourlyForecast(dailyForecastReport, maxCount)
  if (hours.length > 0) return hours
  return wttrHourlyForecast(report, maxCount, nowHour)
}

function hourlyTemp(hour, useImperial) {
  if (!hour) return ""
  var v = useImperial ? hour.tempF : hour.tempC
  if (v === undefined || v === null || v === "") return ""
  return v + "°"
}

function hourlyPercent(value) {
  if (value === undefined || value === null || value === "") return "—"
  var n = parseFloat(String(value))
  return isNaN(n) ? "—" : String(Math.round(n)) + "%"
}

// Expected precipitation amount for one hour, "" when zero/missing.
// Raw value is mm (Open-Meteo `precipitation`, wttr.in `precipMM`);
// imperial callers get inches. Rounds to display precision first so a
// trace amount that displays as zero stays hidden.
function hourlyPrecipAmount(hour, useImperial) {
  if (!hour) return ""
  var mm = parseFloat(String(hour.precipMm))
  if (isNaN(mm) || mm <= 0) return ""
  if (useImperial) {
    var inches = Math.round(mm / 25.4 * 100) / 100
    if (inches <= 0) return ""
    return String(inches) + "in"
  }
  if (mm >= 10) return String(Math.round(mm)) + "mm"
  var rounded = Math.round(mm * 10) / 10
  if (rounded <= 0) return ""
  return String(rounded) + "mm"
}

// Severity color for the amount suffix only ("0.4mm"), based on raw mm/h.
// "" means none/zero (caller keeps the default dimmed color). Bands follow
// the common light/moderate/heavy hourly-rate split: <2.5 light, <7.5
// moderate, above heavy.
function hourlyPrecipColor(hour, useImperial) {
  if (!hour) return ""
  if (hourlyPrecipAmount(hour, useImperial) === "") return ""
  var mm = parseFloat(String(hour.precipMm))
  if (isNaN(mm) || mm <= 0) return ""
  if (mm < 2.5) return "#38bdf8"
  if (mm < 7.5) return "#3b82f6"
  return "#a855f7"
}

// Combined "Rain 32% · 0.4mm" line; amount suffix omitted when zero/missing.
function hourlyRain(hour, useImperial) {
  if (!hour) return ""
  var base = "Rain " + hourlyPercent(hour.precip)
  var amount = hourlyPrecipAmount(hour, useImperial)
  return amount === "" ? base : base + " · " + amount
}

// Combined "Rain 32% · 0.4mm" line as RichText, with only the amount suffix
// colored. Plain (uncolored) when the amount is zero/missing.
function hourlyRainRich(hour, useImperial) {
  if (!hour) return ""
  var base = "Rain " + hourlyPercent(hour.precip)
  var amount = hourlyPrecipAmount(hour, useImperial)
  if (amount === "") return base
  var color = hourlyPrecipColor(hour, useImperial)
  if (color === "") return base + " · " + amount
  return base + " · " + '<font color="' + color + '">' + amount + "</font>"
}

// Sky-state words from cloud cover %. Wide buckets on purpose: 19% vs 21%
// is noise, not information. Driven off cloud_cover only, so the word and
// the condition icon (from weather_code) always agree on the story.
function hourlySky(value) {
  if (value === undefined || value === null || value === "") return "—"
  var n = parseFloat(String(value))
  if (isNaN(n)) return "—"
  if (n < 12) return "Clear"
  if (n < 37) return "Fair"
  if (n < 62) return "Part cloudy"
  if (n < 87) return "Cloudy"
  return "Overcast"
}

function hourlyUv(value) {
  if (value === undefined || value === null || value === "") return "—"
  var n = parseFloat(String(value))
  return isNaN(n) ? "—" : String(Math.round(n))
}

// Semantic color for the UV row: "" means low/none (caller keeps the
// default dimmed color). Thresholds follow the WHO/EPA bands:
// 3-5 moderate, 6-10 high/very high, 11+ extreme.
function hourlyUvColor(value) {
  if (value === undefined || value === null || value === "") return ""
  var n = parseFloat(String(value))
  if (isNaN(n)) return ""
  var r = Math.round(n)
  if (r >= 11) return "#a855f7"
  if (r >= 6) return "#e5484d"
  if (r >= 3) return "#d9a400"
  return ""
}

// PNG selection for hero/hourly/daily (icons/ dir holds user-supplied PNGs).
// Rules from the user's own mapping:
//
// - 0 clear            -> clear-day/clear-night
// - 1 fair             -> fair-day/fair-night
// - 2 partly cloudy    -> cloudy-day/cloudy-night
// - rain/drizzle codes -> rainy.png when cloud >= 70, else drizzle-day/night
// - 3 overcast         -> overcast.png when cloud >= 70, else cloudy-day/night
// - 95/96/99 thunder   -> thunder.png
// - everything else (snow, fog) -> "" so the caller keeps the glyph fallback.
//
// wttr.in path has no cloud cover; pass -1 to always take the <70 branch.
function pngBasenameForCode(code, cloud, night) {
  var c = parseInt(String(code || "0"), 10)
  var suffix = night ? "-night.png" : "-day.png"
  var cl = parseFloat(String(cloud))
  if (isNaN(cl)) cl = -1
  if (c === 0) return "clear" + suffix
  if (c === 1) return "fair" + suffix
  if (c === 2) return "cloudy" + suffix
  if (c === 95 || c === 96 || c === 99) return "thunder.png"
  if (c === 51 || c === 53 || c === 55 || c === 56 || c === 57 || c === 61
      || c === 63 || c === 65 || c === 66 || c === 67 || c === 80 || c === 81 || c === 82)
    return cl >= 70 ? "rainy.png" : "drizzle" + suffix
  if (c === 3) return cl >= 70 ? "overcast.png" : "cloudy" + suffix
  return ""
}

// Relative icon path for one hourly entry, "" when glyph fallback applies.
function pngForHour(hour) {
  if (!hour) return ""
  if (hour.openMeteoWeatherCode === undefined || hour.openMeteoWeatherCode === null) return ""
  var name = pngBasenameForCode(hour.openMeteoWeatherCode, hour.cloud, Number(hour.isDay) === 0)
  return name === "" ? "" : "icons/" + name
}

// Relative icon path for one forecast day, "" when glyph fallback applies.
// Daily rows are daylight scenes, so always the -day variant.
function pngForDay(day) {
  if (!day) return ""
  if (day.openMeteoWeatherCode === undefined || day.openMeteoWeatherCode === null) return ""
  var name = pngBasenameForCode(day.openMeteoWeatherCode, day.cloudCover, false)
  return name === "" ? "" : "icons/" + name
}

// Relative icon path for the current-conditions hero, "" for glyph fallback.
// Uses cloud_cover at the current hour when available (fallback: -1).
function currentPng(current, dailyForecastReport) {
  if (!current) return ""
  if (current.openMeteoWeatherCode === undefined || current.openMeteoWeatherCode === null) return ""
  var cloud = -1
  var hourly = dailyForecastReport && dailyForecastReport.hourly ? dailyForecastReport.hourly : null
  var anchor = dailyForecastReport && dailyForecastReport.current && dailyForecastReport.current.time
    ? String(dailyForecastReport.current.time).slice(0, 13) : ""
  if (hourly && hourly.time && hourly.cloud_cover && anchor !== "") {
    for (var i = 0; i < hourly.time.length; i++) {
      if (String(hourly.time[i]).slice(0, 13) >= anchor) { cloud = hourly.cloud_cover[i]; break; }
    }
  }
  var name = pngBasenameForCode(current.openMeteoWeatherCode, cloud, Number(current.isDay) === 0)
  return name === "" ? "" : "icons/" + name
}

function hourlyIcon(hour) {
  if (!hour) return ""
  if (hour.openMeteoWeatherCode !== undefined && hour.openMeteoWeatherCode !== null)
    return iconForOpenMeteoCode(hour.openMeteoWeatherCode, Number(hour.isDay) === 0)
  return iconForCode(hour.weatherCode, false)
}

function wttrNextForecastDays(report, todayString) {
  var days = report && report.weather ? report.weather : []
  var result = []
  for (var i = 0; i < days.length && result.length < 3; ++i) {
    if (isFutureForecastDate(days[i].date, todayString)) result.push(days[i])
  }
  return result
}

function buildForecastDays(report, dailyForecastReport, todayString) {
  var days = openMeteoForecastDays(dailyForecastReport, todayString)
  return days.length > 0 ? days : wttrNextForecastDays(report, todayString)
}

function bareTempForDay(day, kind, useImperial) {
  if (!day) return ""
  var v = useImperial
    ? (kind === "max" ? day.maxtempF : day.mintempF)
    : (kind === "max" ? day.maxtempC : day.mintempC)
  if (v === undefined || v === null || v === "") return ""
  return v + "°"
}

function dayIcon(day) {
  if (!day) return ""
  if (day.openMeteoWeatherCode !== undefined && day.openMeteoWeatherCode !== null)
    return iconForOpenMeteoCode(day.openMeteoWeatherCode)
  if (!day.hourly || day.hourly.length === 0) return ""

  var best = day.hourly[0]
  var bestDist = 9999
  for (var i = 0; i < day.hourly.length; ++i) {
    var t = parseInt(String(day.hourly[i].time || "0"), 10)
    var dist = Math.abs(t - 1200)
    if (dist < bestDist) {
      bestDist = dist
      best = day.hourly[i]
    }
  }
  return iconForCode(best.weatherCode, false)
}

function iconForOpenMeteoCode(code, night) {
  var c = parseInt(String(code || "0"), 10)
  if (c === 0) return iconForCode(113, night)
  if (c === 1 || c === 2) return iconForCode(116, night)
  if (c === 3) return iconForCode(119, night)
  if (c === 45 || c === 48) return iconForCode(143, night)
  if (c === 51 || c === 53 || c === 55 || c === 56 || c === 57 || c === 61) return iconForCode(266, night)
  if (c === 63 || c === 65 || c === 66 || c === 67 || c === 80 || c === 81 || c === 82) return iconForCode(308, night)
  if (c === 71 || c === 73 || c === 75 || c === 77 || c === 85 || c === 86) return iconForCode(338, night)
  if (c === 95 || c === 96 || c === 99) return iconForCode(389, night)
  return iconForCode(119, night)
}

function iconForCode(code, night) {
  var c = parseInt(String(code || "0"), 10)
  switch (c) {
    case 113: return night ? "" : ""
    case 116: return night ? "" : ""
    case 119: case 122: return ""
    case 143: case 248: case 260: return night ? "\ue346" : "\ue313"
    case 176: case 263: case 353: return night ? "" : ""
    case 179: case 227: case 230: case 323: case 326: case 368: return night ? "" : ""
    case 182: case 185: case 281: case 284: case 311: case 314:
    case 317: case 320: case 350: case 362: case 365: case 374: case 377: return ""
    case 200: case 386: case 389: case 392: case 395: return ""
    case 266: case 293: case 296: case 299: case 302: case 305: case 308: case 356: case 359: return ""
    case 329: case 332: case 335: case 338: case 371: return ""
    default: return ""
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    parseLocationFile: parseLocationFile,
    wttrLocationQuery: wttrLocationQuery,
    parseGeocodingResults: parseGeocodingResults,
    locationCommit: locationCommit,
    isFutureForecastDate: isFutureForecastDate,
    roundedTemp: roundedTemp,
    celsiusToFahrenheit: celsiusToFahrenheit,
    formatTemp: formatTemp,
    formatWind: formatWind,
    normalizedUnit: normalizedUnit,
    localeUsesImperial: localeUsesImperial,
    countryUsesImperial: countryUsesImperial,
    shouldUseImperial: shouldUseImperial,
    dayName: dayName,
    openMeteoForecastDays: openMeteoForecastDays,
    openMeteoCurrentCondition: openMeteoCurrentCondition,
    pngForHour: pngForHour,
    pngForDay: pngForDay,
    currentPng: currentPng,
    currentIcon: currentIcon,
    provisionalCurrentIcon: provisionalCurrentIcon,
    weatherResponseCompletesSave: weatherResponseCompletesSave,
    wttrNextForecastDays: wttrNextForecastDays,
    buildForecastDays: buildForecastDays,
    bareTempForDay: bareTempForDay,
    wttrClockTo24h: wttrClockTo24h,
    openMeteoSunTimes: openMeteoSunTimes,
    wttrSunTimes: wttrSunTimes,
    sunTimes: sunTimes,
    parseHM: parseHM,
    locationNowMinutes: locationNowMinutes,
    skyDayFactor: skyDayFactor,
    skyDeltaMinutes: skyDeltaMinutes,
    skyColorForTime: skyColorForTime,
    mixHex: mixHex,
    skyColorHex: skyColorHex,
    hexLuminance: hexLuminance,
    contrastRatio: contrastRatio,
    skyTextHex: skyTextHex,
    openMeteoHourlyForecast: openMeteoHourlyForecast,
    wttrHourlyForecast: wttrHourlyForecast,
    buildHourlyForecast: buildHourlyForecast,
    hourlyTemp: hourlyTemp,
    hourlyPercent: hourlyPercent,
    hourlyPrecipAmount: hourlyPrecipAmount,
    hourlyPrecipColor: hourlyPrecipColor,
    hourlyRain: hourlyRain,
    hourlyRainRich: hourlyRainRich,
    hourlySky: hourlySky,
    hourlyUv: hourlyUv,
    hourlyUvColor: hourlyUvColor,
    hourlyIcon: hourlyIcon,
    dayIcon: dayIcon,
    iconForOpenMeteoCode: iconForOpenMeteoCode,
    iconForCode: iconForCode
  }
}
