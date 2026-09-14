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

## Serve-loop invariants

The CLI starts a server in this order:

1. Write and read back `CSD_0` through `CSD_3`.
2. Publish the block count in `NUM_BLOCKS`.
3. Read `CACHE_LINES` and configure the host cache model.
4. Drain stale words from `DATA_OUT` and send one failed acknowledgement when
   the channel was not empty.
5. Set `CTRL.ENABLE` and, for `--ro`, `CTRL.READ_ONLY`.

Do not enable the card before the size and channels are ready. The SD host can
start identification as soon as enable reaches the SD domain.

Each request poll is bounded. The server takes at most 64 records from one
reported count, and one record can request at most 256 blocks. One
`READ_THEN_POP` transaction reads the count and both request words, then writes
`REQ_POP` once. It performs the same explicit pop on an invalid record, so all
later records can continue.

A demand read waits for one complete block of `DATA_IN` credit. The credit is
conservative and is spent locally before the runtime reads the register
again. A speculative fill never waits for credit. It defers when a demand
record is pending or when one block does not fit.

A write always removes all 128 words from `DATA_OUT` before it validates the
record. It then updates the image when valid and sends `WRITE_ACK` before it
writes a diagnostic message. These orders keep the record stream and data
stream aligned, and they release DAT0 busy even when logging fails.

## Read-ahead

`--read-ahead=N` fills up to N blocks after a read into the FPGA cache. A
sequential SD host can then read those blocks without another USB request.
The CLI default is 3.

Read-ahead is still under hardware validation. Use `--read-ahead=0` for a
reliable boot until [../docs/status.md](../docs/status.md) removes this
restriction. A nonzero test must start from a freshly programmed FPGA and a
pristine image so stale channel state does not hide the result.

One demand read opens one fixed read-ahead window. The window never moves past
its original end. The server sends at most one speculative block before it
polls `REQ_COUNT` again. Cache hits can consume a window without a new request,
so an idle poll continues an open window until it is complete.

## Host cache model

The runtime models the direct-mapped FPGA cache so it does not send a fill for
a block that is already present. It reads the line count from `CACHE_LINES`.
A count that is not a power of two, is less than two, or is more than 1,024
turns the model off. With the model off, every eligible fill is sent. This
costs bandwidth but cannot skip needed data.

A successful demand response or fill inserts its LBA in the model. A write
removes that LBA only when the line holds the same LBA. If the card requests a
block that the model says is present, the card has lost cache state. CMD0 can
cause this because SD commands do not reach the runtime. The server clears the
whole model and increments `model resets`.

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
during bring-up, or install the udev rule from the `mimic-rt` package. On
NixOS, add the package to `services.udev.packages`:

```nix
services.udev.packages = [ pkgs.mimic-rt ];
```

The rule grants access to active local users and members of `plugdev`. Reload
the udev rules and reconnect Mimic after installation. An access failure
reports `AccessDenied`. A second process on the interface reports
`InterfaceBusy`.

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

The next `serve` can repair only the write-data channel. It removes the stale
words and sends a failed acknowledgement. It cannot prove or repair the
alignment of the read request, read data, and tag channels. Reload the
bitstream after an unclean stop, a USB disconnect, a timeout, or a nonzero
data-overflow event.
