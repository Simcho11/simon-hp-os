"""The HP-OS installer for x86 computers. The screens and keyboard handling are shared with the ARM installer."""
import glob
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, "/installer")
import installer as shared  # noqa: E402
from installer import ESP_ID, ROOT_UUID, SOURCE, TARGET, Keys, Screen, Stop, TextScreen, log, run  # noqa: E402

MINIMUM_DISK = 64 * 1000 ** 3
MINIMUM_MEMORY = 3500 * 1024 ** 2     # A computer sold with 4 GB reports a little less than that.
SWAP_SIZE = "4G"                      # Memory compression does most of the work; this is the safety net.
INTERNAL_DISK = re.compile(r"(nvme\d+n\d+|sd[a-z]+|vd[a-z]+|mmcblk\d+)")


def check_computer():
    """Everything is checked before anything on the computer is touched."""
    if platform.machine() != "x86_64":
        raise Stop("This installer is made for x86 computers. Nothing on this computer was changed.")
    if not os.path.isdir("/sys/firmware/efi"):
        raise Stop("This computer needs to start in UEFI mode. Turn on UEFI in its startup settings, then try again.")
    memory = int(re.search(r"MemTotal:\s+(\d+)", Path("/proc/meminfo").read_text()).group(1)) * 1024
    if memory < MINIMUM_MEMORY:
        raise Stop("HP-OS needs at least 4 GB of memory. Nothing on this computer was changed.")


def whole_disk(device):
    """The disk a partition such as /dev/sdb2 or /dev/nvme0n1p2 belongs to."""
    name = os.path.basename(device)
    link = os.path.realpath("/sys/class/block/" + name)
    if os.path.exists(os.path.join(link, "partition")):
        name = os.path.basename(os.path.dirname(link))
    return "/dev/" + name


def is_external(path):
    if Path(path, "removable").read_text().strip() == "1":
        return True
    return "/usb" in os.path.realpath(path)


def target_disk(source):
    usb = whole_disk(source)
    disks = []
    for path in sorted(glob.glob("/sys/block/*")):
        name = os.path.basename(path)
        if not INTERNAL_DISK.fullmatch(name) or "/dev/" + name == usb or is_external(path):
            continue
        size = int(Path(path, "size").read_text()) * 512
        if size >= MINIMUM_DISK:
            disks.append((size, "/dev/" + name))
    if not disks:
        raise Stop("No internal drive of at least 64 GB was found. Nothing on this computer was changed.")
    return max(disks)[1]


def describe(disk):
    """The drive's name and size, so the person can see what is about to be erased."""
    name = os.path.basename(disk)
    try:
        model = Path("/sys/block", name, "device/model").read_text().strip()
    except OSError:
        model = ""
    size = int(Path("/sys/block", name, "size").read_text()) * 512 / 1000 ** 3
    return "%s (%d GB)" % (model or "Internal drive", round(size))


# ── Checking a computer before anything is erased ──
KEY_C = 46
VENDORS = {"0x8086": "Intel", "0x1002": "AMD", "0x1022": "AMD", "0x10de": "NVIDIA", "0x14e4": "Broadcom",
           "0x10ec": "Realtek", "0x168c": "Qualcomm", "0x17cb": "Qualcomm", "0x14c3": "MediaTek", "0x1af4": "Virtual"}


def read(path, default=""):
    try:
        return Path(path).read_text(errors="replace").strip()
    except OSError:
        return default


def output(*command):
    """A command's normal output only; its complaints are left out."""
    try:
        return subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def modules_for(modalias):
    """The kernel driver HP-OS would use for a device, from the kernel's own list."""
    return [name for name in output("modprobe", "-R", modalias).split() if re.fullmatch(r"[\w-]+", name)] if modalias else []


def firmware_present(module, firmware_root):
    """True when the files the driver asks for are in the HP-OS system on the stick (or it asks for none)."""
    wanted = [line.strip() for line in output("modinfo", "-F", "firmware", module).splitlines() if line.strip()]
    if not wanted:
        return True
    for name in wanted:
        for candidate in glob.glob(str(firmware_root / name)) + [str(firmware_root / name)]:
            if any(os.path.exists(candidate + suffix) for suffix in ("", ".zst", ".xz")):
                return True
    return False


def pci_devices():
    for path in sorted(glob.glob("/sys/bus/pci/devices/*")):
        yield {"slot": os.path.basename(path), "class": read(Path(path, "class")), "vendor": read(Path(path, "vendor")),
               "device": read(Path(path, "device")), "modalias": read(Path(path, "modalias")),
               "driver": os.path.basename(os.path.realpath(Path(path, "driver"))) if os.path.exists(Path(path, "driver")) else ""}


def check_computer_parts():
    """Plain results for the screen, and the details for the report."""
    firmware_root = SOURCE / "system/usr/lib/firmware"
    results, details = [], []
    vendor, model = read("/sys/class/dmi/id/sys_vendor"), read("/sys/class/dmi/id/product_name")
    product = model if model.lower().startswith(vendor.lower()) else " ".join(part for part in (vendor, model) if part)
    details.append("computer: %s | board: %s | bios: %s" % (product, read("/sys/class/dmi/id/board_name"), read("/sys/class/dmi/id/bios_version")))
    cpu = re.search(r"^model name\s*:\s*(.+)$", read("/proc/cpuinfo"), re.M)
    memory = int(re.search(r"MemTotal:\s+(\d+)", read("/proc/meminfo")).group(1)) // 1024 ** 2
    details.append("processor: %s | memory: %d GB" % (cpu.group(1) if cpu else "?", memory))

    def device_result(label, devices, needs_firmware):
        if not devices:
            return "%s: none found" % label, None
        verdicts = []
        for device in devices:
            modules = modules_for(device["modalias"])
            missing = [module for module in modules if needs_firmware and not firmware_present(module, firmware_root)]
            ok = bool(modules) and not missing
            details.append("%s: %s %s:%s class %s driver-now=%s would-use=%s firmware-missing=%s" % (
                label.lower(), device["slot"], device["vendor"], device["device"], device["class"],
                device["driver"] or "-", ",".join(modules) or "-", ",".join(missing) or "-"))
            verdicts.append(ok)
        brand = VENDORS.get(devices[0]["vendor"], "")
        return ("%s%s: %s" % (label, " (" + brand + ")" if brand else "", "ready" if all(verdicts) else "needs work"),
                all(verdicts))

    pci = list(pci_devices())
    checks = [
        device_result("Graphics", [d for d in pci if d["class"].startswith("0x03")], True),
        device_result("Wi-Fi", [d for d in pci if d["class"].startswith("0x0280")], True),
        device_result("Sound", [d for d in pci if d["class"].startswith(("0x0401", "0x0403"))], True),
    ]
    # Input devices, judged by what they can do: letter keys make a keyboard, a finger tool makes a touchpad.
    keyboard = touchpad = False
    for block in read("/proc/bus/input/devices").split("\n\n"):
        name = re.search(r'^N: Name="(.*)"$', block, re.M)
        keys = re.search(r"^B: KEY=(.*)$", block, re.M)
        bits = 0
        if keys:
            for index, word in enumerate(reversed(keys.group(1).split())):
                bits |= int(word, 16) << (64 * index)
        has = lambda code: bool(bits >> code & 1)
        is_keyboard = has(30) and has(44)            # KEY_A and KEY_Z
        is_touchpad = has(325) and not has(330) or bool(name and re.search(r"touchpad|trackpad", name.group(1), re.I))
        keyboard, touchpad = keyboard or is_keyboard, touchpad or is_touchpad   # 325 finger tool, 330 touch screen
        details.append("input: %s%s%s" % (name.group(1) if name else "?", " [keyboard]" if is_keyboard else "",
                                          " [touchpad]" if is_touchpad else ""))
    checks.append(("Touchpad: %s" % ("ready" if touchpad else "not found"), touchpad))
    checks.append(("Keyboard: %s" % ("ready" if keyboard else "not found"), keyboard))
    # The camera: a USB camera works as it is. A camera on Intel's image processing unit (IPU, built into newer Intel
    # chips) needs drivers Ubuntu doesn't have yet, so video calls would have no picture.
    usb_camera = any(read(path) == "0e" for path in glob.glob("/sys/bus/usb/devices/*/bInterfaceClass"))
    ipu = [d for d in pci if d["vendor"] == "0x8086" and d["class"].startswith("0x0480")]
    details.extend("camera-ipu: %s %s:%s driver-now=%s" % (d["slot"], d["vendor"], d["device"], d["driver"] or "-") for d in ipu)
    if usb_camera:
        checks.append(("Camera: ready", True))
    elif ipu:
        checks.append(("Camera: needs work", False))
    else:
        checks.append(("Camera: not found", None))
    bluetooth = bool(glob.glob("/sys/class/bluetooth/hci*")) or any(
        read(Path(path).parent / "bInterfaceClass") == "e0" and read(Path(path).parent / "bInterfaceProtocol") == "01"
        for path in glob.glob("/sys/bus/usb/devices/*/bInterfaceSubClass") if read(path) == "01")
    checks.append(("Bluetooth: %s" % ("ready" if bluetooth else "not found"), None))
    battery = bool(glob.glob("/sys/class/power_supply/BAT*"))
    checks.append(("Battery: %s" % ("ready" if battery else "not found"), None))
    secure = read(glob.glob("/sys/firmware/efi/efivars/SecureBoot-*")[0], "") if glob.glob("/sys/firmware/efi/efivars/SecureBoot-*") else ""
    details.append("secure-boot-raw: %r" % secure)
    unknown = [d for d in pci if not d["class"].startswith(("0x06", "0x0c05", "0x0580", "0x0880")) and not modules_for(d["modalias"])]
    details.extend("no-driver: %s %s:%s class %s" % (d["slot"], d["vendor"], d["device"], d["class"]) for d in unknown)
    for line, _ in checks:
        details.append("summary: " + line)
    lines = [line for line, _ in checks]
    problems = [line for line, ok in checks if ok is False]
    return product, lines, problems, details


def save_check(product, details):
    """Leaves the full results on the stick, next to the installer, for a closer look later."""
    folder = Path("/mnt/report")
    found = run("blkid", "-L", "HPOS-BOOT", check=False).strip()
    if not found.startswith("/dev/"):
        return False
    try:
        folder.mkdir(parents=True, exist_ok=True)
        run("mount", found, str(folder))
        name = re.sub(r"[^A-Za-z0-9]+", "-", product or "computer").strip("-")[:60]
        text = "\n".join(details) + "\n\n=== kernel ===\n" + run("dmesg", check=False)
        Path(folder, "hp-os-check-%s.txt" % name).write_text(text)
        run("umount", str(folder))
        run("sync")
        return True
    except Exception as error:
        log("check not saved:", repr(error))
        return False


def check_screen(screen, keys):
    screen.frame("Checking this computer", ["Looking at its parts. Nothing is changed."])
    product, lines, problems, details = check_computer_parts()
    saved = save_check(product, details)
    verdict = ("Everything HP-OS needs was found." if not problems
               else "Some parts may not work yet. The full results are on the USB stick.")
    screen.frame(product or "This computer", lines + ["", verdict],
                 button="Press Enter to go back",
                 quiet="Results saved to the USB stick." if saved else "The results couldn't be saved to the USB stick.")
    keys.wait({Keys.ENTER, Keys.KEYPAD_ENTER, Keys.ESCAPE, Keys.POWER})


def part(disk, number):
    return "%s%s%d" % (disk, "p" if disk[-1].isdigit() else "", number)


def install(screen, disk):
    def step(fraction, line):
        screen.frame("Installing HP-OS", [line, "Please keep your computer plugged in."], progress=fraction)

    step(0.02, "Preparing your computer...")
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
            step(0.05 + 0.85 * min(shown, 100) / 100, "Copying HP-OS to your computer... %d%%" % shown)
    if copy.wait() != 0:
        log(tail)
        raise RuntimeError("copy failed: " + tail[-300:])

    step(0.92, "Setting up startup...")
    startup = SOURCE / "system/boot/efi"
    for folder, _, files in os.walk(startup):     # The startup partition keeps no owners or permissions.
        destination = TARGET / "boot/efi" / Path(folder).relative_to(startup)
        destination.mkdir(parents=True, exist_ok=True)
        for name in files:
            shutil.copyfile(Path(folder, name), destination / name)
    run("fallocate", "-l", SWAP_SIZE, str(TARGET / "swap.img"))
    os.chmod(TARGET / "swap.img", 0o600)
    run("mkswap", str(TARGET / "swap.img"))
    if os.path.isdir("/sys/firmware/efi/efivars"):
        listing = run("efibootmgr", check=False)
        for number, label in re.findall(r"^Boot([0-9A-Fa-f]{4})\*? (.+)$", listing, re.M):
            if re.search(r"windows|ubuntu|hp-os", label, re.I):
                run("efibootmgr", "-b", number, "-B", check=False)
        run("efibootmgr", "-c", "-d", disk, "-p", "1", "-L", "HP-OS", "-l", "\\EFI\\ubuntu\\shimx64.efi", check=False)
    step(0.97, "Finishing up...")
    run("sync")
    run("umount", str(TARGET / "boot/efi"))
    run("umount", str(TARGET))
    run("sync")


def main():
    try:
        screen = Screen()
    except (OSError, ValueError) as error:
        log("no graphics:", repr(error))
        screen = TextScreen()
    keys = Keys()
    try:
        screen.frame("Getting ready", ["Starting the HP-OS installer..."])
        check_computer()
        source = shared.wait_for_source()
        disk = target_disk(source)
        while shared.low_power():
            screen.frame("Plug in your computer", ["Connect the charger to continue."])
            time.sleep(2)
        while True:
            screen.frame("Install HP-OS", ["This erases everything on %s," % describe(disk),
                                           "including Windows, and replaces it with HP-OS. This can't be undone."],
                         button="Press Enter to erase and install",
                         quiet="Press C to check this computer first, or Esc to turn off without changing anything", danger=True)
            answer = keys.wait({Keys.ENTER, Keys.KEYPAD_ENTER, Keys.ESCAPE, Keys.POWER, KEY_C})
            if answer != KEY_C:
                break
            check_screen(screen, keys)
        if answer not in (Keys.ENTER, Keys.KEYPAD_ENTER):
            screen.frame("Turning off", ["Nothing on this computer was changed."])
            time.sleep(2)
            shared.turn_off()
            return
        install(screen, disk)
        screen.frame("HP-OS is installed", ["Remove the USB stick, then press Enter.", "Your computer will restart and welcome you."],
                     button="Press Enter to restart")
        keys.wait({Keys.ENTER, Keys.KEYPAD_ENTER})
        screen.frame("Restarting", [])
        shared.restart()
    except Stop as reason:
        shared.save_report()
        screen.frame("HP-OS can't be installed", [str(reason)], button="Press Enter to turn off",
                     quiet="This computer turns itself off after one minute.")
        keys.wait({Keys.ENTER, Keys.KEYPAD_ENTER, Keys.ESCAPE, Keys.POWER}, 60)
        shared.turn_off()
    except Exception as error:     # Whatever went wrong, the person gets a clear screen, not a dead one.
        log("failed:", repr(error))
        shared.save_report()
        screen.frame("Installation didn't finish", ["Something went wrong while installing.", "Restart from the USB stick to try again."],
                     button="Press Enter to turn off", quiet="This computer turns itself off after one minute.")
        keys.wait({Keys.ENTER, Keys.KEYPAD_ENTER, Keys.ESCAPE, Keys.POWER}, 60)
        shared.turn_off()


if __name__ == "__main__":
    main()
