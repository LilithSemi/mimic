# Mimic PCB

This directory contains the hardware design for the Mimic SD emulator. The
design is an early development baseline and is not ready for fabrication.

The hardware design files under this directory are licensed under the CERN
Open Hardware Licence v1.2. See [LICENSE](LICENSE). The third-party KiCad
library files under `third_party/gkl/` retain their MIT license.

## Development

Enter the PCB development shell and open the project:

```text
nix develop .#pcb
kicad pcb/mimic.kicad_pro
```

Build the fabrication and review outputs:

```text
nix build .#mimic-pcb
```

The build produces Gerber and drill files, a schematic PDF, and DRC and ERC
reports. Review the reports before fabrication.

## Design status

The current files establish a known OrangeCrab r0.2 baseline in a current
KiCad format. Planned Mimic changes include removal of the DDR3L subsystem and
adaptation of the SD connection for use as an emulated card interface.

## USB PHY

U14 is a Microchip USB3320C ULPI PHY. It connects the USB-C port to the
FPGA. The PHY is on the bottom side because the QFN-32 does not fit between
the BGA and the USB-C receptacle. The ID pin is not connected, so the PHY
operates as a B-device.

The PHY connects to these nets:

- DP and DM go from the USB-C receptacle through the U13 ESD part to pins
  18 and 19.
- VBUS (pin 22) receives VSYS through R43 (10k).
- RBIAS (pin 24) connects to GND through R42 (8.06k 1%).
- VBAT, VDD33, VDDIO and REFSEL0 to REFSEL2 connect to +3.3 V. REFSEL = 111
  selects a 24 MHz reference clock.
- VDD18 (pins 28 and 30) connects to the +1.8 V rail.
- CPEN, SPK_L, SPK_R, N/C, XO and ID are not connected.

### Clocks

OSC1 is a 24 MHz 3.3 V oscillator. Its output net REF_CLK goes to FPGA ball
K16 (PCLKT2_0) and to the PHY REFCLK pin. The PHY supplies a 60 MHz ULPI
clock on CLKOUT. This clock goes through R44 (33 ohm, near the PHY) to FPGA
ball J16 (PCLKT2_1).

### 1.8 V rail

U15 is an NCP115 1.8 V LDO. It uses the same footprint and the same enable
net as the 2.5 V LDO (U10). Its input is VSYS (USB VBUS, 5 V), so the
1.8 V rail does not wait for the 3.3 V rail. C89 (4.7 uF) is on the VSYS input
and C90 (4.7 uF) is on the 1.8 V output. The PHY is the only load on this
rail.

### Review items

Examine these items before fabrication:

- DP/DM pair. The coupled part on F.Cu has 0.22 mm traces with a 0.12 mm
  gap above 0.21 mm of 7628 prepreg (JLC04161H-7628 stack-up). An IPC-2141
  estimate gives approximately 91 ohm differential. Confirm the impedance
  with the fabricator calculator.
- Power order. DS00001792A section 5.5.3 requires VDD18 to be stable
  before VDDIO. U15 takes VSYS and both regulators share the EN net, so the
  LDO is expected to reach 1.8 V before the 3.3 V buck ends its soft
  start. Measure this order on the first boards.
- VSYS capacitance. VSYS has 24.7 uF (C6, C7 and C77). This is more than
  the 10 uF limit for a USB device. The value comes from OrangeCrab and
  this change does not touch it.
- USB return path. The DP/DM pair changes from F.Cu (In1 GND reference) to
  B.Cu (In2 3.3 V reference) at the vias beside U13. C91 (100 nF) beside
  these vias connects 3.3 V to GND for the return current.
- REFSEL straps. REFSEL0, REFSEL1 and REFSEL2 must all connect to +3.3 V
  (111, 24 MHz).
- VDD18 decoupling. C86 and C87 (100 nF) must be near pins 28 and 30.
- CLKOUT strap. The PHY reads CLKOUT at reset. R46 (10k) holds CLKOUT low.
  The FPGA ball J16 (PR23A/PCLKT2_1) is a bidirectional I/O. The gateware
  uses it as an input with PULLMODE=NONE, so it does not pull CLKOUT high.
- RESETB hold. R45 (10k) holds RESETB low until the FPGA drives
  ULPI_RST_N.
- PHY ID. The ID pin is not connected, so the board is a B-device only.
- PHY side. U14 is on the bottom side. Make sure that the assembler can
  place parts on both sides.
- Exposed pad. The EP of U14 has 4 GND vias in the pad. Tell the
  fabricator to tent or plug these vias to keep the solder in the pad.
- U13 jumper pad groups. The board file gives U13 the entry
  `jumper_pad_groups ("1" "6") ("3" "4")`. This entry tells DRC that DP
  and DM go through the USBLC6 between these pads. Make sure that the
  entry stays when the footprint is updated from the library.

## Bill of materials

The schematic symbols hold the BOM data in the `Mfg`, `PN` and `LCSC`
fields. Only the USB PHY parts have an `LCSC` field at this time. Export
the BOM with this command:

```text
kicad-cli sch export bom --fields 'Reference,Value,Footprint,Mfg,PN,LCSC' \
  --output mimic-bom.csv pcb/mimic.kicad_sch
```

## Origin and modifications

This hardware design is based on
[OrangeCrab r0.2](https://github.com/orangecrab-fpga/orangecrab-hardware/tree/c511d569fe2af39467041f888bc231020f40c6ac/hardware/orangecrab_r0.2),
designed by Greg Davill with contributions from the OrangeCrab contributors.
The original hardware is licensed under CERN-OHL v1.2.

LilithSemi modified the documentation on 2026-09-12. The initial changes
renamed the project for Mimic, made its KiCad dependencies self-contained, and
added reproducible development and fabrication tooling. This repository is
the documentation location for the modified design.

