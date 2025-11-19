#!/bin/bash
################################################################################
# Arch Linux ARM Raspberry Pi Image Builder
#
# Builds custom Arch Linux ARM images for Raspberry Pi 4 and 5 with:
# - Pre-configured networking (systemd-networkd)
# - SSH access with key-based authentication
# - USB serial console support
# - Optional WiFi and ZeroTier configuration
#
# Usage:
#   sudo ./build.sh --rpi-model 5
#   sudo ./build.sh --rpi-model 4 --image-size 8G --hostname my-rpi
#
# Requirements:
#   - Arch Linux host (or container)
#   - Root privileges
#   - Internet connection
################################################################################

set -euo pipefail

################################################################################
# Configuration - Defaults (can be overridden by env vars or arguments)
################################################################################

# RPi Configuration
RPI_MODEL="${RPI_MODEL:-5}"
ARM_VERSION="${ARM_VERSION:-aarch64}"

# Image Configuration
IMAGE_SIZE="${IMAGE_SIZE:-4G}"
IMAGE_NAME_PREFIX="${IMAGE_NAME_PREFIX:-archlinux-rpi}"
BOOT_PARTITION_SIZE="${BOOT_PARTITION_SIZE:-512M}"

# System Configuration
OS_TIMEZONE="${OS_TIMEZONE:-Europe/Paris}"
OS_DEFAULT_LOCALE="${OS_DEFAULT_LOCALE:-en_US.UTF-8}"
OS_KEYMAP="${OS_KEYMAP:-us-acentos}"
OS_LOCALES="${OS_LOCALES:-en_US.UTF-8 UTF-8
en_US ISO-8859-1
fr_FR.UTF-8 UTF-8
fr_FR ISO-8859-1
fr_FR@euro ISO-8859-15}"

# Network Configuration
SSH_PUB_KEY_URLS="${SSH_PUB_KEY_URLS:-https://github.com/ts-sz.keys https://gitlab.com/mg.stratzone.keys}"
SSH_PORT="${SSH_PORT:-34522}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"
ZT_NETWORK_ID="${ZT_NETWORK_ID:-}"

# Packages to install
OS_PACKAGES="${OS_PACKAGES:-base base-devel dosfstools git mkinitcpio-utils neovim nftables openssh python qrencode rsync sudo tailscale uboot-tools unzip zerotier-one zsh iwd wireless-regdb linux-firmware crda raspberrypi-bootloader firmware-raspberrypi zstd}"

# Build dependencies
BUILD_DEPS="${BUILD_DEPS:-qemu-user-static-binfmt qemu-user-static dosfstools wget libarchive arch-install-scripts parted tree fping pwgen git s3cmd zstd}"

# Download URLs
ARCH_AARCH64_MIRROR="${ARCH_AARCH64_MIRROR:-http://os.archlinuxarm.org/os}"
ARCH_AARCH64_IMG="${ARCH_AARCH64_IMG:-ArchLinuxARM-rpi-aarch64-latest.tar.gz}"
ARCH_AARCH64_IMG_MD5="${ARCH_AARCH64_IMG_MD5:-ArchLinuxARM-rpi-aarch64-latest.tar.gz.md5}"

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-$(mktemp -d "$PWD/rpi-build.XXXXXX")}"
DOWNLOAD_DIR="$WORKDIR/download"
MOUNT_DIR="$WORKDIR/root"
OUTPUT_DIR="${OUTPUT_DIR:-$WORKDIR}"

# Runtime variables (set during build)
LOOP_DEVICE=""
BUILD_DATE=$(date +%Y%m%d)
SHORT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "local")
RPI_HOSTNAME="${RPI_HOSTNAME:-archlinux-${SHORT_SHA}-rpi${RPI_MODEL}}"
ROOT_PASSWORD="${ROOT_PASSWORD:-$(pwgen -s 17 1 2>/dev/null || echo "changeme")}"
IMAGE_NAME="${IMAGE_NAME_PREFIX}-${ARM_VERSION}-rpi${RPI_MODEL}_v${SHORT_SHA}_${BUILD_DATE}.img"

# Flags
DEBUG="${DEBUG:-false}"
NO_CLEANUP="${NO_CLEANUP:-false}"

################################################################################
# Utility Functions
################################################################################

log_info() {
    echo -e "\e[1;34m[INFO]\e[0m $*"
}

log_success() {
    echo -e "\e[1;32m[SUCCESS]\e[0m $*"
}

log_error() {
    echo -e "\e[1;31m[ERROR]\e[0m $*" >&2
}

log_warn() {
    echo -e "\e[1;33m[WARN]\e[0m $*"
}

die() {
    log_error "$*"
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root. Use: sudo $0"
    fi
}

check_dependencies() {
    local missing_deps=()
    for dep in fallocate losetup sfdisk mkfs.vfat mkfs.ext4 mount umount wget bsdtar arch-chroot; do
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        die "Missing dependencies: ${missing_deps[*]}"
    fi
}

################################################################################
# Cleanup Function
################################################################################

cleanup() {
    local exit_code=$?

    # Skip cleanup in CI - container will be destroyed anyway
    if [[ -n "${CI:-}" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        log_info "CI environment detected - skipping cleanup (container will be destroyed)"
        return
    fi

    if [[ "$NO_CLEANUP" == "true" ]]; then
        log_warn "Cleanup skipped (NO_CLEANUP=true). Manual cleanup needed:"
        log_warn "  umount -R $MOUNT_DIR"
        log_warn "  losetup -d $LOOP_DEVICE"
        log_warn "  rm -rf $WORKDIR"
        return
    fi

    log_info "Cleaning up..."

    # Unmount filesystems
    if mountpoint -q "$MOUNT_DIR/boot" 2>/dev/null; then
        umount -R -fl "$MOUNT_DIR/boot" || log_warn "Failed to unmount boot"
    fi

    if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
        umount -R -fl "$MOUNT_DIR" || log_warn "Failed to unmount root"
    fi

    # Release loop device
    if [[ -n "$LOOP_DEVICE" ]] && losetup "$LOOP_DEVICE" &>/dev/null; then
        losetup -d "$LOOP_DEVICE" || log_warn "Failed to release loop device"
    fi

    # Keep workdir if build failed for debugging
    if [[ $exit_code -eq 0 ]]; then
        # Only auto-cleanup if workdir is in current directory (not /tmp or custom path)
        if [[ "$WORKDIR" =~ ^"$PWD"/rpi-build ]]; then
            rm -rf "$WORKDIR" || log_warn "Failed to remove workdir"
        else
            log_info "Workdir not auto-cleaned (custom path): $WORKDIR"
        fi
    else
        log_warn "Build failed. Workdir preserved for debugging: $WORKDIR"
    fi

    if [[ $exit_code -eq 0 ]]; then
        log_success "Cleanup completed"
    fi
}

trap cleanup EXIT ERR INT TERM

################################################################################
# Build Functions
################################################################################

setup_dependencies() {
    log_info "Installing build dependencies..."

    if ! pacman -Qi archlinux-keyring &>/dev/null; then
        pacman-key --init
        pacman-key --populate archlinux
    fi

    pacman -Sy --needed --noconfirm $BUILD_DEPS

    log_success "Dependencies installed"
}

download_arch_arm() {
    log_info "Downloading Arch Linux ARM base image..."

    mkdir -p "$DOWNLOAD_DIR"

    local img_url="$ARCH_AARCH64_MIRROR/$ARCH_AARCH64_IMG"
    local md5_url="$ARCH_AARCH64_MIRROR/$ARCH_AARCH64_IMG_MD5"

    wget --show-progress --progress=bar:force -t 5 -T 60 --waitretry=10 \
        "$img_url" -O "$DOWNLOAD_DIR/$ARCH_AARCH64_IMG"

    wget --show-progress --progress=bar:force -t 5 -T 60 --waitretry=10 \
        "$md5_url" -O "$DOWNLOAD_DIR/$ARCH_AARCH64_IMG_MD5"

    log_success "Download completed"
}

verify_checksum() {
    log_info "Verifying checksum..."

    cd "$DOWNLOAD_DIR"
    md5sum -c "$ARCH_AARCH64_IMG_MD5" || die "Checksum verification failed"
    cd - >/dev/null

    log_success "Checksum verified"
}

create_image_file() {
    log_info "Creating image file: $IMAGE_NAME ($IMAGE_SIZE)..."

    fallocate -l "$IMAGE_SIZE" "$OUTPUT_DIR/$IMAGE_NAME" || \
        die "Failed to create image file"

    log_success "Image file created"
}

setup_loop_device() {
    log_info "Setting up loop device..."

    # Create loop device nodes if they don't exist
    for i in $(seq 0 31); do
        [[ ! -e /dev/loop$i ]] && mknod -m660 /dev/loop$i b 7 $i || true
    done

    sleep 2

    # Attach image to loop device
    LOOP_DEVICE=$(losetup -fP "$OUTPUT_DIR/$IMAGE_NAME" --show) || \
        die "Failed to setup loop device"

    log_info "Loop device: $LOOP_DEVICE"

    # Create partitions
    log_info "Creating partitions..."
    sfdisk --quiet --wipe always "$LOOP_DEVICE" <<EOF
,$BOOT_PARTITION_SIZE,0c,*
,,83,
EOF

    sleep 2
    sfdisk -d "$LOOP_DEVICE"

    log_success "Partitions created"
}

format_partitions() {
    log_info "Formatting partitions..."

    sleep 2

    # Create partition device nodes if needed
    while read dev node; do
        maj=$(echo $node | cut -d: -f1)
        min=$(echo $node | cut -d: -f2)
        if [[ ! -e "/dev/$dev" ]]; then
            log_info "Creating partition device node: /dev/$dev"
            mknod "/dev/$dev" b $maj $min || log_warn "Failed to create /dev/$dev"
        fi
    done < <(lsblk --raw --output "NAME,MAJ:MIN" --noheadings "$LOOP_DEVICE" | tail -n +2)

    sleep 2

    # Verify partition devices exist
    if [[ ! -e "${LOOP_DEVICE}p1" ]]; then
        die "Partition device ${LOOP_DEVICE}p1 not found after setup"
    fi
    if [[ ! -e "${LOOP_DEVICE}p2" ]]; then
        die "Partition device ${LOOP_DEVICE}p2 not found after setup"
    fi

    log_info "Partition devices verified: ${LOOP_DEVICE}p1, ${LOOP_DEVICE}p2"

    # Format boot partition (FAT32)
    log_info "Formatting boot partition (FAT32)..."
    mkfs.vfat -F32 "${LOOP_DEVICE}p1" -n RPI64-BOOT || \
        die "Failed to format boot partition"

    # Format root partition (ext4)
    log_info "Formatting root partition (ext4)..."
    mkfs.ext4 -q -E lazy_itable_init=0,lazy_journal_init=0 -F "${LOOP_DEVICE}p2" -L RPI64-ROOT || \
        die "Failed to format root partition"

    log_success "Partitions formatted"
}

mount_partitions() {
    log_info "Mounting partitions..."

    mkdir -p "$MOUNT_DIR"

    mount "${LOOP_DEVICE}p2" "$MOUNT_DIR" || \
        die "Failed to mount root partition"

    mkdir -p "$MOUNT_DIR/boot"

    mount "${LOOP_DEVICE}p1" "$MOUNT_DIR/boot" || \
        die "Failed to mount boot partition"

    log_success "Partitions mounted"
}

extract_base_system() {
    log_info "Extracting Arch Linux ARM base system..."

    bsdtar -xpf "$DOWNLOAD_DIR/$ARCH_AARCH64_IMG" -C "$MOUNT_DIR" || \
        die "Failed to extract base system"

    sync

    log_success "Base system extracted"
}

setup_qemu() {
    log_info "Setting up QEMU for cross-architecture support..."

    # Start systemd-binfmt if available
    systemctl start systemd-binfmt 2>/dev/null || true

    # Setup binfmt manually if needed
    if [[ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
        mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
        echo ':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64-static:' > /proc/sys/fs/binfmt_misc/register 2>/dev/null || true
    fi

    # Copy QEMU static binary to chroot
    if [[ -f /usr/bin/qemu-aarch64-static ]]; then
        cp /usr/bin/qemu-aarch64-static "$MOUNT_DIR/usr/bin/"
    else
        # Try to find it in alternative locations
        local qemu_path=$(find /usr -name "qemu-aarch64-static" 2>/dev/null | head -1)
        if [[ -n "$qemu_path" ]]; then
            cp "$qemu_path" "$MOUNT_DIR/usr/bin/"
        else
            log_warn "qemu-aarch64-static not found, chroot operations may fail"
        fi
    fi

    log_success "QEMU setup completed"
}

clean_uboot() {
    log_info "Cleaning old U-Boot files..."

    rm -rf "$MOUNT_DIR/boot"/*
    sync

    log_success "U-Boot cleaned"
}

init_pacman() {
    log_info "Initializing pacman keyring..."

    arch-chroot "$MOUNT_DIR" /usr/bin/pacman-key --init
    arch-chroot "$MOUNT_DIR" /usr/bin/pacman-key --populate archlinuxarm

    # Update mirrorlist (hardcoded as reflector doesn't work in containers)
    cat > "$MOUNT_DIR/etc/pacman.d/mirrorlist" <<EOF
Server = http://de.mirror.archlinuxarm.org/\$arch/\$repo
Server = http://mirror.archlinuxarm.org/\$arch/\$repo
EOF

    arch-chroot "$MOUNT_DIR" /usr/bin/pacman -Sy --noconfirm archlinux-keyring

    log_success "Pacman initialized"
}

remove_old_packages() {
    log_info "Removing old packages..."

    arch-chroot "$MOUNT_DIR" /usr/bin/pacman -R --noconfirm linux-aarch64 uboot-raspberrypi 2>/dev/null || true

    log_success "Old packages removed"
}

install_kernel() {
    log_info "Installing Raspberry Pi kernel..."

    if [[ "$RPI_MODEL" == "5" ]]; then
        log_info "Installing linux-rpi-16k and rpi5-eeprom for RPi 5..."
        arch-chroot "$MOUNT_DIR" /usr/bin/pacman -S --noconfirm --overwrite "/boot/*" \
            linux-rpi-16k rpi5-eeprom
    elif [[ "$RPI_MODEL" == "4" ]]; then
        log_info "Installing linux-rpi and rpi4-eeprom for RPi 4..."
        arch-chroot "$MOUNT_DIR" /usr/bin/pacman -S --noconfirm --overwrite "/boot/*" \
            linux-rpi rpi4-eeprom
    else
        die "Unsupported RPI_MODEL: $RPI_MODEL (must be 4 or 5)"
    fi

    log_success "Kernel installed"
}

install_packages() {
    log_info "Installing packages..."

    arch-chroot "$MOUNT_DIR" /usr/bin/pacman -S --noconfirm $OS_PACKAGES

    log_success "Packages installed"
}

configure_locales() {
    log_info "Configuring locales..."

    echo "$OS_LOCALES" > "$MOUNT_DIR/etc/locale.gen"
    arch-chroot "$MOUNT_DIR" locale-gen

    echo "LANG=$OS_DEFAULT_LOCALE" > "$MOUNT_DIR/etc/locale.conf"
    echo -e "KEYMAP=$OS_KEYMAP\nFONT=eurlatgr" > "$MOUNT_DIR/etc/vconsole.conf"

    log_success "Locales configured"
}

configure_timezone() {
    log_info "Configuring timezone: $OS_TIMEZONE..."

    ln -sf "/usr/share/zoneinfo/$OS_TIMEZONE" "$MOUNT_DIR/etc/localtime"

    log_success "Timezone configured"
}

configure_hostname() {
    log_info "Configuring hostname: $RPI_HOSTNAME..."

    echo "$RPI_HOSTNAME" > "$MOUNT_DIR/etc/hostname"

    log_success "Hostname configured"
}

configure_root_password() {
    log_info "Configuring root password..."

    arch-chroot "$MOUNT_DIR" /bin/bash -c "echo root:$ROOT_PASSWORD | chpasswd"

    # Save password to file
    echo "$ROOT_PASSWORD" > "$OUTPUT_DIR/root_password.txt"
    chmod 600 "$OUTPUT_DIR/root_password.txt"

    log_success "Root password configured and saved to root_password.txt"
}

configure_networking() {
    log_info "Configuring networking..."

    mkdir -p "$MOUNT_DIR/etc/systemd/network"
    chmod 755 "$MOUNT_DIR/etc/systemd/network"

    # Copy network configuration files
    if [[ -f "$SCRIPT_DIR/src/etc/systemd/network/20-wired.network" ]]; then
        cp "$SCRIPT_DIR/src/etc/systemd/network/20-wired.network" \
           "$MOUNT_DIR/etc/systemd/network/20-wired.network"
    else
        log_warn "Wired network config not found, skipping"
    fi

    if [[ -f "$SCRIPT_DIR/src/etc/systemd/network/20-wireless.network" ]]; then
        cp "$SCRIPT_DIR/src/etc/systemd/network/20-wireless.network" \
           "$MOUNT_DIR/etc/systemd/network/20-wireless.network"
    else
        log_warn "Wireless network config not found, skipping"
    fi

    log_success "Networking configured"
}

configure_wifi() {
    if [[ -n "$WIFI_SSID" ]] && [[ -n "$WIFI_PASSWORD" ]]; then
        log_info "Configuring WiFi for SSID: $WIFI_SSID..."

        mkdir -p "$MOUNT_DIR/var/lib/iwd"
        cat > "$MOUNT_DIR/var/lib/iwd/${WIFI_SSID}.psk" <<EOF
[Security]
PreSharedKey=$WIFI_PASSWORD

[Settings]
AutoConnect=true
EOF

        arch-chroot "$MOUNT_DIR" systemctl enable iwd

        log_success "WiFi configured"
    else
        log_info "WiFi configuration skipped (no credentials provided)"
    fi
}

configure_ssh() {
    log_info "Configuring SSH..."

    # Download SSH keys from all sources
    mkdir -p "$MOUNT_DIR/root/.ssh"
    > "$MOUNT_DIR/root/.ssh/authorized_keys"  # Create empty file

    for url in $SSH_PUB_KEY_URLS; do
        log_info "Downloading SSH keys from: $url"
        if curl -sf "$url" >> "$MOUNT_DIR/root/.ssh/authorized_keys"; then
            log_success "Downloaded keys from $url"
        else
            log_warn "Failed to download SSH keys from $url"
        fi
    done

    # Check if we got any keys
    if [[ ! -s "$MOUNT_DIR/root/.ssh/authorized_keys" ]]; then
        log_warn "No SSH keys were downloaded! SSH key authentication will not work."
    fi

    chmod 700 "$MOUNT_DIR/root/.ssh"
    chmod 600 "$MOUNT_DIR/root/.ssh/authorized_keys"

    # Configure sshd
    mkdir -p "$MOUNT_DIR/etc/ssh/sshd_config.d"
    echo "UseDNS no" > "$MOUNT_DIR/etc/ssh/sshd_config.d/10-dns.conf"
    echo "Port $SSH_PORT" > "$MOUNT_DIR/etc/ssh/sshd_config.d/20-port.conf"
    echo "PermitRootLogin prohibit-password" > "$MOUNT_DIR/etc/ssh/sshd_config.d/30-root-login.conf"
    echo "AddressFamily any" > "$MOUNT_DIR/etc/ssh/sshd_config.d/40-address-family.conf"

    arch-chroot "$MOUNT_DIR" systemctl enable sshd

    log_success "SSH configured (port $SSH_PORT)"
}

configure_fstab() {
    log_info "Configuring fstab..."

    echo "LABEL=RPI64-BOOT  /boot   vfat    defaults        0       0" > "$MOUNT_DIR/etc/fstab"

    log_success "Fstab configured"
}

configure_zerotier() {
    if [[ -n "$ZT_NETWORK_ID" ]]; then
        log_info "Configuring ZeroTier network: $ZT_NETWORK_ID..."

        arch-chroot "$MOUNT_DIR" systemctl enable zerotier-one
        mkdir -p "$MOUNT_DIR/var/lib/zerotier-one/networks.d"
        touch "$MOUNT_DIR/var/lib/zerotier-one/networks.d/${ZT_NETWORK_ID}.conf"

        log_success "ZeroTier configured"
    else
        log_info "ZeroTier configuration skipped (no network ID provided)"
    fi
}

configure_usb_gadget() {
    log_info "Configuring USB serial gadget console..."

    # Configure boot config
    cat >> "$MOUNT_DIR/boot/config.txt" <<'EOF'

# === USB SERIAL GADGET CONFIGURATION ===
enable_uart=1
EOF

    if [[ "$RPI_MODEL" == "5" ]]; then
        # For RPi 5: Override cm5 section to use device mode
        sed -i '/\[cm5\]/,/\[.*\]/{s/dtoverlay=dwc2,dr_mode=host/dtoverlay=dwc2,dr_mode=device/}' \
            "$MOUNT_DIR/boot/config.txt"
    else
        # For RPi 4: Standard configuration
        echo "dtoverlay=dwc2" >> "$MOUNT_DIR/boot/config.txt"
    fi
    echo "" >> "$MOUNT_DIR/boot/config.txt"

    # Add USB gadget modules to kernel command line
    if [[ -f "$MOUNT_DIR/boot/cmdline.txt" ]]; then
        sed -i 's/$/ modules-load=dwc2,g_serial/' "$MOUNT_DIR/boot/cmdline.txt"
    fi

    # Configure modules to load
    mkdir -p "$MOUNT_DIR/etc/modules-load.d"
    cat > "$MOUNT_DIR/etc/modules-load.d/usb-gadget.conf" <<'EOF'
# USB gadget modules for serial console over USB power cable
dwc2
g_serial
EOF

    # Create USB gadget setup script
    mkdir -p "$MOUNT_DIR/usr/local/bin"
    cat > "$MOUNT_DIR/usr/local/bin/setup-usb-serial-gadget.sh" <<'GADGET_SCRIPT'
#!/bin/bash
# USB Serial Gadget Configuration Script

GADGET_NAME="rpi_console"
GADGET_DIR="/sys/kernel/config/usb_gadget/$GADGET_NAME"

echo "Setting up USB Serial Gadget..."

# Mount configfs if not already mounted
if [ ! -d "/sys/kernel/config" ]; then
    mount -t configfs none /sys/kernel/config
fi

# Create gadget directory if it doesn't exist
if [ ! -d "$GADGET_DIR" ]; then
    mkdir -p "$GADGET_DIR"
    cd "$GADGET_DIR"

    # Set USB device identifiers
    echo 0x1d6b > idVendor    # Linux Foundation vendor ID
    echo 0x0104 > idProduct   # Multifunction composite gadget
    echo 0x0100 > bcdDevice   # Device version 1.0.0
    echo 0x0200 > bcdUSB      # USB 2.0

    # Set device description strings
    mkdir -p strings/0x409
    echo "Raspberry Pi Foundation" > strings/0x409/manufacturer
    echo "RPi Serial Console" > strings/0x409/product

    # Get Pi serial number
    SERIAL=$(cat /proc/cpuinfo | grep Serial | cut -d ' ' -f 2 2>/dev/null || echo "unknown")
    echo "$SERIAL" > strings/0x409/serialnumber

    # Create configuration
    mkdir -p configs/c.1/strings/0x409
    echo "Serial Console Config" > configs/c.1/strings/0x409/configuration
    echo 250 > configs/c.1/MaxPower

    # Create ACM serial function
    mkdir -p functions/acm.usb0

    # Link function to configuration
    ln -s functions/acm.usb0 configs/c.1/

    # Enable USB Device Controller
    UDC_DEVICE=$(ls /sys/class/udc | head -n1)
    if [ -n "$UDC_DEVICE" ]; then
        echo "$UDC_DEVICE" > UDC
        echo "✅ USB Serial Gadget enabled on controller: $UDC_DEVICE"
    else
        echo "❌ ERROR: No USB Device Controller found"
        exit 1
    fi
else
    echo "ℹ️  USB Serial Gadget already configured"
fi

echo "USB Serial Gadget setup completed!"
GADGET_SCRIPT

    chmod +x "$MOUNT_DIR/usr/local/bin/setup-usb-serial-gadget.sh"

    # Create systemd service
    cat > "$MOUNT_DIR/etc/systemd/system/usb-serial-gadget.service" <<'EOF'
[Unit]
Description=USB Serial Gadget Setup
Documentation=https://www.kernel.org/doc/html/latest/usb/gadget_configfs.html
After=local-fs.target
Before=getty.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-usb-serial-gadget.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Enable services
    arch-chroot "$MOUNT_DIR" systemctl enable usb-serial-gadget.service
    arch-chroot "$MOUNT_DIR" systemctl enable serial-getty@ttyGS0.service

    # Create helper info script
    cat > "$MOUNT_DIR/usr/local/bin/usb-console-info" <<'INFO_SCRIPT'
#!/bin/bash
echo "========================================"
echo "  USB SERIAL CONSOLE INFORMATION"
echo "========================================"
echo ""
echo "SETUP:"
echo "1. Connect USB-C power cable from Pi to your computer"
echo "2. Pi will appear as a USB serial device"
echo "3. Use terminal software to connect"
echo ""
echo "CONNECTION SETTINGS:"
echo "  • Baudrate: 115200"
echo "  • Data bits: 8"
echo "  • Parity: None"
echo "  • Stop bits: 1"
echo ""
echo "DEVICE NAMES:"
echo "  • On Pi: /dev/ttyGS0"
echo "  • On Linux/macOS: /dev/ttyACM0 (or /dev/ttyACM1)"
echo "  • On Windows: COMx (check Device Manager)"
echo ""
echo "CONNECTION EXAMPLES:"
echo "  Linux/macOS:"
echo "    screen /dev/ttyACM0 115200"
echo "    minicom -D /dev/ttyACM0 -b 115200"
echo "    picocom -b 115200 /dev/ttyACM0"
echo ""
echo "  Windows:"
echo "    PuTTY: Serial connection, COMx, 115200 baud"
echo ""
echo "SERVICE STATUS:"

if systemctl is-active --quiet usb-serial-gadget.service; then
    echo "  ✅ USB Gadget Service: Active"
else
    echo "  ❌ USB Gadget Service: Inactive"
fi

if systemctl is-active --quiet serial-getty@ttyGS0.service; then
    echo "  ✅ Serial Console Service: Active"
else
    echo "  ❌ Serial Console Service: Inactive"
fi

if [ -e /dev/ttyGS0 ]; then
    echo "  ✅ USB Serial Device: /dev/ttyGS0 available"
else
    echo "  ❌ USB Serial Device: /dev/ttyGS0 not found"
fi
echo ""
INFO_SCRIPT

    chmod +x "$MOUNT_DIR/usr/local/bin/usb-console-info"

    # Add bash alias
    echo "" >> "$MOUNT_DIR/etc/bash.bashrc"
    echo "# USB Serial Console alias" >> "$MOUNT_DIR/etc/bash.bashrc"
    echo "alias usb-info='usb-console-info'" >> "$MOUNT_DIR/etc/bash.bashrc"

    log_success "USB serial gadget configured"
}

update_system() {
    log_info "Updating system..."

    arch-chroot "$MOUNT_DIR" /usr/bin/pacman -Syu --noconfirm

    log_success "System updated"
}

compress_image() {
    log_info "Compressing image with zstd..."

    zstd -T0 -19 -f "$OUTPUT_DIR/$IMAGE_NAME" -o "$OUTPUT_DIR/$IMAGE_NAME.zst" || \
        die "Failed to compress image"

    log_success "Image compressed: $OUTPUT_DIR/$IMAGE_NAME.zst"
}

################################################################################
# Argument Parsing
################################################################################

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --rpi-model)
                RPI_MODEL="$2"
                shift 2
                ;;
            --image-size)
                IMAGE_SIZE="$2"
                shift 2
                ;;
            --hostname)
                RPI_HOSTNAME="$2"
                shift 2
                ;;
            --output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --no-cleanup)
                NO_CLEANUP=true
                shift
                ;;
            --debug)
                DEBUG=true
                set -x
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                die "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done
}

show_help() {
    cat <<EOF
Arch Linux ARM Raspberry Pi Image Builder

Usage: sudo $0 [OPTIONS]

Options:
  --rpi-model MODEL      Raspberry Pi model (4 or 5) [default: $RPI_MODEL]
  --image-size SIZE      Image size (e.g., 4G, 8G) [default: $IMAGE_SIZE]
  --hostname NAME        System hostname [default: auto-generated]
  --output DIR           Output directory [default: $OUTPUT_DIR]
  --no-cleanup           Don't cleanup on exit (for debugging)
  --debug                Enable debug mode (set -x)
  --help, -h             Show this help message

Environment Variables (override defaults):
  RPI_MODEL              Raspberry Pi model
  IMAGE_SIZE             Image size
  OS_TIMEZONE            System timezone
  SSH_PUB_KEY_URLS       Space-separated URLs to fetch SSH public keys
  WIFI_SSID              WiFi SSID (optional)
  WIFI_PASSWORD          WiFi password (optional)
  ZT_NETWORK_ID          ZeroTier network ID (optional)

Examples:
  sudo $0 --rpi-model 5
  sudo $0 --rpi-model 4 --image-size 8G --hostname my-rpi
  sudo RPI_MODEL=5 WIFI_SSID=MyWiFi WIFI_PASSWORD=secret $0

EOF
}

################################################################################
# Main Function
################################################################################

main() {
    parse_arguments "$@"

    log_info "=========================================="
    log_info "Arch Linux ARM Raspberry Pi Image Builder"
    log_info "=========================================="

    # Validate RPI_MODEL early to catch the bug from old workflow
    if [[ -z "$RPI_MODEL" ]]; then
        die "RPI_MODEL is not set! Must be 4 or 5. Use: --rpi-model 5"
    fi

    if [[ "$RPI_MODEL" != "4" && "$RPI_MODEL" != "5" ]]; then
        die "Invalid RPI_MODEL: '$RPI_MODEL'. Must be 4 or 5."
    fi

    log_info "Configuration:"
    log_info "  RPi Model: $RPI_MODEL"
    log_info "  Image Size: $IMAGE_SIZE"
    log_info "  Hostname: $RPI_HOSTNAME"
    log_info "  Output: $OUTPUT_DIR/$IMAGE_NAME"
    log_info "  Workdir: $WORKDIR"
    log_info "=========================================="

    check_root
    check_dependencies

    # Build process
    setup_dependencies
    download_arch_arm
    verify_checksum
    create_image_file
    setup_loop_device
    format_partitions
    mount_partitions
    extract_base_system
    setup_qemu
    clean_uboot
    init_pacman
    remove_old_packages
    install_kernel
    install_packages
    configure_locales
    configure_timezone
    configure_hostname
    configure_root_password
    configure_networking
    configure_wifi
    configure_ssh
    configure_fstab
    configure_zerotier
    configure_usb_gadget
    update_system

    log_info "Unmounting filesystems..."
    sync
    umount -R "$MOUNT_DIR/boot" || log_warn "Failed to unmount boot"
    umount -R "$MOUNT_DIR" || log_warn "Failed to unmount root"

    log_info "Releasing loop device..."
    losetup -d "$LOOP_DEVICE" || log_warn "Failed to release loop device"
    LOOP_DEVICE=""  # Clear so cleanup doesn't try again

    compress_image

    log_success "=========================================="
    log_success "Build completed successfully!"
    log_success "=========================================="
    log_success "Image: $OUTPUT_DIR/$IMAGE_NAME.zst"
    log_success "Root password: $ROOT_PASSWORD"
    log_success "Password saved to: $OUTPUT_DIR/root_password.txt"
    log_success "=========================================="
}

main "$@"
