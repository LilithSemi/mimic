# Status

This page records the current hardware result. It is a test status, not a
compatibility promise.

## Verified

- The OrangeCrab r0.2 ECP5 25F target builds and enumerates as USB device
  `1209:10c1`.
- The USB register transport passes SCRATCH write and read cycles and burst
  register reads.
- The card completes SD identification in 1-bit mode.
- Single-block reads and writes reach a host disk image.
- A Nix Vegas Badge V2 has booted through U-Boot, Linux, NixOS stage 1, and
  NixOS stage 2 from a Mimic image.
- A clean hardware run with `--read-ahead=3` reached the NixOS serial login
  prompt. U-Boot read the 27,693,915-byte initrd at 216.8 KiB/s and the
  63,945,216-byte kernel at 215.8 KiB/s.
- Writable tests have completed partition and file-system growth with no
  dropped Mimic writes in the measured run.

## Known limitations

- **Cold-start reads are not fully stable.** A new FPGA configuration can
  require more than one device reset before U-Boot reads reliably. Observed
  failures include U-Boot SD errors and an early synchronous abort.
- **The SD data bus is 1 bit wide.** DAT1 through DAT3 have pull-ups but do
  not carry block data.
- **The reference guest uses single-block requests.** The tested U-Boot and
  Linux configuration clips SD commands to one block.
- **Only OrangeCrab is proved on hardware.** The generator can describe other
  targets, but they do not have a current silicon result.
- **The runtime USB identity is fixed.** It scans for `1209:10c1` and claims
  interface 0 through usbfs.
- **Stage 2 is slow on a cold image.** First-boot work and service startup can
  exceed normal systemd timeouts at the current transfer rate. The proved run
  reached a login prompt, but some nonessential services timed out and retried.

## Bring-up target

The next hardware goal is repeated cold boots with nonzero read-ahead and no
read timeout, wrong block, or FIFO alignment fault. A wider test must start
from a new FPGA SRAM configuration and a pristine disk image. Each run must
reach the guest login prompt without an extra device reset.
