#!/usr/bin/env bash
# Experimental compile/ABI qualification. Never flashes or changes a camera.
set -euo pipefail

FW_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_ROOT=$(dirname "$FW_ROOT")
HOST_TOOLS=${T33_HOST_TOOLS_DIR:-$FW_ROOT/output/lumi-t33gs/host}
: "${T33_SDK_ROOT:?Set T33_SDK_ROOT to the extracted vendor SDK release}"
: "${T33_TOOLCHAIN_ROOT:?Set T33_TOOLCHAIN_ROOT to the SDK GCC5.4/uClibc toolchain}"
OUTPUT=${T33_4494_OUTPUT_DIR:-$FW_ROOT/output/t33gs-k4494}
BOARD_DIR="$REPO_ROOT/lumi-ipc-linux/kernel/ingenic/t33gs-4.4.94"
SDK="$OUTPUT/sdk"
KERNEL="$SDK/kernel-4.4.94"
BUILD="$OUTPUT/linux-build"
CROSS="$T33_TOOLCHAIN_ROOT/bin/mips-linux-uclibc-"
PHASE=${1:---all}
case "$PHASE" in --prepare|--kernel|--modules|--all) ;; *) echo "Usage: $0 [--prepare|--kernel|--modules|--all]" >&2; exit 2;; esac
[[ "$OUTPUT" = /* && "$T33_TOOLCHAIN_ROOT" = /* ]] || { echo 'Output and toolchain paths must be absolute' >&2; exit 1; }
mkdir -p "$OUTPUT/host-tools"
ln -sfn "$HOST_TOOLS/bin/mkimage" "$OUTPUT/host-tools/mkimage"
ln -sfn "$HOST_TOOLS/sbin/depmod" "$OUTPUT/host-tools/depmod"
# Do not put the whole Buildroot host/bin ahead of the container's host tools.
# Cached tools such as tar can require a newer host glibc than this builder.
export PATH="$OUTPUT/host-tools:$PATH"
for cmd in 7z make python3 lzop mkimage depmod; do command -v "$cmd" >/dev/null; done
[[ -x "${CROSS}gcc" && -f "$BOARD_DIR/t33gs.dts" && -f "$BOARD_DIR/t33gs.fragment" ]]
mkdir -p "$SDK" "$BUILD" "$OUTPUT/artifacts"
"${CROSS}gcc" --version | head -n1 > "$OUTPUT/artifacts/toolchain.version"
grep -Fxq 'mips-linux-uclibc-gcc (Ingenic r3.3.7.mxu2.cve2-gcc540 2025.07-17) 5.4.0' "$OUTPUT/artifacts/toolchain.version"
sha256sum "${CROSS}gcc" > "$OUTPUT/artifacts/toolchain.sha256"

# Pin archives on first use. Reusing an output with another SDK is forbidden.
python3 - "$T33_SDK_ROOT" "$OUTPUT" <<'PY'
import hashlib,json,pathlib,sys
root,out=map(pathlib.Path,sys.argv[1:])
inputs={}
for name in ('kernel-4.4.94.7z','drivers.7z'):
    candidates=list(root.rglob(name))
    if len(candidates)!=1: raise SystemExit(f'Expected one {name}, found {len(candidates)}')
    p=candidates[0].resolve()
    digest=hashlib.sha256()
    with p.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''): digest.update(block)
    inputs[name]={'path':str(p),'sha256':digest.hexdigest()}
p=out/'sdk-inputs.json'
if p.exists() and json.loads(p.read_text())!=inputs:
    raise SystemExit('SDK changed: select a fresh T33_4494_OUTPUT_DIR')
p.write_text(json.dumps(inputs,indent=2)+'\n')
PY
KERNEL_ARCHIVE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kernel-4.4.94.7z"]["path"])' "$OUTPUT/sdk-inputs.json")
DRIVER_ARCHIVE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["drivers.7z"]["path"])' "$OUTPUT/sdk-inputs.json")
if [[ ! -f "$SDK/.kernel-extracted" ]]; then
  7z x -y "-o$SDK" "$KERNEL_ARCHIVE" > "$SDK/kernel-extract.log" 2>&1
  test -f "$KERNEL/Makefile"
  touch "$SDK/.kernel-extracted"
fi
if [[ ! -f "$SDK/.drivers-extracted" ]]; then
  7z x -y "-o$SDK" "$DRIVER_ARCHIVE" 'drivers/isp/tx-isp/*' 'drivers/sensors/sc4336/*' 'drivers/audio/oss3/*' > "$SDK/drivers-extract.log" 2>&1
  test -f "$SDK/drivers/isp/tx-isp/libPRJ008-firmware-4494-540.a"
  test -f "$SDK/drivers/sensors/sc4336/PRJ007/sc4336.c"
  touch "$SDK/.drivers-extracted"
fi
# This is the same vendor sensor source used by the qualified 3.10 profile.
# It is shared with PRJ007 upstream; PRJ008 use is still a board-test gate.
mkdir -p "$SDK/drivers/sensors/sc4336/PRJ008"
cp "$SDK/drivers/sensors/sc4336/PRJ007/sc4336.c" "$SDK/drivers/sensors/sc4336/PRJ008/sc4336.c"
cp "$BOARD_DIR/t33gs.dts" "$KERNEL/arch/mips/boot/dts/ingenic/goat_prj008.dts"
probe_hash=$(sha256sum "$KERNEL/arch/mips/kernel/cpu-probe.c" | cut -d' ' -f1)
case "$probe_hash" in
  41cd9e1b32982deab19ad704057ad15946d4289b6706dd3e2b9617add6ae5654)
    patch --batch --forward -d "$KERNEL" -p1 < "$BOARD_DIR/0001-prj008-resolve-mxuv2-probe.patch" ;;
  c5b43c9a98228abbe97f9fcb5038c3b057621ca161f8a4029964d82ad225db3a) ;;
  *) echo 'Unexpected cpu-probe.c preimage; use an unmodified matching SDK' >&2; exit 1 ;;
esac
page_alloc_hash=$(sha256sum "$KERNEL/mm/page_alloc.c" | cut -d' ' -f1)
case "$page_alloc_hash" in
  7e298381e50ed5e5564aa2abcee196451e6237a74da889c06ff1e1efe0ad5f10)
    patch --batch --forward -d "$KERNEL" -p1 < "$BOARD_DIR/0003-reclaim-highatomic-before-oom.patch" ;;
  50ba86c154059c882b2504bedfdb6a579559846d6850330554f0cdd13e1adbcd|b0931d3df02e39c5102cd219e50cb9600e29584a539b245a9b60993c16ebe785) ;;
  *) echo 'Unexpected page_alloc.c preimage; use a fresh matching SDK output' >&2; exit 1 ;;
esac
page_alloc_hash=$(sha256sum "$KERNEL/mm/page_alloc.c" | cut -d' ' -f1)
case "${T33_4494_HIGHATOMIC_DIAGNOSTICS:-0}:$page_alloc_hash" in
  1:50ba86c154059c882b2504bedfdb6a579559846d6850330554f0cdd13e1adbcd)
    patch --batch --forward -d "$KERNEL" -p1 < "$BOARD_DIR/0004-debug-first-highatomic-reservation.patch" ;;
  0:50ba86c154059c882b2504bedfdb6a579559846d6850330554f0cdd13e1adbcd|1:b0931d3df02e39c5102cd219e50cb9600e29584a539b245a9b60993c16ebe785) ;;
  *) echo 'Highatomic diagnostic mode changed or invalid; use a fresh output and mode 0/1' >&2; exit 1 ;;
esac
python3 "$FW_ROOT/contrib/test_t33gs_highatomic.py" "$KERNEL/mm/page_alloc.c"
sha256sum "$KERNEL/mm/page_alloc.c" "$BOARD_DIR/0003-reclaim-highatomic-before-oom.patch" \
  > "$OUTPUT/artifacts/highatomic-source.sha256"
if [[ "${T33_4494_HIGHATOMIC_DIAGNOSTICS:-0}" = 1 ]]; then
  sha256sum "$BOARD_DIR/0004-debug-first-highatomic-reservation.patch" >> "$OUTPUT/artifacts/highatomic-source.sha256"
fi
printf 'diagnostics=%s\n' "${T33_4494_HIGHATOMIC_DIAGNOSTICS:-0}" > "$OUTPUT/artifacts/highatomic-mode.txt"
dma_source="$KERNEL/drivers/dma/ingenic/ingenic_dma.c"
dma_hash=$(sha256sum "$dma_source" | cut -d' ' -f1)
case "$dma_hash" in
  6ce8b0128734b83860be69c048c8ab96d0bb499f30aa2aa809217fcd235d9df0)
    patch --batch --forward -d "$KERNEL" -p1 < "$BOARD_DIR/0005-preallocate-dma-descriptor-page.patch" ;;
  4f04924af046fdb5ef5cd66ab2ecaea247524d940aa0e6524a8b22a48f890543) ;;
  *) echo 'Unexpected ingenic_dma.c preimage; use a fresh matching SDK output' >&2; exit 1 ;;
esac
python3 "$FW_ROOT/contrib/test_t33gs_dma_pool.py" "$dma_source"
sha256sum "$dma_source" "$BOARD_DIR/0005-preallocate-dma-descriptor-page.patch" \
  > "$OUTPUT/artifacts/dma-pool-source.sha256"
[[ "$PHASE" != --prepare ]] || exit 0

# Stable metadata; SDK objects and generated files stay outside source repos.
export KBUILD_BUILD_USER=lumi KBUILD_BUILD_HOST=builder
export KBUILD_BUILD_TIMESTAMP='Wed Feb 4 00:00:00 UTC 2026'
export KBUILD_BUILD_VERSION=1
export SOURCE_DATE_EPOCH=1770163200
KMAKE=(make -C "$KERNEL" "O=$BUILD" ARCH=mips "CROSS_COMPILE=$CROSS" 'HOSTCC=gcc -std=gnu89 -fcommon')
if [[ "$PHASE" != --modules ]]; then
  if [[ -n "${T33_4494_BASE_CONFIG:-}" ]]; then
    # Explicit baseline for allocator A/B; do not silently alter kernel options.
    cp "$T33_4494_BASE_CONFIG" "$BUILD/.config"
  else
    "${KMAKE[@]}" PRJ008_goat_defconfig
    (cd "$BUILD" && "$KERNEL/scripts/kconfig/merge_config.sh" -m -O "$BUILD" "$BUILD/.config" "$BOARD_DIR/t33gs.fragment")
  fi
  "${KMAKE[@]}" olddefconfig
fi
python3 - "$BUILD/.config" <<'PY'
import pathlib,sys
cfg=pathlib.Path(sys.argv[1]).read_text().splitlines()
for line in ('CONFIG_SOC_PRJ008=y','CONFIG_KERNEL_4_4_94=y','CONFIG_CMA_SIZE_MBYTES=16',
             'CONFIG_USB_DWC2_HOST=y','CONFIG_IPV6=y','CONFIG_OVERLAY_FS=y',
             '# CONFIG_INGENIC_MAC is not set','# CONFIG_PM is not set'):
    if line not in cfg: raise SystemExit('Required T33gs kernel setting missing: '+line)
PY
if [[ "$PHASE" != --modules ]]; then
  "${KMAKE[@]}" -j"${T33_BUILD_JOBS:-8}" uImage.lzma modules
  cp "$BUILD/.config" "$OUTPUT/artifacts/kernel.config"
  cp "$BUILD/arch/mips/boot/uImage.lzma" "$OUTPUT/artifacts/uImage"
fi
[[ "$PHASE" != --kernel ]] || exit 0

ISP="$SDK/drivers/isp/tx-isp"
SENSOR="$SDK/drivers/sensors/sc4336"
AUDIO="$SDK/drivers/audio/oss3"
cp "$ISP/libPRJ008-firmware-4494-540.a" "$ISP/libPRJ008-firmware.a"
for module in "$ISP" "$SENSOR" "$AUDIO"; do
  "${KMAKE[@]}" -j"${T33_BUILD_JOBS:-8}" "M=$module" "PWD=$module" \
    "TASSADAR_ENV_KERNEL_DIR=$BUILD" CONFIG_SOC_PRJ008=y CONFIG_KERNEL_4_4_94=y modules
done
for native in t33gs-motor t33gs-tnpu; do
  dest="$OUTPUT/$native"
  mkdir -p "$dest"
  cp "$REPO_ROOT/lumi-ipc-linux/kernel/ingenic/$native/Makefile" "$dest/"
  cp "$REPO_ROOT/lumi-ipc-linux/kernel/ingenic/$native/"*.{c,h} "$dest/"
  "${KMAKE[@]}" -j"${T33_BUILD_JOBS:-8}" "M=$dest" modules
done
mkdir -p "$OUTPUT/artifacts/modules"
cp "$ISP/tx-isp-PRJ008.ko" "$SENSOR/sensor_sc4336_PRJ008.ko" "$AUDIO/audio.ko" \
  "$OUTPUT/t33gs-motor/lumi_motor.ko" "$OUTPUT/t33gs-tnpu/tnpu.ko" "$OUTPUT/artifacts/modules/"
"${KMAKE[@]}" --no-print-directory -s kernelrelease > "$OUTPUT/artifacts/kernelrelease.txt"
release=$(cat "$OUTPUT/artifacts/kernelrelease.txt")
[[ "$release" = 4.4.94-lumi-t33gs ]]

AIC_REV=0e218ed686ee04a3006bb142ca70450dfa72f4d2
AIC_ARCHIVE=${T33_AIC_SOURCE_ARCHIVE:-$FW_ROOT/output/t23-nor8/dl/aic8800-openipc/aic8800-openipc-$AIC_REV.tar.gz}
test -f "$AIC_ARCHIVE"
AIC="$OUTPUT/aic8800-$AIC_REV"
if [[ ! -f "$AIC/Makefile" ]]; then
  mkdir -p "$AIC"
  tar -xzf "$AIC_ARCHIVE" --strip-components=1 -C "$AIC"
fi
sha256sum "$AIC_ARCHIVE" > "$OUTPUT/artifacts/aic-source.sha256"
aic_hash=$(sha256sum "$AIC/aic8800_fdrv/aic_priv_cmd.c" | cut -d' ' -f1)
case "$aic_hash" in
  786b458bf8015854a26e638cac349303b00e363fac7ac3a21631a7f6f7174801)
    patch --batch --forward -d "$AIC" -p1 < "$BOARD_DIR/0002-aic8800-include-vmalloc.patch" ;;
  42f78b1302fe372c187f09922460ebe0dd921108282ce0413cc7a58d02c79c9a) ;;
  *) echo 'Unexpected AIC8800 source preimage; use a fresh output directory' >&2; exit 1 ;;
esac
aic_rx_hash=$(sha256sum "$AIC/aic_load_fw/aicwf_rx_prealloc.c" | cut -d' ' -f1)
case "$aic_rx_hash" in
  40c7290c658fa4d5b9b917ed83e0160c4b4488ea004fc07e3a0b8b0fdfe432d3)
    patch --batch --forward -d "$AIC" -p1 < "$FW_ROOT/lumi/board/t33gs-prj008/patches/packages/aic8800-openipc/0001-limit-rx-preallocation.patch" ;;
  c5144f38df23ff50a437e1816d36b6b56d671cdbac597234fe8c5f7aa435b723) ;;
  *) echo 'Unexpected AIC8800 RX pool source preimage; use a fresh output directory' >&2; exit 1 ;;
esac
"${KMAKE[@]}" -j"${T33_BUILD_JOBS:-8}" "M=$AIC" "PWD=$AIC" CONFIG_USE_FW_REQUEST=n modules
cp "$AIC/aic_load_fw/aic_load_fw.ko" "$AIC/aic8800_fdrv/aic8800.ko" "$OUTPUT/artifacts/modules/"

# Install only this build's modules, with a matching dependency index.
MODROOT="$OUTPUT/artifacts/modules-root"
"${KMAKE[@]}" "INSTALL_MOD_PATH=$MODROOT" INSTALL_MOD_STRIP=1 modules_install
mkdir -p "$MODROOT/lib/modules/$release/ingenic" "$MODROOT/lib/modules/$release/kernel/drivers/net/wireless/aic8800"
cp "$ISP/tx-isp-PRJ008.ko" "$SENSOR/sensor_sc4336_PRJ008.ko" "$AUDIO/audio.ko" \
  "$OUTPUT/t33gs-motor/lumi_motor.ko" "$OUTPUT/t33gs-tnpu/tnpu.ko" "$MODROOT/lib/modules/$release/ingenic/"
cp "$AIC/aic_load_fw/aic_load_fw.ko" "$AIC/aic8800_fdrv/aic8800.ko" "$MODROOT/lib/modules/$release/kernel/drivers/net/wireless/aic8800/"
find "$MODROOT/lib/modules/$release" -name '*.ko' -exec "${CROSS}strip" --strip-debug {} +
rm -f "$MODROOT/lib/modules/$release/build" "$MODROOT/lib/modules/$release/source"
depmod -b "$MODROOT" "$release"
python3 "$FW_ROOT/contrib/verify-t33gs-k4494.py" "$OUTPUT/artifacts" --output "$OUTPUT/artifacts/verification.json"
echo "Experimental kernel/modules built in $OUTPUT/artifacts; board qualification pending."
