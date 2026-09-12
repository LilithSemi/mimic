# Documentation

Mimic uses FPGA gateware and a host runtime to present a disk image as an SD
card. These pages describe the reference hardware and the interfaces between
the parts.

- [architecture.md](architecture.md) describes the USB, Wishbone, cache, and
  SD data paths.
- [hardware.md](hardware.md) gives the OrangeCrab pin map and the physical
  setup.
- [bring-up.md](bring-up.md) gives the build, program, and boot procedure.
- [runtime.md](runtime.md) describes the CLI and image handling.
- [registers.md](registers.md) gives the CSR map and channel records.
- [debugging.md](debugging.md) gives a diagnostic sequence for USB and SD
  faults.
- [status.md](status.md) records tested functions and known limitations.

## Where to start

| Goal | Page |
| ---- | ---- |
| Understand the system | [architecture.md](architecture.md) |
| Connect an OrangeCrab | [hardware.md](hardware.md) |
| Build and program it | [bring-up.md](bring-up.md) |
| Serve an image | [runtime.md](runtime.md) |
| Inspect a fault | [debugging.md](debugging.md) |
| Write another runtime | [registers.md](registers.md) |

## Command paths

The Nix runtime package installs `mimic-cli`. A local Zig build writes the same
binary to `runtime/zig-out/bin/mimic-cli`. The Dart package installs
`mimic-genip`. `nix build .#orangecrab-25f-bitstream` gives the reference
bitstream. From the `ip/` directory, you can also run the generator as `dart
run bin/mimic_genip.dart`.
