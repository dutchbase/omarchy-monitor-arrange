function isInternalName(name) { return /^(eDP|LVDS|DSI)-/.test(String(name || "")) }

function gcd(a, b) { while (b) { var t = a % b; a = b; b = t } return a }

function normalizeScale(scale) {
  var n = parseFloat(String(scale || ""))
  return isFinite(n) ? String(Math.round(n * 100) / 100) : ""
}

function cleanScale(scale, width, height) {
  var requested = Number(scale)
  var w = Number(width), h = Number(height)
  if (!isFinite(requested) || !isFinite(w) || !isFinite(h) || requested <= 0 || w <= 0 || h <= 0) return ""
  var divisor = gcd(Math.round(w * 120), Math.round(h * 120))
  var units = Math.round(requested * 120)
  if (units > divisor) units = divisor
  while (divisor % units !== 0) units++
  return normalizeScale(units / 120)
}

function availableScales(presets, width, height) {
  if (!Array.isArray(presets) || Number(width) <= 0 || Number(height) <= 0) return presets || []
  var byEffective = {}
  presets.forEach(function(p, i) {
    var requested = Number(p)
    var effective = Number(cleanScale(requested, width, height))
    if (!isFinite(requested) || !isFinite(effective)) return
    var key = normalizeScale(effective)
    var existing = byEffective[key]
    var distance = Math.abs(requested - effective)
    if (!existing || distance < existing.distance) byEffective[key] = { value: String(p), index: i, distance: distance }
  })
  return Object.keys(byEffective).map(function(k) { return byEffective[k] })
    .sort(function(a, b) { return a.index - b.index })
    .map(function(c) { return c.value })
}

// Ported from panels/monitor/Model.js: which preset (if any) cleans to the
// monitor's currently-live scale, so a ComboBox can preselect it.
function matchingScaleIndex(scales, currentScale, width, height) {
  var current = Number(currentScale)
  if (!Array.isArray(scales) || !isFinite(current)) return -1
  var bestIndex = -1, bestDistance = Infinity
  var normalizedCurrent = normalizeScale(current)
  for (var i = 0; i < scales.length; i++) {
    if (cleanScale(scales[i], width, height) !== normalizedCurrent) continue
    var distance = Math.abs(Number(scales[i]) - current)
    if (distance < bestDistance) { bestIndex = i; bestDistance = distance }
  }
  return bestIndex
}

function logicalSize(monitor) {
  var scale = Number(monitor.scale) || 1
  var transform = Number(monitor.transform) || 0
  var w = Number(monitor.width), h = Number(monitor.height)
  if (transform % 2 === 1) { var tmp = w; w = h; h = tmp }
  return { width: w / scale, height: h / scale }
}

function parseMonitors(raw) {
  var list = Array.isArray(raw) ? raw : []
  // Hyprland reports mirrorOf as "none", or as the SOURCE MONITOR'S ID as a
  // string ("0"), even when the config named it (mirror = "eDP-1"). Resolve to a
  // name so the UI can say what it mirrors; leave a dangling ref untouched.
  function mirrorName(ref) {
    if (ref === undefined || ref === null || ref === "" || ref === "none") return ""
    var match = list.filter(function(m) {
      return String(m.id) === String(ref) || m.name === String(ref)
    })[0]
    return match ? match.name : String(ref)
  }
  return list.map(function(m) {
    return {
      name: m.name, description: m.description || m.name,
      x: m.x, y: m.y, width: m.width, height: m.height,
      scale: m.scale, transform: m.transform || 0,
      refreshRate: m.refreshRate, disabled: !!m.disabled, focused: !!m.focused,
      availableModes: m.availableModes || [],
      isInternal: isInternalName(m.name),
      mirroringOf: mirrorName(m.mirrorOf),
      modeString: m.width + "x" + m.height + "@" + m.refreshRate + "Hz"
    }
  })
}

function snapPositionCanvas(dragged, others, thresholdCanvasPx) {
  var dl = dragged.x, dt = dragged.y
  var dr = dl + dragged.width, db = dt + dragged.height
  var dcx = (dl + dr) / 2, dcy = (dt + db) / 2
  var bestX = dl, bestXDist = thresholdCanvasPx
  var bestY = dt, bestYDist = thresholdCanvasPx

  others.forEach(function(o) {
    var ol = o.x, ot = o.y, or_ = ol + o.width, ob = ot + o.height
    var ocx = (ol + or_) / 2, ocy = (ot + ob) / 2
    ;[[dl, ol], [dl, or_], [dr, ol], [dr, or_], [dcx, ocx]].forEach(function(pair) {
      var dist = Math.abs(pair[0] - pair[1])
      if (dist < bestXDist) { bestXDist = dist; bestX = dl + (pair[1] - pair[0]) }
    })
    ;[[dt, ot], [dt, ob], [db, ot], [db, ob], [dcy, ocy]].forEach(function(pair) {
      var dist = Math.abs(pair[0] - pair[1])
      if (dist < bestYDist) { bestYDist = dist; bestY = dt + (pair[1] - pair[0]) }
    })
  })

  return { x: bestX, y: bestY }
}

function groupModesByResolution(availableModes) {
  var byRes = {}, order = [], seen = {}
  ;(availableModes || []).forEach(function(mode) {
    var label = String(mode)
    if (seen[label]) return
    seen[label] = true
    var match = /^(\d+)x(\d+)@([\d.]+)Hz$/.exec(label)
    if (!match) return
    var res = match[1] + "x" + match[2]
    if (!byRes[res]) { byRes[res] = []; order.push(res) }
    byRes[res].push({ label: label, refreshRate: parseFloat(match[3]) })
  })
  return order.map(function(res) {
    return { resolution: res, modes: byRes[res].sort(function(a, b) { return b.refreshRate - a.refreshRate }) }
  })
}

if (typeof module !== "undefined") {
  module.exports = {
    isInternalName: isInternalName,
    normalizeScale: normalizeScale, cleanScale: cleanScale, availableScales: availableScales,
    matchingScaleIndex: matchingScaleIndex,
    logicalSize: logicalSize, parseMonitors: parseMonitors,
    snapPositionCanvas: snapPositionCanvas,
    groupModesByResolution: groupModesByResolution
  }
}
