#!/bin/bash
# What the installer left on the disk, seen from the system that it boots. The argument is the firmware it ran under.
source /opt/aos-tests/tests/integration/guest/lib.sh
firmware=$1

eq "the system is running with no failed unit" running "$(systemctl is-system-running --wait)"
if [[ $firmware == uefi ]]; then
	eq "the machine booted with UEFI" 0 "$(status_of test -d /sys/firmware/efi)"
else
	eq "the machine booted with BIOS" 1 "$(status_of test -d /sys/firmware/efi)"
fi
eq "the removable EFI path exists" 0 "$(status_of test -f /boot/efi/EFI/BOOT/BOOTX64.EFI)"
eq "the boot loader follows package upgrades" 0 "$(status_of test -e /etc/grub.d/enable_cloud)"

eq "the root is mounted by UUID" 1 "$(grep -c "^UUID=.* / ext4" /etc/fstab)"
eq "the data filesystem is mounted by UUID" 1 "$(grep -c "^UUID=.* /var/lib/agent-os btrfs" /etc/fstab)"
eq "no filesystem is mounted by label" 0 "$(grep -c "^LABEL=" /etc/fstab)"
eq "project data is on Btrfs" btrfs "$(stat -f -c %T /var/lib/agent-os)"
eq "quotas are enabled" 0 "$(status_of btrfs qgroup show /var/lib/agent-os)"
eq "the data directory has the package's mode" 711 "$(stat -c %a /var/lib/agent-os)"
between "the data filesystem fills the disk, in GiB" 15 16 "$(df -BG --output=size /var/lib/agent-os | tail -1 | tr -dc 0-9)"

eq "one key is enrolled" 1 "$(wc -l < /home/admin/.ssh/authorized_keys)"
eq "the key file is private" "600 admin" "$(stat -c "%a %U" /home/admin/.ssh/authorized_keys)"
eq "the key directory is private" "700 admin" "$(stat -c "%a %U" /home/admin/.ssh)"
eq "admin has no password" 1 "$(passwd -S admin | awk '{print ($2 == "L" || $2 == "NP")}')"
eq "root has no password" 1 "$(passwd -S root | awk '{print ($2 == "L")}')"

eq "the installer's own tools are not installed" 1 "$(status_of dpkg -s live-boot)"
eq "the machine ID is generated" 0 "$(status_of grep -Eqx "[0-9a-f]{32}" /etc/machine-id)"
finish
