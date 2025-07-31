#!/bin/bash

set -e

# --- Interactive User Input ---
read -rp "Enter target disk (e.g., /dev/nvme0n1): " DISK
read -rp "Enter hostname: " HOSTNAME
read -rp "Enter username: " USERNAME
read -s -rp "Enter password for $USERNAME (and root): " PASSWORD
read -rp "Enter your timezone (e.g., Australia/Sydney): " TIMEZONE

echo

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
HYPRLAND_PACKAGES=(hyprland waybar fuzzel alacritty swww thunar gtk4 hyprlock)
APPS_PACKAGES=(atril chromium gimp)
UTIL_PACKAGES=(cups cups-pdf cups-filters cups-pk-helper pipewire pavucontrol)
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
echo "[*] Configuring system..."
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
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
echo "cryptroot UUID=$(blkid -s UUID -o value ${DISK}p2) none luks" >> /etc/crypttab

# Enable encrypt hook in mkinitcpio
sed -i 's/HOOKS=(base udev autodetect.*)/HOOKS=(base udev autodetect keyboard keymap consolefont encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Enable pacman eye-candy features
sed -Ei 's/^#(Color)$/\1\nILoveCandy/;s/^#(ParallelDownloads).*/\1 = 10/' /etc/pacman.conf

# GRUB installation and configuration
pacman -S --noconfirm grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB

UUID=\$(blkid -s UUID -o value ${DISK}p2)
sed -i "s|GRUB_CMDLINE_LINUX=\"\"|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=\$UUID:cryptroot root=/dev/mapper/cryptroot\"|" /etc/default/grub
echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# Enable autologin on tty1
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
arch-chroot /mnt /bin/bash <<EOF
cd ~
sudo -u $USERNAME git clone https://zai1208/dotfiles.git
cd dotfiles
chmod +x install.sh
sudo -u $USERNAME ./install.sh
EOF

# --- Dotfiles Deployment ---
echo "[*] Installing yay"
arch-chroot /mnt /bin/bash <<EOF
cd ~
sudo -u $USERNAME git clone https://aur.archlinux.org/yay.git
cd yay
sudo -u $USERNAME makepkg -si
cd ..
rm -rf yay
EOF

# --- Finished ---
echo "[*] Installation Complete! Unmounting and Rebooting..."
umount -R /mnt
reboot
