# Debugging

Work from the host USB link toward the SD link. Do not diagnose the file
system until both links are stable.

## Prove USB first

```
lsusb -d 1209:10c1
sudo mimic-cli version
sudo mimic-cli probe
```

If no USB device appears, check the OrangeCrab configuration, its USB cable,
and the `usb_pullup` signal. If the device appears but has no bulk endpoints,
an enumeration-only bitstream is loaded. If the interface is busy, stop the
other process that claimed interface 0.

`probe` writes five SCRATCH patterns and reads each one back. It then reads
1,024 bursts of 32 registers. Any error means the USB control path is not
ready for an SD boot.

## Check SD activity

Run `mimic-cli info` before and after a device reset. Compare these counters:

| Observation | Likely fault |
| ----------- | ------------ |
| `SD_CLK` does not change | CLK wiring, the pin constraint, or the clock buffer. |
| `SD_CLK` changes and `SD_CMD` does not | CMD wiring or framing. |
| `SD_CRC_ERR` follows `SD_CMD` | Sampling edge, signal integrity, or bit order. |
| `SD_CMD` changes and `SD_RESP` does not | Card command-state logic. |
| `SD_RESP` changes and `REQ_COUNT` stays zero | The host has not requested data yet. |

`CARD_STATE` uses SD state values. The useful bring-up sequence is `idle`,
`ready`, `ident`, `stby`, and `tran`. A return to `idle` can be a device reset
or CMD0.

## Check the serve loop

Run a known clean image with conservative options:

```
sudo mimic-cli serve --read-ahead=0 --stats clean.img
```

Keep UART capture active. U-Boot transfer timeouts with requests in the
server log point at the block return path. No requests with moving SD command
counters point at command handling before the data path.

On exit, check these values:

- `refused` must be zero.
- `blocks dropped` must be zero for a writable test.
- EVENT must be zero.
- `DATA_IN` overflow, EVENT bit 2, makes all later read blocks suspect.
- Repeated `model resets` can show an unexpected card reset or lost cache
  state.

## Separate image faults from transport faults

A writable image changes during boot. Partition growth, file-system repair,
and swap can make later runs different. Reproduce a transport fault from a
pristine copy before you inspect the guest file system.

Use `--ro` for a read-only transfer test. Do not use it for an operating
system that must repair or write its root file system.

## Recover after a channel fault

Stop the server, reload the OrangeCrab SRAM bitstream, run `probe`, and start
a new serve process. This clears channel state that a stopped host or a timed
out SD transfer can leave behind.

Read-ahead is a known fault area. A successful `--read-ahead=0` boot and a
failed nonzero run do not point at the cable. Keep read-ahead off until
[status.md](status.md) removes the limitation.
