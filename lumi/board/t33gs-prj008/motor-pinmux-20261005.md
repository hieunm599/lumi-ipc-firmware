# T33gs motor pinmux verification — 2026-10-05

Owner authorized removing the Ethernet mux and then explicitly approved kernel
flash and reboot on `10.10.61.241`, T33gs PRJ008/SC4336. Recovery UART is
`/dev/ttyUSB0`, 115200; the owner's picocom session retained the console.

## Change and build

The board fragment disables `CONFIG_JZ_MAC`. The SDK's `GMAC_PORTB` mask
`0x0001efc0` overlaps all eight OEM motor GPIOs, 38–43, 45 and 46.
The source-owned helper `overlay/usr/sbin/lumi-t33gs-motor-gpio-init` requests
each motor GPIO, selects output-low, reads back low and releases its claim.
It skips already exported pins, reports failures and retains claims if low
cannot be verified. `S35board` calls the helper before peripheral bring-up.
The helper does not step a motor or enable a PTZ adapter.

Built the staged patched SDK kernel with GCC 5.4/uClibc using its existing final
kernel config merged with the board fragment. The config diff only disables
MAC and dependent PHY/MAC options. Explicit `uImage.lzma` build passed; unused
vendor image variants failed on a relative hard-LZMA script in the initial
all-image invocation and were not used. Linux/MIPS/kernel/LZMA header and data
CRCs passed. `jz_mac_probe` and `synopGMAC_reset` are absent from the new ELF.

Candidate: 1,635,935 bytes, SHA256
`6bd59cb3010cab4eb66e5e8e909f4fa9d738090cece4fb89fdedb51a32996021`.
The live kernel partition is 2,621,440 bytes with 32 KiB erase blocks.

## Backup and activation

Private artifacts and verified backups are in the sibling streamer's ignored
`target/artifacts/t33gs-motor-pinmux-20261005/` directory. Full previous kernel
partition SHA256:
`2308d7e71d7f4d21f54f9946b9841ea7b3d37676b5a7ccc7ccbee2ee563e3370`.
The original S35board and supervisor wrapper were also backed up on the host.

Only `/dev/mtd1` was flashed. `flashcp -v` completed erase/write/verify, and an
independent readback of the image length matched the candidate hash. Boot,
rootfs, environment, streamer binaries and vendor modules were not rewritten.

The existing rootfs is read-only SquashFS; attempting to install S35board there
failed without changing it. Instead, the identical source helper was installed
under `/overlay/lumi-ipc-streamer/bin/`. The existing supervisor wrapper gained
one helper invocation before its original exec; all existing environment settings
were preserved. Helper SHA256:
`c443c7b5951f71a855db0c5ca945eb7496169c2c3968c0c6904cf4f900b39c14`.
Installed wrapper SHA256:
`dae5eed8a8d083c80168e59884ddefb4b135b7b77a1a2a9e86fd0b58f4da5222`.

An interrupted SSH installation did not apply; the owner manually rebooted and
the new kernel came back. Direct authenticated SSH then installed and synced
the helper/wrapper, verified GPIO state, and issued a separate controlled reboot.

## Observed after the final reboot

- Kernel: `3.10.14__isvp_goat_1.0__ #2`, built Oct 5 at 20:50:09 +07.
- Boot ID: `82d387ab-8d04-4005-955e-a56c8028ad8c`.
- Bank B registers: INT `0x10000000`, MASK `0xee006fc0`, PAT1 `0xe2000000`,
  PAT0 `0x14000000`. All eight motor pins decode as GPIO output-low.
- Motor GPIO claims released; existing SD/Wi-Fi GPIO consumers remained.
- No GMAC reset failure, function-redefinition, unknown-symbol, invalid-module,
  OOM or kernel-panic lines appeared in the targeted log check.
- Existing ISP, SC4336, audio, AIC8800 and firmware-loader modules loaded.
- Native health ready; v1 health ok. Supervisor/core/services/RTSP/P2P/relay
  startup reported ready/running.
- FFmpeg decoded 25 frames each via RTSP/TCP: main 2560×1440/25 and second
  1920×1080/25. Both inputs advertised PCMA 8 kHz mono; microphone waveform
  and speaker playback were not re-tested in this rollout.
- A bounded pan +32 halfstep retry completed with 128 matching GPIO readbacks,
  low cleanup and released ownership; no mux warning. The owner reported no
  visible movement or audible response. Motor motion is not validated.
- Public PTZ capability remains `supported=false`, `reason=no adapter`.

BusyBox syntax checks passed for source/device scripts and stripped source.
Shared shell/strip, CI matrix, workflow shell and Kconfig graph checks passed.
An unrelated existing sysupgrade host test stalled and was terminated; it is
not counted as passing and was not used to flash this kernel.

This validates removal of the Linux GMAC claim and persistent GPIO preparation.
It does not establish coil current, complete physical phase order, direction,
mechanical limits, homing or a working public motor-control API.

## Horizontal motor wire measurements

The owner subsequently identified all four measured wires as belonging to the
horizontal motor. The common supply and inactive phase wires measured 4.8 V
to board GND. Each isolated GPIO activation pulled the corresponding wire to
0.2 V:

| GPIO | SoC pin | Motor wire |
| --- | --- | --- |
| 42 | PB10 | Black |
| 43 | PB11 | Yellow |
| 45 | PB13 | Brown |
| 46 | PB14 | Blue |

Black and yellow were also observed returning to 4.8 V after release. These
measurements confirm horizontal channel associations, not winding phase order
or coil current. Earlier yellow-wire observations before mux cleanup did not
establish a switching association and are superseded by these measurements.

The owner manually rebooted between measurements; this was not evidence of a
reset caused by coil load. Startup rechecks retained the new kernel and all
eight inputs low. Final measured boot ID was
`87382854-6c9b-4d5a-b159-e99155cdf481`.

An additional bounded horizontal trial used the exact OEM phase masks and
128 halfsteps at 20 ms per phase (about 2.6 seconds). All 512 GPIO readbacks
matched and cleanup verified low/released. The owner reported complete silence
and no visible motion. Requested resistance measurements from common to each
phase with power off and the motor disconnected to establish winding continuity.
