# openwrt-gl-sft1200

OpenWrt for the GL.iNet GL-SFT1200 (Opal), and the ImageBuilders built with
it. OpenWrt 25.12.6 userland on a 6.18 kernel, `siflower/sf19a2890`, profile
`glinet_gl-sft1200`.

Made from [openwrt-device-template](https://github.com/parkeze/openwrt-device-template),
with a different `build.sh`: see "Why not the template's build" below.

## Status

Not built yet, and not booted. No unit has been harvested; everything below
marked **unverified** is read from GL.iNet's and Siflower's sources, not a
board.

## The GL-SFT1200

| | |
|---|---|
| SoC | Siflower SF19A2890, four MIPS interAptiv cores with FPU (`mipsel_24kc_24kf`) |
| RAM | 128 MiB |
| Flash | 128 MiB SPI NAND, 128 KiB blocks, 2 KiB pages |
| Ethernet | MaxLinear GSW150 switch on the GMAC's RGMII: one WAN, two LAN, gigabit |
| USB | one 2.0 host port |
| Buttons | reset on GPIO 27, a slide switch on GPIO 1, both active low |
| Light | an ET6326 LED driver on I2C at 0x30, not driven yet |
| Wi-Fi | Siflower's own radios, vendor FullMAC driver only; off |
| Serial | 115200 8N1, inside the case **(pads unverified)** |
| Power | 5 V over USB-C |

The switch is a GSW150, not the Airoha AN8855 of the Banana Pi BPI-WiFi5,
which shares the SoC. GL's device tree (`sf19a28_fullmask_ac28nand.dts` in
Siflower's 18.06 SDK) and Siflower's switch driver (`sf_eswitch`, `intel7084`)
say so, as does Hans Ulli Kroll's device tree for the board.

### Flash map

Identical to GL's, so its U-Boot, its recovery and the unit's factory data are
untouched.

| Offset | Size | Partition |
|---|---|---|
| 0x0000000 | 0x20000 | spl-loader (read-only) |
| 0x0020000 | 0x60000 | u-boot (read-only) |
| 0x0080000 | 0x20000 | u-boot-env |
| 0x00a0000 | 0x20000 | factory: MAC addresses **(offsets unverified)** (read-only) |
| 0x00c0000 | 0x400000 | kernel: a raw uImage, where GL's U-Boot loads it from |
| 0x04c0000 | 0x7b40000 | ubi: rootfs and rootfs_data |

## Why the kernel is 6.18 and the userland is 25.12.6

- **The switch.** GSW150 support is the lantiq_gswip GSW1xx series that
  reached Linux in 7.0. Hans Ulli Kroll carries it on 6.18, with the DSA core
  and tag changes it needs, SPI NAND, I2C and USB for the SoC
  ([ulli-kroll/openwrt](https://github.com/ulli-kroll/openwrt), branch
  `openwrt-siflower/v6.18/sf19/master`). Taking it to 25.12's 6.12 would also
  mean every lantiq_gswip change from 6.13 to 6.18 under it.
- **The userland.** A build from OpenWrt main would give this one board a
  different ucode, netifd and fw4 from every other ParkezeOS gateway, and
  main's package feeds change daily.

So `build.sh` builds the v25.12.6 tree with the kernel side grafted in from a
pinned commit (`devices/glinet_gl-sft1200/graft`): `target/linux/siflower`,
the generic 6.18 patches and config, and `package/kernel/linux`. The
ImageBuilder takes userland from the 25.12.6 release's `mipsel_24kc_24kf`
feeds and carries the kernel and every kmod itself.

## Why not the template's build

The template adds a device to a target the release builds, and installs every
kmod from downloads.openwrt.org after checking the vermagic. `siflower/sf19a2890`
is source-only in 25.12: no ImageBuilder, no `config.buildinfo`, no kmods. So
this `build.sh` writes the configuration itself (`ALL_KMODS`, the release's
version and repository), takes the feeds from another 25.12.6 target's
`feeds.buildinfo` (they are the same commits), and adds every package built
for the target to the ImageBuilder's `packages/`, removing the target's lines
from its `repositories`.

## Building

```bash
./build.sh 25.12.6 siflower sf19a2890 out
```

Linux, on a case-sensitive filesystem, with
[OpenWrt's build dependencies](https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem).
`out/` receives the ImageBuilder, `initramfs-kernel.bin`, `squashfs-factory.img`,
`squashfs-sysupgrade.bin` and `sha256sums`.

## Before anything is written to a unit

1. **Harvest it, from GL's own firmware.** Over SSH, with GL's 18.06 running:

   ```sh
   cat /proc/mtd
   for i in 0 1 2 3 4 5 6; do [ -e /dev/mtd$i ] && nanddump -f /tmp/mtd$i.bin /dev/mtd$i; done
   cp /sys/firmware/fdt /tmp/fdt.dtb
   hexdump -C -n 2048 /dev/mtd3          # factory: the MAC offsets
   cat /sys/kernel/debug/gpio
   swconfig dev switch0 show 2>/dev/null; ip link
   ```

   Copy every file off the unit. The factory partition is the one thing a
   reflash cannot bring back.
2. **Settle what is unverified here**: which physical port is `wan`, `lan1` and
   `lan2`, the MAC offsets in `factory`, and the RGMII delay. GL's tree sets
   `delay = <0x17 0x17>`; this one leaves the SoC's delay registers alone and
   relies on `rgmii-id`, as Kroll's working tree does.
3. **Boot from RAM first**, if the serial console is reachable:
   `initramfs-kernel.bin` from U-Boot (`tftpboot` then `bootm`) writes
   nothing. Then install `squashfs-factory.img` with GL's U-Boot web
   recovery, below.

## Recovery

GL's U-Boot web recovery, per GL's
[debrick guide](https://docs.gl-inet.com/router/en/4/faq/debrick/): a cable
from a computer at 192.168.1.2 to a LAN port and nothing else connected; hold
reset while powering on until the blue light has flashed five times and turns
solid white; then browse to `http://192.168.1.1`. It writes GL's own U-Boot
firmware back (from <https://dl.gl-inet.com/>) as readily as it writes
`squashfs-factory.img`. The bootloader partitions are read-only here and
nothing in this repo writes them.

## Licence

GPL-2.0, as OpenWrt. The device tree is `GPL-2.0-or-later OR MIT`.
