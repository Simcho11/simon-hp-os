"""hp-os-file-clipboard copy|cut PATH...  Put files on the Wayland clipboard, as Files does.

Offers the file list in every form apps read it:
  text/uri-list                    the standard list (most apps, and Files' Paste)
  x-special/gnome-copied-files     "copy" or "cut", then the list (GNOME and GTK apps)
  application/x-kde-cutselection   "1" when cut (Files moves the files on Paste instead of copying)
  text/plain (and X11's names)     the paths as text (terminals, text fields)

It owns the clipboard through the data-control protocol (no window or focus needed) and
stays running until something else is copied or the clipboard is cleared, then exits.
Once the files are on the clipboard it says so: "ready" on stdout, and READY=1 to systemd
when it runs as a service (Type=notify). SIGTERM, SIGINT and SIGHUP stop it cleanly.

It never waits on an app that reads the clipboard: each reader's copy is written as the
reader takes it, while the helper goes on answering others, and a reader that takes
nothing for WRITE_TIMEOUT seconds is dropped.
"""
import fcntl
import os
from pathlib import Path
import select
import signal
import socket
import sys
import time

from pywayland.client import Display
from hp_os_clipboard_protocols.wayland import WlSeat
from hp_os_clipboard_protocols.wlr_data_control_unstable_v1 import ZwlrDataControlManagerV1

WRITE_TIMEOUT = 10


def payloads(mode, paths):
    uris = [Path(os.path.abspath(p)).as_uri() for p in paths]
    text = "\n".join(os.path.abspath(p) for p in paths).encode()
    return {
        "text/uri-list": ("\r\n".join(uris) + "\r\n").encode(),
        "x-special/gnome-copied-files": ("\n".join([mode] + uris)).encode(),
        "application/x-kde-cutselection": b"1" if mode == "cut" else b"0",
        "text/plain;charset=utf-8": text,
        "text/plain": text,
        "UTF8_STRING": text,
        "STRING": text,
        "TEXT": text,
    }


def close_quietly(fd):
    try:
        os.close(fd)
    except OSError:
        pass


class Writers:
    """The copies being handed to readers: {fd: [what is left to write, deadline]}."""

    def __init__(self):
        self.pending = {}

    def start(self, fd, payload):
        try:
            fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) | os.O_NONBLOCK)
        except OSError:
            close_quietly(fd)
            return
        self.pending[fd] = [memoryview(payload), time.monotonic() + WRITE_TIMEOUT]
        self.write(fd)

    def write(self, fd):
        entry = self.pending.get(fd)
        if entry is None:
            return
        try:
            while entry[0]:
                written = os.write(fd, entry[0])
                entry[0] = entry[0][written:]
        except BlockingIOError:
            return                          # the reader has its pipe full: go on when it takes some
        except OSError:
            pass                            # the reader went away
        self.close(fd)

    def close(self, fd):
        self.pending.pop(fd, None)
        close_quietly(fd)

    def expire(self, now):
        for fd in [fd for fd, entry in self.pending.items() if entry[1] <= now]:
            self.close(fd)

    def wait_ms(self, now):
        if not self.pending:
            return -1
        return max(0, int((min(entry[1] for entry in self.pending.values()) - now) * 1000) + 1)

    def close_all(self):
        for fd in list(self.pending):
            self.close(fd)


def notify_systemd_ready():
    address = os.environ.get("NOTIFY_SOCKET", "")
    if not address:
        return
    if address.startswith("@"):
        address = "\0" + address[1:]
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM | socket.SOCK_CLOEXEC) as notify:
            notify.connect(address)
            notify.sendall(b"READY=1")
    except OSError:
        pass


def leave(code, message=""):
    """Ends at once. Python's own clean-up at exit frees the Wayland connection before the
    objects that use it, and crashes."""
    try:
        if message:
            print(message, file=sys.stderr)
        sys.stdout.flush()
        sys.stderr.flush()
    except OSError:
        pass
    os._exit(code)


def say_ready():
    try:
        print("ready", flush=True)
    except OSError:
        pass                                # nobody is listening on stdout any more
    notify_systemd_ready()


def main(argv):
    if len(argv) < 3 or argv[1] not in ("copy", "cut"):
        sys.exit(__doc__)
    paths = [p for p in argv[2:] if os.path.lexists(p)]
    if not paths:
        sys.exit("Nothing to put on the clipboard.")
    data = payloads(argv[1], paths)

    # A signal only marks the helper as stopping and wakes its loop; nothing is raised inside
    # a Wayland callback, where an exception would be swallowed with the event it was handling.
    state = {"cancelled": False, "stop": False}
    wake_read, wake_write = os.pipe2(os.O_NONBLOCK | os.O_CLOEXEC)
    signal.set_wakeup_fd(wake_write, warn_on_full_buffer=False)
    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(number, lambda *_: state.__setitem__("stop", True))

    display = Display()
    try:
        display.connect()
    except Exception:
        leave(1, "There is no Wayland display to put the files on the clipboard of.")
    found = {}

    def on_global(registry, name, interface, version):
        if interface == "wl_seat" and "seat" not in found:
            found["seat"] = registry.bind(name, WlSeat, 1)
        elif interface == "zwlr_data_control_manager_v1":
            found["manager"] = registry.bind(name, ZwlrDataControlManagerV1, 1)

    registry = display.get_registry()
    registry.dispatcher["global"] = on_global
    display.roundtrip()
    if "manager" not in found or "seat" not in found:
        leave(1, "This desktop doesn't offer the clipboard to helpers (data-control).")

    manager = found["manager"]
    device = manager.get_data_device(found["seat"])
    source = manager.create_data_source()
    writers = Writers()

    def on_send(_source, mime_type, fd):
        try:
            writers.start(fd, data.get(mime_type, b""))
        except BaseException:
            writers.close(fd)

    def on_cancelled(_source):
        state["cancelled"] = True

    source.dispatcher["send"] = on_send
    source.dispatcher["cancelled"] = on_cancelled
    for mime_type in data:
        source.offer(mime_type)
    device.set_selection(source)
    display.roundtrip()
    if state["cancelled"]:
        leave(1, "Something else was put on the clipboard at the same moment.")
    say_ready()

    wayland_fd = display.get_fd()
    try:
        while not (state["cancelled"] or state["stop"]):
            display.dispatch(block=False)
            display.flush()
            if state["cancelled"] or state["stop"]:
                break
            now = time.monotonic()
            writers.expire(now)
            poller = select.poll()
            poller.register(wayland_fd, select.POLLIN)
            poller.register(wake_read, select.POLLIN)
            for fd in writers.pending:
                poller.register(fd, select.POLLOUT)
            try:
                ready = poller.poll(writers.wait_ms(now))
            except InterruptedError:
                continue
            for fd, events in ready:
                if fd == wayland_fd:
                    if events & select.POLLIN:
                        display.read()
                    elif events & (select.POLLERR | select.POLLHUP):
                        state["stop"] = True    # the display went away
                elif fd == wake_read:
                    try:
                        while os.read(wake_read, 64):
                            pass
                    except BlockingIOError:
                        pass
                else:
                    writers.write(fd)
    except RuntimeError:
        pass                                # the connection to the display broke
    writers.close_all()
    try:
        source.destroy()
        display.flush()
    except Exception:
        pass
    leave(0)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
