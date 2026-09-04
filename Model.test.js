// Model.test.js
const assert = require("assert")
const fs = require("fs")
const path = require("path")
const Model = require("./Model.js")

const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures/monitors.json"), "utf8"))

assert.strictEqual(Model.isInternalName("eDP-1"), true)
assert.strictEqual(Model.isInternalName("DP-7"), false)
assert.strictEqual(Model.isInternalName("LVDS-1"), true)

// 1.5 isn't a "clean" divisor of 2560x1440's logical-pixel grid, so it rounds
// up to 1.6 -- verified by actually running this function, not assumed (an
// earlier draft of this test asserted "1.5" here and was simply wrong).
assert.strictEqual(Model.cleanScale(1.5, 2560, 1440), "1.6")
assert.strictEqual(Model.cleanScale(1.33, 2560, 1440), "1.33") // already clean, passes through unchanged

assert.strictEqual(Model.matchingScaleIndex(["1", "1.25", "1.6"], 1.6, 2560, 1440), 2)
assert.strictEqual(Model.matchingScaleIndex(["1", "1.25", "1.6"], 9.9, 2560, 1440), -1)

assert.deepStrictEqual(Model.logicalSize({ width: 3840, height: 2160, scale: 1.6, transform: 0 }), { width: 2400, height: 1350 })
assert.deepStrictEqual(Model.logicalSize({ width: 3840, height: 2160, scale: 1.6, transform: 1 }), { width: 1350, height: 2400 })
assert.deepStrictEqual(Model.logicalSize({ width: 3840, height: 2160, scale: 1.6, transform: 3 }), { width: 1350, height: 2400 })
assert.deepStrictEqual(Model.logicalSize({ width: 3840, height: 2160, scale: 1.6, transform: 2 }), { width: 2400, height: 1350 })

const parsed = Model.parseMonitors(fixture)
assert.strictEqual(parsed.length, fixture.length)
assert.ok(parsed.every(m => "name" in m && "x" in m && "scale" in m && "isInternal" in m && "modeString" in m))
assert.ok(parsed.some(m => m.isInternal)) // this machine has a laptop panel

const snapped = Model.snapPositionCanvas({ x: 195, y: 0, width: 200, height: 100 }, [{ x: 0, y: 0, width: 200, height: 100 }], 10)
assert.strictEqual(snapped.x, 200)

const grouped = Model.groupModesByResolution(["1920x1080@60.00Hz", "1920x1080@60.00Hz", "1920x1080@59.94Hz", "2560x1440@60.00Hz"])
const res1080 = grouped.find(g => g.resolution === "1920x1080")
assert.strictEqual(grouped.length, 2)
assert.strictEqual(res1080.modes.length, 2)
assert.ok(res1080.modes.some(m => m.refreshRate === 59.94))

console.log("All Model.js tests passed")

assert.doesNotThrow(function() { Model.parseMonitors(null) })
assert.strictEqual(Model.parseMonitors(null).length, 0)

// snapPositionCanvas with a negative dragged position (dragging an external
// monitor to the left of/above the fixed internal panel's canvas origin,
// which is expected and legal now that nothing re-zeroes the layout).
const snappedNegative = Model.snapPositionCanvas(
  { x: -205, y: 0, width: 200, height: 100 },
  [{ x: 0, y: 0, width: 200, height: 100 }],
  10
)
assert.strictEqual(snappedNegative.x, -200)

assert.doesNotThrow(function() { Model.groupModesByResolution(["garbage", null, "1920x1080@60.00Hz"]) })
assert.strictEqual(Model.groupModesByResolution(["garbage", "1920x1080@60.00Hz"]).length, 1)

// mirroringOf resolves Hyprland's id-or-name reference to a readable name.
const mirrorCases = Model.parseMonitors([
  { name: "eDP-1", id: 0, mirrorOf: "none" },
  { name: "DP-1",  id: 1, mirrorOf: "0" },      // id form — what hyprctl actually reports
  { name: "DP-9",  id: 9, mirrorOf: "eDP-1" },  // name form
  { name: "DP-8",  id: 8, mirrorOf: "7" },      // dangling reference passes through
  { name: "DP-7",  id: 2 },                     // field absent entirely
])
assert.strictEqual(mirrorCases.find(m => m.name === "eDP-1").mirroringOf, "")
assert.strictEqual(mirrorCases.find(m => m.name === "DP-1").mirroringOf, "eDP-1")
assert.strictEqual(mirrorCases.find(m => m.name === "DP-9").mirroringOf, "eDP-1")
assert.strictEqual(mirrorCases.find(m => m.name === "DP-8").mirroringOf, "7")
assert.strictEqual(mirrorCases.find(m => m.name === "DP-7").mirroringOf, "")
assert.ok(Model.parseMonitors(fixture).every(m => "mirroringOf" in m))

console.log("All edge-case tests passed")
