#!/env/bin/bash
# First program on the USB installer: bring up the hardware, then show the installer.
export PATH=/env/bin MODULE_DIR=/lib/modules/
mkdir -p /proc /sys /dev /run /tmp /mnt
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null
exec </dev/console >/dev/console 2>&1
mount -t tmpfs tmpfs /run
mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null
ln -sf /proc/self/fd /dev/fd
echo 0 > /proc/sys/kernel/printk
echo 1 > /proc/sys/kernel/sysrq

# The kernel asks for drivers by itself too, for example the character sets the startup partition needs.
printf '#!/env/bin/bash\nMODULE_DIR=/lib/modules/ exec /env/bin/modprobe "$@"\n' > /run/modprobe
chmod 755 /run/modprobe
echo /run/modprobe > /proc/sys/kernel/modprobe

mkdir -p /run/udev /etc/udev
udevd --daemon --resolve-names=never
udevadm trigger --action=add --type=subsystems
udevadm trigger --action=add --type=devices
for module in xhci_plat_hcd i2c_mt65xx nvme usb_storage uas sd_mod hid_generic usbhid i2c_hid_acpi hid_multitouch evdev vfat ext4 nls_cp437 nls_ascii nls_iso8859_1; do
    timeout 20 modprobe "$module" 2>/dev/null
done
udevadm settle --timeout=20

# Load whatever else this laptop's hardware asks for. New devices appear as drivers load, so look a few times.
for pass in 1 2 3; do
    find /sys/devices -name modalias -type f -exec cat {} + 2>/dev/null | sort -u |
        xargs -r -d '\n' -n 1 -P 8 timeout 20 modprobe -q -b 2>/dev/null
    udevadm settle --timeout=10
done

python3 -I /installer/installer.py
# The installer only ends by turning off or restarting. If it ever stops, restart cleanly.
sleep 5
echo b > /proc/sysrq-trigger
sleep 60
