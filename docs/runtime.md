# Runtime

`mimic-cli` controls the FPGA and serves disk images over the custom USB
link.

## Commands

| Command | Function |
| ------- | -------- |
| `version` | Verify the `MIMC` ID and print the interface version. |
| `probe` | Test SCRATCH cycles and repeated register bursts. |
| `info` | Print the main CSR values, the card state, and capacity. |
| `capacity <image or blocks>` | Build and publish a version 2.0 CSD. |
| `serve <image>` | Enable the card and move blocks until stopped. |

The runtime finds USB device `1209:10c1` through sysfs and opens its usbfs
node. It claims interface 0 directly. The kernel does not create a serial
device for this connection.

## Capacity

The card uses 512-byte blocks. A version 2.0 CSD represents capacity in units
of 1,024 blocks, which are 512 KiB. If the image size does not fit exactly,
Mimic rounds the advertised capacity down and reports the unreachable tail.
It never advertises storage that the image does not contain.

Use `--grow` to append zeros to the next exact size:

```
mimic-cli capacity sdcard.img --grow
```

This option only makes the file larger. It cannot be used with `--ro`.

## Serve options

| Option | Function |
| ------ | -------- |
| `--ro` | Open the image read-only and report write protection. |
| `--grow` | Extend the image to an exact CSD capacity before serving. |
| `--stats` | Print transfer, cache, fill, and error counters at exit. |
| `--read-ahead=N` | Fill N blocks after a read into the FPGA cache. |

The reference hardware has completed a NixOS boot with `--read-ahead=3`. A
zero value remains useful as a diagnostic because it removes speculative fill
traffic from the test.

The default serve mode is read-write. The runtime waits for a complete image
write before it acknowledges the SD write. Stop the server cleanly so it can
disable the card and print the final EVENT value.

## Interpret statistics

The first statistics line counts request records, blocks returned to the
card, refused requests, and request polls. The write line shows blocks stored
and blocks dropped. A dropped write did not reach the image.

The fill lines show speculative cache work. `card busy` means the runtime
deferred a fill because a real request was waiting. `no room` means the data
channel did not have space for another whole block.

Cache hit, miss, and fill counters come from the FPGA. They wrap at 16 bits.
Treat a long run as a recent window, not a lifetime total.

`model resets` means the runtime believed that a block was cached but the
card requested it again. The runtime clears its cache model when this occurs.
This counter is useful during CMD0 and cache fault tests.
