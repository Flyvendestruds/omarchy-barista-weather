import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.weather"
  ipcTarget: "omarchy.weather"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    openedFromHotkey = false
    root.controller.show()
    locationFile.reload()
    root.refresh()
  }

  // The stock helper assigns root.bar.centerHoverRevealSuppressed directly,
  // which throws on the readonly PluginBarApi facade clones receive — and
  // the throw aborts close(). Route through the facade setter function only.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    locationFile.reload()
    root.refresh()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.editingLocation) root.cancelEditingLocation()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Parsed wttr.in j1 response. Kept on failure so stale data stays visible.
  property var report: null
  property var dailyForecastReport: null
  property string wttrLocation: ""

  // Configured location, read from the weather.json state file (owned by
  // omarchy-weather-location). The query is the wttr.in path segment
  // (coordinates when stored, else the encoded name); empty means IP
  // auto-detect. The watch makes hand edits take effect live.
  property var configuredLocationState: ({ name: "", latitude: null, longitude: null })
  readonly property string configuredLocation: configuredLocationState.name
  readonly property string locationQuery: Model.wttrLocationQuery(configuredLocationState.name, configuredLocationState.latitude, configuredLocationState.longitude)

  // Keep the previous report visible while the new location loads. The
  // editor remains open with a spinner, so stale data is never presented
  // under the newly configured location label.
  onLocationQueryChanged: {
    if (savingLocation) savingLocationQueryStarted = true
    forecastRetries = 0
    dailyForecastRetries = 0
    forecastProc.running = false
    dailyForecastProc.running = false
    Qt.callLater(refresh)
  }

  property FileView locationFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.configuredLocationState = Model.parseLocationFile(text())
    onLoadFailed: root.configuredLocationState = Model.parseLocationFile("")
  }

  // The first read can race shell startup (observed sporadically), leaving a
  // stored location unhonored until the next file write. One delayed reload
  // self-corrects; if the first read was fine it's a no-op, since identical
  // state doesn't change locationQuery and so triggers no refetch.
  Timer {
    interval: 1500
    running: true
    onTriggered: locationFile.reload()
  }

  property int forecastRetries: 0
  property int dailyForecastRetries: 0

  // Click-to-edit state for the location label.
  property bool editingLocation: false
  property bool savingLocation: false
  property bool savingLocationQueryStarted: false
  property var locationSuggestions: []
  property int suggestionIndex: 0
  property string geocodePendingQuery: ""
  property string geocodeActiveQuery: ""

  // Shared hero/bar icon state, updated with each successful weather response.
  property string label: ""

  // wttr's current conditions when available; open-meteo's (bundled with the
  // much faster daily forecast fetch) fill the hero while wttr is in flight.
  readonly property bool hasConfiguredCoordinates: !isNaN(parseFloat(String(configuredLocationState.latitude))) && !isNaN(parseFloat(String(configuredLocationState.longitude)))
  readonly property var openMeteoCurrent: Model.openMeteoCurrentCondition(dailyForecastReport)
  readonly property var current: (hasConfiguredCoordinates && openMeteoCurrent) ? openMeteoCurrent : ((report && report.current_condition && report.current_condition[0]) ? report.current_condition[0] : openMeteoCurrent)
  readonly property var areaInfo: report && report.nearest_area && report.nearest_area[0] ? report.nearest_area[0] : null
  readonly property var forecastDays: buildForecastDays()
  readonly property var hourlyForecast: buildHourlyForecast()
  readonly property string reportCountry: areaInfo && areaInfo.country && areaInfo.country[0] ? areaInfo.country[0].value : ""

  readonly property bool useImperial: Model.shouldUseImperial(setting("unit", ""), Qt.locale().name, reportCountry)

  // Auto-refresh interval in minutes; clamped to a sane minimum.
  readonly property int refreshMinutes: Math.max(1, parseInt(setting("refreshMinutes", 15), 10) || 15)

  // Sky-tinted card background, following time of day (location-local).
  // skyCardColor "" when sun times are unknown — the tint overlay stays
  // hidden and the card keeps the theme background. skyInk "" likewise
  // means "use theme text colors"; otherwise white, or dark text when white
  // would fail WCAG AA 4.5:1 against the tint. skyClockTick re-evaluates
  // both once a minute so an open panel tracks the sun.
  readonly property var skyUtcOffset: dailyForecastReport && dailyForecastReport.utc_offset_seconds !== undefined
    ? dailyForecastReport.utc_offset_seconds : null
  // Flat day blue deep in the day, flat night navy deep in the night; only
  // the ~1h band around sunrise/sunset moves (peaking warm at rise/set).
  readonly property string skyCardColor: {
    skyClockTick
    var nowMin = Model.locationNowMinutes(skyUtcOffset, Date.now())
    return String(Model.skyColorForTime(nowMin, reportSunrise, reportSunset))
  }
  readonly property string skyInk: skyCardColor === "" ? "" : String(Model.skyTextHex(skyCardColor, 4.5))
  property int skyClockTick: 0
  // Text colors on top of the tint: theme colors while the tint is hidden,
  // else the contrast-picked ink. inkDim() darkens (works both ways: darker
  // light text stays readable on dark skies, darker dark text on light skies).
  function ink() { return skyInk !== "" ? skyInk : bar.foreground }
  function inkDim(f) { return Qt.darker(ink(), f) }
  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: false
    onTriggered: root.skyClockTick++
  }

  readonly property string reportLocation:  configuredLocation || wttrLocation || (areaInfo && areaInfo.areaName && areaInfo.areaName[0] ? areaInfo.areaName[0].value : "")
  readonly property var sun: Model.sunTimes(report, dailyForecastReport)
  readonly property string reportSunrise: sun ? String(sun.sunrise || "") : ""
  readonly property string reportSunset: sun ? String(sun.sunset || "") : ""
  readonly property string reportTempNum:   current ? String(useImperial ? current.temp_F : current.temp_C) : ""
  readonly property string tempUnit:        "°" + (useImperial ? "F" : "C")
  readonly property string reportFeels:     current ? formatTemp(useImperial ? current.FeelsLikeF : current.FeelsLikeC) : ""
  readonly property string reportWind:      current ? Model.formatWind(current, useImperial) : ""
  readonly property string reportHumidity:  current ? (current.humidity + "%") : ""

  function refresh() {
    // Each full refresh cycle gets a fresh retry budget, so an earlier
    // exhausted round (e.g. waking with the network still down) doesn't
    // starve retries for the rest of the session.
    forecastRetries = 0
    dailyForecastRetries = 0
    if (!forecastProc.running) forecastProc.running = true
    if (root.locationQuery === "" && !locationProc.running) locationProc.running = true
    // With stored coordinates this fetches open-meteo right away — no need
    // to wait for the slow wttr response. Without them it's a no-op until
    // wttr reports the detected area.
    refreshDailyForecast(null)
  }

  function refreshDailyForecast(sourceReport) {
    if (dailyForecastProc.running) return

    var lat = parseFloat(String(root.configuredLocationState.latitude))
    var lon = parseFloat(String(root.configuredLocationState.longitude))
    if (isNaN(lat) || isNaN(lon)) {
      var area = sourceReport && sourceReport.nearest_area && sourceReport.nearest_area[0] ? sourceReport.nearest_area[0] : root.areaInfo
      if (!area) return
      lat = parseFloat(String(area.latitude || ""))
      lon = parseFloat(String(area.longitude || ""))
    }
    if (isNaN(lat) || isNaN(lon)) return

    var url = "https://api.open-meteo.com/v1/forecast"
      + "?latitude=" + encodeURIComponent(String(lat))
      + "&longitude=" + encodeURIComponent(String(lon))
      + "&daily=weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,cloud_cover_mean"
      + "&hourly=temperature_2m,precipitation_probability,precipitation,cloud_cover,uv_index,weather_code,is_day"
      + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day"
      + "&forecast_days=4"
      + "&timezone=auto"
    dailyForecastProc.command = ["curl", "-fsS", "--max-time", "5", url]
    dailyForecastProc.running = true
  }

  // ---- Location editing. Clicking the location label swaps it for a search
  //      field; picking a geocoded suggestion persists name + coordinates to
  //      the module's shell.json entry. An empty commit returns to auto.
  function startEditingLocation() {
    editingLocation = true
    savingLocation = false
    savingLocationQueryStarted = false
    locationSuggestions = []
    suggestionIndex = 0
    Qt.callLater(function() {
      locationField.text = root.configuredLocation
      locationField.selectAll()
      locationField.forceActiveFocus()
    })
  }

  function cancelEditingLocation() {
    editingLocation = false
    savingLocation = false
    savingLocationQueryStarted = false
    locationSuggestions = []
    geocodeDebounce.stop()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function commitLocation() {
    var location = Model.locationCommit(locationField.text, locationSuggestions, suggestionIndex)
    if (location.name === "") {
      clearLocation()
      return
    }
    savingLocation = true
    savingLocationQueryStarted = false
    configuredLocationState = {
      name: location.name,
      latitude: location.latitude,
      longitude: location.longitude
    }
    persistLocation(location.name, location.latitude, location.longitude)
  }

  function clearLocation() {
    persistLocation("", null, null)
    wttrLocation = ""
    cancelEditingLocation()
  }

  function pickSuggestion(suggestion) {
    if (!suggestion) return
    savingLocation = true
    savingLocationQueryStarted = false
    configuredLocationState = {
      name: suggestion.name,
      latitude: suggestion.latitude,
      longitude: suggestion.longitude
    }
    persistLocation(suggestion.name, suggestion.latitude, suggestion.longitude)
  }

  function finishSavingLocation() {
    if (savingLocation && savingLocationQueryStarted) cancelEditingLocation()
  }

  function persistLocation(name, latitude, longitude) {
    if (name && latitude !== null && longitude !== null)
      locationSaveProc.command = ["omarchy-weather-location", "--set", name, latitude + "," + longitude]
    else if (name)
      locationSaveProc.command = ["omarchy-weather-location", "--set", name]
    else
      locationSaveProc.command = ["omarchy-weather-location", "--clear"]
    locationSaveProc.running = true
  }

  // Debounced geocoding. Only one curl runs at a time; if the query moved on
  // while a fetch was in flight, the latest query is fetched right after.
  function requestGeocode() {
    var query = locationField.text.trim()
    if (query.length < 2) {
      locationSuggestions = []
      return
    }
    geocodePendingQuery = query
    if (!geocodeProc.running) startGeocode()
  }

  function startGeocode() {
    geocodeActiveQuery = geocodePendingQuery
    geocodeProc.command = ["curl", "-fsS", "--max-time", "5",
      "https://geocoding-api.open-meteo.com/v1/search?name=" + encodeURIComponent(geocodeActiveQuery) + "&count=5&language=en&format=json"]
    geocodeProc.running = true
  }

  function buildForecastDays() {
    return Model.buildForecastDays(report, dailyForecastReport, Qt.formatDate(new Date(), "yyyy-MM-dd"))
  }

  function buildHourlyForecast() {
    var now = new Date()
    var nowHM = now.getHours() * 100 + now.getMinutes()
    return Model.buildHourlyForecast(report, dailyForecastReport, Qt.formatDate(now, "yyyy-MM-dd"), 12, nowHM)
  }

  function openMeteoForecastDays() {
    return Model.openMeteoForecastDays(dailyForecastReport, Qt.formatDate(new Date(), "yyyy-MM-dd"))
  }

  function wttrNextForecastDays() {
    return Model.wttrNextForecastDays(report, Qt.formatDate(new Date(), "yyyy-MM-dd"))
  }

  function isFutureForecastDate(dateString) {
    return Model.isFutureForecastDate(dateString, Qt.formatDate(new Date(), "yyyy-MM-dd"))
  }

  function roundedTemp(value) {
    return Model.roundedTemp(value)
  }

  function celsiusToFahrenheit(value) {
    return Model.celsiusToFahrenheit(value)
  }

  function formatTemp(value) {
    return Model.formatTemp(value, useImperial)
  }

  function dayName(dateString) {
    return Model.dayName(dateString, function(date) { return Qt.formatDate(date, "dddd") })
  }

  // Bare degree value (no unit letter), used in the forecast row.
  function bareTempForDay(day, kind) {
    return Model.bareTempForDay(day, kind, useImperial)
  }

  // PNG path (relative to this file) for hero/hourly/daily, "" = glyph fallback.
  function pngForHour(hour) {
    return Model.pngForHour(hour)
  }

  function pngForDay(day) {
    return Model.pngForDay(day)
  }

  function currentPng() {
    return Model.currentPng(current, dailyForecastReport)
  }

  function hourlyTemp(hour) {
    return Model.hourlyTemp(hour, useImperial)
  }

  function hourlyRain(hour) {
    return Model.hourlyRain(hour, useImperial)
  }

  function hourlySky(value) {
    return Model.hourlySky(value)
  }

  function hourlyUv(value) {
    return Model.hourlyUv(value)
  }

  function hourlyIcon(hour) {
    return Model.hourlyIcon(hour)
  }

  // Representative icon for a forecast day: the hourly entry nearest noon.
  function dayIcon(day) {
    return Model.dayIcon(day)
  }

  function iconForOpenMeteoCode(code) {
    return Model.iconForOpenMeteoCode(code)
  }

  // Mirrors omarchy-weather-icon's wttr.in code → nerd-font glyph mapping.
  function iconForCode(code, night) {
    return Model.iconForCode(code, night)
  }

  Process {
    id: forecastProc
    command: ["curl", "-fsS", "--max-time", "10", "https://wttr.in/" + root.locationQuery + "?format=j1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) {
          root.scheduleForecastRetry()
          return
        }
        try {
          var parsed = JSON.parse(raw)
          root.report = parsed
          if (!root.hasConfiguredCoordinates)
            root.label = Model.provisionalCurrentIcon(parsed.current_condition && parsed.current_condition[0], root.label)
          root.forecastRetries = 0
          if (Model.weatherResponseCompletesSave(root.hasConfiguredCoordinates, "wttr"))
            root.finishSavingLocation()
          // Stored coordinates already drove the fast open-meteo fetch from
          // refresh(); only auto-detect needs the area wttr reported.
          if (isNaN(parseFloat(String(root.configuredLocationState.latitude))))
            root.refreshDailyForecast(parsed)
        } catch (e) {
          // Keep last-good report visible, but try again shortly.
          root.scheduleForecastRetry()
        }
      }
    }
  }

  // wttr.in can be slow or flaky, especially for a location it hasn't
  // cached yet. Retry a few times before leaving it to the refresh timer.
  function scheduleForecastRetry() {
    if (forecastRetries >= 3) return
    forecastRetries++
    forecastRetryTimer.restart()
  }

  Timer {
    id: forecastRetryTimer
    interval: 2500
    onTriggered: if (!forecastProc.running) forecastProc.running = true
  }

  // With configured coordinates this fetch is the only thing that updates the
  // bar icon, so a dropped response (e.g. waking before the network is back)
  // must retry rather than wait out the refresh timer with a stale icon.
  function scheduleDailyForecastRetry() {
    if (dailyForecastRetries >= 3) return
    dailyForecastRetries++
    dailyForecastRetryTimer.restart()
  }

  Timer {
    id: dailyForecastRetryTimer
    interval: 2500
    onTriggered: root.refreshDailyForecast(null)
  }

  Process {
    id: dailyForecastProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) {
          root.scheduleDailyForecastRetry()
          return
        }
        try {
          var parsed = JSON.parse(raw)
          var parsedCurrent = Model.openMeteoCurrentCondition(parsed)
          root.dailyForecastReport = parsed
          root.label = Model.currentIcon(parsedCurrent, root.label)
          root.dailyForecastRetries = 0
          if (Model.weatherResponseCompletesSave(root.hasConfiguredCoordinates, "open-meteo"))
            root.finishSavingLocation()
        } catch (e) {
          // Keep last-good daily forecast visible, but try again shortly.
          root.scheduleDailyForecastRetry()
        }
      }
    }
  }

  Process {
    id: geocodeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.locationSuggestions = root.editingLocation ? Model.parseGeocodingResults(text) : []
        root.suggestionIndex = 0
        if (root.geocodePendingQuery !== root.geocodeActiveQuery) Qt.callLater(root.startGeocode)
      }
    }
  }

  Timer {
    id: geocodeDebounce
    interval: 300
    onTriggered: root.requestGeocode()
  }

  Process {
    id: locationSaveProc
    onExited: function(exitCode) {
      if (exitCode !== 0 || !root.savingLocation) return

      // FileView handles changed locations. Explicitly refresh here too so
      // saving the already-active location cannot strand the spinner.
      locationFile.reload()
      if (!root.savingLocationQueryStarted) {
        root.savingLocationQueryStarted = true
        root.forecastRetries = 0
        root.dailyForecastRetries = 0
        forecastProc.running = false
        dailyForecastProc.running = false
        Qt.callLater(root.refresh)
      }
    }
  }

  Process {
    id: locationProc
    command: ["curl", "-fsS", "--max-time", "4", "https://wttr.in/?format=%l"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        root.wttrLocation = raw.split(",")[0]
      }
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function edit(): void { root.openFromHotkey(); root.startEditingLocation() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    // No card padding: the sky tint below paints the card edge-to-edge and
    // the content re-adds the theme popup padding via weatherScroll margins.
    padding: 0
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(weatherColumn.implicitHeight + Style.spacing.popupPadding * 2)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLocation
      onReturnRequested: root.startEditingLocation()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // Sky tint: the card itself, edge-to-edge. The panel carries
      // padding: 0 so this fills the whole BorderSurface card (the stock
      // theme background is covered when sun times are known).
      Rectangle {
        id: skyTint
        anchors.fill: parent
        visible: root.skyCardColor !== ""
        color: root.skyCardColor
        radius: Style.cornerRadius
        opacity: 1.0
      }

      Flickable {
        id: weatherScroll
        anchors.fill: parent
        anchors.topMargin: skyTint.visible ? Style.spacing.popupPadding : 0
        anchors.rightMargin: skyTint.visible ? Style.spacing.popupPadding : 0
        anchors.bottomMargin: skyTint.visible ? Style.spacing.popupPadding : 0
        anchors.leftMargin: skyTint.visible ? Style.spacing.popupPadding : 0
        contentWidth: width
        contentHeight: weatherColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: weatherColumn
          width: weatherScroll.width
          spacing: Style.space(14)

      // ---- Hero row: big icon + temp on the left; location and stats stacked on the right.
      Item {
        width: parent.width
        height: Math.max(heroLeft.height, heroRight.height)

        Row {
          id: heroLeft
          anchors.left: parent.left
          anchors.leftMargin: Style.space(16)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(16)

          Image {
            id: heroIcon
            anchors.verticalCenter: parent.verticalCenter
            visible: root.currentPng() !== ""
            source: root.currentPng() !== "" ? Qt.resolvedUrl(root.currentPng()) : ""
            sourceSize.width: 128
            sourceSize.height: 128
            width: 64
            height: 64
            fillMode: Image.PreserveAspectFit
            smooth: true
          }

          Text {
            visible: root.currentPng() === ""
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 5
            text: root.label || "—"
            color: root.ink()
            font.family: root.bar.fontFamily
            font.features: { "tnum": 1 }
            // Decorative condition emoji; intentionally larger than the
            // Style.font.* scale's displayLarge (28).
            font.pixelSize: 64
          }

          Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              id: tempBig
              textFormat: Text.PlainText
              text: root.reportTempNum || "—"
              color: root.ink()
              font.family: root.bar.fontFamily
              font.features: { "tnum": 1 }
              // Hero temperature read-out; deliberately oversized, outside
              // the Style.font.* scale.
              font.pixelSize: 56
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              text: root.current ? root.tempUnit : ""
              color: root.ink()
              font.family: root.bar.fontFamily
              font.features: { "tnum": 1 }
              font.pixelSize: Style.font.display
              anchors.top: tempBig.top
              anchors.topMargin: Style.space(10)
            }
          }
        }

          Column {
            id: heroRight
            width: Math.max(weatherStats.implicitWidth, sunRow.implicitWidth)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(20)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

          Row {
            visible: !root.editingLocation && root.reportLocation !== ""
            spacing: Style.space(6)

            TapHandler {
              onTapped: root.startEditingLocation()
            }
            HoverHandler {
              cursorShape: Qt.PointingHandCursor
            }

            Text {
              text: ""  // nf-fa-map_marker
              color: root.inkDim(1.4)
              font.family: root.bar.fontFamily
              font.features: { "tnum": 1 }
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              textFormat: Text.PlainText
              text: (root.reportLocation || "")
              color: root.inkDim(1.4)
              font.family: root.bar.fontFamily
              font.features: { "tnum": 1 }
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Row {
            visible: root.editingLocation
            spacing: Style.space(6)

            TextField {
              id: locationField
              width: Style.space(190)
              enabled: !root.savingLocation
              placeholderText: "Search city"
              foreground: root.ink()
              font.family: root.bar.fontFamily
              font.features: { "tnum": 1 }

              onTextChanged: if (root.editingLocation && !root.savingLocation) geocodeDebounce.restart()

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.cancelEditingLocation()
                  event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                  if (root.suggestionIndex < root.locationSuggestions.length - 1) root.suggestionIndex++
                  event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  if (root.suggestionIndex > 0) root.suggestionIndex--
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.commitLocation()
                  event.accepted = true
                }
              }
            }

            // Clear back to IP auto-detect. While a committed location is
            // loading, this same compact affordance becomes a spinner.
            Rectangle {
              width: Style.space(18)
              height: Style.space(18)
              anchors.verticalCenter: parent.verticalCenter
              radius: Math.min(4, Style.cornerRadius)
              color: !root.savingLocation && clearLocationArea.containsMouse ? Style.hoverFillFor(root.ink(), Color.accent) : "transparent"

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: root.savingLocation ? "󰦖" : "✕"
                font.family: root.bar.fontFamily
                font.features: { "tnum": 1 }
                color: root.inkDim(1.4)
                font.pixelSize: Style.font.bodySmall

                RotationAnimator on rotation {
                  running: root.savingLocation
                  from: 0; to: 360
                  duration: 800
                  loops: Animation.Infinite
                }
              }

              MouseArea {
                id: clearLocationArea
                anchors.fill: parent
                enabled: !root.savingLocation
                hoverEnabled: true
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.clearLocation()
              }
            }
          }

          Row {
            id: weatherStats
            visible: !!root.current
            spacing: Style.space(36)

            Column {
              spacing: Style.space(5)
              Text {
                text: "Feels"
                color: root.inkDim(1.5)
                font.family: root.bar.fontFamily
                font.features: { "tnum": 1 }
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                textFormat: Text.PlainText
                text: root.reportFeels
                color: root.ink()
                font.family: root.bar.fontFamily
                font.features: { "tnum": 1 }
                font.pixelSize: Style.font.title
              }
            }

            Column {
              spacing: Style.space(5)
              Text {
                text: "Wind"
                color: root.inkDim(1.5)
                font.family: root.bar.fontFamily
                font.features: { "tnum": 1 }
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                textFormat: Text.PlainText
                text: root.reportWind
                color: root.ink()
                font.family: root.bar.fontFamily
                font.features: { "tnum": 1 }
                font.pixelSize: Style.font.title
              }
            }

            Column {
              spacing: Style.space(5)
              Text {
                text: "Humid"
                color: root.inkDim(1.5)
                font.family: root.bar.fontFamily
                font.features: { "tnum": 1 }
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                textFormat: Text.PlainText
                text: root.reportHumidity
                color: root.ink()
                font.family: root.bar.fontFamily
                font.features: { "tnum": 1 }
                font.pixelSize: Style.font.title
              }
            }
          }

          // Secondary sun times: small de-emphasized text under the main stats.
          Row {
            id: sunRow
            visible: root.reportSunrise !== "" || root.reportSunset !== ""
            spacing: Style.space(16)

            Text {
              visible: root.reportSunrise !== ""
              textFormat: Text.PlainText
              text: "↑ " + root.reportSunrise
              color: root.inkDim(1.6)
              font.family: root.bar.fontFamily
              font.features: { "tnum": 1 }
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              visible: root.reportSunset !== ""
              textFormat: Text.PlainText
              text: "↓ " + root.reportSunset
              color: root.inkDim(1.6)
              font.family: root.bar.fontFamily
              font.features: { "tnum": 1 }
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }

      // ---- Geocoding suggestions while the location is being edited.
      Column {
        visible: root.editingLocation && !root.savingLocation && root.locationSuggestions.length > 0
        width: parent.width
        spacing: 0

        Repeater {
          model: root.locationSuggestions

          Rectangle {
            required property var modelData
            required property int index
            width: parent.width
            height: suggestionRow.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: index === root.suggestionIndex ? Style.hoverFillFor(root.ink(), Color.accent) : "transparent"

            Row {
              id: suggestionRow
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: modelData.name
                color: index === root.suggestionIndex ? Style.hoverStateColor(root.ink(), Color.accent) : root.ink()
                font.family: root.bar.fontFamily
                font.features: { "tnum": 1 }
                font.pixelSize: Style.font.body
              }
              Text {
                textFormat: Text.PlainText
                visible: text !== ""
                text: modelData.description
                color: root.inkDim(1.5)
                font.family: root.bar.fontFamily
                font.features: { "tnum": 1 }
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onPositionChanged: root.suggestionIndex = index
              onClicked: root.pickSuggestion(modelData)
            }
          }
        }
      }

      Text {
        visible: !root.current
        text: "Fetching forecast…"
        color: root.inkDim(1.5)
        font.family: root.bar.fontFamily
        font.features: { "tnum": 1 }
        font.pixelSize: Style.font.bodySmall
        font.italic: true
      }

      // ---- Divider between current conditions and forecast.
      Rectangle {
        visible: root.hourlyForecast.length > 0 || root.forecastDays.length > 0
        width: parent.width
        height: Style.spacing.hairline
        color: root.ink()
        opacity: 0.12
      }

      // ---- Hourly strip: next 12 hours (temp, rain, cloud, UV) above the 3-day row.
      Item {
        visible: root.hourlyForecast.length > 0
        width: parent.width
        height: hourlyColumn.height

        Column {
          id: hourlyColumn
          width: parent.width
          spacing: Style.space(8)

          Flickable {
            width: parent.width
            height: hourlyRow.height
            contentWidth: hourlyRow.width + Style.space(32)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.HorizontalFlick
            interactive: contentWidth > width

            Row {
              id: hourlyRow
              x: Style.space(16)
              spacing: Style.space(20)

              Repeater {
                model: root.hourlyForecast

                Column {
                  required property var modelData
                  width: Style.space(92)
                  spacing: Style.space(3)

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: modelData.hourLabel
                    color: root.inkDim(1.4)
                    font.family: root.bar.fontFamily
                    font.features: { "tnum": 1 }
                    font.pixelSize: Style.font.caption
                  }
                  Item {
                    width: parent.width
                    height: 28
                    Image {
                      anchors.centerIn: parent
                      visible: root.pngForHour(modelData) !== ""
                      source: root.pngForHour(modelData) !== "" ? Qt.resolvedUrl(root.pngForHour(modelData)) : ""
                      sourceSize.width: 56
                      sourceSize.height: 56
                      width: 28
                      height: 28
                      fillMode: Image.PreserveAspectFit
                      smooth: true
                    }
                    Text {
                      anchors.centerIn: parent
                      visible: root.pngForHour(modelData) === ""
                      textFormat: Text.PlainText
                      text: root.hourlyIcon(modelData)
                      color: root.ink()
                      font.family: root.bar.fontFamily
                      font.features: { "tnum": 1 }
                      font.pixelSize: Style.font.title
                    }
                  }
                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: root.hourlyTemp(modelData)
                    color: root.ink()
                    font.family: root.bar.fontFamily
                    font.features: { "tnum": 1 }
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: root.hourlyRain(modelData)
                    color: root.inkDim(1.5)
                    font.family: root.bar.fontFamily
                    font.features: { "tnum": 1 }
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: root.hourlySky(modelData.cloud)
                    color: root.inkDim(1.5)
                    font.family: root.bar.fontFamily
                    font.features: { "tnum": 1 }
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: "UV " + root.hourlyUv(modelData.uv)
                    color: root.inkDim(1.5)
                    font.family: root.bar.fontFamily
                    font.features: { "tnum": 1 }
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }
          }
        }
      }

      // ---- Divider between the hourly strip and the 3-day forecast.
      Rectangle {
        visible: root.hourlyForecast.length > 0 && root.forecastDays.length > 0
        width: parent.width
        height: Style.spacing.hairline
        color: root.ink()
        opacity: 0.12
      }

      // ---- Forecast row: each cell has the day icon left of a day-name + hi/lo column.
      //      Wrapped in an Item so the block of cells can be centered within the popup.
      Item {
        visible: root.forecastDays.length > 0
        width: parent.width
        height: forecastRow.height

        Row {
          id: forecastRow
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(44)

          Repeater {
            model: root.forecastDays

            Row {
              required property var modelData
              required property int index
              spacing: Style.space(10)

              Image {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.pngForDay(modelData) !== ""
                source: root.pngForDay(modelData) !== "" ? Qt.resolvedUrl(root.pngForDay(modelData)) : ""
                sourceSize.width: 64
                sourceSize.height: 64
                width: 32
                height: 32
                fillMode: Image.PreserveAspectFit
                smooth: true
              }

              Text {
                visible: root.pngForDay(modelData) === ""
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: root.dayIcon(modelData)
                color: root.ink()
                font.family: root.bar.fontFamily
                font.features: { "tnum": 1 }
                font.pixelSize: Style.font.display
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: root.dayName(modelData.date)
                  color: root.inkDim(1.4)
                  font.family: root.bar.fontFamily
                  font.features: { "tnum": 1 }
                  font.pixelSize: Style.font.caption
                }

                Row {
                  spacing: Style.space(6)

                  Text {
                    textFormat: Text.PlainText
                    text: root.bareTempForDay(modelData, "max")
                    color: root.ink()
                    font.family: root.bar.fontFamily
                    font.features: { "tnum": 1 }
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.bareTempForDay(modelData, "min")
                    color: root.inkDim(1.5)
                    font.family: root.bar.fontFamily
                    font.features: { "tnum": 1 }
                    font.pixelSize: Style.font.body
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  }
  }

}
