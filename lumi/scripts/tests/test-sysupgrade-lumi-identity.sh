#!/bin/bash
# Product hostnames must not disable the updater's foreign-image rejection.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
source_file=${SRC:-$root/lumi/overlay/usr/sbin/sysupgrade}
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
awk '/^(verify_rootfs|check_soc|compare_versions|get_system_version|get_device)\(\)/ { copy=1 } copy { print } copy && /^}/ { copy=0 }' "$source_file" | sed "s|local y=/tmp/rootfs|local y=$fixture/rootfs|" | sed "s|/proc/mtd|$fixture/mtd|g" > "$fixture/functions"
run() (
 # Match sysupgrade's shell options, including its legacy grep fallback.
 set +e
 source "$fixture/functions"
 model=t33; system_version=old; skip_soc=; skip_ver=; remote_update=
 echo_c() { shift; printf '%s\n' "$*"; }
 die() { printf '%s\n' "$*" >&2; exit 1; }
 losetup() { case "$1" in -f) echo /dev/loop0;; esac; }
 umount() { :; }
 # The mock image's build identity is independent of its product hostname.
 mount_rootfs() {
  mkdir -p "$2/etc"
  printf 'lumi\n' > "$2/etc/hostname"
  printf 'GITHUB_VERSION=new\n' > "$2/etc/os-release"
  case "$image_model_fixture" in
   legacy) printf 'openipc-t33\n' > "$2/etc/hostname" ;;
   missing) : ;;
   *) printf 'BUILD_PLATFORM=%s_lite\n' "$image_model_fixture" >> "$2/etc/os-release" ;;
  esac
 }
 touch "$fixture/image"
 verify_rootfs "$fixture/image"
)
printf 'mtd2: 00c00000 00008000 "root"\n' > "$fixture/mtd"
( source "$fixture/functions"; test "$(get_device rootfs)" = /dev/mtd2 )
image_model_fixture=t33 run >/dev/null
image_model_fixture=legacy run >/dev/null
for rejected in rv1106 missing; do
 if image_model_fixture=$rejected run >/dev/null 2>&1; then
  echo "FAIL image identity $rejected accepted" >&2; exit 1
 fi
done
echo 'PASS Lumi hostname accepts matching build identity and rejects foreign SoC'
