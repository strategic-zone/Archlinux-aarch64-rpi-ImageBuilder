# Arch Linux ARM Raspberry Pi Image Builder

Automated builder for custom Arch Linux ARM images for Raspberry Pi 4 and 5, with pre-configured networking, SSH access, and USB serial console support.

## Features

- **Automated GitHub Actions CI/CD** - Build images automatically on push or manually via workflow dispatch
- **Raspberry Pi 4 & 5 Support** - Choose your target model during build
- **USB Serial Console** - Access your Pi via USB power cable (no keyboard/monitor needed)
- **Pre-configured Networking** - Systemd-networkd with optional WiFi support
- **SSH Access** - Automated SSH key deployment from GitHub
- **ZeroTier Support** - Built-in mesh networking capability
- **Custom Package Set** - Pre-installed tools including Tailscale, ZeroTier, and development utilities

## Quick Start

### Building Images

#### Option 1: GitHub Actions (Recommended)

1. Fork or clone this repository
2. Go to **Actions** → **Build Archlinux aarch64 Raspberry Pi Image**
3. Click **Run workflow**
4. Select Raspberry Pi model (4 or 5)
5. Optionally enable S3 upload
6. Download the compressed `.img.zst` file from workflow artifacts

#### Option 2: Local Build with Act

Build locally using [act](https://github.com/nektos/act) to test GitHub Actions workflows:

```bash
# Install act (macOS)
brew install act

# Run the build workflow
./run-act.sh
```

**Note**: Local builds require a VM (not LXC containers) and privileged access for loop device manipulation.

### Writing Image to SD Card or USB

#### macOS

```bash
# Extract the compressed image
cd /tmp
unzstd archlinux-rpi-aarch64-*.img.zst

# Identify your SD card/USB device
diskutil list

# Unmount the device (replace disk4 with your device)
sudo diskutil unmountDisk /dev/disk4

# Write the image (use rdisk for faster writes)
sudo dd if=/tmp/archlinux-rpi-aarch64-*.img of=/dev/rdisk4 bs=4m status=progress

# Eject when complete
sudo diskutil eject /dev/disk4
```

#### Linux

```bash
# Extract the compressed image
unzstd archlinux-rpi-aarch64-*.img.zst

# Identify your device
lsblk

# Write the image (replace sdX with your device)
sudo dd if=archlinux-rpi-aarch64-*.img of=/dev/sdX bs=4M status=progress conv=fsync

# Sync and eject
sync
sudo eject /dev/sdX
```

## USB Serial Console Access

This image comes pre-configured with USB serial gadget mode, allowing console access via the USB-C power cable.

### Connection Setup

1. **Connect**: Plug USB-C cable from Raspberry Pi to your computer
2. **Identify Device**:
   - **Linux/macOS**: `/dev/ttyACM0` (or `/dev/ttyACM1`)
   - **Windows**: `COMx` (check Device Manager)

3. **Connect with Terminal Software**:

   **Linux/macOS**:
   ```bash
   # Using screen
   screen /dev/ttyACM0 115200

   # Using minicom
   minicom -D /dev/ttyACM0 -b 115200

   # Using picocom
   picocom -b 115200 /dev/ttyACM0
   ```

   **Windows**:
   - Use [PuTTY](https://www.putty.org/): Serial connection, COMx, 115200 baud
   - Or [Tera Term](https://ttssh2.osdn.jp/): Serial port, COMx, 115200 baud

### Connection Settings
- **Baud rate**: 115200
- **Data bits**: 8
- **Parity**: None
- **Stop bits**: 1
- **Flow control**: None

### On the Raspberry Pi

Run `usb-console-info` or `usb-info` on the Pi for detailed connection information and status.

## Default Configuration

### System Settings
- **Hostname**: `sz-<commit>-rpi<model>` (e.g., `sz-f471ba3-rpi5`)
- **Default User**: `root`
- **Root Password**: Generated randomly during build (saved in workflow artifacts)
- **Locale**: `en_US.UTF-8`
- **Keymap**: `us-acentos`
- **Timezone**: UTC (default, can be changed)

### Network Configuration
- **Wired**: DHCP enabled on all Ethernet interfaces
- **WiFi**: Optional (configure via environment variables)
- **SSH Port**: `34522` (not standard 22)
- **SSH**: Root login with key authentication only

### Pre-installed Packages
- Base system + development tools
- **Networking**: iwd, wireless-regdb, Tailscale, ZeroTier
- **Utilities**: git, neovim, rsync, sudo, zsh, qrencode
- **Firmware**: linux-firmware, raspberrypi-bootloader, firmware-raspberrypi
- **Raspberry Pi Specific**:
  - RPi 5: `linux-rpi-16k`, `rpi5-eeprom`
  - RPi 4: `linux-rpi`, `rpi4-eeprom`

## Customization

### Environment Variables

Edit `.github/workflows/rpi_aarch64_image_builder.yml` to customize:

```yaml
env:
  LOOP_IMAGE_SIZE: 4G              # Image size (increase for more space)
  OS_PACKAGES: >                   # Add/remove packages
    base base-devel git neovim ...
  OS_DEFAULT_LOCALE: en_US.UTF-8   # System locale
  OS_KEYMAP: us-acentos            # Console keymap
  OS_TIMEZONE: UTC                 # System timezone
  SSH_PUB_KEY_URL: https://github.com/username.keys  # SSH public keys
```

### Adding WiFi Credentials

Set repository secrets:
- `WIFI_SSID`: Your WiFi network name
- `WIFI_PASSWORD`: Your WiFi password

### ZeroTier Network

Set repository secret:
- `ZT_NETWORK_ID`: Your ZeroTier network ID

## Partition Layout

- **Boot Partition** (512MB, FAT32): Bootloader, kernel, device tree blobs
- **Root Partition** (remaining space, ext4): System files

## Troubleshooting

### USB Serial Console Not Working

1. Check if services are running on Pi:
   ```bash
   systemctl status usb-serial-gadget.service
   systemctl status serial-getty@ttyGS0.service
   ```

2. Check device on Pi:
   ```bash
   ls -la /dev/ttyGS0
   ```

3. View logs:
   ```bash
   journalctl -u usb-serial-gadget.service
   ```

4. Restart service:
   ```bash
   systemctl restart usb-serial-gadget.service
   ```

### SSH Connection Issues

1. Check SSH service:
   ```bash
   systemctl status sshd
   ```

2. Remember custom port:
   ```bash
   ssh -p 34522 root@<pi-ip-address>
   ```

### WiFi Not Connecting

1. Check iwd service:
   ```bash
   systemctl status iwd
   ```

2. Manually configure WiFi:
   ```bash
   iwctl
   station wlan0 scan
   station wlan0 get-networks
   station wlan0 connect <SSID>
   ```

## Build Process Overview

The automated build process:

1. Downloads latest Arch Linux ARM base image
2. Creates 4GB disk image with 512MB boot + ext4 root partitions
3. Extracts base system to partitions
4. Configures QEMU for ARM64 emulation
5. Installs Raspberry Pi specific kernel and firmware
6. Installs custom package set
7. Configures system settings (locale, timezone, hostname)
8. Sets up networking and SSH
9. Configures USB serial gadget
10. Compresses final image with zstd

## Requirements

### For GitHub Actions Build
- GitHub account with Actions enabled
- Optional: S3-compatible storage credentials for artifact uploads

### For Local Build with Act
- Docker or Podman
- Act installed
- VM environment (not LXC)
- Privileged access for loop device operations

## License

This project is open source. The generated images contain Arch Linux ARM, which is governed by its own licenses.

## Credits

- [Arch Linux ARM](https://archlinuxarm.org/) - Base distribution
- Raspberry Pi Foundation - Hardware support
- Community contributors

## References

- [Arch Linux ARM Installation Guide](https://archlinuxarm.org/platforms/armv8/broadcom/raspberry-pi-4)
- [USB Gadget ConfigFS Documentation](https://www.kernel.org/doc/html/latest/usb/gadget_configfs.html)
- [Raspberry Pi 5 on Arch Linux ARM](https://kiljan.org/2023/11/24/arch-linux-arm-on-a-raspberry-pi-5-model-b/)
