#!/usr/bin/env bash
set -euo pipefail

# --- Colors ---
CYAN='\e[36m'
NC='\e[0m' # No Color

log_info() {
  echo -e "${CYAN}[*] $*${NC}"
}

# --- Interactive User Input ---
read -rp "Enter target disk (e.g., /dev/vda for UTM, or /dev/nvme0n1 for NVMe): " DISK
read -rp "Enter hostname: " HOSTNAME
read -rp "Enter username: " USERNAME
read -s -rp "Enter password for $USERNAME, LUKS encryption, and root: " PASSWORD
echo
read -rp "Enter your timezone (e.g., Australia/Sydney): " TIMEZONE

# sanity check
if [[ ! -b "$DISK" ]]; then
  echo "ERROR: disk $DISK not found. Aborting."
  exit 1
fi

# --- Partition Disk ---
log_info "Partitioning $DISK..."
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

log_info "FAT32 EFI -> $PART1"
mkfs.fat -F32 "$PART1"

log_info "Setting up LUKS encryption on ${PART2}..."
echo -n "$PASSWORD" | cryptsetup -v luksFormat --key-file=- "$PART2"
echo -n "$PASSWORD" | cryptsetup -v open --type luks --key-file=- "$PART2" root

mkfs.ext4 /dev/mapper/root

# --- Mount Partitions ---
mount /dev/mapper/root /mnt
mkdir -p /mnt/boot
mount --mkdir "$PART1" /mnt/boot

# capture UUID for the GRUB cmdline
ROOT_PART_UUID=$(blkid -s UUID -o value "$PART2")
log_info "UUID of encrypted partition: $ROOT_PART_UUID"

BASE_PACKAGES=(base base-devel linux linux-firmware man-db man-pages neovim archlinux-keyring amd-ucode)
LAPTOP_STUFF=(tlp clight)
DEV_PACKAGES=(git fd ripgrep)
VIRTUALISATION_PACKAGES=(qemu libvirt virt-manager ovmf bridge-utils dnsmasq virt-viewer)
HYPRLAND_PACKAGES=(hyprland waybar fuzzel ghostty swww hyprlock yazi gtk4 hyprpolkitagent xdg-desktop-portal-hyprland)
APPS_PACKAGES=(zathura qutebrowser feh)
UTIL_PACKAGES=(cups cups-pdf cups-filters cups-pk-helper pipewire pipewire-pulse pavucontrol bluez blueman networkmanager nm-connection-editor brightnessctl grim slurp htop system-config-printer fbgrab poppler bat)
FONT_CURSOR_PACKAGES=(adwaita-cursors ttf-hack-nerd ttf-nerd-fonts-symbols)
CAD_PACKAGES=(kicad inkscape freecad blender)
EXTRA_PACKAGES=(fastfetch cmatrix)


# --- Fix PGP Keyring Errors ---
log_info "Re-initializing pacman keyring in live environment..."
pacman-key --init
pacman-key --populate archlinux
pacman -Sy archlinux-keyring --noconfirm

# --- Pacstrap Installation ---
log_info "Installing base system with pacstrap..."
pacstrap -K /mnt "${BASE_PACKAGES[@]}"

log_info "Installing laptop stuff with pacstrap..."
pacstrap -K /mnt "${LAPTOP_STUFF[@]}"

log_info "Installing Dev utilities + networkmanager with pacstrap..."
pacstrap -K /mnt "${DEV_PACKAGES[@]}"

log_info "Installing Virtualisation tools with pacstrap..."
pacstrap -K /mnt "${VIRTUALISATION_PACKAGES[@]}"

log_info "Installing Hyprland + apps needed by Hyprland with pacstrap..."
pacstrap -K /mnt "${HYPRLAND_PACKAGES[@]}"

log_info "Installing other apps with pacstrap..."
pacstrap -K /mnt "${APPS_PACKAGES[@]}"

log_info "Installing remaining utilities with pacstrap..."
pacstrap -K /mnt "${UTIL_PACKAGES[@]}"

log_info "Installing fonts and cursor with pacstrap..."
pacstrap -K /mnt "${FONT_CURSOR_PACKAGES[@]}"

log_info "Installing extras with pacstrap..."
pacstrap -K /mnt "${EXTRA_PACKAGES[@]}"

# --- Generate fstab ---
genfstab -U /mnt >> /mnt/etc/fstab

# --- Chroot & Configure System ---
log_info "Configuring system (chroot)..."

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

# Ensure encrypt hook present for initramfs
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect keyboard keymap consolefont encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# pacman eye-candy
sed -Ei 's/^#(Color)$/\1\nILoveCandy/;s/^#(ParallelDownloads).*/\1 = 10/' /etc/pacman.conf

# GRUB
pacman -S --noconfirm grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
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

# Create the virsh net-autostart script
cat <<'EOF2' > /usr/local/bin/virsh-net-autostart.sh
#!/bin/bash
virsh net-autostart default
systemctl disable virsh-net-autostart.service
rm -f /usr/local/bin/virsh-net-autostart.sh
rm -f /etc/systemd/system/virsh-net-autostart.service
EOF2
chmod +x /usr/local/bin/virsh-net-autostart.sh

# Create the systemd service
cat <<'EOF2' > /etc/systemd/system/virsh-net-autostart.service
[Unit]
Description=Enable default libvirt network once
After=network.target libvirtd.service
Requires=libvirtd.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/virsh-net-autostart.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF2

# Enable the service
systemctl enable virsh-net-autostart.service
systemctl enable --now libvirtd
usermod -aG libvirt $USERNAME
if getent group kvm >/dev/null; then
  usermod -aG kvm $USERNAME
fi

systemctl enable NetworkManager
systemctl enable cups.service
systemctl enable tlp.service
systemctl enable tlp-sleep.service
systemctl enable clightd

# Install LunarVim
sudo -u $USERNAME bash <(curl -s https://raw.githubusercontent.com/lunarvim/lunarvim/master/utils/installer/install.sh)

# Create Screenshots directory
mkdir /home/$USERNAME/Screenshots
EOF

# --- Dotfiles Deployment ---
log_info "Cloning dotfiles for $USERNAME..."
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
log_info "Installation Complete! Unmounting and Rebooting..."
umount -R /mnt || echo "Warning: failed to unmount /mnt"
reboot
