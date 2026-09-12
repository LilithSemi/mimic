# Mimic IP

The `mimic` Dart package builds the FPGA side of Mimic. It uses ROHD and
Harbor to generate a USB-controlled SD card, the target constraints, and the
vendor build flow.

For the full system description, start with
[../docs/architecture.md](../docs/architecture.md). For the reference pin map
and bench setup, see [../docs/hardware.md](../docs/hardware.md).

## Package layout

| Path | Function |
| ---- | -------- |
| `bin/mimic_genip.dart` | Parse generator options and write one output directory. |
| `lib/src/genip.dart` | Resolve the board or PDK target and generate all artifacts. |
| `lib/src/soc.dart` | Connect USB, Wishbone, CDC channels, cache, and SD logic. |
| `lib/src/hw/` | Hold the USB device, SD protocol, cache, FIFO, reset, and activity blocks. |
| `lib/src/regs.dart` | Define the gateware side of the CSR and USB contracts. |
| `lib/src/sd_regs.dart` | Build SD CID, CSD, and other card register values. |
| `test/` | Hold focused protocol, CDC, cache, USB, and generator tests. |

## Development shell

Enter the IP shell from the repository root:

```
nix develop .#ip
cd ip
dart pub get
```

The Nix package supplies the locked Dart dependencies. `dart pub get` is only
needed when a direct checkout does not have `.dart_tool/package_config.json`.

Format changed Dart files with:

```
dart format lib test bin
```

## Focused tests

Run the test for the block you changed:

```
dart test test/sd_read_ahead_test.dart
dart test test/sd_cache_fill_test.dart
dart test test/elab_test.dart
dart test test/genip_test.dart
```

Use a name filter for one case:

```
dart test test/sd_read_ahead_test.dart \
  --name 'data waits when its tag FIFO pointer crosses later'
```

The complete SD and USB simulation suite takes hours. Do not use the full
suite as a quick check. Run it only for a planned verification pass:

```
dart test
```

## Generate IP manually

Generate the OrangeCrab design from the `ip/` directory:

```
dart run bin/mimic_genip.dart \
  --board orangecrab-25f \
  --output ../out
```

The reference target is an OrangeCrab r0.2 with an ECP5 25F. It uses a 48 MHz
system clock, full-speed USB, and a 1-bit SD data path.

Build the generated ECP5 design:

```
make -C ../out
```

This writes `MimicSoC.bit`. Program the SRAM configuration with the procedure
in [../docs/bring-up.md](../docs/bring-up.md).

## Nix device targets

`../devices.nix` declares FPGA and PDK targets. Use these packages from the
repository root:

| Package | Result |
| ------- | ------ |
| `.#orangecrab-25f` | Generated OrangeCrab RTL and build files. |
| `.#orangecrab-25f-bitstream` | Generated files and the ECP5 `MimicSoC.bit`. |
| `.#sky130-hd` | Generated SkyWater 130 nm high-density IP. |
| `.#gf180mcu-3v3` | Generated GlobalFoundries 180 nm 3.3 V IP. |

For example:

```
nix build .#orangecrab-25f-bitstream -o result-bitstream
nix build .#sky130-hd -o result-sky130-hd
```

Add another board, FPGA part, or PDK variant in `devices.nix`. Do not create a
versioned package family for each target.

## Block cache

The SD card has a direct-mapped cache of complete 512-byte blocks. The default
OrangeCrab build has 128 lines, which hold 64 KiB of block data. The block
address selects the line and supplies the stored tag. A read hit completes in
the SD clock domain without a host USB request.

The runtime owns replacement policy. It can send a block as a fill with an
LBA and the reserved sequence tag 0. A CMD24 write invalidates the matching
line. CMD0 and reset invalidate all lines.

`--cache-lines` changes the hardware line count. The count must be a power of
two and at least two. More lines use more block RAM.

## Read-data CDC FIFO

The runtime writes read data in the 48 MHz system domain. The card consumes it
in the SD clock domain, which the device under test can stop. The data channel
is therefore an asynchronous FIFO. It is four blocks deep so the runtime can
queue one answer and three speculative fills.

On ECP5, an inferred 512 by 32 dual-clock memory maps to DP16KD x36 mode.
Hardware bring-up found reliable runtime writes in x9 mode. The
`MimicByteLaneCdcFifo` therefore splits each 32-bit word into four 8-bit FIFO
lanes. Each lane maps to one x9 DP16KD. All lanes share the same write and read
enables. Full and empty are the OR of all lane flags, so a word moves only
when all four lanes can move. This rule also absorbs a one-clock difference
between lane pointer synchronizers.

The block tag uses a separate CDC FIFO. Data, tag, and completed-block pointers
can become visible on different SD clocks. The read path waits for both the
data FIFO and tag FIFO before it takes a block. This keeps sequence tags and
block data aligned.

## Generated artifacts

The generator writes a complete target directory:

| Artifact | Function |
| -------- | -------- |
| `rtl/*.sv` | Synthesizable SystemVerilog modules. |
| `MimicSoC.lpf` | OrangeCrab pin and clock constraints. |
| `synth.tcl` | Yosys synthesis script. |
| `Makefile` | Synthesis, place, route, pack, and SRAM program targets. |
| `support/nextpnr/constraints.py` | USB PHY placement constraints. |
| `MimicSoC.dts` | Device-tree description of the generated SoC. |
| `MimicSoC.svd` | Register description. |
| `MimicSoC.dot` and `MimicSoC.mermaid.md` | Generated hierarchy diagrams. |
| `MimicSoC.asl` | Generated address-space description. |
| `filelist.f` and `blackboxes.v` | RTL file list and vendor primitive declarations. |
| `mimic.json` | Host manifest with transport and interface values. |

An FPGA build adds the synthesized JSON, nextpnr configuration, and packed
bitstream. A PDK target stops at generated IP for a later physical-design
flow.
