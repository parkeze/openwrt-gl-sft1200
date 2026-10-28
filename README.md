# openwrt-gl-sft1200

OpenWrt for the GL.iNet GL-SFT1200 (Opal), and the ImageBuilders built with
it. OpenWrt 25.12.6 userland on a 6.18 kernel, `siflower/sf19a2890`, profile
`glinet_gl-sft1200`.

Made from [openwrt-device-template](https://github.com/parkeze/openwrt-device-template),
with a different `build.sh`: see "Why not the template's build" below.

## Status

Not built yet, and not booted. The flash map, MACs, ports, buttons, U-Boot's
behaviour and both RGMII delays are from a unit harvested on GL's firmware
4.8.3; what is marked **unverified** is not.

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
| Serial | ttyS0, 115200 8N1, inside the case **(pads unverified)** |
| Power | 5 V over USB-C |

The switch is a GSW150, not the Airoha AN8855 of the Banana Pi BPI-WiFi5,
which shares the SoC. GL's device tree (`sf19a28_fullmask_ac28nand.dts` in
Siflower's 18.06 SDK) and Siflower's switch driver (`sf_eswitch`, `intel7084`)
say so, as does Hans Ulli Kroll's device tree for the board, which first
brought it up on 6.18.

### Flash map

Identical to GL's, so its U-Boot, its recovery and the unit's factory data are
untouched.

| Offset | Size | Partition |
|---|---|---|
| 0x0000000 | 0x20000 | spl-loader (read-only) |
| 0x0020000 | 0x60000 | u-boot (read-only) |
| 0x0080000 | 0x20000 | u-boot-env |
| 0x00a0000 | 0x20000 | factory: base MAC at 0x0, RGMII delay string at 0xb2, Wi-Fi calibration at 0x800 (read-only) |
| 0x00c0000 | 0x400000 | kernel: a raw uImage, of which U-Boot reads only the first 3 MiB |
| 0x04c0000 | 0x7940000 | ubi: rootfs and rootfs_data |
| 0x7e00000 | 0x40000 | log: GL's mtdoops |
| 0x7e40000 | 0x1c0000 | unmapped, as GL leaves it |

eth0 and WAN are the factory base MAC, the one on the label, and LAN the next. The switch's ports are WAN 0,
then 1 for the LAN jack beside it and 2 for the one at the end, with the GMAC
on port 5. GL's firmware calls port 2 LAN 1 and port 1 LAN 2, and so does this
device tree (`lan1`, `lan2`).

U-Boot (2016.07, GL's web failsafe 24.04.11) has an empty environment
partition and boots its compiled-in `bootcmd`: read 0x300000 bytes from
0xc0000, `bootm`. So the kernel has to fit 3 MiB, which the image recipe
checks, and changing the environment from Linux does nothing. The SoC's RGMII delay is the
factory string (`110a` on the harvested unit: TX 0x11, RX 0x0a), and GL's
switch driver clears the switch's own delays on port 5 (PCDU `0xF101` reads 0
on a running unit). Port 5 is `rgmii-id` with both internal delays set to 0:
lantiq_gswip reads a CPU port's mode from the GMAC's side and would give plain
`rgmii` 2 ns each way. The switch answers at SMI address 31 (0x1f) on the
GMAC's own MDIO, and nowhere else: MANU_ID 0x1713, PNUM_ID 0x3003, MII_CFG5
0x4044, read on the unit by bit-banging MDIO on GPIO 28 and 29. Its reset is
GPIO 0, active low. At address 0 mxl-gsw1xx fails its probe with -ENODEV, there
is no DSA and no LAN, and that is how the first flash came up with no
network. Linux has to pulse that reset itself: GL's U-Boot leaves the internal
PHYs one MDIO address up, and without the reset wan has no PHY. With it, wan,
lan1 and lan2 come up at 1 Gbps on a warm reboot and from a cold power-on.

## Why the kernel is 6.18 and the userland is 25.12.6

- **The switch.** GSW150 support is the lantiq_gswip GSW1xx series that
  reached Linux in 7.0, and fixes from 7.4. It is backported to OpenWrt main's
  6.18, with the device tree, SPI NAND and UBI and the NAND image recipe, on
  [The1TrueJoe/openwrt](https://github.com/The1TrueJoe/openwrt) branch
  `siflower-gl-sft1200`, the work meant for upstream. Taking it to 25.12's 6.12
  would also mean every lantiq_gswip change from 6.13 to 6.18 under it.
- **The userland.** A build from OpenWrt main would give this one board a
  different ucode, netifd and fw4 from every other ParkezeOS gateway, and
  main's package feeds change daily.

So `build.sh` builds the v25.12.6 tree with the kernel side grafted in from a
pinned commit of that branch (`devices/glinet_gl-sft1200/graft`):
`target/linux/siflower`, the generic 6.18 patches and config, and
`package/kernel/linux`. The device tree, image recipe and board files are the
upstream work's own, so this repo and the upstream submission describe the
board identically. The
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
2. **Settle what is unverified here**: the serial pads, and whether the
   slide switch's events are wanted for anything.
3. **The first boot is a flash.** GL's firmware has no kexec, and its U-Boot
   netboots only after an interrupt on the serial console, so without serial
   there is no RAM boot. Install `squashfs-factory.img` with GL's U-Boot web
   recovery, below, through its "Update firmware" page only: the same page
   also offers U-Boot and ART uploads. The way back is the same recovery with
   GL's own image. With serial, `initramfs-kernel.bin` boots from RAM first
   and writes nothing: interrupt autoboot (2 s), `tftpboot 0x81000000 <file>`,
   `bootm`.

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
