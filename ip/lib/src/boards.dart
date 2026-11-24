import 'package:harbor/harbor.dart';

/// The Mimic V1 board: an LFE5U-25F-6BG256C with a 48 MHz oscillator, a
/// USB-C port driven straight from the FPGA, a ZIF connector for the card
/// cable and the OrangeCrab configuration flash and JTAG.
///
/// The SD lines are on bank 7 and the clock is on PCLKT7_0, so the SD clock
/// reaches a global clock net with no clock buffer. Sites come from the
/// Lattice ECP5U-25 pinout (FPGA-SC-02033) for the CABGA256 package.
const HarborBoard mimicV1Board = HarborBoard(
  name: 'mimic-v1',
  vendor: HarborFpgaVendor.ecp5,
  device: 'lfe5u-25f',
  package: 'CABGA256',
  oscillatorHz: 48000000,
  pins: {
    'clk': 'K16 LVCMOS33',
    // The user button, active low. It also drives PROGRAMN, the way the
    // OrangeCrab wires it, so a long press reloads the configuration.
    'rst_n': 'M8 LVCMOS33',
    // Configuration flash. The clock comes from USRMCLK and has no pad.
    'spi_cs_n': 'R8 LVCMOS33',
    'spi_io[0]': 'T8 LVCMOS33',
    'spi_io[1]': 'T7 LVCMOS33',
    'spi_io[2]': 'M7 LVCMOS33',
    'spi_io[3]': 'N7 LVCMOS33',
    'usb_dp': 'J16 LVCMOS33',
    'usb_dm': 'J15 LVCMOS33',
    'usb_pullup': 'H15 LVCMOS33',
    // The RGB LED is active low.
    'led_r': 'A9 LVCMOS33',
    'led_g': 'A10 LVCMOS33',
    'led_b': 'B10 LVCMOS33',
    // The card side. CMD and DAT hold the idle level a card gives, and CLK
    // has a pull-down so no edge is counted while no host is connected.
    'sd_clk': 'K1 LVCMOS33 PULLMODE=DOWN',
    'sd_cmd': 'K2 LVCMOS33 PULLMODE=UP',
    'sd_dat0': 'J1 LVCMOS33 PULLMODE=UP',
    'sd_dat1': 'J2 LVCMOS33 PULLMODE=UP',
    'sd_dat2': 'H2 LVCMOS33 PULLMODE=UP',
    'sd_dat3': 'G2 LVCMOS33 PULLMODE=UP',
    // Card detect to the host slot, and the sense of the VDD the host gives.
    'sd_cd_ctrl': 'G1 LVCMOS33',
    'sd_vdd_sense': 'F1 LVCMOS33',
  },
  clockCapableSites: {'K16', 'K1'},
  progCommand: 'openFPGALoader -c dirtyJtag \$(TOP).bit',
);

/// The boards that Mimic defines itself, keyed by name.
const Map<String, HarborBoard> mimicBoards = {'mimic-v1': mimicV1Board};

/// Resolves [name] to a Mimic board first and to a harbor board second.
HarborBoard mimicBoard(String name) =>
    mimicBoards[name] ?? HarborBoard.get(name);
