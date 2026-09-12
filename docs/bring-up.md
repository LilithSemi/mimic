# Build and bring-up

This procedure uses the OrangeCrab ECP5 25F reference target.

## Build the host runtime

Build the package from the repository root:

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

## Build the gateware with Nix

Build the generated OrangeCrab IP when you need the RTL and flow files:

```
nix build .#orangecrab-25f -o result-ip
```

Build the flashable bitstream directly for normal work:

```
nix build .#orangecrab-25f-bitstream -o result-bitstream
```

The result contains `MimicSoC.bit`. `devices.nix` owns the target declaration.
Add a new FPGA or PDK target there instead of adding another versioned package
family.

The PDK targets generate ASIC IP for later physical-design flows:

```
nix build .#sky130-hd -o result-sky130-hd
nix build .#gf180mcu-3v3 -o result-gf180mcu-3v3
```

## Manual generator flow

Use the manual path when you must inspect or change generated files:

```
nix develop .#ip
cd ip
dart run bin/mimic_genip.dart --board orangecrab-25f -o ../out
cd ../out
make
```

The generator writes synthesizable RTL, `MimicSoC.lpf`, `synth.tcl`, a
nextpnr constraint script, `mimic.json`, and a Makefile. `make` writes
`MimicSoC.bit`.

The complete Dart suite is a long hardware simulation suite. Run a focused
test while you change one block. Reserve the full suite for a planned
verification run.

## Program the OrangeCrab

Check that DirtyJTAG is present and no other program owns it. Load the SRAM
configuration:

```
openFPGALoader -c dirtyJtag result-bitstream/MimicSoC.bit
```

Do not add the flash option during bring-up. An SRAM load is temporary and
goes away after FPGA power is removed. It also makes recovery from a bad
build quick.

The checked-in flake uses openFPGALoader 1.0.0 because 1.1.1 has a known
DirtyJTAG regression.

## Prove the runtime link

After programming, the OrangeCrab must enumerate as `1209:10c1`:

```
lsusb -d 1209:10c1
sudo ./result-runtime/bin/mimic-cli version
sudo ./result-runtime/bin/mimic-cli probe
sudo ./result-runtime/bin/mimic-cli info
```

`probe` must print `PASS`. It tests SCRATCH write and read cycles, then 1,024
burst reads.

## Serve a disk image

Keep the first boot conservative:

```
sudo ./result-runtime/bin/mimic-cli serve --read-ahead=0 --stats sdcard.img
```

The command publishes capacity before it enables the card. Keep it running
for the full device boot. Stop it with Ctrl-C after the device has shut down
or after you finish the test.

Reset the device under test after the server prints `press ctrl-c to stop`.
Watch its UART through a separate terminal. A successful reference run goes
through the ROM loader, U-Boot, the Linux kernel, NixOS stage 1, and NixOS
stage 2.

## Recover a failed run

1. Stop `mimic-cli serve`.
2. Program the known bitstream into OrangeCrab SRAM again.
3. Run `mimic-cli probe`.
4. Start `serve --read-ahead=0` with a clean image.
5. Reset the device under test.

A writable boot can change its image. Keep a pristine copy when a test can
resize a partition, create swap, or repair a file system.
