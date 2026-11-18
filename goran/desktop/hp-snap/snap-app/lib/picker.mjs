// Layout-picker keyboard navigation and Fill Assist ordering (spec §7, §8.2).
// Pure. A selection is { li, zi }: layout index and zone index.

const centre = z => ({ x: z.x + z.w / 2, y: z.y + z.h / 2 });

// Nearest zone of `layout` from zone `zi` in direction dir, or -1.
function spatialNeighbour(layout, zi, dir) {
  const from = centre(layout.zones[zi]);
  let best = -1;
  let bestScore = Infinity;
  layout.zones.forEach((z, i) => {
    if (i === zi) return;
    const c = centre(z);
    const dx = c.x - from.x;
    const dy = c.y - from.y;
    const along = { left: -dx, right: dx, up: -dy, down: dy }[dir];
    if (along <= 0.001) return;
    const across = dir === "left" || dir === "right" ? Math.abs(dy) : Math.abs(dx);
    const score = along + 2 * across; // prefer zones straight ahead
    if (score < bestScore) { bestScore = score; best = i; }
  });
  return best;
}

// Move the selection for a key: "left" | "right" | "up" | "down" | "tab" |
// "backtab" | "1".."9". Arrows move within a layout first, then on to the
// next/previous layout; selections never wrap past the ends.
export function pickerMove(layouts, sel, key) {
  if (!layouts.length) return sel;
  const { li, zi } = sel;
  if (/^[1-9]$/.test(key)) {
    const n = Number(key) - 1;
    return n < layouts.length ? { li: n, zi: 0 } : sel;
  }
  if (key === "tab") return li + 1 < layouts.length ? { li: li + 1, zi: 0 } : sel;
  if (key === "backtab") return li > 0 ? { li: li - 1, zi: 0 } : sel;
  if (!["left", "right", "up", "down"].includes(key)) return sel;
  const n = spatialNeighbour(layouts[li], zi, key);
  if (n >= 0) return { li, zi: n };
  if (key === "right" || key === "down")
    return li + 1 < layouts.length ? { li: li + 1, zi: 0 } : sel;
  return li > 0 ? { li: li - 1, zi: layouts[li - 1].zones.length - 1 } : sel;
}

// Fill Assist order (§8.2): largest empty zone first, ties in reading order.
export function fillOrder(zones, emptyIndices) {
  return emptyIndices.slice().sort((a, b) => {
    const za = zones[a];
    const zb = zones[b];
    const area = zb.w * zb.h - za.w * za.h;
    if (Math.abs(area) > 1e-6) return area;
    if (Math.abs(za.y - zb.y) > 1e-6) return za.y - zb.y;
    return za.x - zb.x;
  });
}

// Candidate windows for Fill Assist: not excluded, most recently focused first.
export function fillCandidates(windows, excludeIds) {
  const ts = w => (w.focus_timestamp ? w.focus_timestamp.secs * 1e9 + w.focus_timestamp.nanos : 0);
  return windows.filter(w => !excludeIds.includes(w.id)).sort((a, b) => ts(b) - ts(a));
}
