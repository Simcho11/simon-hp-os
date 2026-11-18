// LayoutRegistry: built-in layouts, custom-layout validation and per-display
// availability (spec §5.1, §5.2). Pure; shared by the Quickshell app and tests.

const T = 1 / 3;

export const BUILTIN_LAYOUTS = [
  { id: "halves-v", name: "Halves", zones: [
    { x: 0, y: 0, w: 0.5, h: 1 }, { x: 0.5, y: 0, w: 0.5, h: 1 }] },
  { id: "halves-h", name: "Top and bottom", zones: [
    { x: 0, y: 0, w: 1, h: 0.5 }, { x: 0, y: 0.5, w: 1, h: 0.5 }] },
  { id: "quarters", name: "Quarters", zones: [
    { x: 0, y: 0, w: 0.5, h: 0.5 }, { x: 0.5, y: 0, w: 0.5, h: 0.5 },
    { x: 0, y: 0.5, w: 0.5, h: 0.5 }, { x: 0.5, y: 0.5, w: 0.5, h: 0.5 }] },
  { id: "thirds", name: "Thirds", thirds: true, zones: [
    { x: 0, y: 0, w: T, h: 1 }, { x: T, y: 0, w: T, h: 1 }, { x: 2 * T, y: 0, w: T, h: 1 }] },
  { id: "two-one", name: "Two-thirds and one-third", thirds: true, zones: [
    { x: 0, y: 0, w: 2 * T, h: 1 }, { x: 2 * T, y: 0, w: T, h: 1 }] },
  { id: "one-two", name: "One-third and two-thirds", thirds: true, zones: [
    { x: 0, y: 0, w: T, h: 1 }, { x: T, y: 0, w: 2 * T, h: 1 }] },
  { id: "main-stack", name: "Main and stack", zones: [
    { x: 0, y: 0, w: 0.5, h: 1 }, { x: 0.5, y: 0, w: 0.5, h: 0.5 }, { x: 0.5, y: 0.5, w: 0.5, h: 0.5 }] },
  { id: "stack-main", name: "Stack and main", zones: [
    { x: 0, y: 0, w: 0.5, h: 0.5 }, { x: 0, y: 0.5, w: 0.5, h: 0.5 }, { x: 0.5, y: 0, w: 0.5, h: 1 }] },
];

// Zones that edge, corner and keyboard snapping use (§8.1): halves and quarters.
export const NAMED_ZONES = {
  left: { layout: "halves-v", index: 0 },
  right: { layout: "halves-v", index: 1 },
  top: { layout: "halves-h", index: 0 },
  bottom: { layout: "halves-h", index: 1 },
  tl: { layout: "quarters", index: 0 },
  tr: { layout: "quarters", index: 1 },
  bl: { layout: "quarters", index: 2 },
  br: { layout: "quarters", index: 3 },
};

const EPS = 0.001;
const MIN_ZONE_W = 400;
const MIN_ZONE_H = 300;
const THIRDS_MIN_WIDTH = 1600;

export function layoutById(id, custom = []) {
  return BUILTIN_LAYOUTS.find(l => l.id === id) || custom.find(l => l.id === id) || null;
}

function isVerticalSplit(layout) {
  // Every zone spans the full height: columns only.
  return layout.zones.every(z => Math.abs(z.y) < EPS && Math.abs(z.h - 1) < EPS) && layout.zones.length > 1;
}

export function rotateLayout(layout) {
  return Object.assign({}, layout, {
    id: `${layout.id}-rotated`,
    name: `${layout.name} (stacked)`,
    zones: layout.zones.map(z => ({ x: z.y, y: z.x, w: z.h, h: z.w })),
  });
}

function sameZones(a, b) {
  if (a.zones.length !== b.zones.length) return false;
  const key = z => [z.x, z.y, z.w, z.h].map(v => v.toFixed(3)).join(",");
  const ka = a.zones.map(key).sort();
  const kb = b.zones.map(key).sort();
  return ka.every((k, i) => k === kb[i]);
}

// Layouts offered for a work area {w, h} in logical pixels (§5.1 filters).
export function availableLayouts(workArea, customLayouts = []) {
  const portrait = workArea.h > workArea.w;
  let layouts = BUILTIN_LAYOUTS.filter(l => !l.thirds || (portrait ? workArea.h : workArea.w) >= THIRDS_MIN_WIDTH);
  if (portrait) {
    layouts = layouts.map(l => (isVerticalSplit(l) ? rotateLayout(l) : l));
    // Drop duplicates created by rotation (halves-v rotated == halves-h), keep the first.
    layouts = layouts.filter((l, i) => layouts.findIndex(o => sameZones(o, l)) === i);
    layouts.sort((a, b) => (a.id.startsWith("halves") ? -1 : 0) - (b.id.startsWith("halves") ? -1 : 0));
  }
  const valid = customLayouts.filter(l => validateLayout(l).ok);
  return [...layouts, ...valid].filter(l =>
    l.zones.every(z => z.w * workArea.w >= MIN_ZONE_W - EPS && z.h * workArea.h >= MIN_ZONE_H - EPS));
}

function overlaps(a, b) {
  return a.x + EPS < b.x + b.w && b.x + EPS < a.x + a.w && a.y + EPS < b.y + b.h && b.y + EPS < a.y + a.h;
}

// Validate a custom layout (§5.2). Returns {ok, errors, warnings}.
export function validateLayout(layout) {
  const errors = [];
  const warnings = [];
  if (!layout || typeof layout !== "object") return { ok: false, errors: ["Layout must be an object"], warnings };
  if (typeof layout.id !== "string" || !layout.id) errors.push("Layout needs a non-empty string \"id\"");
  if (typeof layout.name !== "string" || !layout.name) errors.push("Layout needs a non-empty string \"name\"");
  const zones = Array.isArray(layout.zones) ? layout.zones : null;
  if (!zones) {
    errors.push("Layout needs a \"zones\" array");
    return { ok: false, errors, warnings };
  }
  if (zones.length < 1 || zones.length > 9) errors.push(`Layout must have 1 to 9 zones (has ${zones.length})`);
  zones.forEach((z, i) => {
    const vals = [z?.x, z?.y, z?.w, z?.h];
    if (!vals.every(v => typeof v === "number" && isFinite(v))) {
      errors.push(`Zone ${i + 1}: x, y, w and h must all be numbers`);
      return;
    }
    if (vals.some(v => v < -EPS || v > 1 + EPS)) errors.push(`Zone ${i + 1}: values must be between 0 and 1`);
    if (z.w <= 0 || z.h <= 0) errors.push(`Zone ${i + 1}: width and height must be above 0`);
    if (z.x + z.w > 1 + EPS) errors.push(`Zone ${i + 1}: x + w is more than 1`);
    if (z.y + z.h > 1 + EPS) errors.push(`Zone ${i + 1}: y + h is more than 1`);
  });
  if (errors.length === 0) {
    for (let i = 0; i < zones.length; i++)
      for (let j = i + 1; j < zones.length; j++)
        if (overlaps(zones[i], zones[j])) errors.push(`Zones ${i + 1} and ${j + 1} overlap`);
    const area = zones.reduce((s, z) => s + z.w * z.h, 0);
    if (Math.abs(area - 1) > 0.01) warnings.push(`Zones cover ${(area * 100).toFixed(0)}% of the screen, not all of it`);
  }
  return { ok: errors.length === 0, errors, warnings };
}

// Human-readable position of a zone, for state names and announcements.
export function zoneName(z) {
  const near = (a, b) => Math.abs(a - b) < EPS;
  const col = near(z.w, 1) ? "" : near(z.x, 0) ? "left" : near(z.x + z.w, 1) ? "right" : "centre";
  const row = near(z.h, 1) ? "" : near(z.y, 0) ? "top" : near(z.y + z.h, 1) ? "bottom" : "middle";
  if (!col && !row) return "full screen";
  const frac = z.w * z.h;
  const size = near(frac, 0.5) ? "half" : near(frac, 0.25) ? "quarter" : near(frac, T) ? "third"
    : near(frac, 2 * T) ? "two-thirds" : "zone";
  return [[row, col].filter(Boolean).join("-"), size].join(" ");
}
