// KeyboardSnapController transition table (spec §11), as data.
//
// State names: "normal", "maximized", and the named zones "left", "right",
// "top", "bottom", "tl", "tr", "bl", "br". A window snapped into any other
// zone (thirds, custom layouts) counts as "other".
//
// Results:
//   { snap: "<zone>" }               snap into a named zone
//   { maximize: true } / { restore: true } / { minimize: true }
//   { display: "prev"|"next", snap: "<zone>", orRestore?: true }
//   null                             no-op
//
// Assumptions where §11 is silent: Super+Up from a top quarter maximizes and
// Super+Down from a bottom quarter minimizes (as on Windows 11); "other"
// behaves like "normal"; top/bottom halves map Up/Down to maximize/restore.

const LEFT = {
  normal: { snap: "left" }, maximized: { snap: "left" }, other: { snap: "left" },
  left: { display: "prev", snap: "right" },
  right: { restore: true },
  tr: { snap: "tl" }, br: { snap: "bl" },
  tl: { display: "prev", snap: "tr" }, bl: { display: "prev", snap: "br" },
  top: { snap: "left" }, bottom: { snap: "left" },
};

const RIGHT = {
  normal: { snap: "right" }, maximized: { snap: "right" }, other: { snap: "right" },
  right: { display: "next", snap: "left" },
  left: { restore: true },
  tl: { snap: "tr" }, bl: { snap: "br" },
  tr: { display: "next", snap: "tl" }, br: { display: "next", snap: "bl" },
  top: { snap: "right" }, bottom: { snap: "right" },
};

const UP = {
  normal: { maximize: true }, other: { maximize: true },
  maximized: null,
  left: { snap: "tl" }, right: { snap: "tr" },
  bl: { snap: "left" }, br: { snap: "right" },
  tl: { maximize: true }, tr: { maximize: true },
  top: { maximize: true }, bottom: { restore: true },
};

const DOWN = {
  maximized: { restore: true },
  left: { snap: "bl" }, right: { snap: "br" },
  tl: { snap: "left" }, tr: { snap: "right" },
  normal: { minimize: true }, other: { restore: true },
  bl: { minimize: true }, br: { minimize: true },
  top: { restore: true }, bottom: { minimize: true },
};

export const KEY_TABLE = { left: LEFT, right: RIGHT, up: UP, down: DOWN };

export function keyTransition(key, state) {
  const table = KEY_TABLE[key];
  if (!table) return null;
  const s = state in table ? state : "other";
  return table[s] ?? null;
}
