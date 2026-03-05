#!/bin/bash
set -e

echo "=========================================================="
echo "Starting MT7927 Setup (Local Repo + GitHub Compliant)"
echo "Target Kernel: $(uname -r)"
echo "=========================================================="

# Ensure we are in the right directory
if [ ! -f "dkms.conf" ]; then
    echo "!!! ERROR: Run this from inside your mediatek-mt7927-dkms directory."
    exit 1
fi

# 1. FIRMWARE PLACEMENT
echo "[1/3] Setting up Firmware..."
sudo mkdir -p /lib/firmware/mediatek/mt6639 /lib/firmware/mediatek/mt7927

# BT Firmware
BT_FILE=$(find ./firmware/bluetooth -name "BT_RAM_CODE_MT6639_2_1_hdr.bin" | head -n 1)
if [ -n "$BT_FILE" ]; then
    sudo cp "$BT_FILE" /lib/firmware/mediatek/mt6639/
    sudo cp "$BT_FILE" /lib/firmware/mediatek/
    echo "  - Bluetooth Firmware placed in mt6639/."
else
    echo "  !!! Warning: BT firmware not found in ./firmware/bluetooth/"
fi

# WiFi Firmware
W_PATCH=$(find ./firmware/wifi -name "WIFI_MT6639_PATCH_MCU_2_1_hdr.bin" | head -n 1)
W_RAM=$(find ./firmware/wifi -name "WIFI_RAM_CODE_MT6639_2_1.bin" | head -n 1)
if [ -n "$W_PATCH" ] && [ -n "$W_RAM" ]; then
    sudo cp "$W_PATCH" /lib/firmware/mediatek/mt7927/WIFI_MT7927_PATCH_MCU_2_1_hdr.bin
    sudo cp "$W_RAM" /lib/firmware/mediatek/mt7927/WIFI_RAM_CODE_MT7927_2_1.bin
    sudo cp "$W_PATCH" /lib/firmware/mediatek/mt6639/
    sudo cp "$W_RAM" /lib/firmware/mediatek/mt6639/
    echo "  - WiFi Firmware placed in mt7927/ and mt6639/."
else
    echo "  !!! Warning: WiFi firmware not found in ./firmware/wifi/"
fi

# 2. SCORCHED EARTH DKMS CLEANUP
echo "[2/3] Cleaning ALL legacy DKMS modules..."
for mod in "mediatek-bt-only" "mediatek-mt7927-wifi" "mediatek-mt7927"; do
    sudo dkms remove -m $mod --all 2>/dev/null || true
    sudo rm -rf /usr/src/${mod}-*
done
echo "  - DKMS tree is clean."

# 3. BUILD & INSTALL
echo "[3/3] Installing DKMS Package from local source..."
DKMS_MOD_NAME=$(grep ^PACKAGE_NAME dkms.conf | cut -d'"' -f2)
DKMS_MOD_VER=$(grep ^PACKAGE_VERSION dkms.conf | cut -d'"' -f2)

sudo mkdir -p "/usr/src/${DKMS_MOD_NAME}-${DKMS_MOD_VER}"
sudo cp -r ./* "/usr/src/${DKMS_MOD_NAME}-${DKMS_MOD_VER}/"
sudo dkms add -m "$DKMS_MOD_NAME" -v "$DKMS_MOD_VER"
sudo dkms build -m "$DKMS_MOD_NAME" -v "$DKMS_MOD_VER" -k $(uname -r)
sudo dkms install -m "$DKMS_MOD_NAME" -v "$DKMS_MOD_VER" -k $(uname -r) --force
sudo update-initramfs -u

echo "=========================================================="
echo "Installation Complete! Reloading and Unblocking..."
sudo systemctl stop bluetooth || true
sudo modprobe -r mt7925e mt7921e mt76_connac_lib mt76 btusb btmtk 2>/dev/null || true

# Clear any soft blocks (rfkill)
sudo rfkill unblock bluetooth
sudo rfkill unblock wlan

sudo modprobe mt7925e
sudo modprobe btusb
sudo systemctl start bluetooth || true
echo "=========================================================="
