#!/bin/bash
set -euo pipefail

BINARIES_DIR="$1"
FW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$FW_ROOT/.." && pwd)"

UBOOT_BIN="${BINARIES_DIR}/u-boot-with-spl.bin"
KERNEL_BIN="${BINARIES_DIR}/uImage"
ROOTFS_BIN="${BINARIES_DIR}/rootfs.squashfs"

# Locate U-Boot binary if not in images dir
if [ ! -f "$UBOOT_BIN" ]; then
    LUMI_UBOOT="${REPO_ROOT}/lumi-u-boot-t33/output/u-boot-with-spl.bin"
    if [ -f "$LUMI_UBOOT" ]; then
        cp -v "$LUMI_UBOOT" "$UBOOT_BIN"
    elif [ -x "${REPO_ROOT}/lumi-u-boot-t33/build.sh" ]; then
        echo "Building U-Boot from lumi-u-boot-t33..."
        (cd "${REPO_ROOT}/lumi-u-boot-t33" && ./build.sh PRJ008_n_sfcnor_config)
        cp -v "$LUMI_UBOOT" "$UBOOT_BIN"
    fi
fi

if [ ! -f "$UBOOT_BIN" ] || [ ! -f "$KERNEL_BIN" ] || [ ! -f "$ROOTFS_BIN" ]; then
    echo "Warning: post-image-t33: missing one or more required images (u-boot, kernel, rootfs). Skipping NOR image packing." >&2
    exit 0
fi

OUTPUT_IMAGE="${BINARIES_DIR}/openipc-t33-prj008n-nor-16m.bin"
rm -f "$OUTPUT_IMAGE"

echo "Packing 16MB SPI-NOR image for Ingenic T33..."
python3 "${FW_ROOT}/contrib/pack-t33gs-nor16.py" \
    --uboot "$UBOOT_BIN" \
    --kernel "$KERNEL_BIN" \
    --rootfs "$ROOTFS_BIN" \
    --output "$OUTPUT_IMAGE"

echo "T33 NOR 16MB image generated successfully: $OUTPUT_IMAGE"
ls -lh "$OUTPUT_IMAGE"
