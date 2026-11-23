"""The HP-OS installer: the whole experience of the USB stick, drawn straight onto the screen."""
import array
import fcntl
import fnmatch
import glob
import json
import mmap
import os
from pathlib import Path
import re
import secrets
import select
import shutil
import struct
import subprocess
import sys
import textwrap
import time

from PIL import Image, ImageDraw, ImageFont

ASSETS = Path("/installer/assets")
SOURCE_LABEL = "HPOS-SYSTEM"
SOURCE = Path("/mnt/source")
TARGET = Path("/mnt/target")
ROOT_UUID = "d2c1c5bd-9c17-4517-abe7-90221e401acb"   # What this system's boot files expect.
ESP_ID = "B6AFFFE5"
MINIMUM_DISK = 200 * 1000 ** 3
KERNEL = "7.0.14-2020-n1x-hibernate"
STARTUP_ENTRY = """menuentry 'HP-OS' --id hp-os {
    insmod part_gpt
    insmod ext2
    insmod gzio
    search --no-floppy --fs-uuid --set=root %(root)s
    linux /boot/vmlinuz-%(kernel)s root=UUID=%(root)s ro console=tty0 'acpi_osi=!Windows 2022' quiet splash plymouth.ignore-serial-consoles plymouth.use-simpledrm=1 loglevel=3 vt.global_cursor_default=0
    initrd /boot/goran-battery-acpi.cpio /boot/initrd.img-%(kernel)s
}
""" % {"root": ROOT_UUID, "kernel": KERNEL}
STARTUP_SETTINGS = """GRUB_DEFAULT=0
GRUB_TIMEOUT_STYLE=hidden
GRUB_TIMEOUT=0
GRUB_RECORDFAIL_TIMEOUT=0
GRUB_DISABLE_OS_PROBER=true
GRUB_DISABLE_SUBMENU=true
"""
LOG = open("/run/hp-os-install.log", "a", buffering=1)


class Stop(Exception):
    """Something to tell the person."""


def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, file=LOG)
    if "hpos.debug=1" in Path("/proc/cmdline").read_text():
        print(*parts, file=sys.stderr, flush=True)


def run(*command, check=True):
    log("$", *command)
    result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    log(result.stdout.strip())
    if check and result.returncode != 0:
        raise RuntimeError("%s failed: %s" % (command[0], result.stdout.strip()[-400:]))
    return result.stdout


# ── The screen ──
class Screen:
    FBIOGET_VSCREENINFO, FBIOGET_FSCREENINFO = 0x4600, 0x4602

    def __init__(self):
        for _ in range(100):
            if os.path.exists("/dev/fb0"):
                break
            time.sleep(0.1)
        self.fd = os.open("/dev/fb0", os.O_RDWR)
        variable = bytearray(160)
        fcntl.ioctl(self.fd, self.FBIOGET_VSCREENINFO, variable)
        fields = struct.unpack("8I", bytes(variable[:32]))
        self.width, self.height, self.bits = fields[0], fields[1], struct.unpack("I", bytes(variable[24:28]))[0]
        fixed = bytearray(80)
        fcntl.ioctl(self.fd, self.FBIOGET_FSCREENINFO, fixed)
        self.stride = struct.unpack("I", bytes(fixed[48:52]))[0]
        self.red_first = struct.unpack("I", bytes(variable[32:36]))[0] == 0
        self.map = mmap.mmap(self.fd, self.stride * self.height)
        self.unit = max(0.75, min(self.width / 1440, self.height / 900))
        backdrop = Image.open(ASSETS / "backdrop.jpg").convert("RGB")
        scale = max(self.width / backdrop.width, self.height / backdrop.height)
        backdrop = backdrop.resize((round(backdrop.width * scale), round(backdrop.height * scale)), Image.LANCZOS)
        left, top = (backdrop.width - self.width) // 2, (backdrop.height - self.height) // 2
        self.backdrop = backdrop.crop((left, top, left + self.width, top + self.height))
        logo = Image.open(ASSETS / "hp-logo.png").convert("RGBA")
        size = self.px(30)
        self.logo = logo.resize((size, round(size * logo.height / logo.width)), Image.LANCZOS)

    def px(self, value):
        return round(value * self.unit)

    def font(self, size, bold=False):
        font = ImageFont.truetype(str(ASSETS / ("bold.ttf" if bold else "regular.ttf")), self.px(size))
        try:
            font.set_variation_by_axes([700 if bold else 400])   # One font file holds every weight.
        except (OSError, NotImplementedError):
            pass
        return font

    def centered(self, draw, y, text, font, fill):
        draw.text((self.width / 2, y), text, font=font, fill=fill, anchor="ma")

    def frame(self, title, lines=(), progress=None, button=None, quiet=None, danger=False):
        image = self.backdrop.copy().convert("RGBA")
        image.alpha_composite(Image.new("RGBA", image.size, (7, 26, 63, 138)))
        image.alpha_composite(self.logo, (self.px(36), self.px(30)))
        draw = ImageDraw.Draw(image)
        draw.text((self.px(78), self.px(33)), "HP-OS", font=self.font(20), fill="white")
        y = round(self.height * 0.33)
        self.centered(draw, y, title, self.font(42, True), "white")
        y += self.px(76)
        body = self.font(20)
        for line in lines:
            for piece in textwrap.wrap(line, 68) or [""]:
                self.centered(draw, y, piece, body, (255, 255, 255, 225))
                y += self.px(32)
        y += self.px(26)
        if progress is not None:
            width, height = self.px(420), max(4, self.px(6))
            left = (self.width - width) // 2
            draw.rounded_rectangle((left, y, left + width, y + height), height / 2, fill=(255, 255, 255, 60))
            draw.rounded_rectangle((left, y, left + max(height, round(width * progress)), y + height), height / 2, fill="white")
            y += self.px(40)
        if button:
            width, height = self.px(320), self.px(56)
            left = (self.width - width) // 2
            fill, ink = ("#d93025", "white") if danger else ("white", "#0b2a6b")
            draw.rounded_rectangle((left, y, left + width, y + height), height / 2, fill=fill)
            draw.text((self.width / 2, y + height / 2), button, font=self.font(19, True), fill=ink, anchor="mm")
            y += height + self.px(22)
        if quiet:
            self.centered(draw, y, quiet, self.font(17), (255, 255, 255, 200))
        self.show(image.convert("RGB"))

    def show(self, image):
        order = "RGB" if self.red_first else "BGR"
        data = image.tobytes("raw", order + "X" if self.bits == 32 else order)
        row = self.width * (4 if self.bits == 32 else 3)
        for line in range(self.height):
            self.map[line * self.stride:line * self.stride + row] = data[line * row:(line + 1) * row]


class TextScreen:
    """If a laptop's firmware gives no graphics at this stage, the same words still appear."""

    def frame(self, title, lines=(), progress=None, button=None, quiet=None, danger=False):
        body = ["", "", "    HP-OS", "", "    " + title, ""] + ["    " + line for line in lines]
        if progress is not None:
            filled = round(progress * 40)
            body += ["", "    [" + "#" * filled + "-" * (40 - filled) + "]"]
        body += ["", "    " + button if button else "", "    " + quiet if quiet else ""]
        with open("/dev/tty1", "w") as tty:
            tty.write("\033[2J\033[H" + "\n".join(body) + "\n")


# ── The keyboard ──
class Keys:
    ENTER, KEYPAD_ENTER, ESCAPE, POWER = 28, 96, 1, 116

    def wait(self, wanted, seconds=None):
        """Returns the key pressed, or None once the time is up."""
        ends = None if seconds is None else time.monotonic() + seconds
        while ends is None or time.monotonic() < ends:
            devices = []
            for path in glob.glob("/dev/input/event*"):
                try:
                    devices.append(os.open(path, os.O_RDONLY | os.O_NONBLOCK))
                except OSError:
                    pass
            try:
                ready = select.select(devices, [], [], 1)[0]
                for device in ready:
                    data = os.read(device, 24 * 64)
                    for offset in range(0, len(data) - 23, 24):
                        kind, code, value = struct.unpack("HHi", data[offset + 16:offset + 24])
                        if kind == 1 and value == 1 and code in wanted:
                            return code
            except OSError:
                pass
            finally:
                for device in devices:
                    os.close(device)


# ── Finding things ──
def wait_for_source():
    for _ in range(90):
        found = run("blkid", "-L", SOURCE_LABEL, check=False).strip()
        if found.startswith("/dev/"):
            SOURCE.mkdir(parents=True, exist_ok=True)
            run("mount", "-o", "ro", found, str(SOURCE))
            if (SOURCE / "system/etc/os-release").is_file():
                return found
            raise Stop("This USB stick is incomplete. Please create it again.")
        time.sleep(1)
    raise Stop("The USB stick couldn't be read. Remove it, plug it into another port and try again.")


def target_disk(source):
    usb = re.sub(r"\d+$", "", source)
    disks = []
    for path in sorted(glob.glob("/sys/block/nvme*n*")):
        name = os.path.basename(path)
        size = int(Path(path, "size").read_text()) * 512
        if not re.fullmatch(r"nvme\d+n\d+", name) or "/dev/" + name == usb or size < MINIMUM_DISK:
            continue
        disks.append((size, "/dev/" + name))
    if not disks:
        raise Stop("No internal drive was found on this laptop.")
    return max(disks)[1]


# The OmniBook models with NVIDIA's N1X (its graphics, 10de:2e03, are on every one): the OmniBook X also comes with
# other chips, which this installer can't run.
SUPPORTED_MODELS = ("OmniBook Ultra", "OmniBook X")


def n1x_chip():
    return any(read(device / "vendor") == "0x10de" and read(device / "device") == "0x2e03"
               for device in Path("/sys/bus/pci/devices").glob("*"))


def supported_hardware():
    product = Path("/sys/class/dmi/id/product_name").read_text().strip() if os.path.exists("/sys/class/dmi/id/product_name") else ""
    return (any(model in product for model in SUPPORTED_MODELS) and n1x_chip()) or "hpos.any_hardware=1" in Path("/proc/cmdline").read_text()


# ── The battery: the N1X firmware reads it from NVIDIA's controller into a buffer too small for the answer, so Linux
# sees no battery. The startup fix is the laptop's own DSDT with that one buffer (FFA0.RBUF's BUFF) made 0x90 bytes. ──
ULTRA_BOARD = "8E6A"          # The OmniBook Ultra's fix is the one made by hand and checked on it; it comes with the system.
SMALL_BUFFER = b"\x08BUFF\x11\x03\x0a\x40"
BIG_BUFFER = b"\x08BUFF\x11\x03\x0a\x90"


def package_length(data, at):
    """An AML PkgLength at this offset: (value, bytes it takes)."""
    lead = data[at]
    follow = lead >> 6
    if follow == 0:
        return lead & 0x3F, 1
    value = lead & 0x0F
    for index in range(follow):
        value |= data[at + 1 + index] << (4 + 8 * index)
    return value, follow + 1


def fixed_dsdt(dsdt):
    """The DSDT with the battery buffer enlarged, its revision raised so it replaces the firmware's, and its checksum
    redone; None unless the buffer is found exactly once, inside a method named RBUF."""
    if len(dsdt) < 36 or dsdt[:4] != b"DSDT" or int.from_bytes(dsdt[4:8], "little") != len(dsdt):
        return None
    spots = []
    at = dsdt.find(b"RBUF")
    while at >= 0:
        for size in range(1, 5):
            start = at - size
            if start > 0 and dsdt[start - 1] == 0x14 and package_length(dsdt, start)[1] == size:
                end = start + package_length(dsdt, start)[0]
                inside = dsdt.find(SMALL_BUFFER, at, end)
                while inside >= 0:
                    spots.append(inside)
                    inside = dsdt.find(SMALL_BUFFER, inside + 1, end)
                break
        at = dsdt.find(b"RBUF", at + 1)
    if len(spots) != 1:
        return None
    fixed = bytearray(dsdt)
    fixed[spots[0]:spots[0] + len(BIG_BUFFER)] = BIG_BUFFER
    fixed[24:28] = (int.from_bytes(fixed[24:28], "little") + 1).to_bytes(4, "little")
    fixed[9] = 0
    fixed[9] = (-sum(fixed)) & 0xFF
    return bytes(fixed)


def battery_fix(target):
    """Writes target/boot/goran-battery-acpi.cpio for this laptop. The OmniBook Ultra keeps the system's own; any other
    gets one made from its firmware, or an empty one (no fix, nothing else changed) if the firmware isn't as expected."""
    if read("/sys/class/dmi/id/board_name") == ULTRA_BOARD:
        return "kept"
    fixed = fixed_dsdt(read("/sys/firmware/acpi/tables/DSDT", binary=True))
    work = Path("/run/hp-os-battery")
    shutil.rmtree(work, ignore_errors=True)
    (work / "kernel/firmware/acpi").mkdir(parents=True)
    if fixed:
        (work / "kernel/firmware/acpi/dsdt.aml").write_bytes(fixed)
    files = "kernel\nkernel/firmware\nkernel/firmware/acpi\n" + ("kernel/firmware/acpi/dsdt.aml\n" if fixed else "")
    archive = subprocess.run(["cpio", "--quiet", "-H", "newc", "-o"], input=files.encode(), cwd=work, capture_output=True, check=True).stdout
    (Path(target) / "boot/goran-battery-acpi.cpio").write_bytes(archive)
    log("battery fix:", "made from this laptop's firmware" if fixed else "none (firmware not as expected)")
    return "made" if fixed else "none"


def low_power():
    for battery in glob.glob("/sys/class/power_supply/BAT*"):
        on_power = any(Path(path).read_text().strip() == "1" for path in glob.glob("/sys/class/power_supply/ADP*/online"))
        if not on_power and int(Path(battery, "capacity").read_text()) < 40:
            return True
    return False


def part(disk, number):
    return "%sp%d" % (disk, number)


# ── Installing ──
def own_identity(target):
    """Each laptop its own machine ID instead of the image's (logs, Bluetooth and network services tell laptops apart
    by it). Written here, rather than left empty for the first start, so nothing about that first start changes."""
    machine_id = target / "etc/machine-id"
    machine_id.write_text(secrets.token_hex(16) + "\n")
    os.chmod(machine_id, 0o444)
    dbus_id = target / "var/lib/dbus/machine-id"
    if dbus_id.exists() and not dbus_id.is_symlink():
        dbus_id.unlink()
        dbus_id.symlink_to("/etc/machine-id")


def install(screen, disk):
    def step(fraction, line):
        screen.frame("Installing HP-OS", [line, "Please keep your laptop plugged in and open."], progress=fraction)

    step(0.02, "Preparing your laptop...")
    run("wipefs", "--all", "--force", disk)
    run("sgdisk", "--zap-all", disk)
    run("sgdisk", "-n", "1:2048:+512M", "-t", "1:EF00", "-c", "1:EFI system partition",
        "-n", "2:0:0", "-t", "2:8300", "-c", "2:HP-OS", disk)
    run("blockdev", "--rereadpt", disk)
    run("udevadm", "settle", "--timeout=20")
    for _ in range(50):
        if os.path.exists(part(disk, 2)):
            break
        time.sleep(0.2)
    run("mkfs.vfat", "-F", "32", "-n", "SYSTEM", "-i", ESP_ID, part(disk, 1))
    run("mkfs.ext4", "-F", "-q", "-L", "HP-OS", "-U", ROOT_UUID, part(disk, 2))
    TARGET.mkdir(parents=True, exist_ok=True)
    run("mount", part(disk, 2), str(TARGET))
    (TARGET / "boot/efi").mkdir(parents=True)
    run("mount", part(disk, 1), str(TARGET / "boot/efi"))

    copy = subprocess.Popen(["rsync", "-aHAX", "--numeric-ids", "--info=progress2", "--no-inc-recursive",
                             "--exclude=/boot/efi/", str(SOURCE / "system") + "/", str(TARGET) + "/"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=False)
    shown, tail, buffer = -1, "", b""
    while True:
        chunk = copy.stdout.read(4096)
        if not chunk:
            break
        buffer = (buffer + chunk)[-2048:]
        text = buffer.decode(errors="replace")
        tail = text[-500:]
        found = re.findall(r"(\d{1,3})%", text)
        if found and int(found[-1]) != shown:
            shown = int(found[-1])
            step(0.05 + 0.85 * min(shown, 100) / 100, "Copying HP-OS to your laptop... %d%%" % shown)
    if copy.wait() != 0:
        log(tail)
        raise RuntimeError("copy failed: " + tail[-300:])

    own_identity(TARGET)
    step(0.92, "Setting up startup...")
    startup = SOURCE / "system/boot/efi"
    for folder, _, files in os.walk(startup):     # The startup partition keeps no owners or permissions.
        destination = TARGET / "boot/efi" / Path(folder).relative_to(startup)
        destination.mkdir(parents=True, exist_ok=True)
        for name in files:
            shutil.copyfile(Path(folder, name), destination / name)
    run("fallocate", "-l", "8G", str(TARGET / "swap.img"))
    os.chmod(TARGET / "swap.img", 0o600)
    run("mkswap", str(TARGET / "swap.img"))
    battery_fix(TARGET)
    clean_startup()
    if os.path.isdir("/sys/firmware/efi/efivars"):
        listing = run("efibootmgr", check=False)
        for number, label in re.findall(r"^Boot([0-9A-Fa-f]{4})\*? (.+)$", listing, re.M):
            if re.search(r"windows|ubuntu|hp-os", label, re.I):
                run("efibootmgr", "-b", number, "-B", check=False)
        run("efibootmgr", "-c", "-d", disk, "-p", "1", "-L", "HP-OS", "-l", "\\EFI\\ubuntu\\shimaa64.efi", check=False)
    step(0.97, "Finishing up...")
    run("sync")
    run("umount", str(TARGET / "boot/efi"))
    run("umount", str(TARGET))
    run("sync")


def save_report():
    """Leaves a hardware report on the stick, so a problem on a real laptop can be diagnosed afterwards."""
    folder = Path("/mnt/report")
    try:
        found = run("blkid", "-L", "HPOS-BOOT", check=False).strip()
        if not found.startswith("/dev/"):
            return
        folder.mkdir(parents=True, exist_ok=True)
        run("mount", found, str(folder))
        LOG.flush()
        sections = [("installer", Path("/run/hp-os-install.log").read_text(errors="replace")),
                    ("drivers", Path("/proc/modules").read_text()), ("disks", Path("/proc/partitions").read_text()),
                    ("input", Path("/proc/bus/input/devices").read_text()), ("kernel", run("dmesg", check=False))]
        Path(folder, "hp-os-report.txt").write_text("".join("=== %s ===\n%s\n" % section for section in sections))
        run("umount", str(folder))
        run("sync")
    except Exception as error:
        log("no report:", repr(error))


# ── Checking a laptop HP-OS doesn't support yet: a report on the stick, nothing changed on the laptop ──
PRIVATE_DMI = ("product_serial", "product_uuid", "board_serial", "chassis_serial", "board_asset_tag", "chassis_asset_tag")


def read(path, binary=False):
    try:
        return Path(path).read_bytes() if binary else Path(path).read_text(errors="replace").strip()
    except OSError:
        return b"" if binary else ""


def driver_table(system):
    """Every hardware pattern the installed system has a driver for: {kind: [(pattern, module)]}."""
    table = {}
    folder = Path(system) / "usr/lib/modules" / KERNEL
    for name in ("modules.alias", "modules.builtin.alias"):
        for line in read(folder / name).splitlines():
            parts = line.split()
            if len(parts) == 3 and parts[0] == "alias":
                table.setdefault(re.match(r"[a-z0-9_]*", parts[1]).group(0), []).append((parts[1], parts[2] + (" (built in)" if "builtin" in name else "")))
    return table


def drivers_for(modalias, table):
    kind = re.match(r"[a-z0-9_]*", modalias).group(0)
    return sorted({module for pattern, module in table.get(kind, []) if fnmatch.fnmatchcase(modalias, pattern)})


def hardware(sysfs="/sys", table=None):
    """What this laptop is made of, from the firmware and the buses, with the driver HP-OS would use for each part."""
    sysfs = Path(sysfs)
    table = table or {}
    found = {"model": {}, "devices": [], "batteries": [], "input": read("/proc/bus/input/devices"), "backlight": [],
             "cpu": sorted({line.split(":", 1)[1].strip() for line in read("/proc/cpuinfo").splitlines()
                            if line.split(":")[0].strip() in ("CPU implementer", "CPU part", "model name")}),
             "memory": next((line for line in read("/proc/meminfo").splitlines() if line.startswith("MemTotal")), "")}
    for entry in sorted((sysfs / "class/dmi/id").glob("*")):
        if entry.is_file() and entry.name not in PRIVATE_DMI and entry.name not in ("modalias", "uevent"):
            found["model"][entry.name] = read(entry)
    seen = set()
    for bus in ("pci", "usb", "acpi", "platform", "i2c", "spi", "serio", "hid", "sdio", "mhi", "auxiliary", "soundwire", "virtio"):
        for device in sorted((sysfs / "bus" / bus / "devices").glob("*")):
            alias = read(device / "modalias")
            if not alias or alias in seen:
                continue
            seen.add(alias)
            item = {"bus": bus, "name": device.name, "modalias": alias, "drivers": drivers_for(alias, table)}
            bound = device / "driver"
            if bound.exists():
                item["bound"] = os.path.basename(os.path.realpath(bound))
            for extra in ("vendor", "device", "class", "hid", "path", "status", "name", "product", "manufacturer"):
                value = read(device / extra)
                if value:
                    item[extra] = value
            found["devices"].append(item)
    for supply in sorted((sysfs / "class/power_supply").glob("*")):
        found["batteries"].append({name: read(supply / name) for name in ("type", "status", "capacity", "energy_full",
                                   "energy_full_design", "charge_full", "voltage_now", "model_name", "manufacturer", "technology") if read(supply / name)})
    for light in sorted((sysfs / "class/backlight").glob("*")):
        found["backlight"].append({"name": light.name, "type": read(light / "type"), "max": read(light / "max_brightness")})
    return found


# Firmware's own housekeeping entries, which no driver is meant to take.
HOUSEKEEPING = re.compile(r"^acpi:(LNX|ACPI000|ACPI001|PNP0A|PNP0C0[^9]|PNP0C80|ARML|INT33|HPIC)")


def unhandled(found):
    """Parts with no driver in HP-OS and none already looking after them: what may not work on this laptop."""
    return [item for item in found["devices"] if not item["drivers"] and "bound" not in item
            and item["bus"] in ("pci", "usb", "acpi", "i2c", "hid", "platform") and item.get("status", "15") != "0"
            and not HOUSEKEEPING.match(item["modalias"])]


def check_laptop(screen):
    """Saves what HP-OS needs to know about this laptop on the stick's startup partition. Returns where."""
    screen.frame("Checking this laptop", ["Looking at its parts. This takes about a minute."], progress=0.1)
    table = driver_table(SOURCE / "system")
    screen.frame("Checking this laptop", ["Looking at its parts. This takes about a minute."], progress=0.4)
    found = hardware(table=table)
    model = re.sub(r"[^A-Za-z0-9]+", "-", found["model"].get("product_name", "laptop")).strip("-")[:40] or "laptop"
    name = "%s-%s" % (model, time.strftime("%Y%m%d-%H%M%S"))
    stick = run("blkid", "-L", "HPOS-BOOT", check=False).strip()
    if not stick.startswith("/dev/"):
        raise Stop("The USB stick's startup partition wasn't found, so the check couldn't be saved.")
    mount = Path("/mnt/report")
    mount.mkdir(parents=True, exist_ok=True)
    run("mount", stick, str(mount))
    try:
        folder = mount / "hp-os-check" / name
        (folder / "acpi").mkdir(parents=True, exist_ok=True)
        Path(folder, "hardware.json").write_text(json.dumps(found, indent=1))
        missing = unhandled(found)
        lines = ["HP-OS laptop check", "", "Model: %s" % found["model"].get("product_name", "?"),
                 "Board: %s" % found["model"].get("board_name", "?"), "BIOS: %s %s" % (found["model"].get("bios_version", "?"),
                 found["model"].get("bios_date", "")), "CPU: %s" % ", ".join(found["cpu"]), found["memory"], "",
                 "Batteries and power: %s" % json.dumps(found["batteries"]), "Backlight: %s" % json.dumps(found["backlight"]), "",
                 "Parts with no HP-OS driver (%d):" % len(missing)]
        lines += ["  %s %s %s" % (item["bus"], item["modalias"], item.get("hid", "")) for item in missing]
        Path(folder, "summary.txt").write_text("\n".join(lines) + "\n")
        screen.frame("Checking this laptop", ["Saving the results on the USB stick..."], progress=0.7)
        for table_file in sorted(Path("/sys/firmware/acpi/tables").glob("*")):
            if table_file.is_file():
                Path(folder, "acpi", table_file.name).write_bytes(read(table_file, binary=True))
        battery_fix = SOURCE / "system/boot/goran-battery-acpi.cpio"
        if battery_fix.is_file():
            shutil.copyfile(battery_fix, folder / "goran-battery-acpi.cpio")
        LOG.flush()
        Path(folder, "startup.txt").write_text("=== installer ===\n%s\n=== drivers ===\n%s\n=== kernel ===\n%s\n" % (
            read("/run/hp-os-install.log"), read("/proc/modules"), run("dmesg", check=False)))
    finally:
        run("umount", str(mount), check=False)
        run("sync", check=False)
    return name


def clean_startup():
    """A new laptop goes straight into HP-OS, with no startup menu, now and after any later system update."""
    for name in ("vmlinuz-" + KERNEL, "initrd.img-" + KERNEL, "goran-battery-acpi.cpio"):
        if not (TARGET / "boot" / name).exists():
            raise RuntimeError("startup file missing: " + name)
    scripts, settings = TARGET / "etc/grub.d", TARGET / "etc/default/grub.d"
    for leftover in (scripts / "46_n1x_simon", settings / "zzzz-n1x-installer.cfg"):
        if leftover.exists():
            leftover.unlink()
    for script in scripts.iterdir():
        if script.is_file() and script.name != "00_header":
            script.chmod(0o644)
    settings.mkdir(parents=True, exist_ok=True)
    (settings / "zzzz-hp-os.cfg").write_text(STARTUP_SETTINGS)
    (scripts / "10_hp_os").write_text('#!/bin/sh\nexec tail -n +3 "$0"\n' + STARTUP_ENTRY)
    (scripts / "10_hp_os").chmod(0o755)
    menu = TARGET / "boot/grub/grub.cfg"
    menu.write_text("set default=0\nset timeout=0\nset timeout_style=hidden\n" + STARTUP_ENTRY)
    menu.chmod(0o600)
    header = "# GRUB Environment Block\n"
    (TARGET / "boot/grub/grubenv").write_text(header + "#" * (1024 - len(header)))


def power(action):
    subprocess.run(["sync"], check=False)
    with open("/proc/sysrq-trigger", "w") as trigger:
        trigger.write(action)
    time.sleep(10)


def turn_off():
    power("o")


def restart():
    power("b")


def main():
    try:
        screen = Screen()
    except (OSError, ValueError) as error:
        log("no graphics:", repr(error))
        screen = TextScreen()
    keys = Keys()
    try:
        screen.frame("Getting ready", ["Starting the HP-OS installer..."])
        source = wait_for_source()
        if not supported_hardware():
            # Another laptop: HP-OS can look at it and save what it finds, and never installs.
            screen.frame("Check this laptop", ["HP-OS doesn't support this laptop yet. It can check its parts and save",
                                               "the results on this USB stick. Nothing on this laptop is changed."],
                         button="Press Enter to check", quiet="Press Esc to turn off")
            if keys.wait({Keys.ENTER, Keys.KEYPAD_ENTER, Keys.ESCAPE, Keys.POWER}) in (Keys.ENTER, Keys.KEYPAD_ENTER):
                name = check_laptop(screen)
                screen.frame("Check saved", ["The results are on this USB stick, in hp-os-check/%s." % name,
                                             "Nothing on this laptop was changed. Plug the stick into your HP-OS laptop to read them."],
                             button="Press Enter to turn off", quiet="This laptop turns itself off after two minutes.")
                keys.wait({Keys.ENTER, Keys.KEYPAD_ENTER, Keys.ESCAPE, Keys.POWER}, 120)
            turn_off()
            return
        disk = target_disk(source)
        while low_power():
            screen.frame("Plug in your laptop", ["Connect the charger to continue."])
            time.sleep(2)
        screen.frame("Install HP-OS", ["This erases everything on this laptop, including Windows,",
                                       "and replaces it with HP-OS. This can't be undone."],
                     button="Press Enter to erase and install", quiet="Press Esc to turn off without changing anything", danger=True)
        if keys.wait({Keys.ENTER, Keys.KEYPAD_ENTER, Keys.ESCAPE, Keys.POWER}) not in (Keys.ENTER, Keys.KEYPAD_ENTER):
            screen.frame("Turning off", ["Nothing on this laptop was changed."])
            time.sleep(2)
            turn_off()
            return
        install(screen, disk)
        screen.frame("HP-OS is installed", ["Remove the USB stick, then press Enter.", "Your laptop will restart and welcome you."],
                     button="Press Enter to restart")
        keys.wait({Keys.ENTER, Keys.KEYPAD_ENTER})
        screen.frame("Restarting", [])
        restart()
    except Stop as reason:
        save_report()
        screen.frame("HP-OS can't be installed", [str(reason)], button="Press Enter to turn off",
                     quiet="This laptop turns itself off after one minute.")
        keys.wait({Keys.ENTER, Keys.KEYPAD_ENTER, Keys.ESCAPE, Keys.POWER}, 60)
        turn_off()
    except Exception as error:     # Whatever went wrong, the person gets a clear screen, not a dead one.
        log("failed:", repr(error))
        save_report()
        screen.frame("Installation didn't finish", ["Something went wrong while installing.", "Restart from the USB stick to try again."],
                     button="Press Enter to turn off", quiet="This laptop turns itself off after one minute.")
        keys.wait({Keys.ENTER, Keys.KEYPAD_ENTER, Keys.ESCAPE, Keys.POWER}, 60)
        turn_off()


if __name__ == "__main__":
    main()
