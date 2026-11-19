"""Read or set the touchpad's haptic feedback intensity and click pressure.

  touchpad-haptics get                print the haptic intensity (0-100)
  touchpad-haptics set N              set it (0 = off, 100 = strongest the touchpad allows)
  touchpad-haptics pressure           print the click pressure threshold (0 = firmware default)
  touchpad-haptics pressure N         set it (100-200, or 0 for the firmware default)

The touchpad (Synaptics SYNA3581, HID 06CB:D019) implements Microsoft's haptic touchpad
controls: feature report 55 is the haptic Intensity (one byte, 0-100) and feature report 54 is
the Button Press Threshold (16 bits, 100-200; 0 reads back while the firmware default is used).
The kernel does not expose them, so this talks to the touchpad's hidraw device directly
(access via /etc/udev/rules.d/70-touchpad-haptics.rules).
"""
import fcntl
import glob
import os
import sys

VENDOR, PRODUCT = "06CB", "D019"
INTENSITY_REPORT = 55
PRESSURE_REPORT = 54


def ioc(nr, length):  # _IOC(_IOC_WRITE|_IOC_READ, 'H', nr, length)
    return (3 << 30) | (length << 16) | (ord("H") << 8) | nr


def get_feature(fd, report, size):
    buf = bytearray([report] + [0] * size)
    fcntl.ioctl(fd, ioc(0x07, len(buf)), buf)
    return int.from_bytes(buf[1:], "little")


def set_feature(fd, report, size, value):
    buf = bytearray([report]) + value.to_bytes(size, "little")
    fcntl.ioctl(fd, ioc(0x06, len(buf)), buf)


def find_device():
    for hid in glob.glob(f"/sys/bus/hid/devices/*:{VENDOR}:{PRODUCT}.*"):
        nodes = glob.glob(os.path.join(hid, "hidraw", "hidraw*"))
        if nodes:
            return "/dev/" + os.path.basename(nodes[0])
    sys.exit("touchpad-haptics: touchpad not found")


def main():
    args = sys.argv[1:]
    if not args or args[0] not in ("get", "set", "pressure"):
        sys.exit(__doc__.strip().split("\n\n")[1])
    path = find_device()
    try:
        fd = os.open(path, os.O_RDWR)
    except PermissionError:
        sys.exit(f"touchpad-haptics: no access to {path} (udev rule missing?)")
    try:
        if args[0] == "get":
            print(get_feature(fd, INTENSITY_REPORT, 1))
        elif args[0] == "set":
            value = max(0, min(100, int(args[1])))
            set_feature(fd, INTENSITY_REPORT, 1, value)
            print(value)
        elif len(args) == 1:
            print(get_feature(fd, PRESSURE_REPORT, 2))
        else:
            value = int(args[1])
            value = 0 if value <= 0 else max(100, min(200, value))
            set_feature(fd, PRESSURE_REPORT, 2, value)
            print(value)
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
