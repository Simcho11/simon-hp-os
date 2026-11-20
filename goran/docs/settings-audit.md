# HP-OS Settings audit

2026-11-20. This audit is read-only: nothing was changed. It covers the shell as you run it: generation 41, shell runtime `5ff0s6…`, with Wi-Fi and Bluetooth under General and Users & Accounts under Lock Screen.

The goal is one place to change each thing, names that say what they do, and no controls that are dead or fight each other.

How it was checked:
- **Exact list of rows:** a copy of the real shell code, loaded with a copy of your config, listed what the Settings window shows. Settings declares 707 rows and shows 535 of them for you. With "Show every setting" off, as you have it, you see 13 sections.
- **Cross-checks:** every More Settings page, the HP-OS preferences window, Customize, the Control Center, the menus and the Nix activation scripts were read against those rows.
- **Verification:** each finding marked **verified** was confirmed by reading both sides of the code. Items marked *needs a live test* could not be confirmed without running the desktop.

Line numbers are in the patched shell: `IrisOptions.qml`, `IrisSettings.qml` and the `modules/settings/*.qml` pages. Most of these come from `goran/desktop/hp-snap/shell.patch` and `desktop-polish.patch`.

---

## The big picture

There are five ways into settings, and they overlap:

| Surface | What it is | Problem |
|---|---|---|
| **Settings** (iRiS settings) | 27 sections, 13 in simple mode | Good core. Some rows are duplicated, and the text talks about surfaces simple mode hides. |
| **More Settings** | 8 older iNiR pages (System, Advanced, Services, Tools, Colour themes, Wallpaper engine, Desktop widgets, Autostart) | Mostly second copies of Settings rows under other names, plus controls for other shell families. |
| **HP-OS preferences** | A separate window (start menu gear, account menu, General › HP-OS) | Repeats accent, material, outlines and language, and has its own "Reduce motion" that writes a different key. |
| **Customize / Studio** | Live editor | Writes the same keys as Settings. Fine, except the "mirror" rows that appear in four sections. |
| **Nix activation** | Scripts that run on every install | One rewrites two of your settings each time. A timer overrides your Light/Dark choice. |

**Recommendation in one line:** make Settings the only owner, shrink More Settings to the few things nowhere else, fold HP-OS preferences into Settings, and let Nix set defaults once rather than enforce them.

---

## P1: settings that fight you (verified unless noted)

### 1. Light / dark: four controls plus a timer
- **Where it can be changed:**
  - Settings › Colour › Scheme (Auto/Dark/Ink/Light). On HP-OS this writes `hpos.appearance`.
  - HP-OS preferences › Appearance (Automatic/Light/Dark), which writes the same key.
  - The Control Center "Dark mode" tile, which only sets light or dark, so it silently drops Auto.
  - Colour › "Light or dark from the wallpaper", a second meaning of Auto.
- **The timer:** `hp-os-appearance-schedule` runs every minute and is on by default. It never reads your choice: `hp-os-appearance-schedule.py` compares the live mode with sunrise/sunset and sets it. If you pick **Light** or **Dark**, the schedule changes it back at the next sunrise or sunset.
- **Your config now:** `hpos.appearance = "light"`. The Settings row reads `iris.appearance.scheme = "auto"` to decide which "Dark look" / "Light look" rows to show (`schemeShown()`, IrisOptions.qml:107). So those rows follow a stale key.
- **Defaults:** `defaults.json` sets `hpos.appearance: "light"` for every new account.
- **Fix:**
  - Colour › Scheme owns it. Auto means the sun schedule, and the wallpaper row goes.
  - The schedule acts only when Auto is chosen.
  - The Control Center tile cycles Auto → Light → Dark.
  - Remove the copy in HP-OS preferences.
  - Fix the two readers to use the HP-OS key.
- **Side note:** the timer service has failed several times today with "Multiple HP-OS shells found". That was probably test shells from Claude sessions, but it shows it gives up rather than picking the right shell.

### 2. "Reduce motion": two switches, same name, different keys
- Settings › Motion › Reduce motion writes `iris.appearance.motion`. HP-OS preferences › Reduce motion writes `hpos.reducedMotion`.
- They are combined with OR (IrisStyle.qml:924), so turning one off does nothing while the other is on.
- Motion is hidden in simple mode, so you only see the HP-OS copy.
- **Fix:** keep one key, as a row in General (visible in simple mode).

### 3. Language: Settings doesn't reach the HP-OS surfaces
- Settings › General › Language writes `language.ui` only.
- HP-OS's own surfaces (start menu, Control Center, preferences) read `hpos.locale`, which with "auto" follows the system locale instead (HposTokens.qml:41).
- HP-OS preferences writes both keys, but offers only 3 choices.
- **Fix:** Settings owns language; set `hpos.locale` from it.

### 4. An install script rewrites two of your settings every time
- `hp-os-battery.py` runs on every home-manager activation (hp-os.nix:229), with no "already done" marker.
- **First:** it puts **battery** and **notifications** back into the Island's bubbles (`iris.bar.pieces`), undoing your choice in Island › "Bubbles in the Island".
- **Second:** it changes Sound › Volume › **Largest jump** from 10 to 11. The slider moves in steps of 2, so 11 can't be selected, and choosing 10 is undone at the next install.
- **Fix:** give it a once-per-account marker like `apply-defaults.py` has, and drop the volume change or make it 10/12.

### 5. Control Center settings don't reach the HP-OS Control Center
- On HP-OS the Control Center is `HposControlCenter`, which keeps its own layout in `hpos.controlCenter.actions` (IrisControlCenter.qml:210).
- Settings › Control Center's rows write `iris.controlCenter.*`, which it never reads: what it carries, columns, names, control shape, accent, slider fill, Connections plate, levels.
- The "Arrange it" button also targets the iRiS editor.
- The section is hidden in simple mode, which hides the problem but doesn't fix it.
- **Fix:** under HP-OS, show one "Quick actions" row for `hpos.controlCenter.actions` and make "Arrange it" open HP-OS edit mode. Hide the rest.

### 6. Appearance › Material silently resets the desktop widgets' material
- Appearance › Glass › Material (Solid/Frosted/Liquid) also writes `iris.widgets.material`, the Dock material and every surface's material (IrisOptions.qml:124, 339).
- Desktop › Widgets › Material is still shown and writes `iris.widgets.material`.
- Pick a widget material, then touch Appearance, and your widget choice is gone.
- The Appearance choice also sets Niri's blur strength (IrisOptions.qml:73).
- **Fix:** under HP-OS, Desktop › Widgets › Material becomes "Same as Appearance / Transparent" only, or its description says Appearance resets it.

### 7. Weather can't be set up from one place, and the text contradicts itself
- **Three places:**
  - General › HP-OS › Weather provider.
  - Sources › Weather (place, units, GPS), which simple mode hides.
  - More Settings › Services › Weather, the only place with **latitude/longitude** and the on switch.
- **The contradiction:** General says HP-OS disables automatic location, and you must enter latitude and longitude "in weather settings". Sources and Services both say "leave it empty and it works it out from your connection" and offer GPS.
- On HP-OS, weather only works with manual coordinates (`services/Weather.qml:15`). Yours are set (Palo Alto), so it works for you; a new user would be stuck.
- Services also writes a Waffle key ("Hide weather location") and an ii-bar key ("Show in top bar").
- **Fix:** one Weather group in General: on/off, place (with a "find" that fills the coordinates), units, how often. Drop the GPS and auto-detect text on HP-OS.

### 8. Keyboard "Options" may be ignored (*needs a live test*)
- Settings › Keyboard & Mouse › Options writes niri's `config.d/10-input-and-cursor.kdl`.
- Nix installs `62-goran-keyboard.kdl` with `xkb { options "ctrl:nocaps" }`, loaded later.
- Depending on how niri merges included files, whatever you type in Settings is overridden. It may even override Layout.
- **Fix:** move `ctrl:nocaps` into the Settings-managed file once, so Settings shows it and can change it.

---

## P2: the same thing in two or more places

### Inside Settings itself

| Setting | Places (section › group: label) | Fix |
|---|---|---|
| Live wallpaper on the lock screen (`lock.enableAnimation`) | Wallpaper › Live wallpapers: "Animate on the lock screen"; Lock Screen › Scene: "Play live wallpapers"; More Settings › System (a third, ii-era copy) | Lock Screen owns it |
| Niri blur (on, strength, colour, grain) | Appearance › Glass; Windows › Glass behind apps | Windows owns it; Appearance links to it |
| Reserve space for windows | Island, Bubbles, Dock, Side Panels; and Windows › "Room for iRiS" | Each surface owns its own; drop "Room for iRiS" (or the reverse) |
| One shape for all, Island/Dock/Bubble shape | Appearance › Shape; Island; Bubbles; Dock | Appearance owns it |
| Corners of each surface | Appearance › "Corners per surface" (10 rows), and again inside each surface's own group (Menus, Settings, Gallery, Volume pill, Control Center, Spotlight, Orbit, Side panels, Cards, Island) | Each surface owns its corners; drop the per-surface list or the copies. On Appearance's own page, Menus and Settings corners appear **twice on the same page** |
| Glass edge (line, width, colour) | Appearance › Edges; Desktop › Widgets (says it's shared) | Appearance owns it |
| Lock screen clock size | Lock Screen › Clock: "Size"; Lock Screen › Type: "Clock size" (two different keys, both resize the lock clock) | Keep one |
| Clock format | General › Date & time "Clock"; Lock Screen › Type "Clock format" (Follow the system/24/12); Desktop widgets › Clock "Time format"; More Settings › System | General owns it; the others follow it |
| Seconds | General "Exact seconds" (tick precisely); Lock Screen "Seconds" (show seconds), with the same word for different things | Rename General's to "Tick exactly on the second" or drop it |
| Edge controls | Appearance › Edges has "Style / Outline colour / Outline width" (`rim`) **and** "Edge line / Edge width / Edge colour" (glass edge): two sets of nearly identical names in one group | Merge into one Edge set |
| "Glass shows" vs "Blur shows" | Both offer "The wallpaper / Everything behind", but write different keys (shell glass vs Niri window rules) | Rename to say what each covers |

### Settings vs More Settings
- **More Settings › System:** almost entirely second copies, under different names:
  - Earbang/Ear protection, battery levels and suspend, charge limit.
  - Language, clock format, "Second precision", alert sounds ("Pomodoro" = "Focus sessions").
  - Caps Lock badge, close confirmation, "Also unlock keyring", login screen and login style.
  - A whole **ii-family Lock screen card** whose options (clock position, "Show 'Locked' text", Hyprlock) don't drive the HP-OS lock screen.
  - Only a few rows are unique: full-battery warning, per-event sound picker, date formats, require password to power off.
- **More Settings › Advanced:** every app-theming switch again (`appearance.wallpaperTheming.enable*`), with different names: "Shell & utilities" = "GTK and KDE apps"; "Force dark mode in terminal" = "Terminals always dark". The rest is the Cava visualizer and GPU monitoring.
- **More Settings › Services:** idle timeouts again, in seconds instead of choices. Also search engine (free text vs choice), update check intervals, weather and calendar.
- **More Settings › Tools:** screenshot and recording paths, OCR language, Japanese lookup, Anki and recording quality again. Also connection-notice switches identical to Island › Connections. Since Screenshots & Recording is hidden in simple mode, Tools is the only place you see these.
- **More Settings › Colour themes:**
  - The page is titled "Themes" and its card says "Color Themes".
  - "Light/dark from wallpaper" and "Apps use this font" are copies, and "Terminal" theming is a third copy.
  - "Scheme Variant" (Expressive, Fidelity, Monochrome…) has the **same choice names** as Colour › Style but writes a different key.
  - Global Style (Aurora, Angel…) and Shell fonts are for other families; HP-OS draws its own surfaces and fonts.
  - The Motion and Advanced tabs are empty in simple mode.
- **More Settings › Wallpaper engine:**
  - Its blurb promises "transitions", which are hidden on HP-OS.
  - It still offers **Shuffle wallpapers**, which commit `338e773` removed from Settings ("no wallpaper shuffle"), so it came back through the side door.
  - The parts worth keeping are the wallpapers folder and the upscale notice.
- **More Settings › Desktop widgets:** 6,900 lines. The "at a glance" switches repeat Desktop › "On the desktop", and the clock's time format repeats General. The per-widget Appearance, Surface and Colors blocks do nothing under the default design, as the page says itself.

### Settings vs HP-OS preferences
- **Accent:** the same key, but HP-OS preferences also forces "Use the accent everywhere", which has no Settings row.
- **Window outline:** called "Accent outline" plus "Outline thickness" in Windows.
- **Window shadows, Liquid glass strength, Material quality:** the same keys as Settings.
- **"Material intensity"** is the same setting as Appearance's **"Opacity"**, under a different name.
- **Only there:** "Liquid glass on selected icons and widgets", "Reduce transparency" and "Application grid".
- **The Settings row that opens it** promises "Typography… component gallery", but the window has neither.
- The start menu gear and the account menu open **this** window, labelled "HP-OS Settings", while the desktop menu and Dock open the real Settings.

### "Make it lighter": five switches that overlap
- General › Low power.
- Appearance › Material quality "Performance" (which also turns glass off).
- HP-OS preferences › Reduce transparency.
- Gaming › "Stop glass and blur".
- Control Center › Power mode.

**Fix:** one Performance choice in General (Full / Balanced / Light) whose description says what it turns off. Gaming keeps only its own "while playing" overrides.

---

## P3: dead ends and things that don't apply on HP-OS

### Text pointing to hidden places
In simple mode, several descriptions send you to places you can't see:
- Dock › Reserve space: "Everything that takes room is together in **Windows, Room for iRiS**". Windows is hidden.
- General › Weather provider: "set latitude and longitude in **weather settings**". That's More Settings › Services, not named.
- General › Default terminal: "…and **anime** playback". Anime is hidden.
- Most of Appearance (57 rows in "simple" mode) adjusts the **Island, Orbit, Spotlight, Side panels and Bubbles**, all hidden sections. Orbit is off in your config (`iris.orbit.enable = false`).
- **Login Screen** (2 rows) is hidden in simple mode, though it matters now that HP-OS has several accounts.

### Doesn't apply to HP-OS
- **Sources › "New iNiR":** watches for upstream iNiR git releases. HP-OS updates through Nix and has its own Software Update card in General.
- **Sound › Ear protection:** says "Shared with Material and Waffle", families HP-OS doesn't offer.
- **Wi-Fi page:** says "this laptop", which is wrong on a desktop PC. The hotspot password is in Services as plain visible text, not on the Wi-Fi page.
- **Wallpaper gallery:** offers Konachan and yande.re in simple mode; its own text says they "lean to fan service". For a family OS, consider leaving them out of the defaults.

---

## Naming

| Problem | Where | Suggestion |
|---|---|---|
| **"iRiS" / "iNiR" on an HP-OS desktop** | 33 visible strings: "how iRiS behaves", "Room for iRiS", "Customize iRiS", "every clock in iRiS", "About iNiR", "New iNiR"; the profile line says "iRiS · Island family" | Say "HP-OS", or nothing ("the shell" → just "your desktop") |
| **Island vs bar** | Section "Island"; rows "Group into a bar", "Menu bar strip"; a group called "Bar" inside Island; Appearance › Material says "the bar" | Pick one word HP-OS users see. The user guide calls it neither, so check what the guide calls it |
| **The volume pop-up has five names** | "On-screen feedback", "OSD width", "OSD position", "Volume and song pill", "Level style" | "Volume pop-up" everywhere |
| **Sleep vs suspend** | General › Power "Sleep"; Lock › "Suspend after", "Lock before sleeping"; Battery › "Suspend when almost empty" | "Sleep" everywhere |
| **Theme-like ideas with overlapping names** | Appearance › "Base look" (iRiS/Soft/Round…); Appearance › Themes; Colour › "Style" (iRiS/Washi/Material You…); Colour › "Colour theme" (Catppuccin…); More Settings › "Colour themes" with "Scheme Variant" | Keep "Colour theme" (palette) and "Style" (shape language); fold the rest |
| **Jargon** | Lume frost, Lume on every widget, Fusion, Afterglow, Reach, Light (Off/Subtle/Vivid = "what lights an open card"), Button rows: Veil, Faces › Figure weight, Paper: Kuro/Sumi/Usuzumi, Legibility wash, Plates, Niri blur, Cava, matugen, awww, "Top of the" | Plain words, e.g. "Blur behind apps", "Number weight", "Darken behind text" |
| **The same label for different things on one page** | Appearance: "Material" is a group (fills, lines, shadows) **and** a row inside Glass; "Light" is a group and a row; "Corners" appears 10 times | Rename the group "Fills and lines" |
| **"System" means four things** | More Settings' group, a More Settings page, a Services tab and a Widgets tab | Rename the page to what's left on it, or remove it |
| **More Settings blurbs are wrong** | Section subtitle says "Wallpaper engine, **Niri**, widgets and services": there's no Niri page. "System — Keyboard indicators, work safety" opens on Audio, and work safety is hidden. "Colour themes" opens a page titled "Themes" | Rewrite after the clean-up |
| **Customize vs Studio** | The button says Customize; the option "Customize opens: On the shell / Studio" | Fine, but "Studio" should explain itself ("Side panel with search") |

---

## Robustness: settings that can break things too easily
- **Keyboard › Shortcut key (Super/Alt/Ctrl)** is in simple mode. Changing it remaps every shortcut.
- **Keyboard › Layout / Variant / Options** are free-text XKB fields ("us,es", "caps:escape"). A typo breaks input. Use a layout picker and checkboxes for common options.
- **General › Factory reset** sits under "Power" next to Sleep and Shut down. Move it to its own "Reset" group, or under Users & Accounts.
- **Services › search engine** is free text, which leaves the Spotlight choice blank.
- **Autostart** writes niri's startup file. If Nix manages that file, the page may only say "re-run the installer". *Needs a live test.*

---

## Suggested order of work

1. **Stop the fights (P1 items 1–6):** the appearance schedule, the two "Reduce motion" keys, the language key, the `hp-os-battery.py` marker, the HP-OS Control Center row, and widget Material. These are small code changes, each in one place.
2. **One Weather group** in General (P1 item 7).
3. **Remove More Settings › System and Advanced,** moving their handful of unique rows into Battery, Sound, General and Colour. Cut Wallpaper engine down to the folder and the upscale notice, and Colour themes down to the icon theme.
4. **Remove the in-Settings copies:** "Corners per surface", the lock-screen live wallpaper copy, Niri blur in Appearance, "Room for iRiS", and the second lock clock size.
5. **Fold HP-OS preferences into Settings** (the four keys only it has), then make the start menu gear open Settings.
6. **Rename:** iRiS → HP-OS, Sleep/Suspend, the volume pop-up, jargon labels, and the More Settings blurbs.
7. **Simple mode:** add Login Screen. Move Island's few common rows (clock, which bubbles) into a visible section. Trim Appearance to about 15 rows, with the rest behind "Show every setting".

Not checked: items needing a live desktop (keyboard option merge, Autostart on Nix), the Island and Bubbles sections in depth, and touchpad rows (no touchpad in the test).
