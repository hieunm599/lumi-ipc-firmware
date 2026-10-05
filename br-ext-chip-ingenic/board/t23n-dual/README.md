# Lumi T23N dual OS02N10 / AIC8800DC

Local board preset: `t23n_dual_lumi`. Firmware remains OpenIPC/Buildroot; only
the matching sensor/ISP and Wi-Fi driver sources are taken from the SDKs below.
No Majestic, streaming daemon, old `libimp`, generic `sinfo` or `load_ingenic`.
The replacement application must use userspace libraries matching the dual ISP
SDK, not assume the previous single-sensor libimp ABI.

## Evidence and limits

Input: `/home/hieunm/workspace/poc/OpenIPC/T23N_DUAL_DEVICE_TREE_REPORT.md`.
Read-only UART inspection on 2026-09-15 confirmed:

- kernel `3.10.14__isvp_pike_1.0__`, PREEMPT, console `ttyS1,115200`;
- Macronix MX25L12835F, JEDEC `c22018`, **16 MiB** total;
- MTD sizes `40000`, `10000`, `200000`, `500000`, `8b0000` (hex);
- `mem=40M rmem=24M@0x2800000`, CPU 1188 MHz;
- SquashFS `/rom`, JFFS2 `/overlay`, ISP currently 150 MHz;
- no wlan0/USB Wi-Fi enumerated at inspection; generic sensor and Ethernet
  probe failures match the report. GPIOs were not driven during this inspection.

The OS02N10 population, GPIO62 active-low enable, and USB `a69c:88dc` follow the
report's earlier evidence. Sensor reset 18, sensor1 reset -1, power-down -1,
fsync mode 3 and MIPI switch 7 are verified against the matching driver sources.
This kernel is legacy platform-data based, not DTB based.

GPIO60 SD power, GPIO63 speaker and GPIO54 LED remain medium-confidence values:
the image does not automatically drive them. GPIO22, BOOT0, motors and IR pins
are not assigned. MMC0 PB/4-bit is enabled with the kernel's existing CD GPIO59;
MMC1, GMAC and RTC are disabled. Audio module is available but not auto-loaded.

## Sources

| Component | Upstream / revision |
| --- | --- |
| Base firmware | `hieunm599/lumi-ipc-firmware`, `06b68e7bd4cfa68e36964ba75c8d56d1df6755ae` + local Lumi changes |
| Kernel | OpenIPC/linux `ingenic-t23`, same cached source as preceding T23 build; board config fragment applied |
| ISP + both sensors + audio + IQ | https://github.com/thingino/ingenic-sdk at `343ae306c99b50f1c79e038a7ef0aee8af6c1c2e` |
| Wi-Fi + complete DC firmware | https://github.com/gtxaspec/aic8800-wifi at `96cd509a9b6282d4f55adf2b394801ae9ae22599` |
| SPL/U-Boot | `hieunm599/lumi-u-boot-ingenic` at `6a308091ef41fd0ba06ba0c668fe406a19210eef`, `isvp_t23_sfcnor` DDR2 64 MiB |

The ISP archive is **1.3.0-double**, selected with `CONFIG_MULTI_SENSOR=1`.
Sensor source, ISP headers and ISP archive come from one revision. Driver
packages include pinned archive SHA256 checks. Vendor ISP/firmware payloads
remain proprietary; source repository license notes must accompany distribution.
No kernel/module binaries are copied from the report's previous images.

## Build

From the firmware repository, with `lumi-ipc-builder:openipc-t23` already built:

```sh
docker run --rm --user "$(id -u):$(id -g)" --cpuset-cpus 0-7 \
  --env PWD=/work --mount "type=bind,source=$(pwd),target=/work" --workdir /work \
  lumi-ipc-builder:openipc-t23 \
  make BOARD=t23n_dual_lumi TARGET=/work/output/t23n-dual-nor16 \
    BR2_DL_DIR=/work/output/t23-nor8/dl BR2_CCACHE_DIR=/work/output/t23-nor8/ccache

python3 contrib/pack-t23n-nor8.py --flash-mib 16 \
  --uboot ../lumi-u-boot-ingenic/output/u-boot-t23n-nor.bin \
  --kernel output/t23n-dual-nor16/images/uImage.t23 \
  --rootfs output/t23n-dual-nor16/images/rootfs.squashfs.t23 \
  --output output/t23n-dual-nor16/images/lumi-t23n-dual-os02n10-aic8800dc-nor16-full.bin
```

The packer retains its historical filename but supports both 8 and 16 MiB.
It refuses overwrites; choose a fresh output name when rebuilding. Firmware
output is isolated from `t23-nor8`; only source downloads and ccache are shared.
This board is intentionally excluded from upstream release CI, but registered
in its coverage audit. All physical-board changes live in this board directory.

## Flash and boot

| Offset | Capacity | Content |
| --- | ---: | --- |
| `0x000000` | 256 KiB | SPL + U-Boot |
| `0x040000` | 64 KiB | environment, erased FF |
| `0x050000` | 2 MiB | kernel |
| `0x250000` | 5 MiB | SquashFS |
| `0x750000` | 8896 KiB | rootfs_data, erased FF |

Full image must be **16,777,216 bytes**. The existing U-Boot's defaults already
match this map; it probes NOR capacity rather than fixing it at 8 MiB.
Back up the original full chip first. Program the full `.bin` at address 0 and
verify/read back before first boot; factory settings and previous overlay are
not retained. This work does not flash or reboot the attached camera.

**Update:** the initial release below subsequently failed boot/rootfs checks on
the user's board. Do not treat it as a validated working firmware. See the
SPI diagnostic revision at the end of this document.

Login remains `root` / `lumivn274`, shared salted SHA-512-crypt hash. UART is
required for first bring-up: **no SSID/password is embedded**, and there is no
Ethernet fallback. S35board enables Wi-Fi GPIO62, loads the Wi-Fi stack and waits
up to 10 seconds for wlan0. S40network only calls `ifup wlan0` when `wlanssid`
is configured in the environment; otherwise the replacement service can manage
the interface. The inherited wlan0 stanza also expects `wlanpass`.

## After user deployment

Check `dmesg`, `lsmod`, `/proc/mtd`, `/proc/mounts`, `/sys/class/net/wlan0` and
`/proc/jz/clock/cgu_isp/rate`. Loader requests 200 MHz and warns if not achieved;
module load success alone is not proof of sensor chip-ID/frames or Wi-Fi binding.
Actual chip-ID reads, dual frames/fsync, Wi-Fi scan/association/DHCP, SD card and
audio loopback require testing after deployment. No streaming application is
included, so video validation also requires the replacement application.

## Build result — 2026-09-15

Clean board build completed in 05:34. Packer tests (4), CI coverage self-test
(56 cases) and init-script syntax checks passed. Verified the **packaged**
SquashFS, not just the staging tree: both sensor modules + ISP + audio, 19 AIC
firmware files and IQ match the pinned sources; all 20 modules have the expected
vermagic and every strong undefined symbol has a provider in the final kernel
or another packaged module. AIC module USB alias covers `a69c:88dc`.

The vendor Wi-Fi modpost reported cfg80211 symbols absent from the kernel's
Module.symvers. They are exported by the packaged `cfg80211.ko`; final depmod
correctly records `aic8800 -> aic_load_fw + cfg80211`. The independent symbol
audit above includes those providers. This is not evidence of successful live
binding; that still requires the user's deployment and boot test.

| Artifact | Bytes | SHA256 |
| --- | ---: | --- |
| `uImage.t23` | 1,520,679 | `2bb0420ff88596846ccd974e6de3093ef3491f3f3257bc38b0302c419ab24016` |
| `rootfs.squashfs.t23` | 2,543,616 | `b8f3ea19dacba7de21af2eea82535b155b11f95d078c9ad018a264077cb43dc6` |
| `lumi-t23n-dual-os02n10-aic8800dc-nor16-full.bin` | 16,777,216 | `df228406257ef57aa45e214c38cec9c401fc3bec2619776624698b157759e0d4` |

Full-image offsets, each component, and every erased gap/environment/data byte
were checked independently after packaging. No new image was flashed during
this work. The previous 8 MiB firmware artifacts remain unchanged.

## SPI diagnostic revision: PIO / 25 MHz + U-Boot ready polling

Observed after user deployment: automatic boot got RDID FF after saveenv;
manual probe/read matched kernel CRC32 `ec28e622` and booted to Linux/login.
SquashFS then reported XZ corruption and programs failed with I/O errors.
Repeated raw MTD reads matched the original rootfs MD5, while mtdblock reads
did not. DMA/cache/timing remains a hypothesis, not a confirmed root cause.

Test changes: kernel `CONFIG_SFC_DMA` off, `CONFIG_SFC_SPEED=25`; rebuilt T23
U-Boot waits for stable ready status before probe and after write/erase, and
uses `&&` in its boot chain. No sensor, Wi-Fi or DDR change in this revision.
See the U-Boot repository's BUILD-T23.md for its modified-source build command.

Rebuild firmware using the command above. Package with the same packer arguments
except `--uboot ../lumi-u-boot-ingenic/output/t23n-spi-diag/source/u-boot-lzo-with-spl.bin`
and output `output/t23n-dual-nor16/images/lumi-t23n-dual-nor16-pio25-spiwait-test.bin`.

Image: **16,777,216 bytes**, SHA256
`0ecfa7481178d031730b2b9cd68c84ac770fb82398e6ab056417bc7437160619`.
Rootfs: 2,543,616 bytes, SHA256
`51551f45a0d2c8173821fa3b6565f7ee3f7f6269679f8ba16bd0342a62f85b1d`.
Build completed in 01:44; exact config, full-image offsets/padding, packaged
account and all 20 module vermagic/export dependencies were checked.
This is an **untested diagnostic image**, not a proven fix.

After full-chip backup/program/verify, capture first cold boot and the next boot.
Expect kernel log `sfc use PIO mode`, no SquashFS/JFFS2 I/O errors, and identical
checksums for both commands below matching the rootfs artifact. Do not move on
to sensor/Wi-Fi diagnosis until storage reads are stable:

Expected MD5 for this test rootfs: `6c3183e3072edec19ed671616f6368d0`.

```sh
dd if=/dev/mtd3 bs=4096 count=621 | md5sum
dd if=/dev/mtdblock3 bs=4096 count=621 | md5sum
```
