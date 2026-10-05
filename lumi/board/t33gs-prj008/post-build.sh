#!/bin/sh
set -eu

TARGET_DIR=$(cd "$1" && pwd)
OUTPUT_DIR=$(cd "$(dirname "$TARGET_DIR")" && pwd)
SDK_WORK="$OUTPUT_DIR/t33-sdk"
KDIR="$OUTPUT_DIR/build/linux-custom"
TOOLCHAIN="$SDK_WORK/toolchain/mips-gcc540-uclibc0.9.33.2-r3.3.7.mxu2.cve2/bin/mips-linux-uclibc-"
DRIVER_SOURCE="$SDK_WORK/driver-source/drivers"
ISP_DIR="$DRIVER_SOURCE/isp/tx-isp"
SENSOR_DIR="$DRIVER_SOURCE/sensors/sc4336"
AUDIO_DIR="$DRIVER_SOURCE/audio/oss3"

if [ ! -f "$KDIR/.config" ] || [ ! -f "$ISP_DIR/Makefile" ] || [ ! -f "$SENSOR_DIR/PRJ008/sc4336.c" ]; then
	echo "T33 post-build: missing kernel configuration or staged SDK driver source" >&2
	exit 1
fi

make -s -C "$KDIR" ARCH=mips CROSS_COMPILE="$TOOLCHAIN" \
	M="$ISP_DIR" PWD="$ISP_DIR" CONFIG_SOC_PRJ008=y CONFIG_KERNEL_3_10=y clean
cp "$SDK_WORK/libPRJ008-firmware-310-540.a" "$ISP_DIR/libPRJ008-firmware.a"
make -C "$KDIR" ARCH=mips CROSS_COMPILE="$TOOLCHAIN" \
	M="$ISP_DIR" PWD="$ISP_DIR" CONFIG_SOC_PRJ008=y CONFIG_KERNEL_3_10=y modules
make -s -C "$KDIR" ARCH=mips CROSS_COMPILE="$TOOLCHAIN" \
	M="$SENSOR_DIR" PWD="$SENSOR_DIR" TASSADAR_ENV_KERNEL_DIR="$KDIR" \
	CONFIG_SOC_PRJ008=y CONFIG_KERNEL_3_10=y clean
make -C "$KDIR" ARCH=mips CROSS_COMPILE="$TOOLCHAIN" \
	M="$SENSOR_DIR" PWD="$SENSOR_DIR" TASSADAR_ENV_KERNEL_DIR="$KDIR" \
	CONFIG_SOC_PRJ008=y CONFIG_KERNEL_3_10=y modules

# The SDK's PRJ008 OSS3 module provides the internal-codec microphone path.
# Build it against this image's kernel; only audio capture is enabled in the
# runtime until the board speaker wiring is verified.
if [ ! -f "$AUDIO_DIR/Makefile" ]; then
	echo "T33 post-build: missing PRJ008 OSS3 audio driver source" >&2
	exit 1
fi
make -s -C "$KDIR" ARCH=mips CROSS_COMPILE="$TOOLCHAIN" \
	M="$AUDIO_DIR" PWD="$AUDIO_DIR" CONFIG_SOC_PRJ008=y CONFIG_KERNEL_3_10=y clean
make -C "$KDIR" ARCH=mips CROSS_COMPILE="$TOOLCHAIN" \
	M="$AUDIO_DIR" PWD="$AUDIO_DIR" CONFIG_SOC_PRJ008=y CONFIG_KERNEL_3_10=y modules

MODULE_DIR="$TARGET_DIR/lib/modules/3.10.14/ingenic"
install -d "$MODULE_DIR"
install -m 0644 "$ISP_DIR/tx-isp-PRJ008.ko" "$MODULE_DIR/"
install -m 0644 "$SENSOR_DIR/sensor_sc4336_PRJ008.ko" "$MODULE_DIR/"
KERNEL_RELEASE=$(make -s -C "$KDIR" ARCH=mips CROSS_COMPILE="$TOOLCHAIN" kernelrelease)
AUDIO_MODULE_DIR="$TARGET_DIR/lib/modules/$KERNEL_RELEASE/ingenic"
install -d "$AUDIO_MODULE_DIR"
install -m 0644 "$AUDIO_DIR/audio.ko" "$AUDIO_MODULE_DIR/"

# Build an SDK-uClibc probe using the registration sequence from the SDK sample.
SDK_INCLUDE="$SDK_WORK/vendor-media/include"
VENDOR_MEDIA="$SDK_WORK/vendor-media/lib"
SDK_LIB="$SDK_WORK/vendor-media/sdk-lib"
SDK_SYSROOT="$SDK_WORK/toolchain/mips-gcc540-uclibc0.9.33.2-r3.3.7.mxu2.cve2/mips-linux-uclibc/libc"
SDK_CC="$SDK_WORK/toolchain/mips-gcc540-uclibc0.9.33.2-r3.3.7.mxu2.cve2/bin/mips-linux-uclibc-gcc"
if [ ! -x "$SDK_CC" ] || [ ! -f "$SDK_INCLUDE/imp/imp_isp.h" ]; then
	echo "T33 post-build: missing SDK compiler or media headers for sensor probe" >&2
	exit 1
fi
"$SDK_CC" -muclibc -march=mips32r2 -O2 -Wall -I"$SDK_INCLUDE" \
	-L"$SDK_SYSROOT/usr/lib" -L"$SDK_SYSROOT/lib" -L"$SDK_LIB" \
	-Wl,--dynamic-linker=/opt/ingenic-t33/lib/ld-uClibc-0.9.33.2.so \
	-Wl,--enable-new-dtags \
	-Wl,-rpath,/opt/ingenic-t33/lib \
	-o "$OUTPUT_DIR/t33-sensor-probe" \
	"$(dirname "$0")/t33-sensor-probe.c" -limp -lalog -lrt
"$SDK_CC" -muclibc -march=mips32r2 -O2 -Wall -Wextra -I"$SDK_INCLUDE" \
	-L"$SDK_SYSROOT/usr/lib" -L"$SDK_SYSROOT/lib" -L"$SDK_LIB" \
	-Wl,--dynamic-linker=/opt/ingenic-t33/lib/ld-uClibc-0.9.33.2.so \
	-Wl,--enable-new-dtags \
	-Wl,-rpath,/opt/ingenic-t33/lib \
	-o "$OUTPUT_DIR/t33-frame-probe" \
	"$(dirname "$0")/t33-frame-probe.c" -limp -lalog -lrt

# libimp is uClibc-linked while OpenIPC userland uses musl. Keep all vendor
# libraries and their SDK runtime in a private directory; never expose them to
# the normal musl loader or replace the system C library.
VENDOR_MEDIA="$SDK_WORK/vendor-media/lib"
if [ ! -f "$VENDOR_MEDIA/libimp.so" ] || [ ! -f "$VENDOR_MEDIA/ld-uClibc.so.0" ]; then
	echo "T33 post-build: staged SDK libimp or its uClibc runtime is missing" >&2
	exit 1
fi
VENDOR_DIR="$TARGET_DIR/opt/ingenic-t33"
rm -rf "$VENDOR_DIR"
install -d "$VENDOR_DIR/lib"
cp -a "$VENDOR_MEDIA"/. "$VENDOR_DIR/lib/"
python3 "$(dirname "$0")/fix-xsym-links.py" "$VENDOR_DIR/lib"
install -m 0755 "$OUTPUT_DIR/t33-sensor-probe" "$VENDOR_DIR/t33-sensor-probe"
install -m 0755 "$OUTPUT_DIR/t33-frame-probe" "$VENDOR_DIR/t33-frame-probe"
cat > "$VENDOR_DIR/README" <<'EOF'
SDK media libraries are local-test-only and use Ingenic's uClibc ABI.
OpenIPC system programs use musl; do not add this directory to their
LD_LIBRARY_PATH. The SDK probes embed their private uClibc interpreter and rpath.
The vendor ISP archive and media libraries are not included in Git.
The sensor probe uses the SDK sample's I2C0/CSI0/MCLK0 and PA20 reset setup.
It leaves the sensor enabled for inspection; stop it with Ctrl-C.
The frame probe initializes SC4336, enables a one-buffer NV12 FrameSource,
retrieves three frames, and samples each buffer before releasing it.
EOF
echo "T33 post-build: installed PRJ008 ISP/sensor/audio modules and libimp probes"

SC4336_ISP_BINS="$SDK_WORK/sc4336-isp-bins"
for mode in day night; do
	bin="sc4336-PRJ008-$mode.bin"
	if [ ! -f "$SC4336_ISP_BINS/$bin" ]; then
		echo "T33 post-build: missing SC4336 ISP tuning bin $SC4336_ISP_BINS/$bin" >&2
		exit 1
	fi
	install -D -m 0644 "$SC4336_ISP_BINS/$bin" "$TARGET_DIR/etc/sensor/$bin"
done
echo "T33 post-build: installed SC4336 PRJ008 day/night ISP tuning bins"

# Keep the camera vendor's matching D80 U02 firmware out of Git. The build
# script extracts it from original-fw/T33_GSCAM01.bin into this ignored SDK
# work directory before Buildroot runs.
AIC_FIRMWARE="$SDK_WORK/aic-firmware"
if [ -d "$AIC_FIRMWARE" ]; then
	install -d "$TARGET_DIR/lib/firmware"
	for fw in "$AIC_FIRMWARE"/*; do
		[ -f "$fw" ] && install -m 0644 "$fw" "$TARGET_DIR/lib/firmware/"
	done
	if [ -d "$AIC_FIRMWARE/aic8800D80" ]; then
		install -d "$TARGET_DIR/lib/firmware/aic8800D80"
		install -m 0644 "$AIC_FIRMWARE/aic8800D80"/* "$TARGET_DIR/lib/firmware/aic8800D80/"
	fi
	cat > "$TARGET_DIR/lib/firmware/README.t33-aic8800d80" <<'EOF'
Firmware blobs extracted locally from the original T33 camera firmware for
its AIC8800D80 U02 USB combo module. They are not distributed in this source tree.
EOF
	echo "T33 post-build: installed locally extracted AIC8800D80 U02 firmware"
else
	echo "T33 post-build: missing original AIC8800D80 firmware; Wi-Fi will not initialize" >&2
fi
