import 'package:harbor/harbor.dart';

/// The Mimic V1 board: an LFE5U-25F-6BG256C with a 24 MHz oscillator, a
/// USB3320C ULPI PHY between the USB-C port and the FPGA, a ZIF connector
/// for the card cable and the OrangeCrab configuration flash and JTAG.
///
/// The oscillator drives both K16 and the PHY reference clock. The PHY
/// sends the 60 MHz ULPI clock to J16, so both clocks land on PCLK balls.
///
/// The SD lines are on bank 7 and the clock is on PCLKT7_0, so the SD clock
/// reaches a global clock net with no clock buffer. Sites come from the
/// Lattice ECP5U-25 pinout (FPGA-SC-02033) for the CABGA256 package.
const HarborBoard mimicV1Board = HarborBoard(
  name: 'mimic-v1',
  vendor: HarborFpgaVendor.ecp5,
  device: 'lfe5u-25f',
  package: 'CABGA256',
  oscillatorHz: 24000000,
  pins: {
    'clk': 'K16 LVCMOS33',
    // FPGA_RESET, active low, with a pull-up. The same net drives PROGRAMN
    // and comes out on the JTAG pads. It is read on a plain IO, because
    // DOUT drives high during configuration.
    'rst_n': 'P1 LVCMOS33',
    // Configuration flash. The clock comes from USRMCLK and has no pad. The
    // chip select is CSSPIN, the pin that selects the flash in Master SPI
    // boot. CSN is used only in the parallel modes.
    'spi_cs_n': 'N8 LVCMOS33',
    'spi_io[0]': 'T8 LVCMOS33',
    'spi_io[1]': 'T7 LVCMOS33',
    'spi_io[2]': 'M7 LVCMOS33',
    'spi_io[3]': 'N7 LVCMOS33',
    // USB3320C ULPI PHY. ulpi_clk is the 60 MHz CLKOUT of the PHY. The
    // PHY reads CLKOUT as a mode strap after reset, so the FPGA never drives
    // it and adds no pull, and the board pull-down holds it low. The board
    // also holds RESETB low until the FPGA is configured.
    'ulpi_clk': 'J16 LVCMOS33 PULLMODE=NONE',
    'ulpi_dir': 'N16 LVCMOS33',
    'ulpi_nxt': 'K14 LVCMOS33',
    'ulpi_stp': 'P16 LVCMOS33',
    'ulpi_data[0]': 'K15 LVCMOS33',
    'ulpi_data[1]': 'J15 LVCMOS33',
    'ulpi_data[2]': 'J14 LVCMOS33',
    'ulpi_data[3]': 'H14 LVCMOS33',
    'ulpi_data[4]': 'H15 LVCMOS33',
    'ulpi_data[5]': 'G16 LVCMOS33',
    'ulpi_data[6]': 'F16 LVCMOS33',
    'ulpi_data[7]': 'G15 LVCMOS33',
    'ulpi_rst_n': 'R15 LVCMOS33 PULLMODE=DOWN',
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
  clockCapableSites: {'K16', 'J16', 'K1'},
  progCommand: 'openFPGALoader -c dirtyJtag \$(TOP).bit',
);

/// The boards that Mimic defines itself, keyed by name.
const Map<String, HarborBoard> mimicBoards = {'mimic-v1': mimicV1Board};

/// Resolves [name] to a Mimic board first and to a harbor board second.
HarborBoard mimicBoard(String name) =>
    mimicBoards[name] ?? HarborBoard.get(name);
