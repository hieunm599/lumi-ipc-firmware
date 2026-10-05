# T33gs / T33 / PRJ008 peripheral notes

This is a bring-up map for the T33gs SK032T4 camera observed on Ingenic T33 /
PRJ008. The older TINA runtime's T33 target is a different board; its board
specific wiring and sensor assumptions do not apply here.
It records values from its vendor boot log and the matching PRJ008 SDK source.
It is not a complete board schematic. In particular, GPIO numbers printed by
the vendor bootloader are legacy Ingenic GPIO IDs; do not treat them as Linux
gpiochip offsets or drive them until their active level and electrical role
have been checked on the board.

## Confirmed from the camera boot log

| Peripheral | Observed value | Notes |
| --- | --- | --- |
| SoC | T33, chip ID `0x10033004` | Board identifies as `PRJ008`; 128 MiB DRAM, 16 MiB NOR. |
| Image sensor | SmartSens SC4336, I2C address `0x30` | Vendor driver reports `gate_i2c0`, 2560x1440 at 30 fps. |
| SD card power | Legacy GPIO 59, driven low during U-Boot init | Polarity and whether low means powered are not established. Current `mmcblk0` enumerates as a raw all-`0xff` device with no partition table/filesystem; recording is unavailable. |
| IR-cut | GPIO 66=BIN, GPIO 67=AIN for the board's LK6208; both idle low | Owner visually confirmed BIN high / AIN low for 200 ms clears the pink cast. Reverse/night movement is not validated. |
| PTZ motors | Legacy GPIOs 38, 39, 40, 41, 42, 43, 45, 46 initialized low | Vendor application also uses TCU channel 2; motor driver/mapping is not in this OpenIPC image. |
| USB Wi-Fi / Bluetooth | AIC8800D80 USB device | The matching module/firmware load on this board. Wi-Fi connects and the flashed S61 watcher restores route/services after link loss; public relay still needs identity credentials. |
| Audio | Ingenic internal codec, I2S | PRJ008 OSS3 microphone and PCMA RTSP are board-validated; capture defaults off. Playback adapter is deployed but disabled pending amplifier path/polarity and audible-output validation. |
| Video engine | `soc_vpu` and TNPU probe in vendor image | The SDK kernel config enables PRJ008 VPU/IPU support. |

## User-provided board pin labels (2026-10-02)

The board owner supplied these pin labels and numbers: MICPL is pin 47,
MICNL pin 48, HPOUTL pin 50, SPEAK_EN pin 52, and IR control pins 92/93.
The owner clarified that SPEAK_EN is active high, and corrected the IR driver:
pins 92/93 are BIN/AIN on one LK6208. Pins 92 and 93 map to PC02 and PC03 on
the T33-compatible QFN96 pin map, corresponding to Linux GPIO offsets 66 and
67; this matches the IR-related GPIOs observed in the boot log. Pin 52 is a
package pin reference and has not yet been mapped to its Linux GPIO offset, so
the OSS3 module continues to use `spk_gpio=-1`.

The owner specified a 200 ms actuation pulse. On the live T33gs, AIN high / BIN
low did not correct the pink image. BIN high / AIN low for 200 ms moved the
filter to its natural-color position; the owner confirmed the pink cast was
gone. Both lines returned low after each pulse. The opposite optical position
(AIN high / BIN low) has not been visually confirmed.

The T33gs streamer adapter now sets both lines to output/idle low, pulses BIN
for 200 ms when opening the video pipeline, and returns both lines low. ISP
running-mode changes also request the corresponding physical pulse. Day was
validated on the board; Night is wired as the inverse direction but remains
unvalidated and is exposed as such in capability metadata.

## Drivers available in this build

- I2C controller 0 and 1 are enabled. The selected PRJ008 SDK pin option for
  I2C0 is PA12/PA13; I2C1 is PA14/PA15. These are SDK pinmux selections, not a
  claim that either bus has been electrically verified on this camera.
- `CONFIG_I2C_CHARDEV=y` is enabled, so Linux can expose `/dev/i2c-*` once the
  kernel is rebuilt and booted. The previous `Device not found` from `ipctool`
  was because that interface was missing from the initial kernel build.
- `CONFIG_MFD_JZ_TCU=y` is enabled. The SDK has its TCU driver, matching the
  vendor kernel's TCU channel-2 PTZ messages.
- The PRJ008 SDK has VPU/IPU drivers and they are selected by the board kernel
  configuration. This does not provide the vendor camera application or ISP
  tuning by itself.
- The SDK tree used for this build does not contain an SC4336 kernel sensor
  driver or AIC8800D80 Wi-Fi driver source. The original firmware loads those
  proprietary drivers and firmware from its own root filesystem; they cannot
  be enabled from the source currently used here.
- The SDK includes `pwm-ingenic`, but enabling it requires selecting the exact
  PWM channel pads. The boot log only says PWM2 is configured; it does not
  identify which pad is wired to the board, so PWM pinmux is intentionally not
  selected yet.
- `CONFIG_SOUND` is off, but the SDK provides a separate PRJ008 OSS3 audio
  module (`driver-source/drivers/audio/oss3`) and an internal-codec driver.
  The module builds against the current 3.10.14 T33 kernel and registers a
  custom `/dev/dsp` ioctl interface. It does not use the ALSA PCM userspace
  ABI. The image builds and stages this module. On the flashed T33gs image,
  microphone samples, PCMA RTSP audio, and privacy stop/restart have been
  validated. Capture remains disabled in saved config by default. Speaker GPIO
  52 is now configured active high from the owner-provided wiring; audible
  playback and the HPOUTL amplifier path still require board validation.

## Safe first checks on the running board

After booting the image with I2C character-device support, inspect
`/dev/i2c-*` and use `ipctool i2cdetect -b 0` (or `i2cdetect -y 0` if the
standard utility is installed). A response at `0x30` would confirm the sensor
is visible on that Linux bus. A scan that finds no device does not prove the
sensor is absent: the camera may use a different pinmux/bus mapping or require
sensor power/clock sequencing first.

Do not export/toggle the GPIOs in the table as part of discovery. Establish
their Linux offsets and electrical levels first; the motor and IR-cut lines
can move the camera or energize coils.

## OEM day/night versus physical IR-cut (2026-10-02)

Static inspection of the extracted matching OEM app (`gsgl_t33n_tuya_app`,
SHA-256 `d6d05204185246b3b11e1d3d287ea725cb73e996715ef06e882530bef9ba457d`)
does not establish the physical IR-cut wiring. Its `device_profiles.ini`
(SHA-256 `b181efee0556f72c2ab711d8959a1f26b43f53b5fc1410b6993df1d0519cfeea`)
sets `IRCut=auto`, but the app's `set_ircut_switch(0/1)` only dispatches to
`set_sensor_day_mode` / `set_sensor_night_mode`. Those functions call
`IMP_ISP_Tuning_SetISPRunningMode` with day/night mode values. They do not
identify GPIO 66/67 or show a coil-polarity sequence. The OEM's night-vision
policy therefore proves an ISP scene switch, not that the mechanical filter
was moved.

The staged PRJ008 SDK's `IMP_ISP_GPIOSwitchAttr` API can configure external
GPIO switching, but its existence does not map the filter pins. The sensor
header describes `switch_gpio` as the MIPI switch for a multi-camera setup;
the T33gs adapter's PA25 assignment is that sensor-switch field and must not
be reused as an IR-cut control. Keep physical IR-cut disabled until the board
control sequence (day/night states and pulse timing) is established for the
owner-mapped pins 92/93.
An ISP day/night control can be implemented as a separate capability if its
effect is tested on this board; do not label that control IR-cut. The streamer
now exposes the same ISP day/night running-mode API separately. A T33gs board
check set Night and Day through the PRJ008 IMP API while `/main` had an active
RTSP lease; hardware readback matched both changes. This does not prove that
GPIO 66/67 or the filter mechanism moved. The runtime API stays gated unless
`/overlay/lumi-ipc-streamer/isp-mode.conf` is root-owned, mode 0600, and
contains the literal `enabled`.

The staged SDK's `sample_motor` source has version string `H20240720a`, also
present in the OEM `t33n_motor.ko`, but its sample header assigns phases to
PB19–PB22 and PC11/PC12/PC15/PC16. Do not use that sample mapping unchanged.
Direct inspection of the exact OEM module's `motors_pdata` data
(SHA-256 `7c31dd08fde7cc11fe1cc6dd22b69a66ef8bbae83a62f6b85a63ad373e9a30fd`)
shows horizontal phases A–D on legacy GPIOs 42, 43, 45, 46 and vertical phases
A–D on 41, 40, 39, 38. This agrees with the eight PTZ-related lines in the
OEM U-Boot log and establishes their logical axis/phase mapping. The module is
not present in the OpenIPC runtime, and this mapping does not validate the
current motor driver's electrical levels, motion limits, or a Linux PTZ API.
Keep PTZ disabled until a source-matched driver and bounded motion behavior
are validated on T33gs.

### Speaker-enable candidate GPIO (2026-10-02)

The extracted matching OEM `app_init.sh` (SHA-256
`cc2b1b4ed035512e75998ce95c942f9c7cfce6ad8bfc012ea0be610edcf1e3ed`)
sets legacy GPIO 63 low before loading `audio.ko` with `spk_level=-1`. In the
staged PRJ008 SDK source `driver-source/drivers/audio/oss3/inner_codecs/PRJ008/codec.c`
(SHA-256 `6ac55b1ec5aa461895ad46dbc1d88a7a5fa4dbc9994047cfb85e03fb5b4495d1`),
the default `spk_gpio` is `GPIO_PB(31)` (legacy GPIO 63), and the codec driver
requests that line for speaker control. This was a candidate based on the OEM
driver only; the board owner has since identified package pin 52 as SPEAK_EN
and confirmed active-high polarity. The package pin's GPIO mux/offset remains
unmapped, so T33gs startup keeps `spk_gpio=-1`. HPOUTL and audible output
remain to be validated.

### Current OpenIPC Linux GPIO ownership (2026-10-02)

Read-only `/sys/kernel/debug/gpio` inspection on T33gs reports GPIO A 0–31,
GPIO B 32–63, and GPIO C 64–95. Linux currently owns GPIO 59 as `SDHCI EXT
PWR` (output low), GPIO 60 as `SDHCI EXT CD` (input low), and GPIO 72 as a
sysfs output low. GPIOs 66/67 and the U-Boot-listed PTZ lines 38–43, 45, and
46 have no Linux consumer in this boot. This identifies Linux offsets and
current ownership only; it does not establish the electrical IR-cut driver,
coil polarity, or motor-board net mapping.

### OSS3 playback path audit (2026-10-02)

The matching PRJ008 OSS3 source does implement a private playback ABI on
`/dev/dsp`: `AMIC_AO_SET_PARAM`, `AMIC_AO_ENABLE_STREAM`,
`AMIC_AO_SET_STREAM`, `AMIC_AO_SYNC_STREAM`, and
`AMIC_AO_DISABLE_STREAM`. This is not the standard ALSA PCM ABI. Its codec
playback path enables the internal DAC and, when a speaker GPIO is configured,
drives that line to `spk_level` on enable and the inverse on disable. The SDK
defaults are legacy GPIO 63 and active-high level 1.

A live read-only T33gs check found `audio.ko` loaded, `/dev/dsp` present, and
module parameters `spk_gpio=-1`, `spk_level=1`; no ALSA sound card is registered.
This records the pre-update running state. It confirms an OSS3 playback API exists,
but not that board speaker wiring, amplifier polarity, sample format, or audible
output is correct. The T33gs runtime now has a matching `AudioPlayback`
adapter, cross-built and deployed behind the existing disabled talkback policy.
The deployed playback adapter has not submitted audio. Keep talkback
disabled until the board path is confirmed and output can be tested through the
actual speaker; see the streamer's
[`OSS3 adapter validation record`](../../../../lumi-ipc-streamer/harness-docs/evidence/t33gs-oss3-playback-adapter-20261002.md).

## OpenIPC T33gs image observation (2026-09-28)

On the experimental NOR image with kernel build `#16`, Linux registered I2C
adapters 0 and 1, and `/dev/i2c-0` and `/dev/i2c-1` were present. Both
`tx_isp_PRJ008` and `sensor_sc4336_PRJ008` were loaded. Running the SDK-based
probe caused the SC4336 driver to read chip-ID bytes `0xdc` and `0x42` from
address `0x30` on `gate_i2c0`; the kernel logged `Sensor chip found` and
created frame channels 0–2. This confirms the sensor is electrically
reachable on I2C0 with the selected reset/MCLK setup.

The userspace SDK call `IMP_ISP_AddSensor` then returned `-4089`, so sensor
detection is confirmed but successful ISP registration and video capture are
not. No `/dev/video*` node appeared. The Ethernet MAC also failed reset and
there was no `eth0`; USB showed only its root hub, with no attached Wi-Fi
device, and no MMC block device was present. These results do not establish
that those peripherals are absent from the board; their drivers, power
sequencing, or pinmux still need bring-up.

## `libimp` capture bring-up (2026-09-29)

The running image lacked `/etc/sensor/sc4336-PRJ008-day.bin` and
`sc4336-PRJ008-night.bin`. A uClibc-linked probe returned `-4089` from
`IMP_ISP_AddSensor` until both matching bins were staged and supplied through
`IMP_ISP_SetDefaultBinPath`. With those paths and the SDK initialization order,
`IMP_ISP_AddSensor`, `IMP_ISP_EnableSensor`, `IMP_System_Init`, ISP tuning,
FrameSource channel setup, stream-on, `GetFrame`, and `ReleaseFrame` all
returned success. The returned buffer was 2560x1440 NV12, 5,529,600 bytes, but
all 20 sampled frames contained only zero bytes.

Kernel ISP counters identify the active image's route configuration as the
remaining capture fault: `direct_mode=1` and `ivdc_mem_line=810` produced 102
ISP frame starts, zero completed frames, and 102 DDR UV overflows. The SDK
module defaults are `direct_mode=0` and `ivdc_mem_line=0`; the original camera
startup also loads TX-ISP without overriding these parameters. The T33gs board
startup was changed to use the SDK defaults, and the build installs the
matching SC4336 day/night bins. On the subsequently flashed image,
`t33-frame-probe` initialized the ISP and returned three nonzero 2560x1440
frames, each 5,529,600 bytes. Five sample offsets per frame changed across
frames, confirming live data delivery. The channel was requested as NV12, but
the returned `pixfmt` field was `0` (the SDK header labels that YUV420P); the
actual plane layout still needs confirmation before wiring it into a streamer.
The probe uses one FrameSource buffer; reading every byte of a frame exhausted
available RAM and triggered the OOM killer, so it samples sparse offsets
instead. Sustained capture and encoder throughput remain untested.

## DRAM split validation (2026-09-30)

U-Boot reports 128 MiB DRAM. The original bootargs exposed 64 MiB to Linux and
reserved the upper 64 MiB for TX-ISP. An 80/48 MiB trial booted and streamed.
The split was then changed to `mem=96M@0x0 rmem=32M@0x6000000`. Linux reported
`MemTotal` 92,268 KiB, up from 59,804 KiB. TX-ISP initialized at the new
reserved base `0x06000000`; the SC4336 streamer delivered direct Wi-Fi H.264
packets with 32,360 KiB free after a short session and no OOM or high-order
allocation failure in that boot. Only the U-Boot environment partition was
updated; the firmware image was not reflashed.
Wi-Fi required manual `ifup wlan0` after reboot. A long capture soak remains.

## IMP SDK still-image and overlay API inventory (2026-09-30)

The exact staged PRJ008 `libimp.so` exports `IMP_Encoder_InputJpege`,
`IMP_FrameSource_GetFrame` / `IMP_FrameSource_ReleaseFrame`, and the IMP OSD
entry points `IMP_OSD_CreateGroup`, `IMP_OSD_CreateRgn`,
`IMP_OSD_RegisterRgn`, `IMP_OSD_SetRgnAttr`, and `IMP_OSD_Start`. Their symbols
and matching headers are present in the firmware SDK output. This confirms the
userspace API surface exists; it does not prove JPEG capture or OSD rendering
works on the SK032T4 board.

The SDK header describes `IMP_Encoder_InputJpege` as taking NV12, while an early
frame probe observed pixel-format value 0, which that SDK header names YUV420P.
The runtime snapshot path therefore uses `IMP_FrameSource_SnapFrame` on its
own bounded 640×360 channel and validates the JPEG bounds/markers. OSD symbols
exist in the SDK, but rendering and placement remain unvalidated on this board.

## Still capture follow-up (2026-09-30)

The staged PRJ008 IMP header documents `IMP_FrameSource_SnapFrame` as a direct
snapshot operation on an enabled FrameSource channel. It accepts NV12 or
YUYV422 output at the channel's configured resolution and writes into a
caller-owned buffer. The SDK also exports `IMP_Encoder_InputJpege`, documented
for external NV12 input with even dimensions and a 16-byte aligned stride.

### Validation update (2026-10-02)

The streamer now captures JPEG using a temporary 640×360 FrameSource channel,
repacks the returned NV12 planes into the JPEGe input layout, enforces a 1 MiB
bound, and closes the channel after each capture. Board validation decoded the
JPEG at 640×360 while `/main` and `/second` were running. Three consecutive
captures succeeded, then the feature was made persistent via the S60 startup
environment and revalidated after a rootfs-only flash and reboot. The public
API is loopback-only at port 18080. Sustained snapshots and longer memory soak
are still open; do not infer OSD support from the JPEG path.

## Persistent Wi-Fi streamer startup (2026-09-30)

The rootfs overlay's `S60lumi-streamer` waits for `/overlay`, wlan0 IPv4,
and supervisor readiness. `S61lumi-streamer-watch` then retries late service
startup, stops the runtime if wlan0 loses its IPv4 address, restarts it when
the address changes, and retries after supervisor exit. This is needed because
RTSP binds to the current wlan0 address. The network watcher and recovery path
have not yet been checked through an actual Wi-Fi disconnect/reconnect cycle
on this camera.
