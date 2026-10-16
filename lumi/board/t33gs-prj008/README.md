# Ingenic T33gs board (T33 SoC, PRJ008)

This directory describes the current **T33gs** board: an SK032T4 board on the
Ingenic T33 SoC, identified in the captured firmware as PRJ008 and fitted with
an SC4336 image sensor. The board identity is T33gs; `t33` in this path and in
the build configuration names the SoC family. It is distinct from the other
T33 hardware targeted by the older TINA runtime. The SDK has SC4336 source for
PRJ007 only; the build stages that source under PRJ008. The sensor has now been
detected at I2C 0x30 and produced the validated primary RTSP stream; long-run
operation and alternate ISP features remain unverified.

## Build

Compact runtime builds after 2026-10-11 install core, integrated HTTP/RTSP/P2P
gateway and a POSIX supervisor; recorder and combined voice worker are optional.
The image hook removes the old RTSP, motor, P2P and two voice executables, and the
boot scripts no longer launch/watch standalone P2P. Keep the external relay
connector when configured. Historical process descriptions below refer to the
earlier image.

Use a verified `make package-t33gs` directory as `T33_RUNTIME_DIR` for a cached
rootfs-only `br-all` build. Include the matched source-built relay and its public
certificate when the product enables relay. Voice credentials/model/profile are
separately provisioned under root-owned mode-0700 `/overlay/lumi-voice`, with
mode-0600 `ENABLED`, `READY`, `model.tflite`, `webrtc_profile.ini`, `luvox.conf`.
`ENABLED` retains `cpu16k-v1`. S60 copies the model/AEC state to RAM before core
starts and passes `/overlay/lumi-voice/luvox.conf` directly to voice for per-session
configuration reload. An optional private `luvox-init.json` stays in overlay and
is referenced by `LUVOX_INIT_FILE`; the main supervisor owns combined voice restart. None of those private
files belongs in the firmware. Without a mounted card, recorder stays disabled.

For a camera already on the 12 MiB root layout, a rootfs-only update preserves
kernel, bootloader, environment and `/overlay`; verify its partition map first.
Set `T33_KERNEL_MODULES_DIR` to the `lib/modules` tree from the byte-verified
prior image when preserving the running kernel's exact module set. Do not use
this input for a kernel-changing build or an unverified SDK cache.
Image build is not flash authorization or board qualification.

Set `T33_SDK_ROOT` to the extracted Tassadar T32/T33 SDK directory and run
`contrib/build-t33.sh`. The build requires `7z` and `lzop`. It creates an
OpenIPC musl rootfs and kernel, then uses the SDK GCC 5.4 uClibc toolchain to
build the TX-ISP and SC4336 modules. The SDK ISP archive and media libraries
are copied only into the ignored output directory and the generated test
image; they are not checked into Git.

The T33 SDK `libimp.so` uses uClibc, while OpenIPC userland uses musl. The
build puts `libimp`, its support libraries, and the matching SDK uClibc
runtime under `/opt/ingenic-t33/lib`; they must not be added to the normal
musl library path. The bundled probe uses its private uClibc interpreter and
library path when launched directly.

The current firmware build embeds the repository-owned runtime, including API,
RTSP, snapshot decoder, recorder, motor executable, WebRTC worker and relay.
See the integrated-image section below; older separately deployed releases are
historical.

The experimental `t33-sensor-probe` utility uses the T33 SDK sample's sensor
registration sequence for SC4336 on I2C0 at `0x30`, CSI0/MCLK0, reset GPIO
PA20 and the SDK sample's sensor-switch GPIO PA25. Start the board driver
modules, then run:

```sh
/opt/ingenic-t33/t33-sensor-probe
```

It prints whether `IMP_ISP_AddSensor` and `IMP_ISP_EnableSensor` succeed and
leaves the sensor active so `dmesg` and `/sys/bus/i2c/devices` can be checked.
Press Ctrl-C to disable and remove the sensor cleanly. PA20 comes from the SDK
sample and still needs confirmation against this board's wiring.

`t33-frame-probe` runs the complete ISP and FrameSource initialization, reads
three frames from a one-buffer 2560x1440 NV12 channel, samples five offsets
from each buffer, then releases the frames:

```sh
/opt/ingenic-t33/t33-frame-probe
```

The buffer depth is kept at one because the T33gs runtime has limited RAM. The
board has 128 MiB DRAM. Its original 64 MiB Linux / 64 MiB TX-ISP split was
reduced to 96 MiB / 32 MiB through the U-Boot environment. The current
one-sensor RTSP pipeline booted and streamed with that split; the build script
uses 96/32 by default. Keep the 32 MiB TX-ISP region until broader ISP features
or a memory high-water measurement justify reducing it. Long-duration capture
remains to be checked. Scanning whole frames in userspace can exhaust RAM.
The current SDK returns `pixfmt=0` in frame metadata even when NV12 is
requested; the header labels zero as YUV420P, so verify plane layout before
passing these buffers to a streamer.

T33gs SC4336 registration requires the matching PRJ008 day and night ISP tuning bins
at `/etc/sensor/sc4336-PRJ008-{day,night}.bin`. The build extracts these from
the supplied original camera firmware into ignored SDK work output and installs
them in the image; the proprietary binaries are not stored in Git. The TX-ISP
module uses its SDK defaults for `direct_mode` and `ivdc_mem_line`; forcing
direct mode with a fixed IVDC line count produced ISP UV overflow and zeroed
FrameSource buffers on this 2560x1440 sensor.

## RAM boot

Use `output/t33-openipc-driver-test/tftp/openipc-t33/boot-openipc-t33.txt` as
the U-Boot command reference. Serve that directory over TFTP, set `serverip`
to the TFTP host and `ipaddr` to an unused camera address, then run the listed
`tftp` and `bootm` commands at the U-Boot prompt. The script uses an initramfs
and does not write NOR or save U-Boot environment changes.

The generated 16 MiB NOR candidate uses this layout:

| Region | Range | Size |
| --- | --- | ---: |
| SPL + U-Boot | `0x000000–0x03ffff` | 256 KiB |
| Kernel | `0x040000–0x2bffff` | 2.5 MiB |
| SquashFS root | `0x2c0000–0x6bffff` | 4 MiB |
| `rootfs_data` | `0x6c0000–0xff7fff` | 9.21875 MiB |
| U-Boot environment | `0xff8000–0xffffff` | 32 KiB erase block (16 KiB data) |

The final NOR erase block is reserved for U-Boot environment data. The image
seeds a valid CRC environment and installs `/etc/fw_env.config`, preventing
`fw_printenv` from scanning invalid offsets and delaying startup. Wi-Fi tools
include `iw`, `wpa_supplicant`, and `wpa_passphrase`. To scan and connect:

```sh
iw dev wlan0 scan
fw_setenv wlanssid 'your-ssid'
fw_setenv wlanpass 'your-password'
/etc/init.d/S40network restart
```

The boot log showed `check_mac` taking about 32 seconds when fw_env had no
configuration; it invokes the failing env utilities several times. This is the
measured dominant avoidable delay. The prior image also lacked kernel overlayfs
support, so OpenIPC's persistent root overlay did not mount and writes to `/etc`
and `/mnt` failed. The env configuration fixes the fw_env delay; writable-root
support remains a separate kernel limitation in this SDK port.

The T33gs kernel fragment disables `CONFIG_JZ_MAC`: its GMAC pin group overlaps
the eight ULN motor inputs (GPIOs 38–43, 45, 46). `S35board` puts these inputs
in GPIO output-low mode through `lumi-t33gs-motor-gpio-init` and releases its
claims for a motor controller. It
skips already exported pins and retains a claim if low readback fails. This
prepares the pins; it does not establish coil order or enable the PTZ API.
The earlier kernel enabled GMAC but failed to initialize Ethernet. Linux
Ethernet and Linux TFTP are unavailable with the new fragment; U-Boot has its
own independent pinmux/network configuration.
The kernel-only rollout and boot GPIO checks are recorded in
[motor pinmux verification](motor-pinmux-20261005.md). The current read-only
rootfs invokes the same helper from its writable supervisor wrapper; the
updated `S35board` will be included in a future rootfs build.
Serial console uses `ttyS1` at 115200 baud. The current kernel/rootfs were
deployed over the attached serial workflow and booted successfully; U-Boot and
its environment were not rewritten.

The current PRJ008N NOR candidate is
`output/t33-openipc-driver-test/images/openipc-t33gs-prj008n-nor-16m-mem96-rmem32-s65-mmc-loginfix.bin`.
It was assembled from that output directory's `uImage`, `rootfs.squashfs`, and
PRJ008N `u-boot-with-spl.bin` using `contrib/pack-t33gs-nor16.py`. The image is
16 MiB; SHA-256:
`25ed3d408cc8034949c958f203a5ab6a75ba6d040d1b77d2edcd393c00ec7ad9`.
The packer checks the MIPS/LZMA uImage header and CRC, SquashFS v4 metadata,
partition capacities, and writes a CRC-seeded U-Boot environment with the
96 MiB Linux / 32 MiB TX-ISP arguments. Its kernel slot hash is
`ff4aaad79f37079eb70657856049978c0ca2d7dd35c8b13fd0bcbef0ad179b15`; its
rootfs slot hash is
`1a15e3a0f8003b8397db02238dd98c71db9b9048a22754c0e7363875a0dd1ef4`. Those
two partitions have been flashed and booted on T33gs; the full NOR candidate
has not been staged to `10.10.60.6`. The older `s61` image remains on that
staging host and is superseded. The current boot validates Wi-Fi auto-connect,
persistent streamer startup, and the primary RTSP profile. The detected
`mmcblk0` has no partition table or filesystem, so recording storage is not
available. See the streamer's `t33gs-rtsp-2026-09-30.md` evidence log for
runtime results.

After a RAM boot, inspect `dmesg`, `/proc/mtd`, module load status, I²C
adapters, and sensor detection before attempting other hardware features. The
SC4336 driver was derived from the SDK's PRJ007 source; initial sensor
detection and one primary stream are validated, but sustained operation and
secondary profiles are not.


## Integrated firmware — 2026-10-08

`contrib/build-t33.sh` now builds `package-t33gs-p2p-runtime` from the sibling
streamer checkout and installs its verified package into
`/usr/lib/lumi-ipc-streamer` in SquashFS. Device configuration remains under
`/overlay/lumi-ipc-streamer`; binaries are not copied into JFFS2 at startup.
The package includes core, RTSP worker, HTTP services, supervisor, motor owner,
snapshot decoder, recorder, WebRTC worker and the compressed relay-agent.
The matching native motor module is compiled from sibling `lumi-ipc-linux`.
No relay identity key is embedded.

For a rootfs-only build with an already built source package, set
`T33_RUNTIME_DIR=/absolute/path/to/package-t33gs-p2p-runtime` before
`make BOARD=lumi_t33gs_prj008_nor16 TARGET=/absolute/output br-all`.
The post-build hook rejects missing executables, mismatched package checksums
and packaged relay identity keys. It records a manifest of the installed bytes.

This replaces the old 4 MiB root/9.2 MiB runtime layout:

| Region | Offset | Capacity |
| --- | --- | --- |
| SPL + U-Boot | `0x000000` | 256 KiB |
| Kernel | `0x040000` | 2560 KiB |
| SquashFS with runtime | `0x2c0000` | 12288 KiB |
| Writable configuration | `0xec0000` | 1248 KiB |
| Environment erase block | `0xff8000` | 32 KiB |

Use the full NOR image for migration from the old layout. Flashing only the
expanded rootfs with old bootargs would overlap rootfs_data. Full NOR flashing
resets Wi-Fi settings and device configuration. The seeded environment and
PRJ008N U-Boot fallback both use the new map and mem96/rmem32. The SquashFS
XZ block is 256 KiB; the existing kernel supports XZ SquashFS.

After Wi-Fi obtains an IPv4 address, S60 starts the stack and S61 monitors it.
HTTP listens on `0.0.0.0:18080`; RTSP listens on the Wi-Fi address at 18554.
Main video uses H.264 for the embedded WebRTC worker. Public API examples:

Timestamp and Lumi logo are enabled by default on both streams and direct ISP
PNG capture. To explicitly disable OSD, create
`/overlay/lumi-ipc-streamer/osd.conf` owned by root with mode 0600 and content
`disabled`, then reboot. Content `enabled` enables it explicitly.

```sh
curl http://CAMERA_IP:18080/health
curl http://CAMERA_IP:18080/api/v1/media/status
curl -X POST http://CAMERA_IP:18080/api/v1/media/snapshot -o capture.png
curl http://CAMERA_IP:18080/api/v1/ptz/capabilities
```

Recorder is launched from firmware only when SD/USB storage is mounted under
`/mnt`. WebRTC starts with the public example configuration. Relay starts only
after a device-specific key is provisioned in `relay-key.json` (root:0600).
The motor executable/module are embedded but PTZ is disabled until the board
qualification in the streamer PTZ plan is complete. A qualified deployment
can use a root-owned 0600 `ptz.conf` containing `enabled`; this enables the
native ioctl owner without homing or moving the motor at startup.
The motor driver defaults to 50 halfsteps/s. Talkback, home and other unimplemented
features retain their existing unsupported responses.

Build/packaging and simulated init checks do not establish board behavior.
Record an actual boot, API snapshot, RTSP and PTZ qualification separately.
