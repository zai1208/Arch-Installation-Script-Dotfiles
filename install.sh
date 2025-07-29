#!/bin/bash

set -e

# --- Interactive User Input ---
read -rp "Enter target disk (e.g., /dev/nvme0n1): " DISK
read -rp "Enter hostname: " HOSTNAME
read -rp "Enter username: " USERNAME
read -s -rp "Enter password for $USERNAME (and root): " PASSWORD

echo

# --- Pre-Checks ---
echo "[*] Checking Internet connectivity..."
ping -c 1 archlinux.org || { echo "No Internet! Aborting..."; exit 1; }

# --- Partition Disk ---
echo "[*] Partitioning $DISK..."
parted --script $DISK \
    mklabel gpt \
    mkpart ESP fat32 1MiB 512MiB \
    set 1 esp on \
    mkpart primary ext4 512MiB 100%

mkfs.fat -F32 ${DISK}p1
mkfs.ext4 -L rootfs ${DISK}p2

# --- Mount Partitions ---
mount ${DISK}p2 /mnt
mount --mkdir ${DISK}p1 /mnt/boot

# --- Pacstrap variables ---
BASE_PACKAGES=(base base-devel linux linux-firmware man-db man-pages vim amd-ucode archlinux-keyring)
DEV_PACKAGES=(git networkmanager)
HYPRLAND_PACKAGES=(hyprland waybar fuzzel alacritty)
APPS_PACKAGES=(atril chromium)
UTIL_PACKAGES=(cups cups-pdf cups-filters cups-pk-helper pipewire)
FONT-CURSOR_PACKAGES=(adwaita-cursors ttf-hack-nerd ttf-nerd-fonts-symbols)
EXTRA_PACKAGES=(neofetch)


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
pacstrap -K /mnt "${FONT-CURSOR_PACKAGES[@]}"

echo "[*] Installing extras with pacstrap..." 
pacstrap -K /mnt "${EXTRA_PACKAGES[@]}"

# --- Generate fstab ---
genfstab -U /mnt >> /mnt/etc/fstab

# --- Chroot & Configure System ---
echo "[*] Configuring system..."
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname

echo "root:$PASSWORD" | chpasswd

useradd -mG wheel $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

pacman -S --noconfirm grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

systemctl enable NetworkManager
systemctl enable cups.service
EOF

# --- Dotfiles Deployment ---
echo "[*] Cloning dotfiles for $USERNAME..."
arch-chroot /mnt /bin/bash <<EOF
cd ~
sudo -u $USERNAME git clone https://zai1208/dotfiles.git
cd dotfiles
sudo -u $USERNAME ./install.sh
EOF

# --- Finished ---
echo "[*] Installation Complete! Unmounting and Rebooting..."
umount -R /mnt
reboot
