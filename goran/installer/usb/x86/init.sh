#!/env/bin/bash
# First program on the x86 USB installer: bring up the hardware, then show the installer.
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
# Storage, USB and keyboards found on x86 laptops and in virtual machines.
for module in nvme ahci ata_piix sd_mod sr_mod mmc_block sdhci_pci sdhci_acpi rtsx_pci_sdmmc \
              virtio_pci virtio_blk virtio_scsi vmd \
              xhci_pci xhci_hcd ehci_pci ehci_hcd uhci_hcd ohci_pci usb_storage uas \
              hid_generic usbhid atkbd i8042 i2c_hid_acpi intel_lpss_pci pinctrl_tigerlake hid_multitouch evdev \
              efivarfs vfat ext4 nls_cp437 nls_ascii nls_iso8859_1 nls_utf8; do
    timeout 20 modprobe "$module" 2>/dev/null
done
udevadm settle --timeout=20

# Load whatever else this computer's hardware asks for. New devices appear as drivers load, so look a few times.
for pass in 1 2 3; do
    find /sys/devices -name modalias -type f -exec cat {} + 2>/dev/null | sort -u |
        xargs -r -d '\n' -n 1 -P 8 timeout 20 modprobe -q -b 2>/dev/null
    udevadm settle --timeout=10
done

python3 -I /installer/installer_x86.py
# The installer only ends by turning off or restarting. If it ever stops, restart cleanly.
sleep 5
echo b > /proc/sysrq-trigger
sleep 60
