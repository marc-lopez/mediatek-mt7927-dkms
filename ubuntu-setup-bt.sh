#!/bin/bash
set -e

# Define variables
PKG_NAME="mediatek-bt-only"
PKG_VER="4.3"
DKMS_DIR="/usr/src/${PKG_NAME}-${PKG_VER}"
KVER_BASE=$(uname -r | cut -d'-' -f1)
KVER_MINOR=$(echo $KVER_BASE | cut -d'.' -f1,2)
BASE_URL="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/bluetooth"

echo "=========================================================="
echo "Starting MT7927 Bluetooth Final Integrated Setup (v4.3)"
echo "Target Kernel: $(uname -r)"
echo "=========================================================="

# 1. FIRMWARE PLACEMENT
echo "[1/6] Setting up Bluetooth Firmware..."
sudo mkdir -p /lib/firmware/mediatek/mt7925 /lib/firmware/mediatek/mt7927
BT_FILE=$(find ./firmware/bluetooth -name "BT_RAM_CODE_MT6639_2_1_hdr.bin" | head -n 1)

if [ -n "$BT_FILE" ]; then
    sudo cp "$BT_FILE" /lib/firmware/mediatek/
    for dir in "" "mt7925/" "mt7927/"; do
        for prefix in "MT7927" "MT7925" "MT6639"; do
            target="/lib/firmware/mediatek/${dir}BT_RAM_CODE_${prefix}_1_1_hdr.bin"
            sudo ln -sf /lib/firmware/mediatek/BT_RAM_CODE_MT6639_2_1_hdr.bin "$target"
        done
    done
    echo "  - Firmware placed."
else
    echo "!!! ERROR: BT_RAM_CODE_MT6639_2_1_hdr.bin not found."
    exit 1
fi

# 2. DKMS CLEANUP
echo "[2/6] Cleaning DKMS tree..."
sudo dkms remove -m ${PKG_NAME} --all 2>/dev/null || true
sudo rm -rf /usr/src/${PKG_NAME}-*
sudo mkdir -p "${DKMS_DIR}/drivers/bluetooth"

# 3. ROBUST DOWNLOADER
echo "[3/6] Downloading Sources..."
dl_file() {
  local filename=$1
  for ref in "v${KVER_BASE}" "linux-${KVER_MINOR}.y" "v${KVER_MINOR}" "master"; do
    if sudo curl -s -f -o "${DKMS_DIR}/drivers/bluetooth/${filename}" "${BASE_URL}/${filename}?h=${ref}"; then
      echo "  - Downloaded $filename (from $ref)"
      return 0
    fi
  done
  echo "!!! ERROR: Failed to download $filename"
  return 1
}

for f in "btusb.c" "btmtk.c" "btmtk.h" "btintel.h" "btbcm.h" "btrtl.h"; do 
    dl_file "$f" || exit 1
done

# 4. PATCHING & ID INJECTION
echo "[4/6] Applying Patches & ROG ID Injection..."
sudo cp mt6639-bt-6.19.patch "${DKMS_DIR}/"
cd "${DKMS_DIR}"

# Apply the main 6.19 patch
sudo patch -p1 < mt6639-bt-6.19.patch

TARGET_USB="drivers/bluetooth/btusb.c"
TARGET_MTK="drivers/bluetooth/btmtk.c"

# Inject ROG ID (0489:e13a) into the mediatek_table
sudo sed -i '/static const struct usb_device_id mediatek_table\[\] = {/a \	{ USB_DEVICE(0x0489, 0xe13a), .driver_info = BTUSB_MEDIATEK | BTUSB_WIDEBAND_SPEECH | BTUSB_VALID_LE_STATES },' "$TARGET_USB"

# Fix the discovery state check
sudo sed -i 's/hci_discovery_active(hdev)/ (hdev->discovery.state != 0) /g' "$TARGET_USB"

# Fix memory allocation syntax
sudo sed -i 's/kmalloc_obj(\*\(.*\))/kmalloc(sizeof(*\1), GFP_KERNEL)/g' "$TARGET_MTK" "$TARGET_USB"
sudo sed -i 's/kzalloc_obj(\*\(.*\))/kzalloc(sizeof(*\1), GFP_KERNEL)/g' "$TARGET_USB"

# 5. BUILD FILES
echo "[5/6] Generating Build Configs..."
sudo tee "Kbuild" > /dev/null <<'EOF'
obj-m += drivers/bluetooth/
EOF
sudo tee "drivers/bluetooth/Kbuild" > /dev/null <<'EOF'
obj-m += btusb.o btmtk.o
ccflags-y := -I$(src)
EOF
sudo tee "dkms.conf" > /dev/null <<EOF
PACKAGE_NAME="${PKG_NAME}"
PACKAGE_VERSION="${PKG_VER}"
BUILT_MODULE_NAME[0]="btusb"; BUILT_MODULE_LOCATION[0]="drivers/bluetooth/"; DEST_MODULE_LOCATION[0]="/updates/dkms/"
BUILT_MODULE_NAME[1]="btmtk"; BUILT_MODULE_LOCATION[1]="drivers/bluetooth/"; DEST_MODULE_LOCATION[1]="/updates/dkms/"
AUTOINSTALL="yes"
EOF

# 6. INSTALL
echo "[6/6] Compiling and Installing Driver..."
sudo dkms add -m ${PKG_NAME} -v ${PKG_VER}
sudo dkms build -m ${PKG_NAME} -v ${PKG_VER}
sudo dkms install -m ${PKG_NAME} -v ${PKG_VER} --force
sudo update-initramfs -u

echo "=========================================================="
echo "Verification: Checking Binary for ROG ID..."
BTUSB_MOD="/lib/modules/$(uname -r)/updates/dkms/btusb.ko.zst"
if strings "$BTUSB_MOD" | grep -i "e13a"; then
    echo "SUCCESS: ROG ID (e13a) is baked into the driver."
    sudo systemctl stop bluetooth || true
    sudo modprobe -r btusb btmtk || true
    sudo modprobe btusb
    echo "0489 e13a" | sudo tee /sys/bus/usb/drivers/btusb/new_id 2>/dev/null || true
    sudo systemctl start bluetooth || true
    bluetoothctl show
else
    echo "FAILURE: ID injection failed."
    grep -n "0xe13a" "$TARGET_USB" || echo "ID not found in source!"
fi
echo "=========================================================="
