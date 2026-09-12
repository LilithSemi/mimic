# Hardware

The tested target is an OrangeCrab r0.2 with a Lattice ECP5 25F. Mimic uses
the OrangeCrab USB connection for the runtime and a separate JTAG programmer
for configuration.

## OrangeCrab signals

| Signal | ECP5 site | Direction at Mimic | Function |
| ------ | --------- | ------------------ | -------- |
| `clk` | A9 | input | 48 MHz board oscillator. |
| `reset_n` | V17 | input | Active-low OrangeCrab reset button. |
| `usb_dp` | N1 | bidirectional | Full-speed USB D+. |
| `usb_dm` | M2 | bidirectional | Full-speed USB D-. |
| `usb_pullup` | N2 | output | USB device pull-up control. |
| `led_g` | M3 | output | SD activity indication. |
| `sd_clk` | K1 | input | Clock from the device under test. |
| `sd_cmd` | K2 | bidirectional | SD command and response. |
| `sd_dat0` | J1 | bidirectional | 1-bit SD data and busy. |
| `sd_dat1` | K3 | input with pull-up | Held idle in 1-bit mode. |
| `sd_dat2` | L3 | input with pull-up | Held idle in 1-bit mode. |
| `sd_dat3` | M1 | input with pull-up | Held idle in 1-bit mode. |

The generated LPF enables pull-ups on CMD and DAT0 through DAT3. It enables a
pull-down on CLK. DAT1 through DAT3 do not carry data in the current design.
They still need stable high levels because some hosts inspect all four data
lines for busy state.

## Bench setup

The setup needs these connections:

1. Connect DirtyJTAG to the OrangeCrab JTAG header and to the host computer.
2. Connect the OrangeCrab USB port to the host computer. This port becomes
   the `1209:10c1` Mimic runtime device after configuration.
3. Connect the OrangeCrab microSD signals to the SD slot of the device under
   test. Keep CLK, CMD, DAT0, DAT1, DAT2, DAT3, and ground connected.
4. Connect the debug UART of the device under test when boot logs are needed.
5. Power the boards from their normal supplies.

Do not connect two active drivers to an SD line. Mimic acts as the card. The
device under test acts as the host and supplies the SD clock.

## Reference device

The current end-to-end test device is the Nix Vegas Badge V2. It uses an
SG2000 Duo S system-on-module. The badge itself is not a Milk-V Duo S board.
Use the badge debug USB port for its SG2000 UART.

The current compatibility setup uses 1-bit SD operation and single-block
transfers in U-Boot and Linux. See [status.md](status.md) before changing
either setting.

## Retargeting

`devices.nix` declares the build targets. An FPGA entry gives a board, part,
package, and pin source. A PDK entry gives an ASIC process target. The current
target packages are:

| Package | Kind | Output |
| ------- | ---- | ------ |
| `orangecrab-25f` | FPGA | Generated RTL and build files. |
| `orangecrab-25f-bitstream` | FPGA | Flashable `MimicSoC.bit`. |
| `sky130-hd` | PDK | Generated SkyWater 130 nm high-density IP. |
| `gf180mcu-3v3` | PDK | Generated GlobalFoundries 180 nm 3.3 V IP. |

The generator also accepts a Harbor board name with `--board`. It accepts an
FPGA part with `--target vendor:device:package` and repeated `--pin
name=site` options. An ASIC target uses `--target pdk:variant` with
`--pdk-root`. A new FPGA target must supply every exposed pin and a 48 MHz
clock plan.

The present silicon proof is OrangeCrab only. A generated design for another
part is not a verified hardware target.
