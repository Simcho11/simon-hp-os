// Geometry: zone → pixel rectangle, size-constraint clamping and shared-edge
// detection (spec §5.3, §10, §12). Pure; all values in logical pixels.

const EPS = 1e-6;

// Round a logical coordinate to the nearest whole physical pixel.
export function toPhysical(v, scale = 1) {
  return Math.round(v * scale) / scale;
}

// Work area wa {x, y, w, h}, zone fractions z {x, y, w, h}, gap g (lp).
// Adjacent zones share exactly the same rounded boundary, then each edge is
// inset by g on the work-area boundary and g/2 on interior edges, giving a
// uniform g everywhere.
export function zoneToRect(wa, z, gap = 0, scale = 1) {
  let left = toPhysical(wa.x + z.x * wa.w, scale);
  let right = toPhysical(wa.x + (z.x + z.w) * wa.w, scale);
  let top = toPhysical(wa.y + z.y * wa.h, scale);
  let bottom = toPhysical(wa.y + (z.y + z.h) * wa.h, scale);
  if (gap > 0) {
    left += z.x <= EPS ? gap : gap / 2;
    right -= z.x + z.w >= 1 - EPS ? gap : gap / 2;
    top += z.y <= EPS ? gap : gap / 2;
    bottom -= z.y + z.h >= 1 - EPS ? gap : gap / 2;
  }
  return { x: left, y: top, w: right - left, h: bottom - top };
}

// Fit a window with constraints {minW, minH, maxW, maxH, aspect} into rect,
// a zone rectangle produced from zone fractions z (§10). Missing constraints
// are ignored. Min size wins over the zone and anchors to the zone's outer
// edge; max size centres the window in the zone.
export function clampToConstraints(rect, z, c = {}) {
  let { x, y, w, h } = rect;
  const touchesRight = z.x + z.w >= 1 - EPS && z.x > EPS;
  const touchesBottom = z.y + z.h >= 1 - EPS && z.y > EPS;

  if (c.aspect > 0) {
    const fitW = Math.min(w, h * c.aspect);
    const fitH = fitW / c.aspect;
    x += (w - fitW) / 2;
    y += (h - fitH) / 2;
    w = fitW;
    h = fitH;
  }
  if (c.maxW > 0 && w > c.maxW) { x += (w - c.maxW) / 2; w = c.maxW; }
  if (c.maxH > 0 && h > c.maxH) { y += (h - c.maxH) / 2; h = c.maxH; }
  if (c.minW > 0 && w < c.minW) { if (touchesRight) x -= c.minW - w; w = c.minW; }
  if (c.minH > 0 && h < c.minH) { if (touchesBottom) y -= c.minH - h; h = c.minH; }
  return { x, y, w, h };
}

// Find edges shared between rects (§12). Two rects share a vertical edge when
// one's right side meets the other's left side within tol (after allowing for
// the gap) and they overlap vertically. Returns [{a, b, axis, pos}] where a is
// the left/top window and b the right/bottom one.
export function sharedEdges(rects, gap = 0, tol = 2) {
  const edges = [];
  for (let i = 0; i < rects.length; i++) {
    for (let j = 0; j < rects.length; j++) {
      if (i === j) continue;
      const a = rects[i];
      const b = rects[j];
      const vOverlap = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y);
      const hOverlap = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
      if (vOverlap > 0 && Math.abs(a.x + a.w + gap - b.x) <= tol)
        edges.push({ a: i, b: j, axis: "x", pos: a.x + a.w + gap / 2 });
      if (hOverlap > 0 && Math.abs(a.y + a.h + gap - b.y) <= tol)
        edges.push({ a: i, b: j, axis: "y", pos: a.y + a.h + gap / 2 });
    }
  }
  return edges;
}

// Is rect at least `fraction` visible inside any of the areas?
export function visibleFraction(rect, areas) {
  let best = 0;
  for (const a of areas) {
    const w = Math.min(rect.x + rect.w, a.x + a.w) - Math.max(rect.x, a.x);
    const h = Math.min(rect.y + rect.h, a.y + a.h) - Math.max(rect.y, a.y);
    if (w > 0 && h > 0) best = Math.max(best, (w * h) / (rect.w * rect.h));
  }
  return best;
}

// Restore-geometry validity (§9): keep the rect if it is at least half visible
// on some work area, otherwise centre it on `fallback` at its size, clamped.
export function validRestoreRect(rect, areas, fallback) {
  if (visibleFraction(rect, areas) >= 0.5) return rect;
  const w = Math.min(rect.w, fallback.w);
  const h = Math.min(rect.h, fallback.h);
  return { x: fallback.x + (fallback.w - w) / 2, y: fallback.y + (fallback.h - h) / 2, w, h };
}

export function rectsEqual(a, b, tol = 2) {
  return a && b && Math.abs(a.x - b.x) <= tol && Math.abs(a.y - b.y) <= tol &&
    Math.abs(a.w - b.w) <= tol && Math.abs(a.h - b.h) <= tol;
}
