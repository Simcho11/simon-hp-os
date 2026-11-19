// SnapEngine: SnapStore + KeyboardSnapController + niri glue logic (spec §8,
// §9, §11, §14). Platform-free: it consumes niri event-stream objects and emits
// niri IPC requests through `io.send`, so it runs the same under Quickshell and
// under the Node tests with a fake niri.
//
// Platform assumptions (niri 26.04):
// - Snapped windows are floating windows sized and positioned by IPC. niri's
//   own "maximize" moves a floating window into the tiled layer; we detect
//   that (full width, below full height) and turn it into our maximize.
// - Floating coordinates (tile_pos_in_workspace_view) are relative to the
//   output. The work-area size comes from the UI layer (a layer-shell probe);
//   its origin is measured once per size with niri's CenterWindow (§4).
// - niri exposes no window types, min/max sizes or minimize; see README.

import { zoneToRect, rectsEqual, validRestoreRect } from "./geometry.mjs";
import { BUILTIN_LAYOUTS, NAMED_ZONES, availableLayouts, layoutById, zoneName } from "./layouts.mjs";
import { keyTransition } from "./keyboard.mjs";
import { fillOrder, fillCandidates } from "./picker.mjs";
import { dragTarget, pointerTarget, sameTarget } from "./hittest.mjs";

export const DEFAULT_SETTINGS = {
  snapEnabled: true,
  edgeSnap: true,
  cornerSnap: true,
  topEdgeMaximize: true,
  layoutPickerOnDrag: false,
  layoutPickerOnHover: true,
  fillAssist: true,
  snapGroups: true,
  resizeAdjacent: true,
  windowGap: 0,
  previewDelayMs: 30,
  instantPreviewModifier: "Alt",
  suppressSnapModifier: "Ctrl",
  interiorEdgeSnap: "dwell",
  animations: true,
  customLayouts: [],
};

const SETTLE_MS = 600;     // ignore geometry churn this long after we move a window
const REAPPLY_MS = 100;    // §10: re-apply once for lagging clients
const PROBE_TIMEOUT_MS = 300;
// A work-area origin measured this soon after the work area changed is provisional: niri and the
// probe layer can briefly disagree while exclusive zones settle (seen as origin 0,32 instead of 0,0,
// which put maximized windows 32 px too low, under the dock). It is measured again at the next snap.
const ORIGIN_SETTLE_MS = 3000;
const MAXIMIZE = { x: 0, y: 0, w: 1, h: 1 };
const DRAG_TIMEOUT_MS = 120000; // forget a drag whose drop niri never reported
const MIN_NEIGHBOUR = 150;     // smallest size a shared-edge resize may squeeze a neighbour to
const MINIMIZE_PROBE_MS = 250; // no WindowMinimized by then: this niri can't minimize itself
const RESTORE_NUDGE_MS = 350; // after niri's restore animation (see unminimize)
const RESIZE_SETTLE_MS = 350;  // a border drag counts as finished after this long without movement

export class SnapEngine {
  constructor(io) {
    this.io = io; // { send(obj), now(), schedule(ms, fn), log(...), emit(name, data) }
    this.settings = Object.assign({}, DEFAULT_SETTINGS);
    this.windows = new Map();     // id -> niri window
    this.lastOutput = new Map();  // id -> output of its last workspace (niri reports none mid-drag)
    this.evicted = new Map();     // id -> output it was on before that monitor was unplugged
    this.workspaces = new Map();  // id -> niri workspace
    this.outputs = new Map();     // name -> { x, y, w, h, scale }
    this.workAreas = new Map();   // output -> { w, h }
    this.origins = new Map();     // output -> { key, x, y }
    this.state = new Map();       // id -> { kind: "zone"|"maximized", layoutId, zoneIndex, instanceId, output, rect, custom, prev }
    this.restore = new Map();     // id -> { rect, output }
    this.lastFloat = new Map();   // id -> { rect, output } last seen while floating
    this.pending = new Map();     // id -> { rect, until, reapplied }
    this.instances = new Map();   // instanceId -> { id, output, layoutId, members: Map(zoneIndex -> winId), overrides }
    this.focusedId = null;
    this.nextInstance = 1;
    this.probe = null;
    this.probeQueue = [];
    this.workAreaChangedAt = new Map(); // output -> io.now() of the last work-area change
    this.generation = new Map();  // id -> placement counter (latest wins)
    this.drag = null;             // current drag session (see onDragStart)
    this.resizeGesture = null;    // border drag in progress (see onUserResize)
    this.liveDrag = false;        // true once niri has reported positions mid-drag (patched niri)
    this.minimized = new Map();   // id -> { workspaceId, rect, floating } for windows hp-snap hid, { native } for niri's
    this.nativeMinimize = null;   // true: niri minimizes itself (patched); false: it can't; null: not known yet
  }

  // ---- configuration -------------------------------------------------------

  setSettings(obj) {
    const merged = Object.assign({}, DEFAULT_SETTINGS);
    for (const k of Object.keys(DEFAULT_SETTINGS)) if (obj && k in obj) merged[k] = obj[k];
    merged.windowGap = Math.max(0, Math.min(32, Number(merged.windowGap) || 0));
    this.settings = merged;
    this.io.emit?.("settings", merged);
  }

  setOutputs(outputs) {
    const before = JSON.stringify([...this.outputs.values()]);
    this.outputs.clear();
    for (const [name, o] of Object.entries(outputs || {})) {
      if (!o.logical) continue;
      const l = o.logical;
      this.outputs.set(name, { name, x: l.x, y: l.y, w: l.width, h: l.height, scale: l.scale || 1 });
    }
    // Outputs are re-read on every workspace change; only a real change re-fits windows.
    if (JSON.stringify([...this.outputs.values()]) !== before) this.refitAll();
  }

  setWorkArea(output, w, h) {
    const prev = this.workAreas.get(output);
    if (prev && prev.w === w && prev.h === h) return;
    this.workAreas.set(output, { w, h });
    this.origins.delete(output);
    this.workAreaChangedAt.set(output, this.io.now());
    this.io.log(`work area ${output}: ${w}x${h}`);
    if (prev) this.refitAll(output); // §14: taskbar/dock changes re-fit snapped windows
  }

  // ---- niri events ---------------------------------------------------------

  handleEvent(ev) {
    const [kind, body] = Object.entries(ev)[0] || [];
    switch (kind) {
      case "WorkspacesChanged": {
        const before = this.workspaces;
        this.workspaces = new Map(body.workspaces.map(w => [w.id, w]));
        this.onMonitorsChanged(before);
        break;
      }
      case "WorkspaceActivated":
        for (const w of this.workspaces.values())
          if (w.output === this.workspaces.get(body.id)?.output) w.is_active = w.id === body.id;
        if (body.focused) for (const w of this.workspaces.values()) w.is_focused = w.id === body.id;
        break;
      case "WindowsChanged":
        this.windows = new Map(body.windows.map(w => [w.id, w]));
        for (const w of body.windows) {
          if (w.is_focused) this.focusedId = w.id;
          this.noteFloating(w);
        }
        break;
      case "WindowOpenedOrChanged":
        this.onWindowChanged(body.window);
        break;
      case "WindowLayoutsChanged":
        for (const [id, layout] of body.changes) this.onLayoutChanged(id, layout);
        break;
      case "WindowClosed":
        this.minimized.delete(body.id);
        if (this.drag?.id === body.id) this.endDrag();
        if (this.resizeGesture?.id === body.id) { this.resizeGesture = null; this.io.emit?.("resize-preview", null); }
        this.forget(body.id);
        this.lastOutput.delete(body.id);
        this.windows.delete(body.id);
        this.io.emit?.("windows");
        break;
      case "WindowMinimizeRequested": // first patched niri: reports the button only
        this.stashMinimize(body.id);
        break;
      case "WindowMinimized": // patched niri minimized it itself (animated)
        this.nativeMinimize = true;
        if (this.windows.has(body.id)) {
          this.minimized.set(body.id, { native: true });
          this.io.emit?.("minimized", { id: body.id, title: this.windows.get(body.id).title });
        }
        break;
      case "WindowFocusChanged":
        if (body.id != null && this.minimized.has(body.id)) this.unminimize(body.id);
        this.focusedId = body.id;
        for (const w of this.windows.values()) w.is_focused = w.id === body.id;
        this.io.emit?.("focus", body.id);
        break;
    }
  }

  // A monitor unplugged: niri moves its workspaces onto another monitor as extra, inactive workspaces,
  // so their windows look closed (HP-OS shows no workspace switcher). Like Windows, bring those windows
  // onto that monitor's visible workspace, snapped ones into the same zone there; when the monitor comes
  // back, return them to it.
  onMonitorsChanged(before) {
    if (!before.size) return;  // the first workspace list: nothing changed
    const outputsNow = new Set([...this.workspaces.values()].map(w => w.output));
    const outputsBefore = new Set([...before.values()].map(w => w.output));
    const activeOn = output => [...this.workspaces.values()].find(w => w.output === output && w.is_active);
    for (const win of this.windows.values()) {
      const id = win.id;
      if (this.minimized.has(id) || this.drag?.id === id) continue;
      const was = before.get(win.workspace_id)?.output;
      const now = this.workspaces.get(win.workspace_id)?.output;
      if (!was || !now || was === now || outputsNow.has(was)) continue;
      const target = activeOn(now);
      if (!target) continue;
      this.evicted.set(id, was);
      this.io.log(`monitor ${was} unplugged: window ${id} moved to ${now}`);
      if (target.id !== win.workspace_id)
        this.io.send({ Action: { MoveWindowToWorkspace: { window_id: id, reference: { Id: target.id }, focus: false } } });
      const st = this.state.get(id);
      if (st) st.output = now;
    }
    for (const [id, output] of [...this.evicted]) {
      if (!this.windows.has(id)) { this.evicted.delete(id); continue; }
      if (!outputsNow.has(output) || outputsBefore.has(output)) continue;
      this.evicted.delete(id);
      this.io.log(`monitor ${output} back: window ${id} returned to it`);
      this.io.send({ Action: { MoveWindowToMonitor: { id, output } } });
      const st = this.state.get(id);
      if (st) st.output = output;
    }
    // Snapped windows re-fit once niri has moved them (and reported the new outputs' sizes).
    if ([...this.evicted.keys()].length || outputsNow.size !== outputsBefore.size)
      this.io.schedule(400, () => this.refitAll());
  }

  onWindowChanged(win) {
    const old = this.windows.get(win.id);
    // A window being dragged has no workspace in niri's reports: remember where it was.
    const output = this.workspaces.get(win.workspace_id)?.output ?? this.workspaces.get(old?.workspace_id)?.output;
    if (output) this.lastOutput.set(win.id, output);
    this.windows.set(win.id, win);
    if (win.is_focused) this.focusedId = win.id;
    // niri may report a restored window's focus only here, without WindowFocusChanged.
    if (win.is_focused && this.minimized.has(win.id)) this.unminimize(win.id);
    if (!old) {
      this.noteFloating(win);
      this.io.emit?.("windows");
      // A window that opens maximized starts in the tiled layer, underneath every floating window.
      if (!win.is_floating) this.onLeftFloating(win.id);
      return;
    }
    const wasPlaced = !!old.layout?.tile_pos_in_workspace_view;
    const isPlaced = !!win.layout?.tile_pos_in_workspace_view;
    if (old.is_floating && win.is_floating && wasPlaced && !isPlaced) { this.onDragStart(win.id); return; }
    if (old.is_floating && win.is_floating && !wasPlaced && isPlaced && this.drag?.id === win.id) {
      this.noteFloating(win);
      this.onDrop(win.id);
      return;
    }
    if (old.is_floating && !win.is_floating) this.onLeftFloating(win.id);
    else if (!old.is_floating && win.is_floating && this.probe?.id === win.id && this.probe.stage === "float")
      this.sendProbeCenter();
    else this.onLayoutChanged(win.id, win.layout);
  }

  noteFloating(win) {
    const rect = win.is_floating ? rectOf(win) : null;
    if (rect) this.lastFloat.set(win.id, { rect, output: this.outputOf(win)?.name });
  }

  onLayoutChanged(id, layout) {
    const win = this.windows.get(id);
    if (!win || !layout) return;
    win.layout = layout;
    if (layout.interactive_move_tile_pos) { this.onDragMove(id, layout); return; }
    if (this.probe && this.probe.id === id) {
      const pos = layout.tile_pos_in_workspace_view;
      const start = this.probe.startPos;
      // Only a move at the same size is the centring we asked for; a resize (the window dragged
      // out of full screen, a client resizing itself) would measure a wrong origin.
      if (this.probe.stage === "center" && pos && (!start || pos[0] !== start[0] || pos[1] !== start[1])
          && this.probeSizeKept(layout))
        this.finishProbe(layout);
      return; // the probe's own centring is not a user move
    }
    if (!win.is_floating) return;
    const rect = rectOf(win);
    if (!rect) return; // lifted for a drag: niri reports no position until the drop
    this.noteFloating(win);
    const p = this.pending.get(id);
    if (p) {
      if (rectsEqual(rect, p.rect)) { this.pending.delete(id); return; }
      if (this.io.now() < p.until) return; // our own move is still settling
      this.pending.delete(id);
    }
    const st = this.state.get(id);
    if (!st) return;
    if (rectsEqual(rect, st.rect)) return;
    // The user moved or resized a snapped window.
    const moved = Math.abs(rect.w - st.rect.w) <= 2 && Math.abs(rect.h - st.rect.h) <= 2;
    if (moved) {
      // §9 drag to unsnap: back to the restore size (position follows the drag).
      const r = this.restore.get(id);
      this.io.log(`window ${id} dragged out of ${this.describe(st)}`);
      this.unsnap(id);
      this.restore.delete(id); // it is a normal window again; its next snap saves fresh geometry
      if (r) this.resizeOnly(id, r.rect.w, r.rect.h);
    } else {
      this.onUserResize(id, st, st.rect, rect);
    }
  }

  // §12: the user resized a snapped window. A moved edge shared with other
  // windows in the same layout instance drags their edge along; a moved outer
  // edge leaves the window in its group with a custom zone.
  //
  // Changing any floating window through IPC cancels niri's interactive resize
  // in progress (one per screen), so neighbours are NOT touched mid-drag: the UI
  // shows where they will go ("resize-preview"), and they are moved once the
  // resized window has been still for RESIZE_SETTLE_MS. Each update is computed
  // from the rects at the start of the gesture.
  onUserResize(id, st, old, now) {
    st.rect = now;
    let gesture = this.resizeGesture;
    if (!gesture || gesture.id !== id) {
      if (gesture) this.commitResize(); // a different window: settle the previous one
      gesture = this.resizeGesture = { id, start: old, gen: 0, updates: [], outerMoved: false };
    }
    const gen = ++gesture.gen;
    this.planResize(gesture, st, now);
    this.io.emit?.("resize-preview", gesture.updates.length
      ? { output: st.output, rects: gesture.updates.map(u => u.rect) } : null);
    this.io.schedule(RESIZE_SETTLE_MS, () => {
      if (this.resizeGesture === gesture && gesture.gen === gen) this.commitResize();
    });
  }

  planResize(gesture, st, now) {
    const old = gesture.start;
    const out = this.outputs.get(st.output);
    const inst = st.instanceId != null ? this.instances.get(st.instanceId) : null;
    const wa = out && this.workAreaRect(out);
    gesture.updates = [];
    gesture.wa = wa;
    if (!wa || st.kind !== "zone") return;
    const g = this.settings.windowGap;
    const tol = 3;
    const moves = [
      ["left", old.x, now.x], ["right", old.x + old.w, now.x + now.w],
      ["top", old.y, now.y], ["bottom", old.y + old.h, now.y + now.h],
    ].filter(([, a, b]) => Math.abs(a - b) > 1);
    const outer = {
      left: v => v <= wa.x + g + tol, right: v => v >= wa.x + wa.w - g - tol,
      top: v => v <= wa.y + g + tol, bottom: v => v >= wa.y + wa.h - g - tol,
    };
    gesture.outerMoved = moves.some(([edge, from]) => outer[edge](from));
    if (!this.settings.resizeAdjacent || !inst) return;
    for (const [edge, from, to] of moves) {
      if (outer[edge](from)) continue;
      for (const otherId of inst.members.values()) {
        if (otherId === gesture.id) continue;
        const ost = this.state.get(otherId);
        if (!ost?.rect) continue;
        const prior = gesture.updates.find(u => u.id === otherId);
        const r = Object.assign({}, prior ? prior.rect : ost.rect);
        const vOverlap = Math.min(r.y + r.h, old.y + old.h) - Math.max(r.y, old.y) > 0;
        const hOverlap = Math.min(r.x + r.w, old.x + old.w) - Math.max(r.x, old.x) > 0;
        let changed = false;
        if (edge === "right" && vOverlap && Math.abs(r.x - (from + g)) <= tol) {
          const right = r.x + r.w; r.x = to + g; r.w = right - r.x; changed = true;
        } else if (edge === "left" && vOverlap && Math.abs(r.x + r.w - (from - g)) <= tol) {
          r.w = to - g - r.x; changed = true;
        } else if (edge === "bottom" && hOverlap && Math.abs(r.y - (from + g)) <= tol) {
          const bottom = r.y + r.h; r.y = to + g; r.h = bottom - r.y; changed = true;
        } else if (edge === "top" && hOverlap && Math.abs(r.y + r.h - (from - g)) <= tol) {
          r.h = to - g - r.y; changed = true;
        }
        if (!changed) continue;
        if (r.w < MIN_NEIGHBOUR || r.h < MIN_NEIGHBOUR) continue; // stop at the neighbour's limit
        if (prior) prior.rect = r;
        else gesture.updates.push({ id: otherId, rect: r });
      }
    }
  }

  commitResize() {
    const gesture = this.resizeGesture;
    if (!gesture) return;
    this.resizeGesture = null;
    this.io.emit?.("resize-preview", null);
    const st = this.state.get(gesture.id);
    const wa = gesture.wa;
    if (!st || !wa) return;
    const inst = st.instanceId != null ? this.instances.get(st.instanceId) : null;
    for (const u of gesture.updates) {
      const ost = this.state.get(u.id);
      if (!ost) continue;
      ost.rect = u.rect;
      ost.zone = fractionsOf(u.rect, wa);
      if (inst) inst.overrides = Object.assign({}, inst.overrides, { [ost.zoneIndex]: ost.zone });
      this.apply(u.id, u.rect, false, false); // no focus change
    }
    st.zone = fractionsOf(st.rect, wa);
    if (inst) inst.overrides = Object.assign({}, inst.overrides, { [st.zoneIndex]: st.zone });
    if (!gesture.updates.length && gesture.outerMoved) {
      st.custom = true;
      this.io.log(`window ${gesture.id} resized at an outer edge; zone is now custom`);
    }
  }

  // niri moved a floating window into the tiled layer. Full width but below
  // full height means a maximize request (title-bar double-click / Super+M).
  onLeftFloating(id) {
    const win = this.windows.get(id);
    const out = this.outputOf(win);
    if (!win || !out || !this.settings.snapEnabled) return;
    const check = (tries) => {
      const w = this.windows.get(id);
      if (!w || w.is_floating) return;
      const [tw, th] = w.layout.tile_size;
      if (th >= out.h - 2) {
        this.io.log(`window ${id} went fullscreen`);
        // niri hides the floating windows only while the fullscreen tile has focus; when focus
        // lands on another floating window instead, the video plays behind all of them.
        if (this.focusedId !== id) this.io.send({ Action: { FocusWindow: { id } } });
        return;
      }
      if (tw >= out.w - 2) { this.onMaximizeRequest(id); return; }
      if (tries > 0) this.io.schedule(20, () => check(tries - 1));
    };
    check(15);
  }

  onMaximizeRequest(id) {
    const st = this.state.get(id);
    this.io.send({ Action: { MoveWindowToFloating: { id } } });
    if (st) this.restoreWindow(id); // double-click on a snapped or maximized window restores it (§9)
    else this.maximize(id);
  }

  // ---- commands ------------------------------------------------------------

  command(line) {
    const [cmd, ...args] = String(line).trim().split(/\s+/);
    // Optional trailing window id; defaults to the focused window.
    const idAt = i => (args[i] !== undefined ? Number(args[i]) : this.focusedId);
    switch (cmd) {
      case "key": return this.onKey(args[0], idAt(1));
      case "snap": return this.snapToLayout(idAt(2), args[0], Number(args[1]));
      case "maximize": return this.maximize(idAt(0));
      case "restore": return this.restoreWindow(idAt(0));
      case "state": return this.dump();
      case "group": return this.raiseGroup(idAt(0));
      default: this.io.log(`unknown command: ${line}`); return null;
    }
  }

  stateName(id) {
    const st = this.state.get(id);
    if (!st) return "normal";
    if (st.kind === "maximized") return "maximized";
    if (st.custom) return "other";
    for (const [name, nz] of Object.entries(NAMED_ZONES))
      if (nz.layout === st.layoutId && nz.index === st.zoneIndex) return name;
    return "other";
  }

  onKey(key, id) {
    if (!this.settings.snapEnabled || id == null || !this.windows.has(id)) return null;
    const from = this.stateName(id);
    const t = keyTransition(key, from);
    this.io.log(`Super+${key} on ${id}: ${from} -> ${JSON.stringify(t)}`);
    if (!t) return null;
    if (t.display) {
      const target = this.adjacentOutput(this.outputOf(this.windows.get(id)), t.display);
      if (!target) return null; // no display that way: no-op
      this.io.send({ Action: { MoveWindowToMonitor: { id, output: target.name } } });
      return this.snapNamed(id, t.snap, target.name);
    }
    if (t.snap) return this.snapNamed(id, t.snap);
    if (t.maximize) return this.maximize(id);
    if (t.restore) return this.restoreWindow(id);
    if (t.minimize) return this.minimizeWindow(id);
    return null;
  }

  snapNamed(id, name, outputName) {
    const nz = NAMED_ZONES[name];
    return this.snapToLayout(id, nz.layout, nz.index, outputName);
  }

  // §8 commit: snap window `id` into zone `zoneIndex` of layout `layoutId`.
  snapToLayout(id, layoutId, zoneIndex, outputName, quiet = false) {
    const win = this.windows.get(id);
    if (!win || !this.settings.snapEnabled) return null;
    const layout = this.findLayout(layoutId);
    const zone = layout?.zones[zoneIndex];
    if (!zone) { this.io.log(`no zone ${zoneIndex} in layout ${layoutId}`); return null; }
    const out = outputName ? this.outputs.get(outputName) : this.outputOf(win);
    if (!out) return null;
    this.saveRestore(id);
    const instance = this.joinInstance(id, out.name, layoutId, zoneIndex);
    const st = { kind: "zone", layoutId, zoneIndex, instanceId: instance.id, output: out.name, custom: false };
    this.place(id, out, this.zoneFor(instance, zoneIndex, zone), st);
    this.io.emit?.("snapped", { id, layoutId, zoneIndex, instanceId: instance.id, output: out.name,
      title: win.title, position: zoneName(zone), quiet });
    return st;
  }

  maximize(id) {
    const win = this.windows.get(id);
    const out = win && this.outputOf(win);
    if (!out) return null;
    const prev = this.state.get(id);
    this.saveRestore(id);
    if (prev && prev.kind === "zone") this.leaveInstance(id);
    const st = { kind: "maximized", output: out.name, prev: prev && prev.kind === "zone" ? prev : null };
    this.place(id, out, MAXIMIZE, st);
    this.io.emit?.("snapped", { id, title: win.title, position: "full screen" });
    return st;
  }

  restoreWindow(id) {
    const st = this.state.get(id);
    const win = this.windows.get(id);
    if (!win) return null;
    // §9: unmaximizing returns a window to its zone if that instance survives.
    if (st && st.kind === "maximized" && st.prev && this.instances.has(st.prev.instanceId)) {
      const inst = this.instances.get(st.prev.instanceId);
      if (!inst.members.has(st.prev.zoneIndex))
        return this.snapToLayout(id, st.prev.layoutId, st.prev.zoneIndex, st.prev.output, true);
    }
    const r = this.restore.get(id);
    this.unsnap(id);
    this.restore.delete(id);
    if (!r) return null;
    const out = this.outputs.get(r.output) || this.outputOf(win);
    const areas = [...this.outputs.values()].map(o => this.workAreaRect(o)).filter(Boolean);
    const rect = validRestoreRect(r.rect, areas, this.workAreaRect(out) || r.rect);
    this.apply(id, rect);
    this.io.emit?.("restored", { id, title: win.title });
    return rect;
  }

  // ---- state helpers ---------------------------------------------------------

  saveRestore(id) {
    // §8.1: never overwrite the restore geometry with snapped bounds.
    if (this.state.has(id) || this.restore.has(id)) return;
    // Use the last floating geometry: a window niri just maximized is already
    // tiled, and a tiled window has no windowed geometry of its own.
    const last = this.lastFloat.get(id);
    if (last) { this.restore.set(id, { rect: last.rect, output: last.output }); return; }
    // A window that opened maximized has never floated: restore it to a centred window.
    const out = this.outputOf(this.windows.get(id));
    const wa = out && this.workAreaRect(out);
    if (!wa) return;
    const w = Math.round(wa.w * 0.6), h = Math.round(wa.h * 0.7);
    const rect = { x: wa.x + Math.round((wa.w - w) / 2), y: wa.y + Math.round((wa.h - h) / 2), w, h };
    this.restore.set(id, { rect, output: out.name });
  }

  unsnap(id) {
    this.leaveInstance(id);
    this.state.delete(id);
    this.pending.delete(id);
  }

  forget(id) {
    this.unsnap(id);
    this.restore.delete(id);
    this.lastFloat.delete(id);
    if (this.probe?.id === id) this.probe = null;
  }

  joinInstance(id, output, layoutId, zoneIndex) {
    this.leaveInstance(id);
    let inst = [...this.instances.values()].find(i =>
      i.output === output && i.layoutId === layoutId && !i.members.has(zoneIndex));
    if (!inst) {
      inst = { id: this.nextInstance++, output, layoutId, members: new Map(), overrides: null };
      this.instances.set(inst.id, inst);
    }
    inst.members.set(zoneIndex, id);
    return inst;
  }

  leaveInstance(id) {
    const st = this.state.get(id);
    if (!st || st.instanceId == null) return;
    const inst = this.instances.get(st.instanceId);
    if (!inst) return;
    for (const [z, w] of inst.members) if (w === id) inst.members.delete(z);
    if (inst.members.size === 0) this.instances.delete(inst.id); // §8.1: instance ends when empty
  }

  zoneFor(instance, zoneIndex, zone) {
    return instance.overrides?.[zoneIndex] || zone;
  }

  emptyZones(instanceId) {
    const inst = this.instances.get(instanceId);
    const layout = inst && this.findLayout(inst.layoutId);
    if (!layout) return [];
    return layout.zones.map((z, i) => i).filter(i => !inst.members.has(i));
  }

  // ---- drag to snap (§6.1, adapted) ---------------------------------------------
  //
  // During an interactive move niri lifts the window out of the layout: its
  // position becomes null until the drop, and niri reports nothing in between
  // (no pointer either). So: position -> null on the focused floating window is
  // the drag start (show drop-zone hints, take Esc/Ctrl), and null -> position
  // is the drop, judged from where the window landed (hittest.mjs).

  onDragStart(id) {
    const win = this.windows.get(id);
    const out = this.outputOf(win);
    const start = this.lastFloat.get(id)?.rect;
    if (!win || !out || !start || !this.settings.snapEnabled) return;
    if (this.focusedId !== id && !win.is_focused) return; // the user drags the window under the pointer, which niri focuses
    const st = this.state.get(id);
    // §9 drag to unsnap: the window goes back to its windowed size. niri ignores
    // size changes for a window lifted for a drag, so the restore geometry is
    // kept for the whole drag and applied on drop (the request here is in case
    // niri ever honours it mid-drag).
    const restore = st ? this.restore.get(id) || null : null;
    if (st) {
      this.io.log(`window ${id} dragged out of ${this.describe(st)}`);
      this.unsnap(id);
      if (restore) this.resizeOnly(id, restore.rect.w, restore.rect.h);
    }
    const d = { id, output: out.name, startRect: start, cancelled: false, suppressed: false,
      prevState: st || null, restore };
    this.drag = d;
    this.io.log(`drag ${id} started on ${out.name} (workspace ${win.workspace_id})`);
    this.io.emit?.("drag-start", { id, output: out.name, live: !!this.liveDrag });
    this.io.schedule(DRAG_TIMEOUT_MS, () => { if (this.drag === d) this.endDrag(); });
  }

  onDrop(id) {
    const d = this.drag;
    if (!d || d.id !== id) return null;
    this.endDrag();
    const win = this.windows.get(id);
    const out = this.outputOf(win);
    const rect = rectOf(win);
    if (!rect || !out) return null;
    if (d.cancelled) {
      // §6.1 Esc: back to where the drag started, snapped again if it was.
      const prev = d.prevState;
      if (prev?.kind === "zone") this.snapToLayout(id, prev.layoutId, prev.zoneIndex, prev.output, true);
      else if (prev?.kind === "maximized") this.maximize(id);
      else this.apply(id, d.startRect);
      return "cancelled";
    }
    let target;
    if (d.live) {
      // Patched niri: the cursor chose the target during the drag; only a target
      // whose preview was showing counts (§6.1). The window already shrank.
      target = d.shown && !d.suppressed ? d.target : null;
      if (!target) {
        if (d.restore && !d.shrunk) this.dropWindowed(id, rect, d.restore.rect, out);
        return null;
      }
    } else {
      // Stock niri: judged from where the window landed. A window dragged out of a
      // snap is judged at its windowed size, centred where it landed: as wide as
      // the screen, its edges would otherwise always stick out past the screen edge.
      const judged = d.restore ? centredAt(rect, d.restore.rect) : rect;
      target = d.suppressed ? null : dragTarget(judged, out, this.settings);
      if (!target) {
        if (d.restore) this.dropWindowed(id, rect, d.restore.rect, out);
        return null;
      }
    }
    this.io.log(`drop of ${id} onto ${JSON.stringify(target)}`);
    if (target.kind === "zone") this.snapNamed(id, target.name, out.name);
    else if (target.kind === "maximize") this.maximize(id);
    else if (target.kind === "picker") this.io.emit?.("open-picker", id);
    return target;
  }

  // A snapped window dropped away from any target becomes a normal window at its
  // windowed size, centred where the large one landed (niri doesn't say where it
  // was grabbed), kept on screen.
  dropWindowed(id, dropped, windowed, out) {
    const wa = this.workAreaRect(out) || { x: 0, y: 0, w: out.w, h: out.h };
    let { x, y, w, h } = centredAt(dropped, { w: Math.min(windowed.w, wa.w), h: Math.min(windowed.h, wa.h) });
    x = Math.max(wa.x - w + 100, Math.min(x, wa.x + wa.w - 100)); // keep at least 100 px visible
    y = Math.max(wa.y, Math.min(y, wa.y + wa.h - 60));            // title bar stays reachable
    this.restore.delete(id);
    this.apply(id, { x, y, w, h });
  }

  endDrag() {
    if (!this.drag) return;
    const shown = this.drag.shown;
    this.drag = null;
    if (shown) this.io.emit?.("drag-preview", null);
    this.io.emit?.("drag-end", null);
  }

  // Esc while dragging: on drop the window goes back where the drag started.
  dragCancel() {
    if (!this.drag) return;
    this.drag.cancelled = true;
    this.io.emit?.("drag-state", { cancelled: true, suppressed: this.drag.suppressed });
    this.evalLiveTarget(this.drag);
  }

  // suppressSnapModifier (Ctrl) held or released while dragging.
  dragSuppress(on) {
    if (!this.drag) return;
    this.drag.suppressed = on;
    this.io.emit?.("drag-state", { cancelled: this.drag.cancelled, suppressed: on });
    this.evalLiveTarget(this.drag);
  }

  // ---- live drags (patched niri reports positions mid-drag) -------------------

  onDragMove(id, layout) {
    let d = this.drag;
    if (!d || d.id !== id) {
      this.onDragStart(id);
      d = this.drag;
      if (!d || d.id !== id) return;
    }
    if (!d.live) {
      d.live = true;
      this.liveDrag = true;
      this.io.emit?.("drag-live", { output: d.output });
      // §9: back to the windowed size right away (niri keeps the grab point).
      if (d.restore && !d.shrunk) {
        d.shrunk = true;
        this.resizeOnly(id, d.restore.rect.w, d.restore.rect.h);
      }
    }
    const ptr = layout.interactive_move_pointer_pos;
    if (ptr) {
      const pointer = { x: ptr[0], y: ptr[1] };
      if (!d.pointer) this.io.log(`drag ${id} first pointer ${Math.round(pointer.x)},${Math.round(pointer.y)} on ${d.output}`);
      d.output = this.outputUnderPointer(d, pointer);
      d.pointer = pointer;
    }
    this.queueDesktopSwitch(d);
    this.evalLiveTarget(d);
  }

  // Carrying a window to another desktop (niri keeps a dragged window under the pointer while the desktop changes
  // and drops it on the one showing): hold it at the bottom edge for the desktop below, at the top edge for the one
  // above (the maximize preview shows first; holding on switches instead, so letting go early still maximizes), or
  // over one of the workspace dots at the right edge for that desktop. Holding on at an edge keeps going.
  desktopSwitchZone(d) {
    const out = this.outputs.get(d.output);
    const p = d.pointer;
    if (!out || !p || d.cancelled || p.x < 0 || p.x > out.w) return null;
    const edge = 24;
    if (p.y <= edge) return "up";
    if (p.y >= out.h - edge) return "down";
    const pages = this.desktopPages(d.output);
    const dots = Math.min(10, pages.length);   // up to ten desktops (niri keep-desktops-max-ten.patch)
    if (dots > 1 && p.x >= out.w - edge) {
      // The rail (inir-next IrisWorkspacePages, slider) centres its dots on the right edge, 16 px apart.
      const first = out.h / 2 - dots * 16 / 2;
      const at = Math.floor((p.y - first) / 16);
      if (at >= 0 && at < dots) return `dot:${at}`;
    }
    return null;
  }

  desktopPages(output) {
    return [...this.workspaces.values()]
      .filter(w => w.output === output && !String(w.name || "").startsWith("__"))
      .sort((a, b) => a.idx - b.idx);
  }

  switchDesktopFor(d, zone) {
    const pages = this.desktopPages(d.output);
    const index = pages.findIndex(w => w.is_active);
    if (index < 0) return false;
    let next = null;
    if (zone === "up") next = pages[index - 1];
    else if (zone === "down") next = pages[index + 1];
    else if (zone.startsWith("dot:")) {
      const first = Math.max(0, Math.min(index - 4, pages.length - 10));   // the dots the rail shows
      next = pages[first + Number(zone.slice(4))];
    }
    if (!next || next.is_active) return false;
    this.io.log(`drag ${d.id} carried to desktop ${next.idx} (${zone})`);
    this.io.send({ Action: { FocusWorkspace: { reference: { Id: next.id } } } });
    return true;
  }

  queueDesktopSwitch(d) {
    const zone = this.desktopSwitchZone(d);
    if (zone === d.switchZone) return;
    d.switchZone = zone;
    d.afterSwitch = false;
    if (!zone) { d.switchToken = null; return; }
    const token = d.switchToken = {};
    const fire = () => {
      if (this.drag !== d || d.switchToken !== token || d.cancelled) return;
      if (this.switchDesktopFor(d, zone)) {
        // Still in the zone after the switch: no snap preview here, so letting go just drops it on this desktop.
        d.afterSwitch = true;
        d.target = null;
        d.gen = (d.gen || 0) + 1;
        if (d.shown) { d.shown = false; this.io.emit?.("drag-preview", null); }
      }
      if (zone === "up" || zone === "down") this.io.schedule(900, fire);
    };
    this.io.schedule(zone === "up" ? 1000 : zone === "down" ? 650 : 700, fire);
  }

  // niri reports the pointer relative to the output it is over, without naming it. The pointer
  // moves continuously, so the output it is over is the one where that position lands closest to
  // where it was a moment ago (crossing an edge jumps from x≈width to x≈0 on the neighbour).
  outputUnderPointer(d, pointer) {
    const cur = this.outputs.get(d.output);
    if (!cur || !d.pointer || this.outputs.size < 2) return d.output;
    const gx = cur.x + d.pointer.x, gy = cur.y + d.pointer.y;
    let best = d.output, bestDist = Infinity;
    for (const o of this.outputs.values()) {
      if (pointer.x < -1 || pointer.y < -1 || pointer.x > o.w + 1 || pointer.y > o.h + 1) continue;
      const dist = Math.hypot(o.x + pointer.x - gx, o.y + pointer.y - gy);
      if (dist < bestDist || (dist === bestDist && o.name === d.output)) { best = o.name; bestDist = dist; }
    }
    if (best !== d.output) {
      this.io.log(`drag ${d.id} moved to output ${best}`);
      // The preview belongs to the new screen: re-show it there rather than move it.
      if (d.shown) { d.shown = false; d.target = null; this.io.emit?.("drag-preview", null); }
    }
    return best;
  }

  evalLiveTarget(d) {
    if (!d || !d.live) return;
    const out = this.outputs.get(d.output);
    const target = d.afterSwitch || d.switchZone === "down" || d.suppressed || d.cancelled ? null
      : pointerTarget(d.pointer, out, this.settings);
    if (sameTarget(target, d.target)) return;
    d.target = target;
    const gen = d.gen = (d.gen || 0) + 1;
    if (!target) {
      if (d.shown) { d.shown = false; this.io.emit?.("drag-preview", null); }
      return;
    }
    if (d.shown) { this.emitDragPreview(d); return; } // A -> B: move the preview, no new dwell
    this.io.schedule(Math.max(0, Number(this.settings.previewDelayMs) || 0), () => {
      if (this.drag !== d || d.gen !== gen || !d.target) return;
      d.shown = true;
      this.emitDragPreview(d);
    });
  }

  emitDragPreview(d) {
    const t = d.target;
    let rect = null;
    if (t.kind === "zone") {
      const nz = NAMED_ZONES[t.name];
      rect = this.zoneRectOn(d.output, this.findLayout(nz.layout).zones[nz.index]);
    } else if (t.kind === "maximize") {
      rect = this.zoneRectOn(d.output, MAXIMIZE);
    }
    this.io.log(`drag ${d.id} preview ${t.kind}${t.name ? " " + t.name : ""} on ${d.output} at pointer ${Math.round(d.pointer?.x)},${Math.round(d.pointer?.y)}`);
    this.io.emit?.("drag-preview", { output: d.output, target: t, rect });
  }

  // ---- minimize ------------------------------------------------------------------
  //
  // The patched niri minimizes itself: it animates the window away to a stash workspace and
  // restores it (animated) when anything activates it, and reports WindowMinimized. With
  // other niri builds hp-snap does the same without animation: it moves the window to a
  // "stash" workspace on its screen (as HP-OS's Pocket does); when anything focuses it again
  // (dock, Alt+Tab, window list) it comes straight back to its workspace and position.

  // Super+Down on a normal window.
  minimizeWindow(id) {
    const win = this.windows.get(id);
    if (!win || this.minimized.has(id) || !this.settings.snapEnabled) return null;
    if (this.nativeMinimize === false) return this.stashMinimize(id);
    // Other niri builds refuse this action; if no WindowMinimized follows, stash it ourselves.
    this.io.send({ Action: { MinimizeWindow: { id } } });
    if (!this.nativeMinimize) this.io.schedule(MINIMIZE_PROBE_MS, () => {
      if (this.nativeMinimize || this.minimized.has(id) || !this.windows.has(id)) return;
      this.nativeMinimize = false;
      this.stashMinimize(id);
    });
    return { minimized: true };
  }

  stashMinimize(id) {
    const win = this.windows.get(id);
    if (!win || this.minimized.has(id) || !this.settings.snapEnabled) return null;
    const ws = this.workspaces.get(win.workspace_id);
    if (!ws) return null;
    const stash = this.stashWorkspace(ws.output, id);
    if (!stash || stash.id === ws.id) return null;
    this.minimized.set(id, { workspaceId: ws.id, rect: win.is_floating ? rectOf(win) : null,
      floating: win.is_floating });
    this.io.log(`minimize ${id} -> stash workspace ${stash.idx}`);
    this.io.send({ Action: { MoveWindowToWorkspace: { window_id: id, reference: { Id: stash.id }, focus: false } } });
    this.io.emit?.("minimized", { id, title: win.title });
    return { minimized: true };
  }

  // A workspace on `output` holding only hp-snap-minimized windows, else the empty one niri
  // keeps at the end of the list.
  stashWorkspace(output, exceptId) {
    const onOutput = [...this.workspaces.values()].filter(w => w.output === output);
    const windowsOn = wsId => [...this.windows.values()].filter(w => w.workspace_id === wsId && w.id !== exceptId);
    const stash = onOutput.find(w => {
      const ws = windowsOn(w.id);
      return ws.length > 0 && ws.every(x => this.minimized.has(x.id));
    });
    if (stash) return stash;
    const empty = onOutput.filter(w => windowsOn(w.id).length === 0).sort((a, b) => b.idx - a.idx);
    return empty[0] || null;
  }

  unminimize(id) {
    const m = this.minimized.get(id);
    if (!m) return null;
    this.minimized.delete(id);
    if (m.native) { // niri has already brought it back
      this.nudgeAfterRestore(id);
      this.io.emit?.("unminimized", { id });
      return { restored: true };
    }
    const target = this.workspaces.has(m.workspaceId) ? m.workspaceId : null;
    this.io.log(`restore ${id} -> workspace ${target}`);
    if (target != null)
      this.io.send({ Action: { MoveWindowToWorkspace: { window_id: id, reference: { Id: target }, focus: true } } });
    if (m.floating && m.rect) {
      const st = this.state.get(id);
      this.apply(id, st?.rect || m.rect); // same spot (or zone) as before
    }
    this.io.emit?.("unminimized", { id });
    return { restored: true };
  }

  // Some apps (the Electron-based Claude app) stay frozen after coming back from minimize at a
  // snapped or full size, until their size changes. A 1 px nudge and back wakes them; hp-snap
  // marks both sizes as its own so neither counts as a user resize.
  nudgeAfterRestore(id) {
    const st = this.state.get(id);
    if (!st?.rect) return;
    this.io.schedule(RESTORE_NUDGE_MS, () => {
      if (!this.windows.has(id) || this.minimized.has(id) || this.state.get(id) !== st) return;
      const r = st.rect;
      this.pending.set(id, { rect: { x: r.x, y: r.y, w: r.w, h: r.h - 1 }, until: this.io.now() + SETTLE_MS, reapplied: true });
      this.io.send({ Action: { SetWindowHeight: { id, change: { SetFixed: Math.round(r.h) - 1 } } } });
      this.io.schedule(80, () => {
        if (this.windows.has(id) && this.state.get(id) === st) this.apply(id, st.rect, false, false);
      });
    });
  }

  // §13 (without dock integration): raise every window in this window's group,
  // then focus the one that was focused last.
  raiseGroup(id) {
    const st = this.state.get(id);
    const inst = st && this.instances.get(st.instanceId);
    if (!inst || inst.members.size < 2) return null;
    const members = [...inst.members.values()];
    const ts = w => (w?.focus_timestamp ? w.focus_timestamp.secs * 1e9 + w.focus_timestamp.nanos : 0);
    members.sort((a, b) => ts(this.windows.get(a)) - ts(this.windows.get(b)));
    for (const m of members) this.io.send({ Action: { FocusWindow: { id: m } } });
    return members;
  }

  // ---- queries for the picker and Fill Assist ---------------------------------

  findLayout(layoutId) {
    return layoutById(layoutId, this.settings.customLayouts) ||
      availableLayouts({ w: 1, h: 2 }).find(l => l.id === layoutId) || null; // rotated variants
  }

  layoutsFor(outputName) {
    const out = this.outputs.get(outputName);
    const wa = out && this.workAreaRect(out);
    return wa ? availableLayouts(wa, this.settings.customLayouts) : [];
  }

  zoneRectOn(outputName, zone) {
    const out = this.outputs.get(outputName);
    if (!out) return null;
    return zoneToRect(this.workAreaRect(out), zone, this.settings.windowGap, out.scale);
  }

  // The zone Fill Assist should offer next for an instance, or null (§8.2).
  nextFillZone(instanceId) {
    const inst = this.instances.get(instanceId);
    const layout = inst && this.findLayout(inst.layoutId);
    const empty = this.emptyZones(instanceId);
    if (!layout || !empty.length) return null;
    const zi = fillOrder(layout.zones, empty)[0];
    const zone = this.zoneFor(inst, zi, layout.zones[zi]);
    return { instanceId, layoutId: inst.layoutId, zoneIndex: zi, output: inst.output,
      position: zoneName(zone), rect: this.zoneRectOn(inst.output, zone) };
  }

  fillCandidates(instanceId) {
    const inst = this.instances.get(instanceId);
    const members = inst ? [...inst.members.values()] : [];
    return fillCandidates([...this.windows.values()], members)
      .map(w => ({ id: w.id, title: w.title || w.app_id || `Window ${w.id}`, appId: w.app_id || "" }));
  }

  isPending(id) {
    return this.pending.has(id);
  }

  outputNameOf(id) {
    return this.outputOf(this.windows.get(id))?.name || null;
  }

  // ---- geometry & IPC --------------------------------------------------------

  outputOf(win) {
    if (!win) return null;
    const ws = this.workspaces.get(win.workspace_id);
    return (ws && this.outputs.get(ws.output)) || this.outputs.get(this.lastOutput.get(win.id))
      || [...this.outputs.values()][0] || null;
  }

  adjacentOutput(out, dir) {
    if (!out) return null;
    const overlapsV = o => Math.min(o.y + o.h, out.y + out.h) > Math.max(o.y, out.y);
    const cands = [...this.outputs.values()].filter(o => o !== out && overlapsV(o) &&
      (dir === "prev" ? o.x + o.w <= out.x + 1 : o.x >= out.x + out.w - 1));
    cands.sort((a, b) => (dir === "prev" ? b.x - a.x : a.x - b.x));
    return cands[0] || null;
  }

  workAreaRect(out) {
    if (!out) return null;
    const wa = this.workAreas.get(out.name) || { w: out.w, h: out.h };
    const origin = this.origins.get(out.name);
    return { x: origin?.x ?? 0, y: origin?.y ?? 0, w: wa.w, h: wa.h };
  }

  // Place window `id` into zone fractions on output `out`, measuring the
  // work-area origin first if needed.
  place(id, out, zone, st, focus = true) {
    const go = () => {
      const wa = this.workAreaRect(out);
      const rect = zoneToRect(wa, zone, this.settings.windowGap, out.scale);
      st.rect = rect;
      st.zone = zone;
      this.state.set(id, st);
      this.apply(id, rect, false, focus);
    };
    const wa = this.workAreas.get(out.name);
    const origin = this.origins.get(out.name);
    // A provisional origin serves while the work area may still be settling; the first snap after
    // that measures it again.
    const changed = this.workAreaChangedAt.get(out.name);
    const settling = changed !== undefined && this.io.now() - changed < ORIGIN_SETTLE_MS;
    if (!wa || (origin && origin.key === `${wa.w}x${wa.h}` && (origin.settled || settling))) return go();
    this.startProbe(id, out, go);
  }

  // Measure where the work area starts: CenterWindow centres the window in it.
  // One probe runs at a time; snaps arriving meanwhile wait for it.
  startProbe(id, out, then) {
    const win = this.windows.get(id);
    if (!win) return;
    if (this.probe) { this.probeQueue.push({ id, out, then }); return; }
    this.probe = { id, out, then, stage: win.is_floating ? "center" : "float", startPos: null };
    if (win.is_floating) this.sendProbeCenter();
    else this.io.send({ Action: { MoveWindowToFloating: { id } } }); // centre once it floats
    this.io.schedule(PROBE_TIMEOUT_MS, () => {
      if (this.probe?.id !== id) return;
      // Already centred (no layout change) or no answer: measure from current state.
      const w = this.windows.get(id);
      if (w?.is_floating && w.layout?.tile_pos_in_workspace_view && this.probeSizeKept(w.layout)) this.finishProbe(w.layout);
      else this.endProbe();
    });
  }

  sendProbeCenter() {
    const w = this.windows.get(this.probe.id);
    this.probe.stage = "center";
    this.probe.startPos = w?.layout?.tile_pos_in_workspace_view?.slice() || null;
    this.probe.startSize = w?.layout?.tile_size?.slice() || null;
    this.io.send({ Action: { CenterWindow: { id: this.probe.id } } });
  }

  probeSizeKept(layout) {
    const a = this.probe?.startSize, b = layout?.tile_size;
    return !a || (b && Math.abs(a[0] - b[0]) < 1 && Math.abs(a[1] - b[1]) < 1);
  }

  finishProbe(layout) {
    const { out } = this.probe;
    const wa = this.workAreas.get(out.name);
    const [px, py] = layout.tile_pos_in_workspace_view;
    const [tw, th] = layout.tile_size;
    const x = Math.round(px - (wa.w - tw) / 2);
    const y = Math.round(py - (wa.h - th) / 2);
    // The work area lies inside the output: an origin outside that was measured on a workspace that
    // isn't this output's yet (a monitor was just unplugged) and would shift every snap on it.
    if (x < -2 || y < -2 || x > out.w - wa.w + 2 || y > out.h - wa.h + 2) {
      this.io.log(`work area origin ${out.name}: ${x},${y} is impossible; ignored`);
      this.endProbe();
      return;
    }
    const changed = this.workAreaChangedAt.get(out.name);
    const settled = changed === undefined || this.io.now() - changed >= ORIGIN_SETTLE_MS;
    this.origins.set(out.name, { key: `${wa.w}x${wa.h}`, x, y, settled });
    this.io.log(`work area origin ${out.name}: ${x},${y}${settled ? "" : " (provisional)"}`);
    this.endProbe();
  }

  endProbe() {
    const { then } = this.probe;
    this.probe = null;
    then();
    // Queued snaps: re-run through place(), which now finds the origin.
    const queued = this.probeQueue.splice(0);
    for (const q of queued) {
      if (this.probe) this.probeQueue.push(q);
      else q.then();
    }
  }

  apply(id, rect, reapplied = false, focus = true) {
    const win = this.windows.get(id);
    if (!win) return;
    if (!win.is_floating) this.io.send({ Action: { MoveWindowToFloating: { id } } });
    // §19.18: the latest placement wins; older retries see a newer generation and stop.
    const gen = reapplied ? this.generation.get(id) : (this.generation.get(id) || 0) + 1;
    this.generation.set(id, gen);
    const current = () => this.generation.get(id) === gen;
    this.pending.set(id, { rect, until: this.io.now() + SETTLE_MS, reapplied });
    this.io.send({ Action: { SetWindowWidth: { id, change: { SetFixed: Math.round(rect.w) } } } });
    this.io.send({ Action: { SetWindowHeight: { id, change: { SetFixed: Math.round(rect.h) } } } });
    this.io.send({ Action: { MoveFloatingWindow: { id, x: { SetFixed: rect.x }, y: { SetFixed: rect.y } } } });
    if (focus) this.io.send({ Action: { FocusWindow: { id } } }); // §8 step 5: raise and focus
    if (!reapplied) {
      // §10 lagging clients: re-apply once; then accept whatever size they chose.
      this.io.schedule(REAPPLY_MS + SETTLE_MS / 2, () => {
        const w = this.windows.get(id);
        const st = this.state.get(id);
        if (!w || !w.is_floating || !current()) return;
        const now = rectOf(w);
        if (!rectsEqual(now, rect)) {
          if (!this.pending.get(id)?.reapplied) this.apply(id, rect, true, focus);
          else if (st) st.rect = now;
        } else this.pending.delete(id);
      });
    } else if (this.state.has(id)) {
      this.io.schedule(SETTLE_MS, () => {
        const w = this.windows.get(id);
        const st = this.state.get(id);
        if (w && st && current()) st.rect = rectOf(w); // accept the client's own size
      });
    }
  }

  resizeOnly(id, w, h) {
    this.io.send({ Action: { SetWindowWidth: { id, change: { SetFixed: Math.round(w) } } } });
    this.io.send({ Action: { SetWindowHeight: { id, change: { SetFixed: Math.round(h) } } } });
  }

  // §14: re-fit snapped windows after a work-area or output change, no animation. Focus
  // stays where it is, and minimized windows stay hidden.
  refitAll(outputName) {
    for (const [id, st] of this.state) {
      if (outputName && st.output !== outputName) continue;
      if (this.minimized.has(id)) continue;
      const out = this.outputs.get(st.output) || this.outputOf(this.windows.get(id));
      if (!out || !st.zone || st.custom) continue;
      st.output = out.name;
      this.place(id, out, st.zone, st, false);
    }
  }

  describe(st) {
    if (!st) return "normal";
    if (st.kind === "maximized") return "full screen";
    return zoneName(st.zone || layoutById(st.layoutId)?.zones[st.zoneIndex] || MAXIMIZE);
  }

  dump() {
    return {
      settings: this.settings,
      focused: this.focusedId,
      workAreas: fromEntries(this.workAreas),
      origins: fromEntries(this.origins),
      windows: [...this.state].map(([id, st]) => ({ id, title: this.windows.get(id)?.title, state: this.stateName(id),
        position: this.describe(st), instance: st.instanceId, rect: st.rect })),
      restore: fromEntries([...this.restore].map(([id, r]) => [id, r.rect])),
      instances: [...this.instances.values()].map(i => ({ id: i.id, output: i.output, layout: i.layoutId,
        members: fromEntries(i.members) })),
    };
  }
}

// A rect of size `size`, horizontally centred on `on`, top edge aligned.
function centredAt(on, size) {
  return { x: on.x + (on.w - size.w) / 2, y: on.y, w: size.w, h: size.h };
}

// Zone fractions of a rect inside work area wa (for resize overrides).
export function fractionsOf(r, wa) {
  return { x: (r.x - wa.x) / wa.w, y: (r.y - wa.y) / wa.h, w: r.w / wa.w, h: r.h / wa.h };
}

export function rectOf(win) {
  const l = win?.layout;
  const pos = l?.tile_pos_in_workspace_view;
  if (!pos) return null;
  return { x: pos[0], y: pos[1], w: l.tile_size[0], h: l.tile_size[1] };
}

export { BUILTIN_LAYOUTS };

// Object.fromEntries is missing from Quickshell's JavaScript engine.
function fromEntries(entries) {
  const obj = {};
  for (const [k, v] of entries) obj[k] = v;
  return obj;
}
