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

# --- Pacstrap Installation ---
echo "[*] Installing base system with pacstrap..."
pacstrap -K /mnt base base-devel linux linux-firmware git sudo networkmanager hyprland waybar fuzzel neofetch \
            amd-ucode man-db man-pages texinfo vim alacritty pipewire atril cups cups-pdf cups-filters cups-pk-helper \
            archlinux-keyring chromium 

# --- Generate fstab ---
genfstab -U /mnt >> /mnt/etc/fstab

# --- Chroot & Configure System ---
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
