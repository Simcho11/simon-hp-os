"""Read or set the touchpad's haptic feedback intensity and click pressure.

  touchpad-haptics detect             print what this laptop's touchpad offers, as JSON:
                                      {"haptic": bool, "pressure": bool, "device": "/dev/hidrawN" or "", "access": bool}
  touchpad-haptics ids                print the vendor:product of each haptic touchpad (for its access rule)
  touchpad-haptics get                print the haptic intensity (0-100)
  touchpad-haptics set N              set it (0 = off, 100 = strongest the touchpad allows)
  touchpad-haptics pressure           print the click pressure threshold (0 = firmware default)
  touchpad-haptics pressure N         set it (100-200, or 0 for the firmware default)

A haptic touchpad (one that clicks with a motor instead of a hinge) implements Microsoft's haptic touchpad controls:
a feature report with the Haptics page's Intensity (0x0E/0x23, 0-100) and one with the Digitizer page's Button Press
Threshold (0x0D/0xB0, 100-200; 0 reads back while the firmware default is used). The kernel doesn't expose them, so
this reads each HID device's report descriptor to find them, then talks to that device's hidraw node directly (access
via /etc/udev/rules.d/70-touchpad-haptics.rules). A regular touchpad has neither, and Settings hides both controls.
"""
import fcntl
import glob
import json
import os
import sys

HAPTICS_PAGE, INTENSITY = 0x0E, 0x23
DIGITIZER_PAGE, PRESS_THRESHOLD = 0x0D, 0xB0
# The OmniBook Ultra's Synaptics SYNA3581, in case its descriptor can't be read: report 55 intensity, 54 pressure.
KNOWN = {("06CB", "D019"): {"intensity": (55, 1), "pressure": (54, 2)}}


def ioc(nr, length):  # _IOC(_IOC_WRITE|_IOC_READ, 'H', nr, length)
    return (3 << 30) | (length << 16) | (ord("H") << 8) | nr


def get_feature(fd, report, size):
    buf = bytearray([report] + [0] * size)
    fcntl.ioctl(fd, ioc(0x07, len(buf)), buf)
    return int.from_bytes(buf[1:1 + size], "little")


def set_feature(fd, report, size, value):
    buf = bytearray([report]) + value.to_bytes(size, "little")
    fcntl.ioctl(fd, ioc(0x06, len(buf)), buf)


def feature_controls(descriptor):
    """{"intensity": (report id, bytes), "pressure": (report id, bytes)} for the controls a HID report descriptor has.
    A short walk through its items: global Usage Page, Report ID, Report Size and Report Count, local Usages, and the
    Feature main items they describe."""
    found, usages = {}, []
    page = report = size = count = 0
    stack = []
    i = 0
    while i < len(descriptor):
        prefix = descriptor[i]
        if prefix == 0xFE:                                   # long item: skip it
            i += 3 + (descriptor[i + 1] if i + 1 < len(descriptor) else 0)
            continue
        length = (0, 1, 2, 4)[prefix & 0x03]
        data = int.from_bytes(descriptor[i + 1:i + 1 + length], "little")
        kind, tag = (prefix >> 2) & 0x03, prefix >> 4
        if kind == 1:                                        # global
            if tag == 0x0: page = data
            elif tag == 0x7: size = data
            elif tag == 0x8: report = data
            elif tag == 0x9: count = data
            elif tag == 0xA: stack.append((page, report, size, count))
            elif tag == 0xB and stack: page, report, size, count = stack.pop()
        elif kind == 2 and tag == 0x0:                       # local Usage (4 bytes: page in the high half)
            usages.append((data >> 16, data & 0xFFFF) if length == 4 else (page, data))
        elif kind == 0:                                      # main
            if tag == 0xB:                                   # Feature
                for usage in usages:
                    nbytes = max(1, (size * max(1, count if len(usages) == 1 else 1) + 7) // 8)
                    if usage == (HAPTICS_PAGE, INTENSITY):
                        found.setdefault("intensity", (report, nbytes))
                    elif usage == (DIGITIZER_PAGE, PRESS_THRESHOLD):
                        found.setdefault("pressure", (report, nbytes))
            usages = []
        i += 1 + length
    return found


def touchpads():
    """Every HID device with haptic controls: (hidraw node or "", "VID:PID", controls)."""
    out = []
    for hid in sorted(glob.glob("/sys/bus/hid/devices/*")):
        try:
            _, vendor, product = os.path.basename(hid).split(".")[0].split(":")
        except ValueError:
            continue
        controls = {}
        try:
            with open(os.path.join(hid, "report_descriptor"), "rb") as stream:
                controls = feature_controls(stream.read())
        except OSError:
            pass
        if "intensity" not in controls:
            controls = dict(KNOWN.get((vendor.upper(), product.upper()), {}), **controls)
        if "intensity" not in controls:
            continue
        nodes = glob.glob(os.path.join(hid, "hidraw", "hidraw*"))
        out.append(("/dev/" + os.path.basename(nodes[0]) if nodes else "", "%s:%s" % (vendor.upper(), product.upper()), controls))
    return out


def main():
    args = sys.argv[1:]
    if not args or args[0] not in ("detect", "ids", "get", "set", "pressure"):
        sys.exit(__doc__.strip().split("\n\n")[1])
    found = touchpads()
    if args[0] == "ids":
        print("\n".join(sorted({ids for _, ids, _ in found})))
        return
    if args[0] == "detect":
        path, _, controls = found[0] if found else ("", "", {})
        print(json.dumps({"haptic": bool(found), "pressure": "pressure" in controls, "device": path,
                          "access": bool(path) and os.access(path, os.R_OK | os.W_OK)}))
        return
    if not found or not found[0][0]:
        sys.exit("touchpad-haptics: this touchpad has no haptic controls")
    path, _, controls = found[0]
    try:
        fd = os.open(path, os.O_RDWR)
    except PermissionError:
        sys.exit(f"touchpad-haptics: no access to {path} (udev rule missing?)")
    try:
        if args[0] in ("get", "set"):
            report, size = controls["intensity"]
            if args[0] == "get":
                print(get_feature(fd, report, size))
            else:
                value = max(0, min(100, int(args[1])))
                set_feature(fd, report, size, value)
                print(value)
        else:
            if "pressure" not in controls:
                sys.exit("touchpad-haptics: this touchpad has no click pressure control")
            report, size = controls["pressure"]
            if len(args) == 1:
                print(get_feature(fd, report, size))
            else:
                value = int(args[1])
                value = 0 if value <= 0 else max(100, min(200, value))
                set_feature(fd, report, size, value)
                print(value)
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
