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

## Origin and modifications

This hardware design is based on
[OrangeCrab r0.2](https://github.com/orangecrab-fpga/orangecrab-hardware/tree/c511d569fe2af39467041f888bc231020f40c6ac/hardware/orangecrab_r0.2),
designed by Greg Davill with contributions from the OrangeCrab contributors.
The original hardware is licensed under CERN-OHL v1.2.

LilithSemi modified the documentation on 2026-09-12. The initial changes
renamed the project for Mimic, made its KiCad dependencies self-contained, and
added reproducible development and fabrication tooling. This repository is
the documentation location for the modified design.

