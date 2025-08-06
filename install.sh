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

echo "[*] Setting up LUKS encryption on ${DISK}p2..."
echo -n "$PASSWORD" | cryptsetup luksFormat ${DISK}p2 -
echo -n "$PASSWORD" | cryptsetup open ${DISK}p2 cryptroot -

mkfs.ext4 /dev/mapper/cryptroot

# --- Mount Partitions ---
mount /dev/mapper/cryptroot /mnt
mount --mkdir ${DISK}p1 /mnt/boot

# --- Pacstrap variables ---
BASE_PACKAGES=(base base-devel linux linux-firmware man-db man-pages vim amd-ucode archlinux-keyring)
DEV_PACKAGES=(git networkmanager)
HYPRLAND_PACKAGES=(hyprland waybar fuzzel alacritty swww)
APPS_PACKAGES=(atril chromium)
UTIL_PACKAGES=(cups cups-pdf cups-filters cups-pk-helper pipewire)
FONT_CURSOR_PACKAGES=(adwaita-cursors ttf-hack-nerd ttf-nerd-fonts-symbols)
EXTRA_PACKAGES=(neofetch limine)

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

mkswap --size 4G --file /swapfile
swapon /swapfile
echo "/swapfile none swap defaults 0 0" >> /etc/fstab

# Setup crypttab
echo "cryptroot UUID=\$(blkid -s UUID -o value ${DISK}p2) none luks" >> /etc/crypttab

# Enable encrypt hook in mkinitcpio
sed -i 's/HOOKS=(base udev autodetect.*)/HOOKS=(base udev autodetect keyboard keymap consolefont encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Limine installation and configuration
limine-install ${DISK}p1
mkdir -p /boot/limine
cp /usr/share/limine/limine.cfg /boot/limine/limine.cfg

UUID=\$(blkid -s UUID -o value ${DISK}p2)
cat <<EOL2 > /boot/limine/limine.cfg
TIMEOUT=5
INTERFACE=advanced
:Arch Linux
    PROTOCOL=linux
    KERNEL_PATH=/vmlinuz-linux
    CMDLINE=root=UUID=\$UUID cryptdevice=UUID=\$UUID:cryptroot rw quiet
    MODULE_PATH=/initramfs-linux.img
EOL2

# Enable autologin on tty1
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat <<EOL3 > /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $USERNAME --noclear %I \\\$TERM
EOL3

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
