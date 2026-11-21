# HP-OS file handling: audit and clean-up plan (2026-11-20)

This audit was read-only. It used the installed shell build
(`/nix/store/8445mdd8…-hp-os-runtime-hp-snap`), the repo, and Simon's home folder.
The items marked ✔ were also checked by hand. The rest come from reading the code.

## Why it feels disjointed

These separate systems all handle files, and none of them owns the whole job.

| Job | Who does it today |
|---|---|
| File manager | **Dolphin** ("HP-OS Files", patched, with a private profile) **and** **COSMIC Files** (Simon only) |
| Open a folder | Dolphin (a stray `~/.config/hp-os-mimeapps.list` overrides the COSMIC default) ✔ |
| "Show in folder" (FileManager1) | **Unpatched stock Dolphin**, with no HP-OS profile or theme. On the user bus it is Nautilus. |
| Trash in the dock | Dolphin `trash:/`, even where Files is COSMIC |
| Desktop icons | Shell QML, plus a JSON layout, plus 3 Python helpers, plus `gio`/`mv` run in the background |
| File dialogs | Ubuntu's stock GTK portal. HP-OS's network-share patch never runs (gated on `XDG_CURRENT_DESKTOP=niri`, but HP-OS is `HP-OS:niri`). |
| Default apps | 4 mimeapps lists that disagree |
| Search | Recoll (shell), Baloo (Dolphin) and COSMIC's own search |
| Places sidebar | Three separate lists: Dolphin `user-places.xbel`, GTK `bookmarks` and COSMIC's own |
| Network shares | KIO (Dolphin) and gvfs (COSMIC). A share mounted in one isn't visible in the other. |

## Broken

1. **Apps opened from Files run with a private settings folder.**
   - `hp-os-files.py:66` sets `XDG_CONFIG_HOME=~/.config/hp-os/apps/files`, and every app Dolphin launches inherits it.
   - That folder now holds a second Chrome profile (not signed in), plus Codex, LibreOffice and mpv. ✔
   - A document opened from Files therefore gets different settings and sign-ins than the same document opened from the desktop.
2. **Default apps are split and wrong.**
   - Images and PDFs open in **Chrome**. ✔
   - `microsoft365-word.desktop` (and the other Microsoft 365 launchers) has no `%U`. A .docx opened through gio or Dolphin opens a blank Word page instead of the file. ✔
   - xdg-open and gio pick different apps for text and video.
   - Gwenview ships but isn't on PATH.
3. **Desktop drops can land in the wrong folder.**
   - Until the first scan finishes, `DesktopFolder.folder` is `""` (`DesktopDropCoordinator.qml:104`).
   - `folder_drop.py` then resolves `""` to its working directory and moves the files there. ✔
4. **Races between the desktop scan and file operations.**
   - Rename and new-folder update the JSON first, then run `mv` and the helper detached.
   - A full rescan runs every 4 s. ✔
   - A scan that is already running can bring back the old name or drop the new item, and the icon jumps.
5. **Errors are silent.**
   - Rename onto an existing name is `mv -n`: nothing happens and nothing is reported. ✔
   - Trash, copy-in and scan failures go only to the console.
   - `smb://` and `sftp://` drops from Dolphin are refused.
6. **Icons shift.** `gio info` output is matched by position, so one broken symlink shifts every icon after it to the wrong file. ✔
7. **The Trash icon never shows full, and there is no Empty Trash** outside the file managers. The Trash currently holds 10 items. ✔
8. **Mixed selections can't be dragged out.** If any selected icon isn't a file (for example the Trash icon), the drag carries no files at all.

## Janky

- **Two drop paths with different rules.**
  - `folder_drop.py` names a clash "X 2.pdf" and uses a staging folder.
  - `desktop_folder.py copy-in` names a clash "X (2).pdf" and always copies.
- **Four delete paths with different lock and folder checks:** the Delete key, the single-item menu, the group menu, and dropping on the Trash.
- **Old JSON "app" and "url" items are still created on drop,** then migrated into `.desktop` files one scan later.
- **Undo only restores JSON records.** It can't bring back a trashed file, although it sits next to "Move to Trash".
- **No file clipboard.** There is no Ctrl+C/X/V, and the `x-special/gnome-copied-files` and `application/x-kde-cutselection` formats aren't supported. The only key that works is Delete: no F2, Enter, Ctrl+A or Ctrl+Z.
- **Drag feedback is wrong.** A drag between drives shows "move" but actually copies. A drop on a folder icon makes it flicker.
- **New icons are placed using screen 0's height,** so on other screens they can land off-screen.
- **The scan is costly and loses positions.** Every 4 s it runs Python plus `gio info` over every file. Items are tracked by path, so a file renamed outside the shell loses its position.
- **No thumbnails on the desktop,** only generic mime icons.
- **Downloaded `.desktop` files run when double-clicked,** with no trust check.
- **No drives on the desktop or dock,** and no eject.
- **Restore from Trash works only for the home Trash,** and puts the file at the drop location rather than its original one.
- **Recents miss files opened from the desktop or search,** because neither writes `recently-used.xbel`.
- **The Recoll index updates only every 30 min,** and `hp-os-search` hardcodes the English folder names.

## Status

**Phases 1 to 4a were kept (4a on 2026-11-21). Phase 4b is installed as a trial (record 3, `jqqd10b7…-home-manager-generation`, 2026-11-21 07:15); one `switch-back` returns to generation 49 (4a). The desktop and search parts take effect at the next sign-in. Nothing is committed yet.**

Done in Phase 4b (recent files, search):
- **Files opened from the desktop or from search are remembered among recent files** (`recently-used.xbel`, which the start menu's Recent, file dialogs and GTK apps read). Before, only apps that record their own opens put them there, so a PDF opened in Chrome from the desktop never showed.
  - `hp-os-recents record PATH...` writes the list as GTK does (GLib's URI escaping, the mime type, an "HP-OS" application entry with its count), under a lock, atomically, mode 0600. GLib's own parser reads the result (tested), and a list it cannot read is never rewritten.
- **Search results have "Show in folder"**: the folder button on a file result, or Ctrl+Enter, opens Files with the file selected (FileManager1.ShowItems).
  - `dbus-send` waits for the reply. Without that, the first call after login was lost while Files' service was starting, because the bus drops a call whose sender has gone.
- **Search looks in the user's own folders** as `user-dirs.dirs` names them (another language, or moved), not fixed English names. The index's folder list follows them; the rest of its settings are kept.
- **Searching brings the index up to date** (at most every two minutes), as well as the half-hourly run, and the results refresh when it finishes.

Done in Phase 4a (thumbnails, trusted launchers, Files in dark mode):
- **Desktop thumbnails.** Pictures, PDFs and comics, videos and album covers show a small picture instead of their type's icon, framed by a hairline.
  - They come from the thumbnail cache every app shares (`~/.cache/thumbnails/large`, the freedesktop.org spec, URIs escaped as GLib does). A thumbnail Files made is used by the desktop and the other way round.
  - Missing ones are made in the background by the installed thumbnailers (`.thumbnailer` files, as GNOME's), a batch at a time. The next thumbnailer for a type is tried when one fails; a file no thumbnailer can do is remembered (`fail/hp-os-desktop`) until it changes.
  - Ubuntu's `papers-thumbnailer` fails on every PDF on this machine, and x86 images have none, so HP-OS installs Nix's Papers and ffmpegthumbnailer thumbnailers in `~/.local/share/thumbnailers` (`hp-os-default-apps.nix`).
  - A picture no thumbnailer can do (JPEG, PNG, GIF, WebP, BMP, SVG up to 40 MB) is drawn from the file itself.
- **A launcher that isn't trusted asks before it runs**, as in Files. Trusted means executable, which every launcher HP-OS puts on the desktop already is. A `.desktop` file downloaded or copied onto the desktop shows "“X” isn't trusted yet" with "Trust and Open" (which marks it executable) or Cancel.
- **Files' toolbar and menu icons show in dark mode.** They are Breeze's one-colour icons, which KDE recolours only when the current icon theme says it follows the colour scheme. Files now uses `HP-OS-Files`: the same icons and fallbacks as HP-OS (the same folder), with that flag. Every icon resolves as before (checked with `kiconfinder6`).
  - A side effect: Files now reads the package's repaired HP-OS icons instead of a stale hand-made copy in `~/.local/share/icons/HP-OS` (from 2 November). That copy shows an empty Trash icon for a full Trash; its own README says to delete it now that the package ships fixed icons. Other apps still read it; it was left in place.

Fixed in Phase 3c after the first trial (the user's report: Cut and Paste in the same folder asked to overwrite the file with itself; Ctrl+V never reached the desktop; copying back and forth a few times "broke it"):
- **The clipboard helper hung.** When the desktop copied again, the shell stopped the old helper with SIGTERM. Python raised the exit inside a Wayland callback, where pywayland's callback wrapper swallowed it together with the event: the helper never exited, the next Copy or Cut on the desktop waited for it forever, and Files' paste read timed out ("QWaylandDataOffer: timeout reading from pipe"), leaving its pipe open in the helper.
  - The helper now has its own event loop: a signal only wakes it, nothing is raised inside a callback, and it exits cleanly on SIGTERM, SIGINT and SIGHUP.
  - It never waits on an app that reads the clipboard. Each reader's copy is written as the reader takes it, and a reader that takes nothing for 10 s is dropped.
  - `desktop_files.py clip` starts it on its own and returns once the files are on the clipboard: as a systemd user service when the session has one (as the shell's other clipboard owners run), else in its own session. It outlives a shell restart, and the desktop never stops it: the next copy replaces it.
  - Reproduced and tested in niri itself (nested, in the test display): the stuck read, then 5 rounds of desktop Copy, Paste in Files, Cut in Files, Paste on the desktop, with no stuck reads and no helpers left over.
- **Files: Cut and Paste into the folder the files are already in does nothing**, as on Windows and macOS. Before, it asked to overwrite the file with itself. **Copy and Paste there makes a numbered copy** ("Report (1).pdf") instead of asking. This is a KIO patch only Files loads (`hp-snap/files-paste-in-place.patch`).
- **Names are numbered as Files numbers them:** "Report (1).pdf", "Report (2).pdf", "New Folder (1)". A name that already ends in a number counts on from it. The desktop used "Report 2.pdf" before.
- **A click on the desktop gives it the keyboard**, as on Windows and macOS: Ctrl+V pastes there even with a window open above, and Ctrl+A, Ctrl+C, Ctrl+X, Ctrl+Z and Delete work. Clicking or focusing a window, a newly opened window, a workspace switch or Escape hands the keyboard back. Before, a click on the bare desktop gave it straight back to the window.
- **A Cut pasted where it already is keeps its icon in place**; it used to jump to the paste point.
- **Cut icons are dimmed from the clipboard itself**, so a Cut made in Files dims the desktop's icons too, and copying anything else clears it.
- **New Folder from the desktop menu asks for the name in the menu**, which holds the keyboard; Enter makes it where the desktop was clicked, Escape cancels. On niri, once that menu closes the keyboard goes to the window, so the name typed into the icon's own field went to the window instead (in a terminal it would have run).
- **An icon's menu opens upward when the icon is low on the screen.** It was cut off at the bottom edge (Rename, Move to Trash).

Known limit: after choosing Paste in the desktop menu, the keyboard is with the window again (niri), so Ctrl+Z goes there; "Undo Paste" is in the desktop menu.

Done in Phase 3c (copy, cut and paste):
- **Copy and Cut put files on the clipboard in every form apps read.** That means `text/uri-list`, GNOME's `x-special/gnome-copied-files` (copy or cut), KDE's `application/x-kde-cutselection`, and plain-text paths. They are on the item menu, the group menu, Ctrl+C and Ctrl+X.
- **A small helper holds the clipboard.** It's `hp-snap/file-clipboard` (Python and pywayland over the wlr data-control protocol; no window or focus needed). It runs until something else is copied, because `wl-copy` can offer only one format.
- **Files moves a desktop Cut when pasting**, and the cut icon is dimmed until then.
- **Paste takes files cut or copied in Files (or GNOME apps).** It's in the desktop menu (only when the clipboard holds files) and on Ctrl+V, plus "Paste into Folder" on folder icons. A cut is moved, across drives too, and the clipboard is cleared afterwards, as Files does. A copy pasted where it is gets a number.
- **Undo Paste puts everything back.**
- **Tested both ways with HP-OS Files:**
  - Desktop Cut, then Paste in Files: the file moved.
  - Files Copy, then desktop Paste: the file was copied.
  - Files Cut, then Paste into Folder on the desktop: the file moved.
  - Undo Paste brought it back.
- **This build packages `hpos.appearance: "light"` for new accounts again.** Generations 44 and 45 had "auto" from a short-lived defaults.json.

Done in Phase 3b (also in `hp-snap/desktop-files.patch`):
- **Keys on the desktop:** F2 renames (only the name is selected, not the extension), Enter opens, Ctrl+A selects all, Ctrl+Z undoes, Ctrl+Shift+N makes a new folder, Escape clears the selection, Delete moves to the Trash.
- **Undo for the desktop's own file changes:** Move to Trash, Rename, New Folder, and moving or copying by dropping. Trashed files come back to their old place and icon position. The desktop menu shows "Undo …".
- **Trash:**
  - The Trash shows when it has something in it, on the desktop and in the Dock. `hp-snap/icons/trash-full.svg` is installed as `hp-os-trash-full` and `user-trash-full`, so Files uses it too.
  - "Empty Trash…" is on the desktop Trash icon and in the Dock's Trash menu, and both ask first.
  - Emptying follows the Trash spec itself (home Trash and each drive's own), so it works without GVfs, which x86 images don't install.
  - Restoring is done the same way.
- **The name field:**
  - It survives the desktop rebuilding its icons while typing; the edit is kept in DesktopFolder.
  - The desktop doesn't re-read its own layout writes any more. Each change used to rebuild every icon twice.
  - Keyboard focus returns to the desktop after a rename.
- **Fixed:** new icons were placed on top of icons filed under no display (the seeded Home, Documents and others).
- **Desktop menu:** "Open in Files" added.
- **Trash icon menu:** "Locate target" and "Edit destination" are hidden for the Trash.

Known limit (fixed in Phase 3c, see above):
- **New Folder from the desktop right-click menu opened its name field, but the keyboard wasn't handed back** after that menu (an Overlay surface with exclusive keyboard) closed. Ctrl+Shift+N and F2 typed straight away.


Seen while testing, for later: in dark mode, Files' toolbar buttons (back, forward, search, menu) are hard to see.

Done in Phase 3a (`hp-snap/desktop-files.patch`, applied last to the shell):
- **One helper does every desktop and Dock file operation:** `scripts/hp-snap/desktop_files.py`, which replaces `folder_drop.py` and `desktop_folder.py`.
  - Operations: scan, move/copy, trash, rename, new folder, open with, migrate.
  - One rule for name clashes: "Report 2.pdf", "New Folder 2".
  - Failures show as a notification and are never silent: a taken name, a network place, an unknown folder.
  - Tests are in `scripts/hp-snap/test_desktop_files.py`.
- **The desktop changes an icon only after the helper reports what happened.** A scan that overlapped a file operation is thrown away. Rename, new folder and drops no longer race the scan, so icons don't jump back or vanish.
- **The folder is watched, so outside changes show within about a second.** The full rescan was every 4 s; a 30 s rescan remains only as a safety net. A file renamed outside the desktop keeps its icon's place (matched by inode).
- **Fixed:**
  - Drops before the first scan no longer go to the wrong folder.
  - A broken link no longer shifts the other icons.
  - Mixed selections with the Trash icon can be dragged.
  - Files with `%` or `#` in their name open.
  - Locked items stay put on group Move to Trash.
  - "Undo remove" is no longer offered for files, where it couldn't bring them back.
  - New desktop items are placed on their own display.

Seen while testing and left for 3b:
- **New Folder doesn't open its name field** in the test display, on the old shell too.
- **The test display (headless sway) crashes the shell intermittently.** It happens on the old and new shell at the same rate, with or without the JavaScript JIT. The user's real session doesn't.
- To go back: `~/.local/state/hp-os/trial/switch-back` undoes the most recent install only. Run it again to undo the one before.
- To keep it: `~/.local/state/hp-os/trial/switch-back keep`
- To install a later build as a trial: `goran/installer/try-desktop.sh start <activation package>`

Done in Phase 2 (`hp-os-default-apps.nix`, `default-apps/`):
- **Every account gets the same default apps**, built with Nix, so x86 devices have them too:
  - Image Viewer (Loupe) for pictures
  - Document Viewer (Papers) for PDF, DjVu and comics
  - Text Editor
  - Celluloid for video and music
  - Archive Manager (File Roller) for archives
- **Their launchers live in `~/.local/share/applications`.** They run the Nix build by its full path, not over D-Bus, so Ubuntu's copy or a missing one is never started instead.
- **An account's own choices win.** Simon keeps Chrome for PDFs and Emacs for text. Emacs now has a visible launcher (`defaultApps.extraLaunchers`); before, HP-OS couldn't see it and text opened in LibreOffice Writer.
- **`~/.config/hp-os-mimeapps.list` is the one list of your own choices.**
  - `default-apps/migrate.py` drops choices whose app can't take a file or link. The Microsoft 365 web launchers had been set as the default for Office files and `ms-word:` links, and dropped the file.
  - Files' "Open with… always" choices and `xdg-mime default` both save there. Files' private list was merged in and replaced by a link.
  - A choice an app saves over the managed list is kept, and the file is set aside, so Home Manager updates don't fail.
- **Gwenview's broken launcher is hidden.** It was listed but not installed.

Left for later:
- `text/markdown` and other text subtypes have no explicit default yet.
- A hand-made `~/.local/share/applications/cloud-office.desktop` overrides the managed Office opener with `~/.local/bin/m365-file-open`. Both open files, so it was left alone.
- Standard accounts have no local handler for Office files.

Done in Phase 1:
- **Apps opened from Files run with your normal settings.**
  - A one-function KIO patch (`hp-snap/files-launch-env.patch`) starts them from the environment Files was launched with. Before, they got Files' private settings folder, Qt plugins and theme.
  - Only Files loads this KIO, through its RUNPATH.
- **"Open in New Window", "Detach Tab" and "Show in folder" open HP-OS Files** (`hp-snap/files-new-window.patch`). Before, they failed with "Could not find the program 'dolphin'".
- **"Show in folder" (`org.freedesktop.FileManager1`) is served by HP-OS Files.** Before, it started Ubuntu's Nautilus.
- **COSMIC Files is removed.** The dock pin moves to Files (`files-dock-pin.py`), and folders open in Files for every account. COSMIC Terminal, Launcher and App Library and their theme stay.
- **The old hand-made Trash launcher is set aside** (`~/.local/state/hp-os/files-migration`). Home Manager now provides it.

Deferred from Phase 1:
- **The file-dialog portal gate.** Enabling it would swap Ubuntu's GTK file dialog for the Nix build. Better handled together with matching file dialogs in Phase 4.
- **The leftover app folders under `~/.config/hp-os/apps/files`** (a second Chrome profile, Codex, LibreOffice and others). Nothing writes there any more. They are kept until the trial is accepted.

## Clean-up plan

**Phase 1: one file manager (Dolphin / HP-OS Files)**
- Dolphin is what all other accounts, the Trash, xdg-open, the tests and the drop-slot and drag work already use.
- Remove COSMIC Files:
  - `cosmic-niri.nix` and `cosmic-files-default.py`
  - the `hp-os.nix:58` call
  - the COSMIC theme and settings daemon, if nothing else needs them
- Keep the font fallback.
- Migrate Simon's dock pin back to `org.kde.dolphin`.
- Scope the Files profile to Dolphin only, so launched apps get the real environment back. Migrate the stray contents out of `~/.config/hp-os/apps/files`.
- Ship a `FileManager1` D-Bus service that runs HP-OS Files. Keep stock Dolphin out of `XDG_DATA_DIRS` and build a single Dolphin.
- Have Home Manager own `hp-os-mimeapps.list`, and remove the stray local `hp-os-trash.desktop`.
- Fix the portal gate (`HP-OS:niri`) so network-aware file dialogs actually run.

**Phase 2: one set of default apps**
- Give images, PDF, text, video and audio real defaults. Pick one image viewer and put it on PATH.
- Route Office files to the file-opening handler (`cloud-office` / `%U`).
- Give the same defaults to every account.

**Phase 3: one file-operations service for the desktop**
- One helper does move, copy, trash, rename, mkdir and paste. It runs in the foreground and reports errors as toasts.
- One rule for name clashes, plus a real undo log that covers Trash restore.
- The folder is the only source of truth. The JSON keeps only positions, and scans get a generation number so stale results are thrown away.
- Watch the folder for changes instead of polling every 4 s.
- Delete the old app/url records, `migrate`, `copy-in` and the dead `DesktopImageChoice` path.
- Fix the empty-folder drop, the icon shift and mixed-selection drags.
- Add a file clipboard (GNOME and KDE formats), plus F2, Enter, Ctrl+A/C/X/V/Z and Delete.
- Show the Trash full or empty, and add Empty Trash and Restore in the dock and desktop menus.

**Phase 4: polish**
- Desktop thumbnails from `~/.cache/thumbnails`.
- Drives on the desktop and dock, with eject.
- Recents recorded for opens from the desktop and search.
- Search on XDG folders with faster indexing, plus "Show in folder".
