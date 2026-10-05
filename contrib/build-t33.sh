#!/usr/bin/env bash
set -euo pipefail

FW_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_ROOT=$(cd "$FW_ROOT/.." && pwd)
: "${T33_SDK_ROOT:?Set T33_SDK_ROOT to the directory containing the Ingenic T32/T33 SDK}"

OUTPUT=${T33_OUTPUT_DIR:-$FW_ROOT/output/t33-openipc}
DL_DIR=${BR2_DL_DIR:-$FW_ROOT/output/t23-nor8/dl}
# The T33gs has 128 MiB DRAM. The one-sensor RTSP pipeline boots and streams
# with 32 MiB reserved at the top for TX-ISP; expose the lower 96 MiB to Linux.
# Do not reduce rmem further without measuring the ISP allocation high-water.
T33_MEM_ARGS=${T33_MEM_ARGS:-'mem=96M@0x0 rmem=32M@0x6000000'}
SDK_WORK="$OUTPUT/t33-sdk"
KERNEL_SOURCE="$SDK_WORK/kernel-3.10.14"
TOOLCHAIN_ROOT="$SDK_WORK/toolchain/mips-gcc540-uclibc0.9.33.2-r3.3.7.mxu2.cve2"
PATCH_DIR="$FW_ROOT/lumi/board/t33gs-prj008/patches/linux"
PATCH_FILE="$PATCH_DIR/0001-prj008-report-mxuv2-on-t33.patch"
MSC0_PATCH_FILE="$PATCH_DIR/0002-prj008-enable-msc0-pb-pinmux.patch"
MMC_PWR_PATCH_FILE="$PATCH_DIR/0003-prj008-goat-enable-mmc-power-pb27.patch"
UBOOT_SOURCE="$SDK_WORK/uboot/uboot"
UBOOT_HOST_PATCH="$REPO_ROOT/lumi-ipc-firmware/lumi/board/t33gs-prj008/uboot-host-tools.patch"

LUMI_UBOOT_REPO="$REPO_ROOT/lumi-u-boot-t33"
KERNEL_ARCHIVE=$(find "$T33_SDK_ROOT" -type f -path '*/opensource/kernel-3.10.14.7z' -print -quit)
TOOLCHAIN_ARCHIVE=$(find "$T33_SDK_ROOT" -type f -path '*/software/pc/toolchain/mips-gcc540-uclibc0.9.33.2-r3.3.7.mxu2.cve2.tar.bz2' -print -quit)
UBOOT_ARCHIVE=$(find "$T33_SDK_ROOT" -type f -path '*/opensource/uboot.7z' -print -quit)
DRIVER_ARCHIVE=$(find "$T33_SDK_ROOT" -type f -path '*/opensource/drivers.7z' -print -quit)
IMP_DIR=$(find "$T33_SDK_ROOT" -type f -path '*/media/en/lib/uclibc/libimp.so' -printf '%h\n' -quit)
UCLIBC_RUNTIME=$(find "$T33_SDK_ROOT" -type f -path '*/resource/rootfs/zeratul/5.4.0/uclibc/rootfs_camera/lib/ld-uClibc.so.0' -printf '%h\n' -quit)
if [[ -z "$KERNEL_ARCHIVE" || -z "$TOOLCHAIN_ARCHIVE" || -z "$DRIVER_ARCHIVE" || -z "$IMP_DIR" || -z "$UCLIBC_RUNTIME" ]]; then
	echo "T33 SDK is missing its kernel, toolchain, drivers, libimp, or uClibc runtime" >&2
	exit 1
fi
if [[ ! -d "$LUMI_UBOOT_REPO" && -z "$UBOOT_ARCHIVE" ]]; then
	echo "T33 U-Boot repository not found and SDK opensource/uboot.7z is missing" >&2
	exit 1
fi
command -v 7z >/dev/null || { echo "Install 7zip to extract the vendor kernel archive" >&2; exit 1; }
command -v lzop >/dev/null || { echo "Install lzop; the vendor kernel's uImage target builds its LZO variant too" >&2; exit 1; }

mkdir -p "$SDK_WORK/kernel-extract" "$SDK_WORK/toolchain"
if [[ ! -d "$KERNEL_SOURCE" ]]; then
	# Some SDK releases contain three unsupported relative symlinks; 7-Zip
	# reports exit status 2 after extracting the source files we need.
	7z x -y "-o$SDK_WORK/kernel-extract" "$KERNEL_ARCHIVE" >/dev/null || true
	[[ -f "$SDK_WORK/kernel-extract/kernel-3.10.14/Makefile" ]] || {
		echo "Kernel archive did not extract completely" >&2
		exit 1
	}
	mv "$SDK_WORK/kernel-extract/kernel-3.10.14" "$KERNEL_SOURCE"
fi

if [[ ! -x "$TOOLCHAIN_ROOT/bin/mips-linux-uclibc-gcc" ]]; then
	tar -xjf "$TOOLCHAIN_ARCHIVE" -C "$SDK_WORK/toolchain"
fi

if [[ ! -d "$LUMI_UBOOT_REPO" && ! -f "$UBOOT_SOURCE/Makefile" ]]; then
	mkdir -p "$SDK_WORK/uboot"
	7z x -y "-o$SDK_WORK/uboot" "$UBOOT_ARCHIVE" >/dev/null
	[[ -f "$UBOOT_SOURCE/Makefile" ]] || {
		echo "U-Boot archive did not extract completely" >&2
		exit 1
	}
fi

# Build only the ISP and SC4336 driver sources from the local SDK archive.
# No prebuilt OEM kernel modules are copied into the image. The SDK contains
# the SC4336 source under PRJ007 only; the board firmware proves that this
# sensor is paired with PRJ008, so stage it under PRJ008 for an explicitly
# experimental compile. Validate on hardware before treating it as supported.
DRIVER_SOURCE="$SDK_WORK/driver-source"
if [[ ! -f "$DRIVER_SOURCE/drivers/isp/tx-isp/Makefile" ]]; then
	mkdir -p "$DRIVER_SOURCE"
	7z x -y "-o$DRIVER_SOURCE" "$DRIVER_ARCHIVE" >/dev/null || true
	[[ -f "$DRIVER_SOURCE/drivers/isp/tx-isp/Makefile" && \
	   -f "$DRIVER_SOURCE/drivers/sensors/sc4336/PRJ007/sc4336.c" ]] || {
		echo "Could not extract TX-ISP and SC4336 sources from the SDK" >&2
		exit 1
	}
	mkdir -p "$DRIVER_SOURCE/drivers/sensors/sc4336/PRJ008"
	cp "$DRIVER_SOURCE/drivers/sensors/sc4336/PRJ007/sc4336.c" \
		"$DRIVER_SOURCE/drivers/sensors/sc4336/PRJ008/sc4336.c"
fi
if [[ ! -f "$DRIVER_SOURCE/drivers/isp/tx-isp/libPRJ008-firmware-310-540.a" ]]; then
	# The driver archive is a large solid 7z. Extract the binary ISP firmware
	# members explicitly because the initial bulk pass can skip these entries
	# after reporting unsafe SDK symlinks.
	7z x -y "-o$DRIVER_SOURCE" "$DRIVER_ARCHIVE" \
		'drivers/isp/tx-isp/libPRJ008-firmware*' >/dev/null
fi
cp "$DRIVER_SOURCE/drivers/isp/tx-isp/libPRJ008-firmware-310-540.a" \
	"$SDK_WORK/libPRJ008-firmware-310-540.a"

# Keep vendor userspace libraries isolated from the OpenIPC musl rootfs. They
# can be loaded by SDK-uClibc-linked local test programs via their own loader.
mkdir -p "$SDK_WORK/vendor-media/lib"
cp -a "$IMP_DIR"/*.so "$SDK_WORK/vendor-media/lib/"
cp -a "$UCLIBC_RUNTIME"/*.so* "$SDK_WORK/vendor-media/lib/"
SDK_MEDIA_DIR=$(dirname "$(dirname "$IMP_DIR")")
mkdir -p "$SDK_WORK/vendor-media/include"
cp -a "$SDK_MEDIA_DIR/include/." "$SDK_WORK/vendor-media/include/"
mkdir -p "$SDK_WORK/vendor-media/sdk-lib"
cp -a "$IMP_DIR"/*.so "$SDK_WORK/vendor-media/sdk-lib/"

# The upstream AIC8800 source supports D80 USB, but the public firmware blobs
# are from a different D80 U02 build than this camera's combo module. Extract
# the exact matching blobs locally from the original camera image; never add
# these proprietary files to the source tree.
ORIGINAL_CAMERA_FW="$REPO_ROOT/original-fw/T33_GSCAM01.bin"
AIC_FW_DIR="$SDK_WORK/aic-firmware"
if [[ -f "$ORIGINAL_CAMERA_FW" && ! -f "$AIC_FW_DIR/fw_patch_table_8800d80_u02.bin" ]]; then
	command -v unsquashfs >/dev/null || { echo "Install squashfs-tools to extract the camera's AIC firmware" >&2; exit 1; }
	mkdir -p "$AIC_FW_DIR"
	AIC_APPFS="$SDK_WORK/aic-appfs.squashfs"
	dd if="$ORIGINAL_CAMERA_FW" of="$AIC_APPFS" bs=4096 skip=$((0x358000 / 4096)) status=none
	unsquashfs -f -d "$SDK_WORK/aic-appfs" "$AIC_APPFS" >/dev/null
	CAMERA_FW_DIR="$SDK_WORK/aic-appfs/lib/firmware"
	for fw in fw_patch_table_8800d80_u02.bin fw_patch_8800d80_u02.bin \
		fw_patch_8800d80_u02_ext0.bin fw_adid_8800d80_u02.bin \
		fmacfw_8800d80_h_u02.bin; do
		[[ -f "$CAMERA_FW_DIR/$fw" ]] || { echo "Camera firmware is missing $fw" >&2; exit 1; }
		install -m 0644 "$CAMERA_FW_DIR/$fw" "$AIC_FW_DIR/$fw"
	done
	install -d "$AIC_FW_DIR/aic8800D80"
	install -m 0644 "$CAMERA_FW_DIR/aic8800D80/aic_userconfig_8800d80.txt" \
		"$AIC_FW_DIR/aic8800D80/"
fi

# The SC4336 ISP needs the matching PRJ008 day/night tuning bins. Keep these
# proprietary files in ignored SDK work output and install them into the image
# from the board post-build hook, not into the source tree.
SC4336_BIN_DIR="$SDK_WORK/sc4336-isp-bins"
if [[ ! -f "$SC4336_BIN_DIR/sc4336-PRJ008-day.bin" || \
	  ! -f "$SC4336_BIN_DIR/sc4336-PRJ008-night.bin" ]]; then
	[[ -f "$ORIGINAL_CAMERA_FW" ]] || {
		echo "Missing original camera firmware for SC4336 ISP tuning bins: $ORIGINAL_CAMERA_FW" >&2
		exit 1
	}
	command -v unsquashfs >/dev/null || { echo "Install squashfs-tools to extract SC4336 ISP tuning bins" >&2; exit 1; }
	CAMERA_APPFS="$SDK_WORK/camera-appfs.squashfs"
	CAMERA_APPFS_DIR="$SDK_WORK/camera-appfs"
	dd if="$ORIGINAL_CAMERA_FW" of="$CAMERA_APPFS" bs=4096 skip=$((0x358000 / 4096)) status=none
	unsquashfs -f -d "$CAMERA_APPFS_DIR" "$CAMERA_APPFS" >/dev/null
	mkdir -p "$SC4336_BIN_DIR"
	for mode in day night; do
		bin="sc4336-PRJ008-$mode.bin"
		[[ -f "$CAMERA_APPFS_DIR/etc/sensor/$bin" ]] || {
			echo "Original camera firmware is missing /etc/sensor/$bin" >&2
			exit 1
		}
		install -m 0644 "$CAMERA_APPFS_DIR/etc/sensor/$bin" "$SC4336_BIN_DIR/$bin"
	done
fi
[[ -f "$AIC_FW_DIR/fw_patch_table_8800d80_u02.bin" ]] || {
	echo "Missing AIC8800D80 firmware; expected $ORIGINAL_CAMERA_FW" >&2
	exit 1
}

# The bundled DDR host utility has a stale function-pointer declaration and
# missing prototypes; correct these declarations so it also builds on modern
# host compilers. This only changes the extracted SDK copy.
if ! grep -q 'void fill_ddr_addrmap' "$UBOOT_SOURCE/tools/ingenic-tools/ddr_creator_chip_v3/ddr_params_creator.h"; then
	patch --batch --forward -d "$UBOOT_SOURCE" -p1 < "$UBOOT_HOST_PATCH"
fi

# The archive also contains stale vendor .o files. Clean them before Buildroot
# rsyncs the source into its package build directory.
make -s -C "$KERNEL_SOURCE" ARCH=mips CROSS_COMPILE="$TOOLCHAIN_ROOT/bin/mips-linux-uclibc-" distclean
if ! grep -q 'static inline int soc_support_mxuv2' "$KERNEL_SOURCE/arch/mips/kernel/cpu-probe.c"; then
	patch --batch --forward -d "$KERNEL_SOURCE" -p1 < "$PATCH_FILE"
fi
if ! grep -q 'T33 SD/MMC0: PB0-PB5' "$KERNEL_SOURCE/arch/mips/xburst/soc-PRJ008/common/platform.c"; then
	patch --batch --forward -d "$KERNEL_SOURCE" -p1 < "$MSC0_PATCH_FILE"
fi
if ! grep -q 'GPIO_MMC_PWR[[:space:]]*GPIO_PB(27)' "$KERNEL_SOURCE/arch/mips/xburst/soc-PRJ008/chip-PRJ008/isvp/Goat/board.h"; then
	patch --batch --forward -d "$KERNEL_SOURCE" -p1 < "$MMC_PWR_PATCH_FILE"
fi
# Buildroot requests the vendor kernel's `all` target before the requested
# uImage. Its unused zboot target fails to link against this vendor toolchain;
# OpenIPC boots the explicit uImage.lzma target instead.
sed -i -E '/^bootz-y[[:space:]]*(:=|\+=)/d' \
	"$KERNEL_SOURCE/arch/mips/Makefile"
sed -i '/all-$(CONFIG_SYS_SUPPORTS_ZBOOT).*vmlinuz/d' \
	"$KERNEL_SOURCE/arch/mips/Makefile"
mkdir -p "$OUTPUT"
cat > "$OUTPUT/local.mk" <<EOF
LINUX_OVERRIDE_SRCDIR = $KERNEL_SOURCE
override LINUX_MAKE_FLAGS += CROSS_COMPILE=$TOOLCHAIN_ROOT/bin/mips-linux-uclibc-
EOF

(cd "$FW_ROOT" && make BOARD=lumi_t33gs_prj008_nor16 TARGET="$OUTPUT" BR2_DL_DIR="$DL_DIR" br-all)

BOOT_DIR="$OUTPUT/tftp/openipc-t33"
mkdir -p "$BOOT_DIR"
cp "$OUTPUT/images/uImage" "$BOOT_DIR/uImage"
gzip -9 -c "$OUTPUT/images/rootfs.cpio" > "$BOOT_DIR/rootfs.cpio.gz"
"$OUTPUT/host/bin/mkimage" -A mips -O linux -T ramdisk -C gzip \
	-a 0x82000000 -e 0x82000000 -n "OpenIPC T33 initramfs" \
	-d "$BOOT_DIR/rootfs.cpio.gz" "$BOOT_DIR/openipc-t33-initramfs.uImage"

cat > "$BOOT_DIR/boot-openipc-t33.txt" <<EOF
# Stop the stock U-Boot autoboot and connect Ethernet to the TFTP server.
# Replace the two addresses, then run these commands at the U-Boot prompt.
setenv ipaddr 192.168.1.100
setenv serverip 192.168.1.2
setenv bootargs 'console=ttyS1,115200n8 $T33_MEM_ARGS root=/dev/ram0 rw rdinit=/init mtdparts=sfc0_nor:256k(boot),1728k(kernel),1184k(root),256k(config),12960k(appfs),16384k@0(all)'
tftp 0x80600000 openipc-t33/uImage
tftp 0x83000000 openipc-t33/openipc-t33-initramfs.uImage
bootm 0x80600000 0x83000000
EOF

if [[ -d "$LUMI_UBOOT_REPO" ]]; then
	echo "Building T33 U-Boot from lumi-u-boot-t33 repository..."
	(cd "$LUMI_UBOOT_REPO" && CROSS_COMPILE="$TOOLCHAIN_ROOT/bin/mips-linux-uclibc-" ./build.sh PRJ008_n_sfcnor_config)
	UBOOT_BIN="$LUMI_UBOOT_REPO/output/u-boot-with-spl.bin"
else
	# Build Ingenic's T33N SPI-NOR SPL + U-Boot candidate. Its bootargs use an
	# adjusted 16 MiB layout with 4 MiB root for the local-only media runtime.
	# OpenIPC's flash-root init is /init and expects a writable rootfs_data MTD
	# partition for its overlay. The SDK camera defaults use /linuxrc and appfs.
	sed -i -e 's/init=\/linuxrc/init=\/init/g' \
		-e 's/-(appfs)/-(rootfs_data)/g' \
		-e 's/2560k(kernel),2048k(root)/2560k(kernel),4096k(root)/g' \
		-e 's/4096k(root),-(rootfs_data)/4096k(root),9440k(rootfs_data),32k(env)/g' \
		-e 's/4096k(root),64k(dtb),-(rootfs_data)/4096k(root),64k(dtb),9376k(rootfs_data),32k(env)/g' \
		"$UBOOT_SOURCE/include/configs/PRJ.h"
	# The SDK defaults put ENV immediately after the U-Boot image, inside an
	# erase block shared with boot code. Reserve the final NOR erase block instead.
	sed -i '/#elif CONFIG_ENV_IS_IN_SPI_FLASH/,/#endif \/\* endif CONFIG_ENV_IS_IN_MMC \*\// {
	 s/^#define CONFIG_ENV_SECT_SIZE.*/#define CONFIG_ENV_SECT_SIZE    (1024 * 32)/
	 s/^#define CONFIG_ENV_OFFSET.*/#define CONFIG_ENV_OFFSET       0xff8000/
	}' \
		"$UBOOT_SOURCE/include/configs/PRJ.h"
	UBOOT_CROSS_COMPILE="$TOOLCHAIN_ROOT/bin/mips-linux-uclibc-"
	make -s -C "$UBOOT_SOURCE" CROSS_COMPILE="$UBOOT_CROSS_COMPILE" distclean
	make -s -C "$UBOOT_SOURCE" CROSS_COMPILE="$UBOOT_CROSS_COMPILE" PRJ008_n_sfcnor_config
	make -s -C "$UBOOT_SOURCE" -j"$(nproc)" CROSS_COMPILE="$UBOOT_CROSS_COMPILE" u-boot-with-spl.bin
	UBOOT_BIN="$UBOOT_SOURCE/u-boot-with-spl.bin"
fi

NOR_IMAGE="$OUTPUT/images/openipc-t33-prj008n-nor-16m.bin"
KERNEL_BIN="$OUTPUT/images/uImage"
ROOTFS_BIN="$OUTPUT/images/rootfs.squashfs"
UBOOT_PART_SIZE=$((256 * 1024))
KERNEL_PART_SIZE=$((2560 * 1024))
ROOTFS_PART_SIZE=$((4096 * 1024))
NOR_SIZE=$((16 * 1024 * 1024))
for image in "$UBOOT_BIN" "$KERNEL_BIN" "$ROOTFS_BIN"; do
	[[ -f "$image" ]] || { echo "Missing image: $image" >&2; exit 1; }
done
[[ $(stat -c '%s' "$UBOOT_BIN") -le $UBOOT_PART_SIZE ]] || { echo "T33 U-Boot exceeds its 256 KiB partition" >&2; exit 1; }
[[ $(stat -c '%s' "$KERNEL_BIN") -le $KERNEL_PART_SIZE ]] || { echo "T33 kernel exceeds its 2.5 MiB partition" >&2; exit 1; }
[[ $(stat -c '%s' "$ROOTFS_BIN") -le $ROOTFS_PART_SIZE ]] || { echo "T33 rootfs exceeds its 4 MiB partition" >&2; exit 1; }
python3 - "$NOR_IMAGE" "$UBOOT_BIN" "$KERNEL_BIN" "$ROOTFS_BIN" "$T33_MEM_ARGS" <<'PY'
import struct
import sys
import zlib

image_path, uboot_path, kernel_path, rootfs_path, memory_args = sys.argv[1:]
size = 16 * 1024 * 1024
parts = ((0, uboot_path), (256 * 1024, kernel_path),
		 (256 * 1024 + 2560 * 1024, rootfs_path))
with open(image_path, "wb") as image:
	image.write(b"\xff" * size)
	for offset, path in parts:
		with open(path, "rb") as src:
			image.seek(offset)
			image.write(src.read())
	# Seed a valid U-Boot environment so fw_printenv/fw_setenv work on first
	# boot and retain the boot command/partition map expected by the image.
	variables = {
		"baudrate": "115200",
		"bootcmd": "sf0 probe;sf0 read 0x80600000 0x40000 0x280000;bootm 0x80600000",
		"bootdelay": "1",
		"bootargs": f"console=ttyS1,115200n8 {memory_args} init=/init rootfstype=squashfs root=/dev/mtdblock2 rw mtdparts=sfc0_nor:256k(boot),2560k(kernel),4096k(root),9440k(rootfs_data),32k(env)",
		"stdin": "serial",
		"stdout": "serial",
		"stderr": "serial",
		"wlandev": "aic8800d80-t33",
	}
	data = b"\0".join(f"{key}={value}".encode() for key, value in variables.items()) + b"\0\0"
	payload = data.ljust(16 * 1024 - 4, b"\0")
	env = struct.pack("<I", zlib.crc32(payload) & 0xffffffff) + payload
	image.seek(size - 32 * 1024)
	image.write(env)
PY
cp "$UBOOT_BIN" "$BOOT_DIR/u-boot-with-spl.bin"
cat > "$OUTPUT/images/openipc-t33-prj008n-nor-16m.layout.txt" <<'EOF'
Flash: 16 MiB SPI NOR
0x000000-0x03ffff  Ingenic PRJ008N SPL + U-Boot (padded remainder erased)
0x040000-0x2bffff  OpenIPC MIPS uImage kernel
0x2c0000-0x6bffff  OpenIPC SquashFS root filesystem
0x6c0000-0xff7fff  rootfs_data partition, formatted on first boot
0xff8000-0xffffff  U-Boot environment erase block; 16 KiB CRC-seeded environment
Bootargs and boot command: Ingenic SDK PRJ008N SPI-NOR defaults
EOF

echo "T33 RAM-boot files: $BOOT_DIR"
echo "Kernel: $(stat -c '%s bytes' "$BOOT_DIR/uImage")"
echo "Initramfs U-Boot image: $(stat -c '%s bytes' "$BOOT_DIR/openipc-t33-initramfs.uImage")"
echo "16 MiB NOR image: $NOR_IMAGE"
echo "U-Boot with SPL: $(stat -c '%s bytes' "$UBOOT_BIN")"
echo "Kernel: $(stat -c '%s bytes' "$KERNEL_BIN")"
echo "SquashFS rootfs: $(stat -c '%s bytes' "$ROOTFS_BIN")"
