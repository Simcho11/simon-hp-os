// HitTester for drag-to-snap (spec §6.2), adapted to niri.
//
// niri does not expose the pointer during a window drag, so this works from the
// dragged WINDOW's rectangle instead: the title bar is under the pointer, so a
// window whose left edge reaches the screen's left edge (or is pushed past it)
// stands in for "pointer within T of the left edge", and a window whose top
// reaches the top edge stands in for the top edge. The pointer's horizontal
// position along the title bar is unknown, so the top-centre picker trigger
// uses the window's centre. Bottom corners need the title bar near the bottom
// edge. All values in logical pixels, relative to the output.

export const EDGE_T = 8;          // edge threshold
export const TITLE_H = 40;        // assumed title-bar height (pointer lies within it)

// rect: window {x, y, w, h}; out: {w, h} output size; settings: snap settings.
// Returns null or { kind: "zone", name } | { kind: "maximize" } | { kind: "picker" }.
export function dragTarget(rect, out, settings) {
  if (!settings.snapEnabled || !rect) return null;
  const atLeft = rect.x <= EDGE_T;
  const atRight = rect.x + rect.w >= out.w - EDGE_T;
  const atTop = rect.y <= EDGE_T;
  const titleAtBottom = rect.y + TITLE_H >= out.h - EDGE_T;
  const portrait = out.h > out.w;

  if (settings.cornerSnap) {
    if (atLeft && atTop) return zone("tl");
    if (atRight && atTop) return zone("tr");
    if (atLeft && titleAtBottom) return zone("bl");
    if (atRight && titleAtBottom) return zone("br");
  }
  if (settings.edgeSnap) {
    if (portrait) {
      if (titleAtBottom) return zone("bottom");
    } else {
      if (atLeft) return zone("left");
      if (atRight) return zone("right");
    }
  }
  if (atTop) {
    const centreX = rect.x + rect.w / 2;
    const inPickerBand = centreX >= out.w * 0.25 && centreX <= out.w * 0.75;
    if (settings.layoutPickerOnDrag && inPickerBand) return { kind: "picker" };
    if (portrait && settings.edgeSnap) return zone("top");
    if (settings.topEdgeMaximize) return { kind: "maximize" };
  }
  return null;
}

function zone(name) {
  return { kind: "zone", name };
}

export function sameTarget(a, b) {
  if (!a || !b) return a === b;
  return a.kind === b.kind && a.name === b.name;
}

// ---- pointer-based targets (patched niri reports the pointer during drags) ----
//
// Spec §6.2 as written: within T of a display edge snaps; corners are within T of
// one edge and within C of the other; the top edge maximizes (or opens the picker
// in its centre band when layoutPickerOnDrag is on). p: pointer within the output.
export const CORNER_C = 48;

export function pointerTarget(p, out, settings) {
  if (!settings.snapEnabled || !p || !out) return null;
  const T = EDGE_T;
  const C = CORNER_C;
  const nearL = p.x <= T, nearR = p.x >= out.w - T, nearT = p.y <= T, nearB = p.y >= out.h - T;
  const inL = p.x <= C, inR = p.x >= out.w - C, inT = p.y <= C, inB = p.y >= out.h - C;
  const portrait = out.h > out.w;

  if (settings.cornerSnap) {
    if ((nearL && inT) || (nearT && inL)) return zone("tl");
    if ((nearR && inT) || (nearT && inR)) return zone("tr");
    if ((nearL && inB) || (nearB && inL)) return zone("bl");
    if ((nearR && inB) || (nearB && inR)) return zone("br");
  }
  if (settings.edgeSnap) {
    if (portrait) {
      if (nearB) return zone("bottom");
    } else {
      if (nearL) return zone("left");
      if (nearR) return zone("right");
    }
  }
  if (nearT) {
    const inPickerBand = p.x >= out.w * 0.25 && p.x <= out.w * 0.75;
    if (settings.layoutPickerOnDrag && inPickerBand) return { kind: "picker" };
    if (portrait && settings.edgeSnap) return zone("top");
    if (settings.topEdgeMaximize) return { kind: "maximize" };
  }
  return null;
}
