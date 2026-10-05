#!/bin/bash
# Post-build steps shared by every Lumi board. Runs after GENERAL's
# rootfs_script.sh (see BR2_ROOTFS_POST_BUILD_SCRIPT in lumi/configs/*).
set -eu
TARGET_DIR=$1

# Lumi ships a preconfigured root account, so a licensed Majestic preset must
# not silently bypass its owner claim/EULA flow. Lumi uses its own streamer.
if grep -q '^BR2_PACKAGE_MAJESTIC=y$' "${BR2_CONFIG}" ||
	[ -e "${TARGET_DIR}/usr/bin/majestic" ] ||
	[ -d "${TARGET_DIR}/usr/share/openipc/eula" ]; then
	echo 'Lumi fixed-login firmware requires Majestic disabled; use a clean target when switching presets.' >&2
	exit 1
fi

# Git does not preserve restrictive read permissions; enforce them in the image.
chmod 600 "${TARGET_DIR}/etc/shadow"

# The OpenIPC donation notice is not shown on Lumi products.
rm -f "${TARGET_DIR}/etc/openipc_donors"

# OS identity. GENERAL already wrote OPENIPC_VERSION/BUILD_* (kept for the
# tools that read them); prepend the standard os-release fields for Lumi.
OS_RELEASE="${TARGET_DIR}/usr/lib/os-release"
version=$(sed -n 's/^OPENIPC_VERSION=//p' "${OS_RELEASE}" | tail -1)
sed -i '/^\(NAME\|ID\|PRETTY_NAME\|LUMI_VERSION\)=/d' "${OS_RELEASE}"
{
	echo 'NAME="Lumi Camera OS"'
	echo 'ID=lumi_cam'
	echo "PRETTY_NAME=\"Lumi Camera OS ${version}\""
	echo "LUMI_VERSION=${version}"
	cat "${OS_RELEASE}"
} > "${OS_RELEASE}.new"
mv "${OS_RELEASE}.new" "${OS_RELEASE}"

# ONVIF identity, only when the onvif-simple-server package is installed.
ONVIF="${TARGET_DIR}/etc/onvif.conf"
if [ -f "${ONVIF}" ]; then
	sed -i \
		-e 's/^model=.*/model=Lumi Smart Camera/' \
		-e 's/^manufacturer=.*/manufacturer=Lumi/' \
		-e 's/^firmware_ver=.*/firmware_ver='"${version}"'/' \
		-e 's/^hardware_id=.*/hardware_id=LUMI_CAMERA/' \
		-e 's/^serial_num=.*/serial_num=LUMI-IPC/' \
		"${ONVIF}"
fi
