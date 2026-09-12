# Mimic runtime

The runtime is a Zig library and the `mimic-cli` program. It finds the Mimic
USB device, controls the FPGA registers, and backs the emulated SD card with a
host disk image.

See [../docs/runtime.md](../docs/runtime.md) for the operator reference and
[../docs/registers.md](../docs/registers.md) for the wire contract.

## Package layout

| Path | Function |
| ---- | -------- |
| `src/main.zig` | Implement `mimic-cli`, argument handling, output, and signals. |
| `lib/mimic.zig` | Export the runtime library modules. |
| `lib/mimic/usb.zig` | Find and claim USB device `1209:10c1` through usbfs. |
| `lib/mimic/protocol.zig` | Encode the USB register command protocol. |
| `lib/mimic/device.zig` | Provide register and stream operations. |
| `lib/mimic/sd.zig` | Define the CSR map, SD capacity values, and event bits. |
| `lib/mimic/serve.zig` | Move read and write blocks between the image and FPGA. |
| `lib/mimic/manifest.zig` | Parse the generated `mimic.json` contract. |

## Build and test

Build the Nix package from the repository root:

```
nix build .#mimic-rt -o result-runtime
./result-runtime/bin/mimic-cli help
```

For runtime development:

```
nix develop .#rt
cd runtime
zig build
zig build test
```

`zig build test` runs the CLI tests and each library module test. A local
build writes the program to `zig-out/bin/mimic-cli`.

## Prove the device

Program the OrangeCrab before you run the CLI. Then verify the USB and
register paths:

```
sudo ./zig-out/bin/mimic-cli version
sudo ./zig-out/bin/mimic-cli probe
sudo ./zig-out/bin/mimic-cli info
```

`version` checks the `MIMC` ID. `probe` tests SCRATCH writes and repeated
register bursts. `info` prints the primary CSR values, control bits, SD card
state, and advertised capacity.

Do not serve an image until `probe` prints `PASS`.

## Capacity and exact CSD sizes

An SD version 2.0 CSD represents capacity in steps of 1,024 blocks. One block
is 512 bytes, so each step is 512 KiB. Mimic never reports storage past the
end of the image.

Inspect and publish the capacity of an image:

```
sudo ./zig-out/bin/mimic-cli capacity sdcard.img
```

If the size is not an exact CSD step, the CLI rounds the advertised capacity
down and reports the unreachable tail. `--grow` appends zeros to the next
exact size:

```
sudo ./zig-out/bin/mimic-cli capacity sdcard.img --grow
```

`--grow` only makes a file larger. It cannot be used with `--ro`. Keep a
pristine copy before you grow or boot a writable image.

## Serve an image

The stable hardware command is:

```
sudo ./zig-out/bin/mimic-cli serve \
  --read-ahead=0 \
  --stats \
  sdcard.img
```

The image opens read-write by default. Add `--ro` for a transfer test that
must not modify it. Do not use `--ro` when the guest must repair or write its
root file system.

The server publishes the CSD, learns the hardware cache size, clears stale
write-channel words, and then enables the card. Reset the device under test
only after the CLI prints `press ctrl-c to stop`.

## Read-ahead

`--read-ahead=N` fills up to N blocks after a read into the FPGA cache. A
sequential SD host can then read those blocks without another USB request.
The CLI default is 3.

Read-ahead is still under hardware validation. Use `--read-ahead=0` for a
reliable boot until [../docs/status.md](../docs/status.md) removes this
restriction. A nonzero test must start from a freshly programmed FPGA and a
pristine image so stale channel state does not hide the result.

## Statistics

Add `--stats` to print counters when the server stops. Check these groups:

| Output | Meaning |
| ------ | ------- |
| Requests, blocks, and bytes | Read work returned to the card. |
| Refused | Invalid or out-of-range requests. This must be zero. |
| Blocks written and dropped | Valid image writes and writes that did not reach the image. |
| Fills and fills skipped | Read-ahead work sent or avoided. |
| Model resets | The card requested a block that the runtime cache model marked present. |
| Card busy and no room | Read-ahead deferrals caused by a request or a full channel. |
| Cache hits, misses, and fills | Hardware cache counters. They wrap at 16 bits. |

The CLI also reads EVENT at exit. A nonzero value reports a read timeout,
write timeout, or read-data overflow. See
[../docs/registers.md](../docs/registers.md#event-bits).

## USB and image permissions

The runtime claims USB interface 0 through `/dev/bus/usb`. Run it with `sudo`
during bring-up, or install a local udev rule that grants your user access to
USB device `1209:10c1`. An access failure reports `AccessDenied`. A second
process on the interface reports `InterfaceBusy`.

The process also needs read access to the image. Normal serve mode needs write
access. `--grow` needs permission to extend the file. Check the image owner and
mode before you start a long boot.

## Stop safely

Shut down or stop SD activity in the device under test first. Then press
Ctrl-C in the serve terminal. SIGINT and SIGTERM ask the loop to stop between
passes. The CLI disables the card, prints statistics when requested, reads
EVENT, releases the USB interface, and closes the image.

Do not kill the process while the card holds DAT0 busy for a write. If a run
ends during a transfer, reload the FPGA SRAM bitstream before the next boot.
This clears request, tag, and data channel state.
