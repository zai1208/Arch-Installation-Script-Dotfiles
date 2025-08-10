#!/usr/bin/env bash
set -euo pipefail

# --- Interactive User Input ---
read -rp "Enter target disk (e.g., /dev/vda for UTM, or /dev/nvme0n1 for NVMe): " DISK
read -rp "Enter hostname: " HOSTNAME
read -rp "Enter username: " USERNAME
read -s -rp "Enter password for $USERNAME (and root): " PASSWORD
echo
read -rp "Enter your timezone (e.g., Australia/Sydney): " TIMEZONE

# sanity check
if [[ ! -b "$DISK" ]]; then
  echo "ERROR: disk $DISK not found. Aborting."
  exit 1
fi

# --- Partition Disk ---
echo "[*] Partitioning $DISK..."
parted --script "$DISK" \
    mklabel gpt \
    mkpart ESP fat32 1MiB 512MiB \
    set 1 esp on \
    mkpart primary ext4 512MiB 100%

# partition name helpers (nvme/mmcblk use p1/p2 nomenclature)
if [[ "$DISK" == *nvme* || "$DISK" == *mmcblk* ]]; then
  PART1="${DISK}p1"
  PART2="${DISK}p2"
else
  PART1="${DISK}1"
  PART2="${DISK}2"
fi

echo "[*] FAT32 EFI -> $PART1"
mkfs.fat -F32 "$PART1"

echo "[*] Setting up LUKS encryption on ${PART2}..."
# Use -v and explicit --key-file=- to read passphrase from stdin
# (keeps behaviour similar to your original script but uses --key-file for clarity)
echo -n "$PASSWORD" | cryptsetup -v luksFormat --key-file=- "$PART2"
echo -n "$PASSWORD" | cryptsetup -v open --type luks --key-file=- "$PART2" root

mkfs.ext4 /dev/mapper/root

# --- Mount Partitions ---
mount /dev/mapper/root /mnt
mkdir -p /mnt/boot
mount --mkdir "$PART1" /mnt/boot

# capture UUID for the GRUB cmdline
ROOT_PART_UUID=$(blkid -s UUID -o value "$PART2")
echo "[*] UUID of encrypted partition: $ROOT_PART_UUID"

# --- Pacstrap variables ---
BASE_PACKAGES=(base base-devel linux linux-firmware man-db man-pages vim archlinux-keyring amd-ucode)
DEV_PACKAGES=(git)
HYPRLAND_PACKAGES=(hyprland waybar fuzzel alacritty swww thunar gtk4 hyprlock)
APPS_PACKAGES=(atril chromium gimp feh)
UTIL_PACKAGES=(cups cups-pdf cups-filters cups-pk-helper pipewire pipewire-pulse pavucontrol bluez blueman networkmanager nm-connection-editor)
FONT_CURSOR_PACKAGES=(adwaita-cursors ttf-hack-nerd ttf-nerd-fonts-symbols)
EXTRA_PACKAGES=(fastfetch cmatrix)

# --- Fix PGP Keyring Errors ---
echo "[*] Re-initializing pacman keyring in live environment..."
pacman-key --init
pacman-key --populate archlinux
pacman -Sy archlinux-keyring --noconfirm

# --- Pacstrap Installation ---
echo "[*] Installing base system with pacstrap..."
pacstrap -K /mnt "${BASE_PACKAGES[@]}"

echo "[*] Installing Dev utilities + networkmanager with pacstrap..."
pacstrap -K /mnt "${DEV_PACKAGES[@]}"

echo "[*] Installing Hyprland + apps needed by Hyprland with pacstrap..."
pacstrap -K /mnt "${HYPRLAND_PACKAGES[@]}"

echo "[*] Installing other apps with pacstrap..."
pacstrap -K /mnt "${APPS_PACKAGES[@]}"

echo "[*] Installing remaining utilities with pacstrap..."
pacstrap -K /mnt "${UTIL_PACKAGES[@]}"

echo "[*] Installing fonts and cursor with pacstrap..."
pacstrap -K /mnt "${FONT_CURSOR_PACKAGES[@]}"

echo "[*] Installing extras with pacstrap..."
pacstrap -K /mnt "${EXTRA_PACKAGES[@]}"

# --- Generate fstab ---
genfstab -U /mnt >> /mnt/etc/fstab

# --- Chroot & Configure System ---
echo "[*] Configuring system (chroot)..."

arch-chroot /mnt /bin/bash <<EOF
# timezone / locale
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname

# root + user
echo "root:$PASSWORD" | chpasswd
useradd -mG wheel $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

mkswap --size 4G --file /swapfile
swapon /swapfile
echo "/swapfile none swap defaults 0 0" >> /etc/fstab

# Ensure encrypt hook present for initramfs (keeps mapper name 'root')
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect keyboard keymap consolefont encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# pacman eye-candy
sed -Ei 's/^#(Color)$/\1\nILoveCandy/;s/^#(ParallelDownloads).*/\1 = 10/' /etc/pacman.conf

# GRUB
pacman -S --noconfirm grub efibootmgr
# use /boot as the EFI directory (we mounted the FAT32 there earlier)
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB

# Set GRUB kernel command line to use the cryptdevice=UUID=_device-UUID_:root format
sed -i "s|^GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$ROOT_PART_UUID:root root=/dev/mapper/root\"|" /etc/default/grub
echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub

grub-mkconfig -o /boot/grub/grub.cfg

# tty1 autologin for user
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat <<EOL2 > /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $USERNAME --noclear %I \\$TERM
EOL2

systemctl enable NetworkManager
systemctl enable cups.service
EOF

# --- Dotfiles Deployment ---
echo "[*] Cloning dotfiles for $USERNAME..."
arch-chroot /mnt /bin/bash <<EOF2
cd /home/$USERNAME/
if [ ! -d dotfiles ]; then
  sudo -u $USERNAME git clone https://github.com/zai1208/dotfiles.git
fi
cd dotfiles
chmod +x install.sh || true
sudo -u $USERNAME ./install.sh || true
EOF2

# --- Finished ---
echo "[*] Installation Complete! Unmounting and Rebooting..."
umount -R /mnt || echo "Warning: failed to unmount /mnt"
reboot
