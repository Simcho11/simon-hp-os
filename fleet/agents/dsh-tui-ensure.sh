#!/usr/bin/env bash
# Keep the DeepSeek Harness terminal UI usable beside the running web profile.
#
# The TUI is the community dsh-TUI bundle, installed into its own dsh profile
# (`~/.dsh/profiles/dsh-tui`). It reads the same `~/.dsh/sessions` store as the
# web profile, so `/resume` reaches web conversations. Three runtime pieces are
# outside what Nix can own:
#
#   1. The profile's dependency on `@deepseek-harness-tui/dsh-tui` and its
#      bundle selection. A package reinstall or profile reset can drop either,
#      and the launcher's bootstrap is the only other writer.
#   2. `profiles/tui`, a relative link to `dsh-tui`, so the command the person
#      types (`dsh tui`) names the same profile the dsh-TUI launcher hard-codes.
#      A real `tui` directory is another operator's profile and is left alone.
#   3. `--expose-internals` for the Node children that dsh-TUI starts directly.
#      The Nix dsh package replaces the native require-builtin addon with a
#      plain `require`, which can only reach `internal/modules/*` when Node was
#      started with that flag. The dsh wrapper sets it; `process.execPath`
#      children and the `dst` automation CLI do not, so they fail with
#      "Cannot find module 'internal/modules/esm/loader'". The TUI falls back to
#      `dsh --profile`, but the fallback prints a warning and `dst` (session
#      list, run, update) fails outright. The edits below add the flag to the
#      exact spawn sites and are idempotent.
#
# The script also moves a web-only `ui-theme` override out of the global
# `~/.dsh/cordis.patch.yml`. DSH composes the global patch into every profile,
# and a terminal profile has no such row, so a global theme override stops
# `dsh tui` from booting. The override belongs in the web profile's own patch.
#
# Environment: HOME (profile owner), DSH_BIN (the harness CLI), PYTHON
# (interpreter), DSH_TUI_VERSION (version pinned on first install), and
# DSH_TUI_PACKAGE (bundle package name, optional).
set -euo pipefail

DSH_BIN="${DSH_BIN:-dsh}"
PYTHON_BIN="${PYTHON:-python3}"
PACKAGE="${DSH_TUI_PACKAGE:-@deepseek-harness-tui/dsh-tui}"
VERSION="${DSH_TUI_VERSION:-latest}"
dsh_root="${DSH_HOME:-${HOME}/.dsh}"
profiles="${dsh_root}/profiles"
profile="${profiles}/dsh-tui"
global_patch="${dsh_root}/cordis.patch.yml"
web_patch="${profiles}/web/cordis.patch.yml"

# A host without dsh keeps no profile to repair.
if [ ! -d "${dsh_root}" ]; then
  echo "dsh-tui-ensure: no ${dsh_root} on this host; nothing to do"
  exit 0
fi

select_bundle() {
  "${PYTHON_BIN}" - "${profile}/package.json" "$1" <<'PYTHON'
import json
import sys

path, bundle = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as handle:
        manifest = json.load(handle)
except Exception as error:  # A hand-edited manifest must never be clobbered.
    print(f"{bundle}: leaving {path} alone: {error}", file=sys.stderr)
    raise SystemExit(0)
bundles = manifest.setdefault("dsh", {}).setdefault("profile", {}).setdefault("bundles", [])
if bundle in bundles:
    raise SystemExit(0)
bundles.append(bundle)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
print(f"dsh-tui-ensure: selected the {bundle} bundle")
PYTHON
}

ensure_profile() {
  # `dsh plugin add` both writes the dependency and selects the bundle. It runs
  # only when the installed copy or the manifest entry is missing, so a person
  # who updated the TUI through `/update` is never rolled back.
  if [ ! -f "${profile}/node_modules/${PACKAGE}/package.json" ] \
    || ! grep -q "\"${PACKAGE}\"" "${profile}/package.json" 2>/dev/null; then
    echo "dsh-tui-ensure: installing ${PACKAGE}@${VERSION} into the dsh-tui profile"
    "${DSH_BIN}" plugin --profile dsh-tui add "${PACKAGE}@${VERSION}"
  fi
  # Base is the profile's first layer; select it before the TUI layer.
  select_bundle "@deepseek-ai/dsh-base"
  select_bundle "${PACKAGE}"
}

ensure_tui_alias() {
  if [ -L "${profiles}/tui" ]; then
    if [ "$(readlink -f "${profiles}/tui")" != "$(readlink -f "${profile}")" ]; then
      echo "dsh-tui-ensure: ${profiles}/tui points somewhere else; leaving dsh tui on that profile" >&2
    fi
    return 0
  fi
  if [ -e "${profiles}/tui" ]; then
    echo "dsh-tui-ensure: ${profiles}/tui is a separate profile; leaving dsh tui on that profile" >&2
    return 0
  fi
  ln -s dsh-tui "${profiles}/tui"
  echo "dsh-tui-ensure: linked profiles/tui -> dsh-tui"
}

patch_expose_internals() {
  local package="${profile}/node_modules/${PACKAGE}"
  [ -f "${package}/bin/dsh-tui.js" ] || return 0
  "${PYTHON_BIN}" - "${package}" <<'PYTHON'
import sys
from pathlib import Path

root = Path(sys.argv[1])
FLAG = "--expose-internals"

# Each pair is one exact spawn site. The replacement keeps every other token
# unchanged so a surrounding refactor fails the patch instead of hiding.
TARGETS = (
    (
        "bin/dsh-tui.js",
        "const child = spawn(process.execPath, [entry, ...appArgs], {",
        "const child = spawn(process.execPath, ['--expose-internals', entry, ...appArgs], {",
    ),
    (
        "cli/adapters/dsh/index.mjs",
        "command: process.execPath, args, cwd: request.cwd",
        "command: process.execPath, args: ['--expose-internals', ...args], cwd: request.cwd",
    ),
    (
        "cli/adapters/dsh/index.mjs",
        "command: process.execPath, args: [runtime.path, ...request.args], cwd: request.cwd",
        "command: process.execPath, args: ['--expose-internals', runtime.path, ...request.args], cwd: request.cwd",
    ),
)


def rewrite(path: Path, old: str, new: str) -> str:
    text = path.read_text(encoding="utf-8")
    if new in text:
        return "already patched"
    matches = text.count(old)
    if matches != 1:
        return "anchor not found once (%d matches); left untouched" % matches
    # Replace through a new file so a hardlink into the pnpm store is not
    # rewritten in place.
    staged = path.with_name(path.name + ".ensure-new")
    staged.write_text(text.replace(old, new), encoding="utf-8")
    staged.replace(path)
    return "patched"


failed = False
for relative, old, new in TARGETS:
    target = root / relative
    if not target.exists():
        print("dsh-tui-ensure: %s is missing; skipped" % relative)
        continue
    outcome = rewrite(target, old, new)
    print("dsh-tui-ensure: %s %s" % (relative, outcome))
    if outcome.startswith("anchor not found"):
        failed = True
if failed:
    raise SystemExit(1)
PYTHON
}

migrate_theme_override() {
  "${PYTHON_BIN}" - "${global_patch}" "${web_patch}" <<'PYTHON'
import sys
from pathlib import Path

global_path, web_path = Path(sys.argv[1]), Path(sys.argv[2])
BEGIN = "# BEGIN tmux-theme managed appearance\n"
END = "# END tmux-theme managed appearance\n"

try:
    text = global_path.read_text(encoding="utf-8")
except FileNotFoundError:
    raise SystemExit(0)
if BEGIN not in text:
    raise SystemExit(0)
before, rest = text.split(BEGIN, 1)
if END not in rest:
    print("dsh-tui-ensure: incomplete managed theme block in %s; left untouched" % global_path, file=sys.stderr)
    raise SystemExit(0)
block, after = rest.split(END, 1)
managed = BEGIN + block + END
remaining = (before + after).strip()
if remaining in ("", "[]", "---\n[]"):
    remaining = "[]"
global_path.write_text(remaining + "\n", encoding="utf-8")
print("dsh-tui-ensure: removed the web-only ui-theme override from %s" % global_path)

# The web profile keeps the preference; other profiles cannot compose the row.
if not web_path.exists():
    print("dsh-tui-ensure: no web profile patch; dropped the ui-theme override", file=sys.stderr)
    raise SystemExit(0)
web = web_path.read_text(encoding="utf-8")
if "id: ui-theme" in web:
    raise SystemExit(0)
web_path.write_text(managed + "\n" + web, encoding="utf-8")
print("dsh-tui-ensure: moved the ui-theme override into %s" % web_path)
PYTHON
}

ensure_profile
ensure_tui_alias
patch_expose_internals
migrate_theme_override
