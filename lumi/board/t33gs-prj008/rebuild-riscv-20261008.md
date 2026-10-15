# T33gs rebuild and RISC-V experiment, 2026-10-08

Owner request: rebuild current firmware for camera flashing and experiment with
the RISC-V core for future wake-word use.

## Scope and recovery

Build the PRJ008/SC4336 kernel, SDK modules, base rootfs and NOR candidate,
plus the current streamer runtime as a separate package. The NOR packer leaves
rootfs_data erased; it does not install the streamer or camera credentials.
Target confirmed by owner: root@10.10.60.133, recovery UART /dev/ttyUSB1
(held by the owner's picocom). Existing board: PRJ008/SC4336, Linux
3.10.14__isvp_goat_1.0__ #48, 96 MiB Linux / 32 MiB ISP, 16 MiB NOR.
No firmware or persistent runtime replacement has been performed.

The first bounded counter probe refused before writing SRAM because the
controller wasn't in its expected reset state. Further source inspection
showed that the old probe mixed MCU SRAM with the separate TNPU controller.
The final source-owned probe only reads MCU registers; it has no execution,
reset or clock-writing command. Old ignored binaries were retained under
/tmp/lumi-t33gs-legacy-probes-20261008 and removed from the image overlay.

## Build context

- Firmware source: ec05200a plus the owner's existing working-tree changes.
- Streamer source: 1e5bdf0.
- SDK: /home/hieunm/workspace/poc/T33_Tassadar_20260203.
- Output: output/lumi-t33gs.
- Host dependencies: 7zip and lzop unpacked under /tmp/lumi-fw-host-deps;
  binaries exposed through /tmp/lumi-fw-host-bin without system installation.
- Logs: /tmp/lumi-t33gs-fw-build-20261008.log and
  /tmp/lumi-t33gs-runtime-build-20261008.log.

## Progress

- Fixed post-image firmware root path after the directory refactor.
- Reuse the already staged SDK ISP archive rather than requiring extraction
  again (the available drivers.7z could not be opened by 7zip).
- Reconfigure kernel and rebuild hardware modules on incremental builds.
- Fix SDK XSym link helper filename and propagate its failures.
- Restore INSTALL_MOD_PATH/ARCH/host flags lost through make override
  precedence; the previous build silently failed to install kernel modules.
- Fix S35 Wi-Fi discovery for the full kernel release and nested module path.
- Recreate merged target from per-package outputs to remove old hook debris.
- Replace vendor library directory before recopying SDK XSym aliases;
  copying over an existing symlink otherwise corrupts the real ELF loader.
- Runtime package built and its SHA256SUMS verified. Final firmware build
  completed with repaired loader and read-only MCU probe.

## Final build validation

Release files: output/rebuild-20261008; private recovery backup:
output/backups/lumi-t33gs-10.10.60.133-backup-20261008 (mode 0700).

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| uImage | 1,635,460 | c41a56cf880878a155ed084e4751e49627fbf09ac38d8b86eae8e8fb95461b67 |
| rootfs.squashfs | 4,100,096 | 12f41af589fe4a43f8aa6e4f89508f3ca50403d41dee0f8c002ba62b49787a37 |
| openipc-t33-prj008n-nor-16m.bin | 16,777,216 | 7b672adccf78d48d0caf0c327bde2be390abcfde80aa73d460add9d81be48164 |
| lumi-t33gs-runtime-20261008.tar.gz | 6,819,199 | See release SHA256SUMS |

Checks passed against the actual packed image and extracted SquashFS:

- Entire NOR bytes match the validating packer; uImage CRC, SquashFS v4
  metadata, partition capacities and seeded environment are valid.
- ISP/sensor/audio modules have the matching full kernel vermagic; nested
  AIC modules and modules.dep are present.
- Day/night sensor tuning, hardware.env, motor preparation and boot scripts
  are present; private uClibc loader is an ELF and all SDK symlinks resolve.
- Packed MCU probe is the final read-only version; Majestic is absent.
- 145 shipped shell scripts parse under BusyBox ash; all comment-strip
  checks pass; changed scripts parse and git diff --check passes.

The new firmware has not been flashed or boot-tested. The NOR candidate
erases rootfs_data and seeds a default environment, so it excludes the
existing runtime and Wi-Fi credentials. For an update of this working camera,
preserve boot/rootfs_data/env and update only validated kernel/root partitions.

## Board evidence

Verified host backup: runtime/boot tar matched all six board file hashes;
full partition read is exactly 16 MiB. Private backup is kept separately from
release artifacts. Before reboot boot ID was
d37c7499-4bb4-4ae9-a572-e18545e0bb76; after reboot it is
91188588-de97-4938-84af-a3eb9f28bbfd. Supervisor ready and Wi-Fi returned.
No same-boot IMP restart was used.

Read-only MCU observations at idle and during video:

```text
div_riscv / gate_riscv: 475 MHz
CPM_RISCV: 0x00000001
MCU_CCU_CONTROL[0x122200f0]: 0x00000000 (SDK stop bit31 clear)
MCU_CCU_CONFIG[0x12220000]: 0x0000003f
MCU_CCU_BOOT_VECTOR[0x12220004]: 0x07ffe080
MCU_CCU_IRQ_WORD[0x1222000c]: 0x00000000
word at boot vector: 0x0800006f (RV32 JAL)
```

The MCU is configured to run the ISP's bundled firmware in the final 8 KiB
of reserved ISP RAM. Register state alone is not an independent instruction
execution test. The existing firmware decoded 376 H.265 frames at
2560x1440/25 fps over 15 seconds after reboot. These observations do not prove
the newly built firmware boots or recognize a wake word.

## Wake-word blocker

The local SDK's T32/T33 Zeratul RISC-V guide requires obtaining
riscv_project.7z from vendor support; that project is absent locally. The SDK
ISP archive contains genuine RV32 riscv_vic payload and identifies the actual
MCU CCU at physical 0x12220000: tx_isp_riscv_stop sets bit31 at +0xf0,
tx_isp_riscv_run sets its DDR vector then clears that bit. Physical 0x12700000
belongs to TNPU and cannot be used as this MCU's controller.

Full Zeratul firmware reserves DDR 0x03b78000–0x04000000, currently allocated
to Linux under this board's 96/32 split. A wake-word runtime needs validated
startup/linker and a memory/ISP ownership arrangement before loading it.
No wake-word model or firmware has been built, installed or exercised.


## Heartbeat investigation after integrated-image flash — 2026-10-08

The board at 10.10.60.133 was checked read-only after the integrated firmware
flash. MCU clock is enabled at 475 MHz, stop bit31 is clear, and the boot vector
is 0x07ffe080. The isp_riscv interrupt count remains zero; that does not prove
that the MCU has stopped or that it is executing. No MCU-owned heartbeat
protocol/counter has been established.

The complete local SDK directory was searched, including archive listings:
41 SDK archives opened successfully, with 207483 listing entries. drivers.7z
has 1696 entries and no RISC-V project/source path. There is no riscv_project
archive or unpacked project in the searched SDK. Generic Linux mailbox,
RISC-V architecture and LED-heartbeat files are not firmware for this MCU.

Found:

- resource/tools/riscv_read/riscvread.c: MIPS/Linux reader of the Zeratul
  firmware log buffer; it does not execute on RISC-V or increment a heartbeat.
- resource/tools/zeratul/make_tag/riscv_fw/riscv_fw_PRJ008_sc4336p.bin and other
  precompiled sensor firmware. They are separate Zeratul images, not editable
  source for the active 2264-byte riscv_vic payload bundled in the ISP object.
- The SDK RISC-V debugging guide describes riscv_project sources and a full
  Zeratul memory layout at 0x03b78000..0x04000000. That range overlaps Linux
  under this board's 96/32 split and cannot be loaded into the running camera.
- The ISP object's tisp_g_riscv_info sets a RISC-V enable flag and copies
  parameters; its name does not establish a heartbeat/read-only status API.

The initial archive-listing failure was a host tool issue: launching the local
7-Zip executable through a symlink made it look for 7z.so in the wrong directory.
The temporary host shim was corrected to execute the real binary in its codec
directory. All 41 archives were then listed without errors; the SDK archive
itself is not corrupt. This clarifies the earlier cached-driver workaround.

A real heartbeat still requires the source/build integration for the active MCU
firmware and a defined shared-memory/mailbox ABI, including ownership and cache
visibility. Adding a Linux-only timer, sampling clock/reset or ISP frame IRQs
would not prove RISC-V execution. No counter was fabricated, firmware blob
patched, MCU stopped/reset, or shared memory overwritten during this task.
Heartbeat implementation/board validation remains blocked on that firmware
source and ABI. Existing camera streaming remains running.
