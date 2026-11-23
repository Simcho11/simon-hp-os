#!/usr/bin/env python3
import importlib.util
import pathlib
import os
import json
import subprocess
import shutil
import tempfile
import unittest
import sys
import signal
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("installer", ROOT / "packaging/install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
HP_OS = str(ROOT / "packaging/hp-os")
BASH = shutil.which("bash")


def hermetic_env(base, **extra):
    """An environment whose per-user folders all live in BASE, away from any running desktop."""
    env = dict(os.environ)
    for name in ("WAYLAND_DISPLAY", "NIRI_SOCKET", "DISPLAY", "WAYLAND_SOCKET", "XDG_SESSION_ID", "QS_ICON_THEME",
                 "HP_OS_OWNED_SESSION", "HP_OS_RUNTIME", "INIR_NIRI_CONFIG_DIR", "QS_CONFIG_PATH"):
        env.pop(name, None)
    (base / "run").mkdir(mode=0o700, exist_ok=True)
    env.update(HOME=str(base / "home"), XDG_RUNTIME_DIR=str(base / "run"), XDG_CONFIG_HOME=str(base / "config"),
               XDG_STATE_HOME=str(base / "state"), XDG_CACHE_HOME=str(base / "cache"),
               INIR_CONFIG_DIR=str(base / "config/hp-os"), INIR_STATE_DIR=str(base / "state/hp-os"),
               INIR_CACHE_DIR=str(base / "cache/hp-os"), HP_OS_PACKAGING=str(ROOT / "packaging"),
               DBUS_SESSION_BUS_ADDRESS="unix:path=" + str(base / "no-bus"), FAKE_DIR=str(base),
               PATH=str(base / "bin") + ":" + os.environ["PATH"])
    env.update(extra)
    return env


def fake(base, name, body):
    path = base / "bin" / name
    path.parent.mkdir(exist_ok=True)
    path.write_text("#!" + BASH + "\n" + body)
    path.chmod(0o755)


# Quickshell for these tests: "-n" is the shell (it blocks until killed, or fails straight away
# for the first $FAKE_FAILS starts); "kill" and "ipc" act on it the way qs does.
FAKE_QS = r'''printf 'qs' >> "$FAKE_DIR/calls"; printf ' <%s>' "$@" >> "$FAKE_DIR/calls"; printf '\n' >> "$FAKE_DIR/calls"
shell="$FAKE_DIR/shell.pid"
case "$1" in
  kill) [[ -f "$shell" ]] && kill "$(cat "$shell")" 2>/dev/null && exit 0; exit 255 ;;
  ipc) [[ -f "$shell" ]] && kill -0 "$(cat "$shell")" 2>/dev/null && exit 0; exit 255 ;;
  -n)
    printf '%s' "${QS_ICON_THEME-}" > "$FAKE_DIR/theme"
    starts=$(( $(cat "$FAKE_DIR/starts" 2>/dev/null || echo 0) + 1 )); echo "$starts" > "$FAKE_DIR/starts"
    if (( starts <= ${FAKE_FAILS:-0} )); then exit 1; fi
    echo $$ > "$shell"
    exec python3 -c 'import time; time.sleep(60)'
    ;;
esac
'''


def wait_for(condition, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.05)
    return condition()

class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = pathlib.Path(self.temp.name)
        self.runtime = self.base / "runtime"
        (self.runtime / "modules/hpos").mkdir(parents=True)
        (self.runtime / "shell.qml").write_text("ShellRoot {}")
        (self.runtime / "modules/hpos/HposPanels.qml").write_text("Item {}")
        self.prefix = self.base / "installed"

    def test_dry_run_creates_nothing(self):
        result = installer.install(self.runtime, self.prefix, True)
        self.assertTrue(result["dry_run"])
        self.assertFalse(self.prefix.exists())

    def test_install_and_replacement_preserve_previous_version(self):
        installer.install(self.runtime, self.prefix)
        self.assertTrue((self.prefix / "bin/hp-os").stat().st_mode & 0o111)
        self.assertNotIn("@runtime@", (self.prefix / "bin/hp-os").read_text())
        settings = (self.prefix / "share/applications/hp-os-settings.desktop").read_text()
        self.assertIn(f"Exec={self.prefix}/bin/hp-os settings", settings)
        (self.prefix / "keep").write_text("previous installation")
        result = installer.install(self.runtime, self.prefix)
        self.assertEqual((pathlib.Path(result["backup"]) / "keep").read_text(), "previous installation")
        self.assertFalse((self.prefix / "keep").exists())

    def test_invalid_runtime_rejected(self):
        (self.runtime / "shell.qml").unlink()
        with self.assertRaises(ValueError):
            installer.install(self.runtime, self.prefix)
        self.assertFalse(self.prefix.exists())

class RunnerIsolationTests(unittest.TestCase):
    def test_commands_target_only_selected_quickshell_runtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary)
            binary = base / "qs"
            binary.write_text('#!' + shutil.which('bash') + '\nprintf "%s\\n" "$@" > "$COMMAND_LOG"\n')
            binary.chmod(0o755)
            env = hermetic_env(base, PATH=str(base) + ":" + os.environ["PATH"], COMMAND_LOG=str(base / "args"), HP_OS_RUNTIME=str(base / "runtime"))
            expected = {"stop": ["kill", "-p", str(base / "runtime")], "settings": ["ipc", "-p", str(base / "runtime"), "call", "settings", "toggle"], "logs": ["log", "-p", str(base / "runtime")]}
            for command, arguments in expected.items():
                subprocess.run(["bash", str(ROOT / "packaging/hp-os"), command], env=env, check=True)
                self.assertEqual((base / "args").read_text().splitlines(), arguments)

    def test_starting_session_inside_wayland_is_rejected(self):
        env = dict(os.environ, WAYLAND_DISPLAY="wayland-existing")
        result = subprocess.run(["bash", str(ROOT / "packaging/hp-os"), "session"], env=env, capture_output=True)
        self.assertEqual(result.returncode, 1)

    def test_hp_os_session_uses_private_bus_and_owned_config(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary)
            binary = base / "dbus-run-session"
            binary.write_text('#!' + shutil.which('bash') + '\nprintf "%s\\n" "$@" > "$COMMAND_LOG"\nprintf "%s\\n" "$XDG_CURRENT_DESKTOP" "$XDG_SESSION_DESKTOP" "${NIRI_SOCKET-unset}" > "$SESSION_LOG"\n')
            binary.chmod(0o755)
            owned = base / "hp-os-niri"
            existing = base / "niri/config.kdl"
            existing.parent.mkdir()
            existing.write_text('spawn-at-startup "dms"\n')
            # touch-support failing must not stop the session (and adds no include).
            fake(base, "touch-support", "exit 1\n")
            env = hermetic_env(base, PATH=str(base) + ":" + str(base / "bin") + ":" + os.environ["PATH"],
                               HOME=str(base), XDG_CONFIG_HOME=str(base / "config"),
                               COMMAND_LOG=str(base / "args"), SESSION_LOG=str(base / "env"),
                               INIR_NIRI_CONFIG_DIR=str(owned), HP_OS_PACKAGING=str(ROOT / "packaging"),
                               NIRI_SOCKET="existing-session-socket")
            fake(base, "logger", "")
            packaged_config = base / "dbus/share/dbus-1/session.conf"
            packaged_config.parent.mkdir(parents=True)
            packaged_config.write_text("<busconfig/>")
            runner = base / "hp-os"
            host_config = base / "etc/dbus-1/session.conf"
            runner.write_text((ROOT / "packaging/hp-os").read_text().replace("@dbusSessionConfig@", str(packaged_config)).replace("/etc/dbus-1/session.conf", str(host_config)))
            runner.chmod(0o755)
            subprocess.run(["bash", str(runner), "session"], env=env, check=True)
            self.assertEqual((base / "args").read_text().splitlines(), ["--config-file=" + str(packaged_config), "--", "niri", "--config", str(owned / "config.kdl")])
            self.assertIn("'@dbusSessionConfig@' '${pkgs.dbus}/share/dbus-1/session.conf'", (ROOT / "packaging/package.nix").read_text())
            # NixOS host config takes precedence, avoiding a duplicate listener.
            host_config.parent.mkdir(parents=True)
            host_config.write_text("<busconfig/>")
            runner.chmod(0o755)
            subprocess.run(["bash", str(runner), "session"], env=env, check=True)
            self.assertEqual((base / "args").read_text().splitlines()[0], "--config-file=" + str(host_config))
            self.assertEqual((base / "env").read_text().splitlines(), ["HP-OS:niri", "hp-os", "unset"])
            self.assertEqual(existing.read_text(), 'spawn-at-startup "dms"\n')
            self.assertNotIn('"dms"', (owned / "config.kdl").read_text())
            (owned / "config.kdl").write_text("// existing HP-OS preferences\n")
            subprocess.run(["bash", str(ROOT / "packaging/hp-os"), "session"], env=env, check=True)
            self.assertEqual((owned / "config.kdl").read_text(), "// existing HP-OS preferences\n")

    def test_private_bus_activation_environment_precedes_shell_start(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary)
            runtime = base / "runtime"
            runtime.mkdir()
            (runtime / "shell.qml").write_text("ShellRoot {}")
            log = base / "calls"
            for command in ["dbus-update-activation-environment", "gdbus"]:
                fake(base, command, 'printf "%s" "' + command + '" >> "$FAKE_DIR/calls"\nprintf " <%s>" "$@" >> "$FAKE_DIR/calls"\nprintf "\\n" >> "$FAKE_DIR/calls"\n')
            fake(base, "qs", FAKE_QS)
            fake(base, "logger", "")
            env = hermetic_env(base, HP_OS_RUNTIME=str(runtime), HP_OS_OWNED_SESSION="1", DISPLAY=":test")

            def run_until_started():
                (base / "starts").unlink(missing_ok=True)
                shell = subprocess.Popen(["bash", HP_OS, "run"], env=env)
                try:
                    self.assertTrue(wait_for(lambda: (base / "starts").exists()), "shell did not start")
                    subprocess.run(["bash", HP_OS, "stop"], env=env, check=True)
                    self.assertEqual(shell.wait(timeout=10), 0)
                finally:
                    if shell.poll() is None:
                        shell.kill()
                        shell.wait()

            run_until_started()
            self.assertEqual((base / "theme").read_text(), "HP-OS")
            lines = log.read_text().splitlines()
            self.assertEqual(lines[0], "dbus-update-activation-environment <WAYLAND_DISPLAY> <XDG_CURRENT_DESKTOP> <XDG_SESSION_DESKTOP> <XDG_SESSION_TYPE> <XDG_RUNTIME_DIR> <NIRI_SOCKET> <DISPLAY>")
            self.assertIn(f"qs <-n> <-p> <{runtime}>", lines)
            self.assertNotIn("--systemd", log.read_text())
            log.write_text("")
            env.pop("HP_OS_OWNED_SESSION")
            env["QS_ICON_THEME"] = "ExplicitTheme"
            run_until_started()
            self.assertNotIn("dbus-update-activation-environment", log.read_text())
            self.assertEqual((base / "theme").read_text(), "ExplicitTheme")

    def test_login_entry_has_hp_os_name(self):
        entry = (ROOT / "packaging/hp-os.desktop").read_text()
        self.assertIn("\nName=HP-OS\n", entry)
        self.assertIn("\nExec=@exec@ session\n", entry)

    def test_first_run_wallpaper_path_and_existing_config_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = pathlib.Path(temporary) / "config.json"
            wallpaper = str(pathlib.Path(temporary) / "wallpaper with spaces.svg")
            command = ["python3", str(ROOT / "packaging/initialize-config.py"), str(ROOT / "packaging/default-config.json"), str(target), wallpaper]
            env = dict(os.environ, INIR_STATE_DIR=str(pathlib.Path(temporary) / "state"))
            subprocess.run(command, env=env, check=True)
            self.assertEqual(json.loads(target.read_text())["background"]["wallpaperPath"], wallpaper)
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            target.write_text('{"user": "preferences"}')
            subprocess.run(command, env=env, check=True)
            self.assertEqual(json.loads(target.read_text()), {"user": "preferences"})

    def test_version_metadata_replaces_broken_updater_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            version = directory / "version.json"
            version.write_text("")
            user_config = directory / "config.json"
            user_config.write_text('{"custom":true}')
            subprocess.run(["python3", str(ROOT / "packaging/write-version.py"), temporary], check=True)
            metadata = json.loads(version.read_text())
            self.assertEqual(metadata["version"], "0.1.0")
            self.assertEqual(metadata["upstreamVersion"], "2.33.0")
            self.assertEqual(metadata["updateStrategy"], "package-manager")
            self.assertEqual(metadata["installSource"], "HP-OS")
            self.assertEqual(version.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(user_config.read_text()), {"custom": True})
            self.assertEqual(sorted(p.name for p in directory.iterdir()), ["config.json", "version.json"])

    def test_fresh_config_enables_real_family_panels(self):
        settings = json.loads((ROOT / "packaging/default-config.json").read_text())
        self.assertEqual(settings["panelFamily"], "hpos")
        self.assertIn("irisBar", settings["enabledPanels"])
        self.assertIn("irisNotificationPopup", settings["enabledPanels"])
        self.assertFalse(settings["appearance"]["typography"]["syncWithSystem"])


class ShellSupervisionTests(unittest.TestCase):
    """hp-os run keeps the shell for the session; stop and restart work with it."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = pathlib.Path(temporary.name)
        self.runtime = self.base / "runtime"
        self.runtime.mkdir()
        (self.runtime / "shell.qml").write_text("ShellRoot {}")
        fake(self.base, "qs", FAKE_QS)
        fake(self.base, "logger", 'printf "%s\\n" "$*" >> "$FAKE_DIR/journal"\n')
        self.env = hermetic_env(self.base, HP_OS_RUNTIME=str(self.runtime))
        self.runs = []
        self.addCleanup(self.cleanup)

    def cleanup(self):
        for run in self.runs:
            if run.poll() is None:
                run.kill()
                run.wait()
            run.stderr.close()
        shell = self.base / "shell.pid"
        if shell.exists():
            try:
                os.kill(int(shell.read_text()), signal.SIGKILL)
            except ProcessLookupError:
                pass

    def hp_os(self, *args, **kwargs):
        return subprocess.run(["bash", HP_OS, *args], env=self.env, capture_output=True, text=True, **kwargs)

    def start(self):
        run = subprocess.Popen(["bash", HP_OS, "run"], env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        self.runs.append(run)
        return run

    def starts(self):
        path = self.base / "starts"
        return int(path.read_text()) if path.exists() else 0

    def shell_alive(self):
        try:
            pid = (self.base / "shell.pid").read_text().strip()
            return pathlib.Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] != "Z"
        except (OSError, IndexError):
            return False

    def test_shell_comes_back_after_a_crash_and_stop_really_stops(self):
        self.env["FAKE_FAILS"] = "1"
        run = self.start()
        self.assertTrue(wait_for(lambda: self.starts() == 2 and self.shell_alive()), "shell was not started again")
        self.assertIn("starting it again in 1 s", (self.base / "journal").read_text())
        self.assertEqual(self.hp_os("stop").returncode, 0)
        self.assertEqual(run.wait(timeout=10), 0)
        time.sleep(1.5)
        self.assertEqual(self.starts(), 2, "the shell came back after stop")
        self.assertFalse(self.shell_alive())

    def test_restart_starts_one_new_shell_at_once(self):
        run = self.start()
        self.assertTrue(wait_for(lambda: self.starts() == 1 and self.shell_alive()))
        first = (self.base / "shell.pid").read_text()
        began = time.monotonic()
        self.assertEqual(self.hp_os("restart").returncode, 0)
        self.assertTrue(wait_for(lambda: self.starts() == 2 and self.shell_alive()), "restart did not start the shell")
        self.assertLess(time.monotonic() - began, 1, "restart waited as if the shell had crashed")
        self.assertNotEqual((self.base / "shell.pid").read_text(), first)
        # A second "run" in the same session leaves the shell to the first one.
        second = self.hp_os("run", timeout=20)
        self.assertEqual(second.returncode, 0)
        self.assertIn("already running", second.stderr)
        self.assertEqual(self.starts(), 2)
        self.assertNotIn("stopped unexpectedly", (self.base / "journal").read_text() if (self.base / "journal").exists() else "")
        self.hp_os("stop")
        self.assertEqual(run.wait(timeout=10), 0)

    def test_crash_loop_gives_up(self):
        self.env["FAKE_FAILS"] = "100"
        fake(self.base, "sleep", "exit 0\n")  # no waiting between attempts in this test
        run = self.start()
        self.assertEqual(run.wait(timeout=30), 1)
        self.assertEqual(self.starts(), 6)
        self.assertIn("not starting it again", (self.base / "journal").read_text())

    def test_no_restart_once_the_compositor_is_gone(self):
        import socket
        display = self.base / "run/wayland-test"
        listener = socket.socket(socket.AF_UNIX)
        self.addCleanup(listener.close)
        here = os.getcwd()
        os.chdir(display.parent)  # a short socket name, whatever the temporary folder's length
        try:
            listener.bind(display.name)
        finally:
            os.chdir(here)
        self.env["WAYLAND_DISPLAY"] = "wayland-test"
        run = self.start()
        self.assertTrue(wait_for(lambda: self.starts() == 1 and self.shell_alive()))
        display.unlink()
        os.kill(int((self.base / "shell.pid").read_text()), signal.SIGKILL)
        self.assertEqual(run.wait(timeout=10), 0)
        self.assertEqual(self.starts(), 1)

    def test_session_end_stops_supervision_and_shell(self):
        run = self.start()
        self.assertTrue(wait_for(lambda: self.starts() == 1 and self.shell_alive()))
        run.terminate()
        self.assertEqual(run.wait(timeout=10), 0)
        self.assertTrue(wait_for(lambda: not self.shell_alive()), "shell outlived its session")
        self.assertEqual(self.starts(), 1)

    def owner(self, *arguments):
        owner = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", *arguments])
        self.addCleanup(owner.wait)
        self.addCleanup(owner.kill)
        (self.base / "owner.pid").write_text(str(owner.pid))
        fake(self.base, "gdbus", r'''case "$*" in
  *NameHasOwner*) n=$(( $(cat "$FAKE_DIR/owner-checks" 2>/dev/null || echo 0) + 1 )); echo $n > "$FAKE_DIR/owner-checks"
    if (( n <= FAKE_OWNED_CHECKS )); then echo '(true,)'; else echo '(false,)'; fi ;;
  *GetConnectionUnixProcessID*) echo "(uint32 $(cat "$FAKE_DIR/owner.pid"),)" ;;
esac
''')

    def test_waits_for_a_previous_shell_to_let_go_of_notifications(self):
        self.owner(str(self.runtime))
        self.env["FAKE_OWNED_CHECKS"] = "5"
        run = self.start()
        self.assertTrue(wait_for(lambda: self.starts() == 1, timeout=15), "did not start once the old shell let go")
        self.hp_os("stop")
        self.assertEqual(run.wait(timeout=10), 0)

    def test_waits_while_the_notifications_owner_is_already_gone(self):
        self.owner(str(self.runtime))
        (self.base / "owner.pid").write_text("4194305")  # above pid_max: no such process
        self.env["FAKE_OWNED_CHECKS"] = "3"
        run = self.start()
        self.assertTrue(wait_for(lambda: self.starts() == 1, timeout=15))
        self.hp_os("stop")
        self.assertEqual(run.wait(timeout=10), 0)

    def test_never_replaces_another_desktops_notifications(self):
        self.owner("some-other-desktop")
        self.env["FAKE_OWNED_CHECKS"] = "1000"
        run = self.start()
        self.assertEqual(run.wait(timeout=10), 1)
        self.assertIn("A notification server is already running", run.stderr.read())
        self.assertEqual(self.starts(), 0)


class SessionSettingsTests(unittest.TestCase):
    """hp-os session always gives niri settings it accepts (real niri validate)."""

    def setUp(self):
        if not shutil.which("niri"):
            self.skipTest("niri is needed to check settings")
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = pathlib.Path(temporary.name)
        self.niri = self.base / "config/hp-os/niri"
        fake(self.base, "dbus-run-session", 'printf "%s\\n" "$@" > "$FAKE_DIR/started"\n')
        fake(self.base, "touch-support", 'printf "// gestures\\n"\n')
        fake(self.base, "logger", "")
        self.env = hermetic_env(self.base)

    def session(self):
        (self.base / "started").unlink(missing_ok=True)
        result = subprocess.run(["bash", HP_OS, "session"], env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.base / "started").exists(), "niri was not started")
        return result

    def read(self, name):
        return (self.niri / name).read_text()

    def test_first_session_keeps_accepted_settings(self):
        self.session()
        self.assertIn('include "config.d/60-touch.kdl"', self.read("config.kdl"))
        self.assertEqual((self.niri / "last-good/config.kdl").read_text(), self.read("config.kdl"))
        self.assertEqual((self.niri / "last-good/config.d/60-touch.kdl").read_text(), "// gestures\n")

    def test_broken_main_settings_are_put_back_and_other_changes_stay(self):
        (self.niri / "config.d").mkdir(parents=True)
        (self.niri / "config.d/46-accent.kdl").write_text("// accent A\n")
        self.session()
        with (self.niri / "config.kdl").open("a") as stream:
            stream.write('include "config.d/46-accent.kdl"\n')
        self.session()
        good = self.read("config.kdl")
        accent = 'layout { focus-ring { active-color "#123456"; }; }\n'
        (self.niri / "config.d/46-accent.kdl").write_text(accent)
        with (self.niri / "config.kdl").open("a") as stream:
            stream.write("binds {\n")
        broken = self.read("config.kdl")
        result = self.session()
        self.assertEqual(self.read("config.kdl"), good)
        self.assertEqual((self.niri / "rejected/config.kdl").read_text(), broken)
        self.assertIn("put back the last accepted config.kdl", result.stderr)
        self.assertEqual(self.read("config.d/46-accent.kdl"), accent)
        self.assertEqual((self.niri / "last-good/config.d/46-accent.kdl").read_text(), accent)

    def test_broken_include_is_put_back_alone(self):
        (self.niri / "config.d").mkdir(parents=True)
        (self.niri / "config.d/47-unlock-zoom.kdl").write_text("// empty\n")
        self.session()
        with (self.niri / "config.kdl").open("a") as stream:
            stream.write('include "config.d/47-unlock-zoom.kdl"\n')
        self.session()
        main = self.read("config.kdl")
        (self.niri / "config.d/47-unlock-zoom.kdl").write_text("overview {\n")
        self.session()
        self.assertEqual(self.read("config.d/47-unlock-zoom.kdl"), "// empty\n")
        self.assertEqual(self.read("config.kdl"), main)

    def test_a_broken_home_manager_include_is_left_out(self):
        managed = self.base / "home-manager/49-hp-snap.kdl"
        managed.parent.mkdir()
        managed.write_text("// house rules\n")
        (self.niri / "config.d").mkdir(parents=True)
        (self.niri / "config.d/49-hp-snap.kdl").symlink_to(managed)
        self.session()
        with (self.niri / "config.kdl").open("a") as stream:
            stream.write('include "config.d/49-hp-snap.kdl"\n')
        self.session()
        main = self.read("config.kdl")
        managed.write_text("window-rule {\n")
        result = self.session()
        self.assertIn('left out include "config.d/49-hp-snap.kdl"', result.stderr)
        self.assertEqual(self.read("config.kdl"), main.replace('include "config.d/49-hp-snap.kdl"\n', ""))
        self.assertTrue((self.niri / "config.d/49-hp-snap.kdl").is_symlink())
        self.assertEqual(managed.read_text(), "window-rule {\n")

    def test_without_a_copy_hp_os_settings_and_accepted_includes_are_used(self):
        (self.niri / "config.d").mkdir(parents=True)
        (self.niri / "config.d/61-goran-ime.kdl").write_text("// ime\n")
        (self.niri / "config.kdl").write_text('binds {\ninclude "config.d/61-goran-ime.kdl"\ninclude "config.d/99-missing.kdl"\n')
        (self.niri / "config.kdl.bindings-state.json").write_text("{}")
        self.session()
        main = self.read("config.kdl")
        self.assertTrue(main.startswith((ROOT / "packaging/niri.kdl").read_text().rstrip()))
        self.assertIn('include "config.d/61-goran-ime.kdl"', main)
        self.assertNotIn("99-missing", main)
        self.assertFalse((self.niri / "config.kdl.bindings-state.json").exists())
        self.assertEqual(subprocess.run(["niri", "validate", "--config", str(self.niri / "config.kdl")], capture_output=True).returncode, 0)

    def test_failing_steps_do_not_stop_the_session(self):
        fake(self.base, "touch-support", "exit 1\n")
        (self.base / "config/hp-os").mkdir(parents=True)
        (self.base / "config/hp-os/config.json").write_text("{ not json")
        result = self.session()
        self.assertIn("could not update settings", result.stderr)
        self.assertIn("kept its previous touch gestures", result.stderr)


class SessionLifetimeTests(unittest.TestCase):
    def check_lifetime(self, terminate):
        with tempfile.TemporaryDirectory() as directory:
            pidfile = pathlib.Path(directory) / "detached.pid"
            # Simulate Niri starting a detached shell which ignores TERM.
            sleeper = "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)"
            parent = ("import subprocess,sys,time,pathlib; "
                      "p=subprocess.Popen([sys.executable,'-c',sys.argv[2]],start_new_session=True); "
                      "pathlib.Path(sys.argv[1]).write_text(str(p.pid)); "
                      "time.sleep(60 if sys.argv[3]=='wait' else .3)")
            sentinel = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
            supervisor = subprocess.Popen([sys.executable, str(ROOT / "packaging/session-supervisor.py"),
                                           sys.executable, "-c", parent, str(pidfile), sleeper,
                                           "wait" if terminate else "exit"])
            detached = None
            try:
                deadline = time.monotonic() + 5
                while not pidfile.exists() and time.monotonic() < deadline:
                    time.sleep(.05)
                self.assertTrue(pidfile.exists(), "compositor child did not start")
                detached = int(pidfile.read_text())
                if terminate:
                    time.sleep(.2)
                    supervisor.terminate()
                self.assertEqual(supervisor.wait(timeout=10), 0)
                self.assertFalse(pathlib.Path(f"/proc/{detached}").exists(), "detached shell was not reaped")
                self.assertIsNone(sentinel.poll(), "unrelated desktop process was stopped")
            finally:
                if supervisor.poll() is None:
                    supervisor.kill()
                supervisor.wait()
                sentinel.terminate()
                sentinel.wait()
                if detached and pathlib.Path(f"/proc/{detached}").exists():
                    os.kill(detached, signal.SIGKILL)

    def test_compositor_exit_reaps_detached_children(self):
        self.check_lifetime(False)

    def test_session_termination_reaps_detached_children(self):
        self.check_lifetime(True)

    def test_apps_that_exit_during_the_session_are_reaped(self):
        # The compositor starts apps detached (a double fork), so they come back to the supervisor.
        compositor = """
import os, sys, time
pid = os.fork()
if pid == 0:
    if os.fork() == 0:
        os._exit(0)
    os._exit(0)
os.waitpid(pid, 0)
time.sleep(1.5)
zombies = 0
for entry in os.listdir('/proc'):
    try:
        state, parent = open(f'/proc/{entry}/stat').read().rsplit(')', 1)[1].split()[:2]
    except (OSError, ValueError):
        continue
    zombies += state == 'Z' and parent == str(os.getppid())
sys.exit(zombies)
"""
        supervisor = subprocess.run([sys.executable, str(ROOT / "packaging/session-supervisor.py"), sys.executable, "-c", compositor], timeout=20)
        self.assertEqual(supervisor.returncode, 0, "exited apps stayed behind as zombies")

if __name__ == "__main__":
    unittest.main()
