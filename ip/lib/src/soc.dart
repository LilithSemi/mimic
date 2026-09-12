/// Composes the Mimic SoC: a [MimicUsbDevice] host master (USB
/// vendor-class command bridge) plus a [MimicSdCard] CSR slave on a harbor
/// [HarborSoC] Wishbone fabric, and a [MimicSdCardDevice] on the SD bus.
///
/// Net effect: bytes a host streams over USB bulk become Wishbone reads and
/// writes into the SD card's CSR space. The USB device is the bus master and
/// the only master. The SD card stub is the only slave. Harbor's
/// [WishboneDecoder] sits between.
///
/// SD note
/// [MimicSdCardDevice] is the card personality. It is NOT on the Wishbone
/// fabric: it answers the SD bus directly, and the DUT that holds the card
/// drives its clock. The two paths meet at four kinds of signal.
/// `card_state` crosses into the bus domain through a [HarborCdcSync] per
/// bit and reads back in the CARD_STATE CSR. The four SD bring-up counters
/// cross the same way through a [MimicSdGraySync] each, which is a gray
/// code and not a raw binary count, so a bus read can never be torn.
/// `sd_activity_toggle` crosses as a level that inverts once per event, and
/// [MimicSdActivityLed] turns each change of it back into one event for the
/// board LED. The CSD crosses the other way, from the CSD CSR block into
/// the SD clock domain, through one [HarborCdcHandshake]. See
/// [buildMimicSoc].
///
/// SD clocking note
/// The SD clock is a top-level INPUT. The host owns it, it is asynchronous to
/// [mimicSysDomain], and it STOPS whenever the host stops clocking the card,
/// so it can never be a harbor clock domain with a PLL. It reaches the global
/// clock net through [mimicPinClock], which puts a vendor clock buffer on the
/// pad unless the board definition states that the ball reaches a clock net
/// by itself.
///
/// Bus-width note
/// harbor's [WishboneDecoder] gives every slave interface the SoC busConfig
/// address width, and [connectInterfaces] requires matching widths. The SD
/// card's Wishbone slave is 12 bits wide (its 2 KiB window), so the SoC bus
/// is built 12 bits wide and the USB master is built 12 bits wide to match.
/// The SD card therefore sits at base 0x000, the fabric CSR base.
///
/// Clocking note
/// On an FPGA target the SoC runs on one harbor clock domain, [mimicSysDomain],
/// which a real PLL drives at [mimicClockHz]. The ratio to the board
/// oscillator is 1:1, so `forcePll` keeps the PLL that harbor would otherwise
/// remove: the PLL gives a LOCK signal, and harbor holds the domain reset
/// until LOCK is high. The SoC therefore starts only after the clock is
/// stable, and it needs no hand-written power-on counter.
///
/// The domain also builds harbor's own power-on reset, so the FPGA build takes
/// an active-low `reset_n` button input ([mimicResetPortName]) instead of an
/// active-high `reset`. Simulation targets keep the plain `reset` input,
/// because there is no PLL to lock in a simulator.
library;

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'hw/led_activity.dart';
import 'hw/byte_lane_cdc_fifo.dart';
import 'hw/reset_sync.dart';
import 'hw/sd_block_cache.dart' show sdCacheDefaultLines, sdCacheLinesValid;
import 'hw/sd_card.dart';
import 'hw/sd_card_device.dart';
import 'hw/sd_card_fsm.dart' show sdCardCidValueFor, sdCardStateBits;
import 'hw/sd_debug.dart';
import 'hw/sd_link.dart' show sdCommandArgBits, sdResponseRegBits;
import 'hw/sd_read_path.dart'
    show
        sdBlockWords,
        sdDataFifoWords,
        sdDataInFifoWords,
        sdRequestBits,
        sdRequestFifoDepth,
        sdDataWordCountBits,
        sdRequestSeqBits,
        sdTagChannelBits,
        sdTagChannelLbaLsb,
        sdTagChannelValidBit,
        sdTagFifoDepth;
import 'hw/sd_write_path.dart' show sdWriteAckBits, sdWriteAckFifoDepth;
import 'hw/usb_device.dart';
import 'regs.dart';
import 'sd_regs.dart';

/// SoC bus address width. Matched to the SD card's 12-bit slave window so the
/// harbor decoder's slave interface width lines up with the peripheral
/// (connectInterfaces requires equal widths).
const int mimicBusAddressWidth = 12;

/// Base address of the SD card CSR space inside the SoC map. The peripheral
/// lives at 0x000; with a 12-bit fabric its window [0x000, 0x800) decodes
/// cleanly.
const int mimicSdCardBase = mimicCsrBase;

/// The clock rate the SoC runs at, in Hz.
///
/// harbor's full-speed USB line PHY ([HarborUsbFsRx] / [HarborUsbFsTx]) counts
/// the 12 Mbit/s line in whole clock cycles at 4x oversampling, so it only
/// decodes correctly on a 48 MHz clock. The PLL holds this rate, and it can
/// only hold it if the board oscillator agrees: the ECP5 PLL locks to an
/// integer ratio of the input, and the USB rate is not negotiable. A board
/// with a different oscillator needs a divider plan before it can carry this
/// SoC.
const int mimicClockHz = 48000000;

/// Highest SD clock rate this card advertises and accepts, in Hz.
///
/// The card reports default speed only. SD default speed has a 25 MHz limit,
/// and the SG2000 boot ROM changes between 6 MHz and 25 MHz during boot. The
/// FPGA timing constraint must cover the higher rate instead of treating this
/// host-supplied clock as another 48 MHz system clock.
const int mimicSdClockMaxHz = 25000000;

/// Name of the SoC clock domain the whole design runs in.
///
/// harbor treats a domain called `sys` as the default bus domain, so every
/// peripheral added with no domain of its own lands here.
const String mimicSysDomain = 'sys';

/// Name of the SoC top-level reset port on an FPGA build.
///
/// harbor builds this port when the SoC has clock domains and
/// `externalReset` is set. It is ACTIVE LOW, and harbor ORs it into the
/// internal power-on reset. Simulation targets have no clock domains, so they
/// keep the plain active-high `reset` port instead.
const String mimicResetPortName = 'reset_n';

/// Name of the SoC top-level LED port. It matches the `led_g` signal of the
/// harbor board catalog, so the board file alone gives it a site.
const String mimicLedPinName = 'led_g';

/// The USB pad signals, as external pin names. The nextpnr pre-place script
/// builds its region around exactly these, so the line PHY sits beside the
/// pads it drives.
const List<String> mimicUsbPadPins = ['usb_dp', 'usb_dm', 'usb_pullup'];

/// Name of the SD clock pin. The HOST drives it. It is an input of the SoC
/// and never an output.
const String mimicSdClkPinName = 'sd_clk';

/// Name of the SD command pin. It is bidirectional on the board, and split
/// into `sd_cmd_in` / `sd_cmd_out` / `sd_cmd_oe` inside the design.
const String mimicSdCmdPinName = 'sd_cmd';

/// Name of the SD data pin, line 0. It is bidirectional on the board and
/// split inside the design, the same way as [mimicSdCmdPinName].
const String mimicSdDatPinName = 'sd_dat0';

/// Names of the SD data pins the datapath does not read, DAT1 to DAT3.
///
/// The bus is 1 bit wide, so no logic in this design reads these three
/// lines. They still need a pad each. An SD HOST holds its command inhibit
/// while DAT[3:0] read busy, and a real card holds all four lines high
/// through pull-ups. A ball with no constraint has no pull-up and floats,
/// so a host can read a card that is permanently busy and send no command
/// at all, which looks the same as a card that is deaf.
///
/// The board build therefore takes a top-level INPUT for each one and reads
/// none of them. The port exists so that the pad, and the `PULLMODE=UP`
/// attribute the board catalog carries with the site, holds the line high
/// the way a card does. A constraint for a port the design does not have
/// makes nextpnr reject the build, so the port is what makes the pull-up
/// reach the ball.
///
/// The 4-bit datapath reads these same three lines later. It replaces the
/// ports with a wider `sd_dat` bus into [MimicSdCardDevice].
const List<String> mimicSdDatPullupPinNames = ['sd_dat1', 'sd_dat2', 'sd_dat3'];

/// Every external pin name the Mimic SoC drives on an FPGA board build.
const List<String> mimicExposedPins = [
  'clk',
  mimicResetPortName,
  'usb_dp',
  'usb_dm',
  'usb_pullup',
  mimicLedPinName,
  mimicSdClkPinName,
  mimicSdCmdPinName,
  mimicSdDatPinName,
  ...mimicSdDatPullupPinNames,
];

/// The board catalog signal that carries each SoC port whose name differs
/// from the catalog name.
///
/// harbor names its external reset input `reset_n`. The OrangeCrab catalog
/// calls the same button `rst_n`. harbor keeps only the pins the design has a
/// top-level port for, so without this alias the button site is dropped and
/// the pin is left unconstrained. [resolveMimicTarget] copies the catalog site
/// to the port name.
const Map<String, String> mimicPinAliases = {mimicResetPortName: 'rst_n'};

/// The clock domains the SoC is built with for [target].
///
/// An FPGA target gets one domain on a real PLL. The board oscillator and the
/// USB rate are both 48 MHz, and harbor removes a 1:1 PLL by default, so
/// `forcePll` is what keeps it. The PLL is worth the block: it gives a LOCK
/// output, and harbor holds the domain reset asserted until LOCK is high and
/// then releases it through a two-flop synchroniser on the domain clock. A
/// counter cannot know when the clock is good.
///
/// There is ONE PLL on purpose. A second EHXPLLL may not lock on ECP5 silicon,
/// because of how the second PLL site takes its clock input. When the SDIO
/// domain arrives it must come from `coClkosSecondary` on THIS domain, which
/// makes it a CLKOS output of the same VCO and the same LOCK. Nothing consumes
/// a second clock yet, so none is built.
///
/// Any other target (a simulator, or no target at all) gets no domain: there
/// is no PLL to instantiate, and harbor would then either short the domain
/// back to the input clock or invent a second top-level clock port for a
/// harness to drive. Both are worse than the plain input clock.
List<HarborClockConfig> mimicClockConfigs(
  HarborDeviceTarget? target,
  int oscHz,
) {
  if (target is! HarborFpgaTarget) return const [];
  return [
    HarborClockConfig.fixed(
      name: mimicSysDomain,
      frequency: mimicClockHz,
      sourceFrequency: oscHz,
      forcePll: true,
    ),
  ];
}

/// Puts [pin] on a global clock net for [target], and returns the clock net
/// the design must use.
///
/// A pad that clocks logic has to reach the global clock tree. A ball on a
/// dedicated clock route reaches it by itself, and [clockCapable] says so.
/// Every other ball needs a clock buffer between the pad and the logic, or
/// the tool routes the clock through general fabric: the skew across the
/// loads is then large, and the design fails on hardware even though it
/// passes in simulation.
///
/// The buffer is chosen by the target VENDOR, in the shape of harbor's
/// `HarborSdioController._uhsConditionBit`, so no part of the card side
/// becomes ECP5-only. A target that is not an FPGA (a simulator, or no
/// target) takes the pad as it is: there is no clock tree to reach.
///
/// [clockCapable] comes from the BOARD DEFINITION, through
/// [HarborBoard.siteIsClockCapable], and never from the board name. A board
/// that states nothing gets the buffer, which is always correct and costs one
/// global buffer.
Logic mimicPinClock(
  HarborSoC soc,
  HarborDeviceTarget? target,
  Logic pin, {
  required bool clockCapable,
  required String name,
}) {
  if (clockCapable || target is! HarborFpgaTarget) return pin;
  switch (target.vendor) {
    case HarborFpgaVendor.ecp5:
      // DCCA is the ECP5 global clock buffer. CE is tied high: the clock is
      // always on as far as the fabric is concerned, and the HOST stops it
      // by not driving the pad.
      final dcca = Ecp5Dcca(name: name);
      soc.addSubModule(dcca);
      dcca.input('CLKI').srcConnection! <= pin;
      dcca.input('CE').srcConnection! <= Const(1);
      // The net keeps a name of its own. Every load of a global clock
      // shares one net, and without a name of its own that net takes the
      // port name of whichever load reached it last. A clock net that is
      // named after one of its loads reads as a local signal in the
      // netlist and in a timing report.
      //
      // The name comes from [name], which is unique to the buffer, and not
      // from the port name of the primitive. `Naming.reserved` refuses a
      // second net of the same name, so a hardcoded `CLKO` would throw as
      // soon as one SoC buffered two clocks.
      return dcca.output('CLKO').named('${name}_clk', naming: Naming.reserved);
    case HarborFpgaVendor.ice40:
      final gb = Ice40SbGb(name: name);
      soc.addSubModule(gb);
      gb.input('USER_SIGNAL_TO_GLOBAL_BUFFER').srcConnection! <= pin;
      return gb.output('GLOBAL_BUFFER_OUTPUT');
    case HarborFpgaVendor.vivado:
    case HarborFpgaVendor.openXc7:
      final bufg = XilinxBufg(name: name);
      soc.addSubModule(bufg);
      bufg.input('I').srcConnection! <= pin;
      return bufg.output('O');
  }
}

/// Parses a "vendor:device:package" target spec into a [HarborFpgaTarget]
/// with the given pin map and oscillator [frequency] (declarative targeting.
/// No hardcoded device, no hardcoded clock).
HarborFpgaTarget parseFpgaTarget(
  String spec,
  Map<String, String> pins, {
  int frequency = mimicClockHz,
}) {
  final parts = spec.split(':');
  if (parts.length != 3) {
    throw FormatException(
      'Target format is vendor:device:package (e.g. ecp5:25f:CSFBGA285), '
      'got: $spec',
    );
  }
  final (vendor, device, package) = (parts[0], parts[1], parts[2]);
  return switch (vendor) {
    'ecp5' => HarborFpgaTarget.ecp5(
      device: device,
      package: package,
      frequency: frequency,
      pinMap: pins,
    ),
    'ice40' => HarborFpgaTarget.ice40(
      device: device,
      package: package,
      frequency: frequency,
      pinMap: pins,
    ),
    _ => throw UnsupportedError('Unknown FPGA vendor: $vendor'),
  };
}

/// Parses `name=value` pin specs (the `--pin` flag) into a pin map.
///
/// The value goes through VERBATIM. Harbor's pin grammar is
/// `"SITE [IO_TYPE] [ATTR=VAL...]"` and harbor already writes IO_TYPE=LVCMOS33
/// for a value that carries no attribute, so `--pin clk=A9` and
/// `--pin sdram_dq=K2 SSTL135` both do what they say.
Map<String, String> parseMimicPinSpecs(Iterable<String> pinSpecs) {
  final pins = <String, String>{};
  for (final spec in pinSpecs) {
    final eq = spec.indexOf('=');
    if (eq < 0) throw FormatException('--pin format is name=site, got: $spec');
    pins[spec.substring(0, eq)] = spec.substring(eq + 1);
  }
  return pins;
}

/// Resolves the build target from `--board` (harbor's [HarborBoard] catalog)
/// or the `--target` escape hatch, plus any `name=site` pin overrides.
///
/// The board catalog is the pin source. Every catalog signal is offered to
/// harbor and a `--pin` of the same name REPLACES that one entry, so naming
/// one pin never drops the others. Harbor's [HarborSoC.generateAll] then
/// keeps only the pins the design has a top-level port for, so a catalog
/// signal this SoC does not drive costs nothing.
///
/// [oscHz] overrides the oscillator rate. It defaults to the board's
/// [HarborBoard.oscillatorHz], and to [mimicClockHz] on the `--target` path
/// where no board states the rate.
HarborFpgaTarget resolveMimicTarget({
  String? board,
  String? targetSpec,
  Iterable<String> pinSpecs = const [],
  int? oscHz,
}) {
  final userPins = parseMimicPinSpecs(pinSpecs);
  // The --target escape hatch (board not in the catalog) wins when set: there
  // is no catalog to merge with, so its pins come entirely from --pin.
  if (targetSpec != null) {
    return _withMimicFpgaConstraints(
      parseFpgaTarget(targetSpec, userPins, frequency: oscHz ?? mimicClockHz),
    );
  }
  if (board == null) {
    throw ArgumentError('One of board or targetSpec is needed.');
  }
  final catalog = HarborBoard.get(board);
  // Copy every aliased catalog site to the port name the SoC really emits.
  // A --pin of the port name still wins, because userPins is merged last.
  final aliased = <String, String>{};
  mimicPinAliases.forEach((port, signal) {
    final site = catalog.pins[signal];
    if (site != null) aliased[port] = site;
  });
  return _withMimicFpgaConstraints(
    catalog.fpgaTarget(frequency: oscHz, extraPins: {...aliased, ...userPins}),
  );
}

/// Adds constraints for clocks that the Mimic design receives from its host.
///
/// Harbor constrains the board oscillator through [HarborFpgaTarget.frequency].
/// The SD clock is unrelated to that oscillator and needs its own constraint.
/// LPF can state both clocks. Other target families need their own constraint
/// syntax, so this function does not put an LPF statement in those files.
HarborFpgaTarget _withMimicFpgaConstraints(HarborFpgaTarget target) {
  if (target.vendor != HarborFpgaVendor.ecp5) return target;
  return HarborFpgaTarget(
    name: target.name,
    vendor: target.vendor,
    device: target.device,
    package: target.package,
    frequency: target.frequency,
    pinMap: target.pinMap,
    extraConstraints: {
      ...target.extraConstraints,
      'mimic_sd_clock':
          'FREQUENCY PORT "$mimicSdClkPinName" '
          '${mimicSdClockMaxHz / 1000000} MHz;',
    },
    clockPortName: target.clockPortName,
    progCommand: target.progCommand,
  );
}

/// Assembles the Mimic SoC: a USB vendor-class command bridge master plus
/// the SD card CSR slave on a harbor Wishbone B4 32-bit fabric, targeting
/// [target]. An FPGA target adds the [mimicSysDomain] PLL clock domain (see
/// [mimicClockConfigs]).
///
/// [oscHz] is the rate the board clocks the SoC at. It must be
/// [mimicClockHz]: the USB line PHY only decodes full speed on that clock, and
/// the PLL locks to an integer ratio of the input, so no other oscillator
/// reaches the rate the PHY needs. It must also agree with [target], which
/// carries the same rate into the timing constraint and into the sim harness.
///
/// [tbCmdPorts] exposes the command engine's `cmd_*`/`resp_*` byte streams at
/// the SoC level for command-level sim. Keep it false for synthesizable
/// builds: the only path to the command engine is then the real EP1 bulk
/// endpoints through the PHY.
///
/// [ownPads] gives the SoC one bidirectional ball for `usb_dp`, `usb_dm`,
/// [mimicSdCmdPinName] and [mimicSdDatPinName] (see [MimicUsbDevice.ownPads]).
/// Off by default so the PHY-level tests drive the split line ports; genip
/// turns it on for the board build.
///
/// [activityLed] adds the [MimicSdActivityLed] on the [mimicLedPinName] pad.
/// It is the activity light of the card: dark while nothing happens, and a
/// flicker while the host talks to the card. genip turns it on for the board
/// build, and it stays off in simulation where it only costs cycles.
///
/// [manufactureYear] and [manufactureMonth] are the MDT date the CID
/// reports. The DATE OF THE BUILD belongs there, so the generator resolves
/// it and passes it in. The default is the one [sdCid] states, so a caller
/// that names no date still gets a card with a date the field can hold.
/// [sdCid] checks both parts and throws on a value the MDT field cannot
/// express, so a card with a date nobody can read never reaches a bitstream.
///
/// [board] is the board catalog entry the build targets, when there is one.
/// The SD clock buffer decision reads it: the SoC asks whether the ball
/// behind [mimicSdClkPinName] reaches a clock net, and NEVER tests the board
/// name. With no board the SoC assumes no ball reaches a clock net, so it
/// puts a clock buffer on the SD clock. That is the safe direction: a buffer
/// that was not necessary costs one global buffer, while a missing one gives
/// a skewed clock that only shows on hardware.
HarborSoC buildMimicSoc({
  String name = 'MimicSoC',
  HarborDeviceTarget? target,
  int oscHz = mimicClockHz,
  int idVendor = 0x1209,
  int idProduct = 0x10C1,
  String? serialNumber,
  bool bulkEndpoints = true,
  bool tbCmdPorts = false,
  bool ownPads = false,
  bool activityLed = false,
  int manufactureYear = sdCidDefaultManufactureYear,
  int manufactureMonth = sdCidDefaultManufactureMonth,
  HarborBoard? board,
  int cacheLines = sdCacheDefaultLines,
}) {
  if (!sdCacheLinesValid(cacheLines)) {
    // The index of the block cache is the LOW bits of the block address, so
    // a line count that is not a power of two needs a modulo, and a modulo
    // is a divider in the lookup path of the SD clock domain. Say so here,
    // where the build names the number, and not in a synthesis report.
    throw ArgumentError.value(
      cacheLines,
      'cacheLines',
      'must be a power of two, 2 or more. It is the line count of the '
          'block cache, and the index is the low bits of the block address.',
    );
  }
  // The clock is a hard requirement of the line PHY, not a preference. Say so
  // here, where the board rate arrives, rather than let a board with another
  // oscillator build a bitstream that never enumerates.
  if (oscHz != mimicClockHz) {
    throw ArgumentError(
      'The Mimic SoC runs the USB full-speed PHY at $mimicClockHz Hz, and the '
      'PLL can only reach that rate from an oscillator with an integer ratio '
      'to it. Got $oscHz Hz. Use a board with a 48 MHz oscillator, or pass the '
      'rate the board really has.',
    );
  }
  final targetHz = switch (target) {
    HarborFpgaTarget(:final frequency) => frequency,
    HarborSimTarget(:final frequency) => frequency,
    _ => oscHz,
  };
  if (targetHz != oscHz) {
    throw ArgumentError(
      'Target clock $targetHz Hz does not match the SoC oscillator $oscHz Hz. '
      'The timing constraint and the SoC would then state different rates.',
    );
  }

  final soc = HarborSoC(
    name: name,
    compatible: 'lilithsemi,mimic',
    busConfig: WishboneConfig(
      addressWidth: mimicBusAddressWidth,
      dataWidth: 32,
    ),
    target: target,
    clocks: mimicClockConfigs(target, oscHz),
    // The OrangeCrab reset button, ORed into harbor's power-on reset. It only
    // takes effect on a target that has clock domains, which is the FPGA
    // build. See [mimicResetPortName].
    externalReset: true,
  );

  // The custom vendor-class device (class 0xFF, two bulk endpoints) on the
  // ported TinyFPGA protocol engine: its EP1 bulk command engine is a
  // Wishbone MASTER. tbCmdPorts false removes the testbench byte-stream ports
  // so the only path in is the real EP1 bulk endpoints through the dp/dm PHY.
  // Every endpoint of this device declares a 32-byte maximum packet size,
  // which is the ceiling of the ported endpoint buffer.
  final device = MimicUsbDevice(
    config: MimicUsbDeviceConfig(
      busAddressWidth: mimicBusAddressWidth,
      busDataWidth: 32,
      idVendor: idVendor,
      idProduct: idProduct,
      bulkEndpoints: bulkEndpoints,
      serialNumber: serialNumber,
    ),
    tbCmdPorts: tbCmdPorts,
    ownPads: ownPads,
  );
  soc.addMaster(device, busInterfaceName: 'bus');

  // The SD card CSR slave at the fabric CSR base. The debug counters
  // are internal to the slave and count bus accesses directly.
  final sdCard = MimicSdCard(
    baseAddress: mimicSdCardBase,
    cacheLines: cacheLines,
  );
  soc.addPeripheral(sdCard);

  // Port name -> external pad name. With ownPads D+ and D- are one
  // bidirectional ball each and the port name is already the pad name. The
  // split shape needs the usb_ prefix and carries the driver ports too. The
  // pullup port is already usb-prefixed in both shapes.
  final usbPins = ownPads
      ? const {
          'usb_dp': 'usb_dp',
          'usb_dm': 'usb_dm',
          'usb_pullup': 'usb_pullup',
        }
      : const {
          'dp': 'usb_dp',
          'dm': 'usb_dm',
          'dp_out': 'usb_dp_out',
          'dm_out': 'usb_dm_out',
          'oe': 'usb_oe',
          'usb_pullup': 'usb_pullup',
        };
  usbPins.forEach(
    (port, external) => soc.exposePin(device, port, externalName: external),
  );

  // The SD card personality: the link and the card state machine, on the SD
  // bus. It is NOT on the Wishbone fabric. The host that holds the card owns
  // its clock, and the SoC only watches the card through `card_state`.
  //
  // The CID carries the manufacture date of the build. [sdCardCidValueFor]
  // goes through [sdCid], which checks the year and the month against what
  // the 12-bit MDT field holds, so a date the field cannot express stops
  // the build here and not on a host that reads a card made in 1900.
  final card = MimicSdCardDevice(
    name: 'sd_card_device',
    cid: sdCardCidValueFor(
      manufactureYear: manufactureYear,
      manufactureMonth: manufactureMonth,
    ),
    cacheLines: cacheLines,
  );
  soc.addSubModule(card);

  // The SD clock comes in on a pad the HOST drives, so it is a top-level
  // input of the SoC and never an output. [mimicPinClock] puts it on a
  // global clock net when the board says the ball does not reach one.
  soc.createPort(mimicSdClkPinName, PortDirection.input);
  final sdClkPin = switch (target) {
    HarborFpgaTarget(:final pinMap) => pinMap[mimicSdClkPinName],
    _ => null,
  };
  final sdClk = mimicPinClock(
    soc,
    target,
    soc.input(mimicSdClkPinName),
    clockCapable:
        board != null && sdClkPin != null && board.siteIsClockCapable(sdClkPin),
    name: 'sd_clk_buf',
  );
  card.input('clk').srcConnection! <= sdClk;

  // The reset of the SD clock domain. The SoC domain reset cannot go
  // straight into the card: the registers of the card are clocked by the SD
  // clock, ROHD builds a SYNCHRONOUS reset, and a synchronous reset does
  // nothing without a clock edge while it is high. A host that starts the
  // SD clock only after the SoC releases its reset would then leave every
  // register of the card with no reset value at all, and CMD9 would answer
  // a CSD that no one loaded.
  //
  // [MimicResetSync] gives the domain a reset that goes high with no clock
  // and drops two SD clock edges after the SoC releases it. The card
  // therefore always sees its reset high on its first clock edges, however
  // late the host starts the clock.
  final (sysClk, sysReset) = soc.defaultClock;
  final sdResetSync = MimicResetSync(name: 'sd_reset_sync');
  soc.addSubModule(sdResetSync);
  sdResetSync.input('clk').srcConnection! <= sdClk;
  sdResetSync.input('async_reset').srcConnection! <= sysReset;
  final sdReset = sdResetSync.output('reset');
  card.input('reset').srcConnection! <= sdReset;

  // The SD lines. With ownPads the SoC binds one bidirectional ball for CMD
  // and one for DAT0 and drives each through a tristate buffer, the same
  // shape MimicUsbDevice uses for D+ and D-. Without it the split ports come
  // up to the top, where a test can drive them with no shared bidirectional
  // net (ROHD does not co-simulate one between siblings).
  if (ownPads) {
    soc.createPort(mimicSdCmdPinName, PortDirection.inOut);
    soc.createPort(mimicSdDatPinName, PortDirection.inOut);
    final cmdPad = soc.inOut(mimicSdCmdPinName);
    final datPad = soc.inOut(mimicSdDatPinName);
    cmdPad <=
        TriStateBuffer(
          card.output('sd_cmd_out'),
          enable: card.output('sd_cmd_oe'),
        ).out;
    datPad <=
        TriStateBuffer(
          card.output('sd_dat_out'),
          enable: card.output('sd_dat_oe'),
        ).out;
    card.input('sd_cmd_in').srcConnection! <= cmdPad;
    card.input('sd_dat_in').srcConnection! <= datPad;

    // DAT1 to DAT3. Nothing in this design reads them. Each one is a
    // top-level input so that the ball takes the board constraint, and the
    // pull-up in that constraint holds the line high the way a card does.
    // See [mimicSdDatPullupPinNames] for why a floating line here stops a
    // host from sending any command at all.
    //
    // The ports are deliberately left with no reader. A tie into logic
    // would give the synthesis tool a reason to keep them and would also
    // put three lines the card must not read into the card. What keeps
    // them is that they are ports of the top module.
    for (final pin in mimicSdDatPullupPinNames) {
      soc.createPort(pin, PortDirection.input);
    }
  } else {
    const splitPorts = [
      'sd_cmd_in',
      'sd_cmd_out',
      'sd_cmd_oe',
      'sd_dat_in',
      'sd_dat_out',
      'sd_dat_oe',
    ];
    for (final p in splitPorts) {
      soc.exposePin(card, p, externalName: p);
    }
  }

  // `card_state` crosses from the SD clock domain into the SoC domain. The
  // two clocks are genuinely asynchronous, and the SD clock STOPS when the
  // host stops clocking the card, so a plain register would sample a signal
  // that changes at any moment and can go metastable.
  //
  // One two-flop synchroniser per bit. The state register is not gray coded,
  // so during a state change one read can show a bit pattern that is a mix
  // of the old state and the new one, for one SoC clock. That is acceptable
  // here and nowhere else: CARD_STATE is an OBSERVATION register that a
  // person or a runtime polls, no logic acts on it, and the value settles on
  // the next clock. The block data path of phase 3 carries real data and
  // gets a handshake or a FIFO, not this.
  final cardStateBits = <Logic>[];
  for (var i = 0; i < sdCardStateBits; i++) {
    final sync = HarborCdcSync(name: 'card_state_sync_$i');
    soc.addSubModule(sync);
    sync.input('async_in').srcConnection! <= card.output('card_state')[i];
    sync.input('dst_clk').srcConnection! <= sysClk;
    sync.input('dst_reset').srcConnection! <= sysReset;
    cardStateBits.add(sync.output('sync_out'));
  }
  // rswizzle puts element 0 in the LSB, which is the bit it came from.
  sdCard.input('card_state').srcConnection! <= cardStateBits.rswizzle();

  // The four bring-up counters cross the same way `card_state` does, and
  // for a different reason. They are free-running counters, so neither
  // house pattern of this SoC fits them:
  //   - A synchroniser per RAW BINARY bit tears. Several bits of a binary
  //     counter change on one increment (7 to 8 changes four of them), and
  //     a bus clock that samples in that window reads a number the counter
  //     never held. A torn count is worse than no count, because it sends
  //     a person after a fault that never happened.
  //   - A handshake never retires. The value changes on every SD clock, so
  //     the source would raise a new request before the last acknowledge
  //     comes back, and the crossing would carry almost nothing.
  // The card therefore publishes each counter as a GRAY CODE, in which two
  // numbers one apart differ in exactly ONE bit. Only one bit of the word
  // is ever moving, so a sampled word is the old count or the new count
  // and both are real. [MimicSdGraySync] holds the synchroniser per bit and
  // turns the settled gray word back into a binary count.
  //
  // The destination side takes the SoC clock and the SoC reset, so a read
  // gives 0 and never X on a board whose SD clock never ticks: the source
  // registers reset to 0 through [MimicResetSync], and the synchronisers
  // reset to 0 on the SoC reset with no SD clock at all.
  final dbgCounters = <String, ({String cardPort, int width})>{
    'dbg_sd_clk': (cardPort: 'dbg_sd_clk_gray', width: sdDbgClkBits),
    'dbg_sd_cmd': (cardPort: 'dbg_sd_cmd_gray', width: sdDbgEventBits),
    'dbg_sd_crc_err': (cardPort: 'dbg_sd_crc_err_gray', width: sdDbgEventBits),
    'dbg_sd_resp': (cardPort: 'dbg_sd_resp_gray', width: sdDbgEventBits),
    // The three block cache counters take the same road, and for the same
    // reason: they count in the SD clock domain, which the host stops.
    'dbg_cache_hit': (cardPort: 'dbg_cache_hit_gray', width: sdDbgEventBits),
    'dbg_cache_miss': (cardPort: 'dbg_cache_miss_gray', width: sdDbgEventBits),
    'dbg_cache_fill': (cardPort: 'dbg_cache_fill_gray', width: sdDbgEventBits),
  };
  dbgCounters.forEach((csrPort, spec) {
    final sync = MimicSdGraySync(width: spec.width, name: '${csrPort}_sync');
    soc.addSubModule(sync);
    sync.input('gray_in').srcConnection! <= card.output(spec.cardPort);
    sync.input('clk').srcConnection! <= sysClk;
    sync.input('reset').srcConnection! <= sysReset;
    sdCard.input(csrPort).srcConnection! <= sync.output('count');
  });

  // The CSD crosses the other way: from the CSR block in the SoC domain
  // into the SD clock domain, where CMD9 answers with it.
  //
  // A synchroniser per bit is WRONG here and right for card_state. The CSD
  // is 128 bits, and a per-bit crossing can show the card a register that
  // is part old and part new, so a host reads a capacity that no runtime
  // ever asked for. The handshake carries all 128 bits behind one request,
  // so each 128-bit SNAPSHOT moves whole.
  //
  // The handshake alone does not make the CSD whole. The runtime writes the
  // CSR block one 32-bit word at a time, and a snapshot taken between two
  // of those writes carries a value that is part old and part new. The
  // block is made whole at the SOURCE instead: [MimicSdCard] holds a
  // committed shadow of the four CSR words and loads all 128 bits on one
  // bus clock, and `csd` is that shadow. This crossing therefore only ever
  // sees a CSD that the runtime finished writing.
  //
  // The value is quasi-static: it changes when the runtime configures the
  // card and stands still after that. A handshake is therefore enough and a
  // FIFO would buy nothing.
  final csdCdc = HarborCdcHandshake(
    dataWidth: sdResponseRegBits,
    name: 'csd_cdc',
  );
  soc.addSubModule(csdCdc);
  csdCdc.input('src_clk').srcConnection! <= sysClk;
  csdCdc.input('src_reset').srcConnection! <= sysReset;
  csdCdc.input('src_data').srcConnection! <= sdCard.output('csd');
  // The request stands. The handshake sends the CSR value again as soon as
  // the last transfer ends, so a write that lands while the SD clock is
  // stopped still reaches the card once the host clocks it again. The card
  // reloads the same value in between, which changes nothing.
  csdCdc.input('src_valid').srcConnection! <= Const(1);
  csdCdc.input('dst_clk').srcConnection! <= sdClk;
  // The destination side lives in the SD clock domain, so it takes the SD
  // domain reset. See [MimicResetSync] above.
  csdCdc.input('dst_reset').srcConnection! <= sdReset;
  // Hold the acknowledge while the request stands, and release it only
  // after the request drops. That is the four phase handshake.
  //
  // With `dst_ready` tied high instead, the acknowledge would go low again
  // on the very next SD clock and then rise again while the request still
  // stands, which is a square wave and not a handshake. `~dst_valid` makes
  // the acknowledge a LEVEL that stands until the request drops, so the
  // source domain has a stable window of many clocks to sample it in, and
  // the transfer retires once and not again and again.
  csdCdc.input('dst_ready').srcConnection! <= ~csdCdc.output('dst_valid');
  card.input('csd').srcConnection! <= csdCdc.output('dst_data');
  card.input('csd_valid').srcConnection! <= csdCdc.output('dst_valid');

  // The SD domain reset, as the SoC domain sees it.
  //
  // [HarborCdcFifo] resets its pointers SYNCHRONOUSLY. The pointers of the
  // side that the SD clock drives therefore hold no reset value until that
  // clock ticks, and a board where no host has started the SD clock leaves
  // them with whatever the flops powered up with. The comparison that
  // makes `rd_empty` and `wr_full` reads the other domain's pointer through
  // a synchroniser, so the fault crosses into the SoC domain and reaches
  // the CSR read data: REQ, REQ_COUNT and REQ_HI all read `req_empty`, so
  // a channel that reads NOT empty hands the runtime a record that no card
  // ever wrote, and a bulk read of the map answers X for three of its
  // addresses.
  //
  // This level is the gate that fixes it, and it is the gate that
  // [MimicSdGrayCounter] puts on its own published word. The FIFO cannot
  // hold one of its own, so the SoC holds it here: while the SD domain is
  // in reset the request channel reads EMPTY and the data channel reads NOT
  // FULL, which is what both channels truly are before the card runs.
  //
  // The SoC reset joins the synchronised level because the flops of
  // [HarborCdcSync] reset to 0 and need two SoC clocks to load the 1.
  final sdHeldSync = HarborCdcSync(name: 'sd_reset_sys_sync');
  soc.addSubModule(sdHeldSync);
  sdHeldSync.input('async_in').srcConnection! <= sdReset;
  sdHeldSync.input('dst_clk').srcConnection! <= sysClk;
  sdHeldSync.input('dst_reset').srcConnection! <= sysReset;
  final sdHeld = (sdHeldSync.output('sync_out') | sysReset).named(
    'sd_domain_held',
  );

  // The block read channels, one FIFO in each direction.
  //
  // Neither of the other two house patterns fits a STREAM. A synchroniser
  // per bit tears a 32-bit word. A handshake carries one word behind one
  // request and cannot hold a block, and its destination side has to
  // acknowledge, which the SD domain cannot do while the host holds the
  // clock still. An asynchronous FIFO carries a stream: the words go into
  // a memory that only the write domain writes and only the read domain
  // reads, and the only thing that crosses is a GRAY pointer, which cannot
  // be read torn. [HarborCdcFifo] is that FIFO.
  //
  // The FIFO alone does not tell the card that a WHOLE block has arrived,
  // and the card cannot pause in the middle of a block on DAT. The CSR
  // slave therefore also publishes a level that inverts once per complete
  // block, and the card counts the changes of it.
  final reqFifo = HarborCdcFifo(
    dataWidth: sdRequestBits,
    depth: sdRequestFifoDepth,
    name: 'sd_req_fifo',
  );
  soc.addSubModule(reqFifo);
  // The card writes a record in the SD clock domain and the runtime reads
  // it in the SoC domain.
  reqFifo.input('wr_clk').srcConnection! <= sdClk;
  reqFifo.input('wr_reset').srcConnection! <= sdReset;
  reqFifo.input('wr_data').srcConnection! <= card.output('req_data');
  reqFifo.input('wr_en').srcConnection! <= card.output('req_valid');
  reqFifo.input('rd_clk').srcConnection! <= sysClk;
  reqFifo.input('rd_reset').srcConnection! <= sysReset;
  reqFifo.input('rd_en').srcConnection! <= sdCard.output('req_pop');
  sdCard.input('req_data').srcConnection! <= reqFifo.output('rd_data');
  // The channel reads EMPTY while the SD domain is in reset. See [sdHeld].
  sdCard.input('req_empty').srcConnection! <=
      reqFifo.output('rd_empty') | sdHeld;

  // The data channel holds FOUR blocks. The card cannot start a block on
  // DAT before it holds all of it, so the channel must hold a whole block,
  // and it must hold SEVERAL for the link to be fast: one block leaves the
  // channel in 4114 SD clocks, which is 165 us at 25 MHz, and one USB
  // full-speed round trip is about 1 ms. A runtime that can hold only one
  // block therefore always answers late, so it must be able to push the
  // blocks of a stream before the card asks for them.
  //
  // The depth costs NOTHING. The buffer is on ONE DP16KD, which is 16
  // kbit, so it holds 512 words of 32 bits: 128 words used one whole
  // DP16KD and left three quarters of it empty. Built from flops the same
  // buffer costs thousands of them, and 128 words of flops alone took the
  // SoC domain from 89 MHz down to 55 MHz. A target with no block RAM
  // falls back to flops on its own, so the flag is safe on every board.
  //
  // The margin is one whole block, so `wr_almost_full` tells the CSR slave
  // that it cannot safely admit another block. The write channel below has
  // another depth, so [HarborCdcFifo] gives the two channels different
  // module definition names.
  final dataFifo = MimicByteLaneCdcFifo(
    depth: sdDataInFifoWords,
    almostFullMargin: sdBlockWords,
    target: target,
    name: 'sd_data_fifo',
  );
  soc.addSubModule(dataFifo);
  dataFifo.input('wr_clk').srcConnection! <= sysClk;
  dataFifo.input('wr_reset').srcConnection! <= sysReset;
  dataFifo.input('wr_data').srcConnection! <= sdCard.output('data_word');
  dataFifo.input('wr_en').srcConnection! <= sdCard.output('data_push');
  dataFifo.input('rd_clk').srcConnection! <= sdClk;
  dataFifo.input('rd_reset').srcConnection! <= sdReset;
  dataFifo.input('rd_en').srcConnection! <= card.output('data_pop');
  // The channel reads NOT FULL while the SD domain is in reset. See
  // [sdHeld]. The card has taken nothing yet, so the channel really is
  // empty, and `DATA_IN_COUNT` keeps its own exact count of the free space
  // whatever this signal says.
  sdCard.input('data_full').srcConnection! <=
      dataFifo.output('wr_full') & ~sdHeld;
  sdCard.input('data_blocked').srcConnection! <=
      dataFifo.output('wr_almost_full') & ~sdHeld;
  card.input('data_word').srcConnection! <= dataFifo.output('rd_data');
  card.input('data_empty').srcConnection! <= dataFifo.output('rd_empty');

  // The tag channel. One entry per block, beside the data channel.
  //
  // The tag names the record that the block answers, and the card throws
  // away a block whose tag names another one. The channel is separate from
  // the data channel because the tag is one byte and the block is 128
  // words: a shared channel would have to carry a word of tag for each
  // block and the card would have to know which word that is.
  //
  // One entry per block the data channel holds. The runtime writes one tag
  // per block and the card takes one off when it TAKES the block that tag
  // names, so the head of this channel always names the head of the data
  // channel.
  final tagFifo = HarborCdcFifo(
    dataWidth: sdTagChannelBits,
    depth: sdTagFifoDepth,
    name: 'sd_tag_fifo',
  );
  soc.addSubModule(tagFifo);
  tagFifo.input('wr_clk').srcConnection! <= sysClk;
  tagFifo.input('wr_reset').srcConnection! <= sysReset;
  tagFifo.input('wr_data').srcConnection! <= sdCard.output('tag_word');
  tagFifo.input('wr_en').srcConnection! <= sdCard.output('tag_push');
  tagFifo.input('rd_clk').srcConnection! <= sdClk;
  tagFifo.input('rd_reset').srcConnection! <= sdReset;
  tagFifo.input('rd_en').srcConnection! <= card.output('data_tag_pop');
  // Reserve both halves of a block together. The tag FIFO has its own full
  // state and may lag a read in this clock domain through its synchronizer.
  sdCard.input('tag_full').srcConnection! <=
      tagFifo.output('wr_full') & ~sdHeld;
  // One entry names one block. The low bits are the sequence tag and the
  // rest is the FILL ADDRESS, which is what places a block that answers no
  // record. The bit numbers come from the field constants, so a field that
  // moves takes both ends of the channel with it.
  card.input('data_tag').srcConnection! <=
      tagFifo.output('rd_data').getRange(0, sdRequestSeqBits);
  card.input('data_fill_lba').srcConnection! <=
      tagFifo
          .output('rd_data')
          .getRange(sdTagChannelLbaLsb, sdTagChannelLbaLsb + sdCommandArgBits);
  card.input('data_fill_valid').srcConnection! <=
      tagFifo.output('rd_data')[sdTagChannelValidBit];
  card.input('data_tag_empty').srcConnection! <= tagFifo.output('rd_empty');

  // The block WRITE channel. It is the mirror of the data channel above and
  // it runs the other way: the card pushes the 512 bytes the host wrote and
  // the runtime takes them.
  //
  // It is the SAME shape and the same size, and it is on BLOCK RAM for the
  // same reason. 128 words of 32 bits built from flops cost about 4800 of
  // them, and that alone took the SoC domain from 89 MHz to 55 MHz. On
  // block RAM it is one DP16KD. A target with no block RAM falls back to
  // flops by itself, so this is safe on every board.
  //
  // The margin is the WHOLE depth, so `wr_almost_full` reads "free space is
  // below 128", which for a channel of 128 words is "the channel holds at
  // least one word". That is the signal the card gates a new write on. It
  // uses the synchronised read pointer, which lags, so it can only ever
  // over-state the occupancy, and over-stating it holds a write off for a
  // few more SD clocks. That is the safe direction. The data channel above
  // takes the same margin so that both stay ONE module definition.
  final outFifo = HarborCdcFifo(
    dataWidth: 32,
    depth: sdDataFifoWords,
    almostFullMargin: sdDataFifoWords,
    target: target,
    blockRam: true,
    name: 'sd_out_fifo',
  );
  soc.addSubModule(outFifo);
  outFifo.input('wr_clk').srcConnection! <= sdClk;
  outFifo.input('wr_reset').srcConnection! <= sdReset;
  outFifo.input('wr_data').srcConnection! <= card.output('out_word');
  outFifo.input('wr_en').srcConnection! <= card.output('out_push');
  outFifo.input('rd_clk').srcConnection! <= sysClk;
  outFifo.input('rd_reset').srcConnection! <= sysReset;
  outFifo.input('rd_en').srcConnection! <= sdCard.output('out_pop');
  sdCard.input('out_data').srcConnection! <= outFifo.output('rd_data');
  // The channel reads EMPTY while the SD domain is in reset, the way the
  // request channel does. See [sdHeld]. A channel that read NOT empty there
  // would hand the runtime a word that no card ever pushed.
  sdCard.input('out_empty').srcConnection! <=
      outFifo.output('rd_empty') | sdHeld;
  // The card reads the WRITE side of the same FIFO. `out_room` says the
  // channel holds no word, and the card takes no new write while a block
  // is still on it. The count of records the card keeps cannot say that:
  // an acknowledgement moves that count whatever it named, so one write of
  // WRITE_ACK that named nothing would have opened the card to a second
  // block while the first was still there.
  card.input('out_room').srcConnection! <= ~outFifo.output('wr_almost_full');
  // The FIFO drops a push into a full channel, so the card counts the
  // pushes that this flag says the channel took.
  card.input('out_full').srcConnection! <= outFifo.output('wr_full');

  // The acknowledge channel. One entry retires one block write and releases
  // the SD host from busy, so it sits in the write latency and is small on
  // purpose: nine bits and four entries.
  //
  // It is a FIFO and not a handshake because a handshake waits for the
  // destination to answer, and the SD domain cannot answer while the host
  // holds its clock still. A FIFO parks the acknowledgement until the host
  // clocks the card again, which is exactly what a host that is waiting on
  // busy does.
  final ackFifo = HarborCdcFifo(
    dataWidth: sdWriteAckBits,
    depth: sdWriteAckFifoDepth,
    name: 'sd_ack_fifo',
  );
  soc.addSubModule(ackFifo);
  ackFifo.input('wr_clk').srcConnection! <= sysClk;
  ackFifo.input('wr_reset').srcConnection! <= sysReset;
  ackFifo.input('wr_data').srcConnection! <= sdCard.output('ack_word');
  ackFifo.input('wr_en').srcConnection! <= sdCard.output('ack_push');
  ackFifo.input('rd_clk').srcConnection! <= sdClk;
  ackFifo.input('rd_reset').srcConnection! <= sdReset;
  ackFifo.input('rd_en').srcConnection! <= card.output('ack_pop');
  card.input('ack_data').srcConnection! <= ackFifo.output('rd_data');
  card.input('ack_empty').srcConnection! <= ackFifo.output('rd_empty');

  // The words the card pushed into the write channel. It is a free-running
  // counter of the SD clock domain, so it takes the gray road that the
  // bring-up counters take.
  final wordsSync = MimicSdGraySync(
    width: sdDataWordCountBits,
    name: 'words_written_sync',
  );
  soc.addSubModule(wordsSync);
  wordsSync.input('gray_in').srcConnection! <=
      card.output('words_written_gray');
  wordsSync.input('clk').srcConnection! <= sysClk;
  wordsSync.input('reset').srcConnection! <= sysReset;
  sdCard.input('words_written').srcConnection! <= wordsSync.output('count');

  // The two levels that cross without a FIFO. Each one is a single bit
  // that the destination samples with a two-flop synchroniser of its own,
  // so the crossing lives in the destination module. See the class docs of
  // [MimicSdCardDevice] and [MimicSdCard].
  card.input('card_enable').srcConnection! <= sdCard.output('card_enable');
  card.input('data_blocks_pushed_gray').srcConnection! <=
      sdCard.output('data_blocks_pushed_gray');
  sdCard.input('sd_read_timeout_toggle').srcConnection! <=
      card.output('read_timeout_toggle');
  card.input('write_back').srcConnection! <= sdCard.output('write_back');
  sdCard.input('sd_write_timeout_toggle').srcConnection! <=
      card.output('write_timeout_toggle');

  // The WORDS the card took off the data channel. It is a free-running
  // counter of the SD clock domain, so it takes the gray road that the
  // bring-up counters take.
  //
  // WORDS and not blocks, because `DATA_IN_COUNT` is built from it. A
  // count that moved a block at a time reported the same free space
  // through the whole 165 us send of one block, and the runtime learned
  // nothing from reading it.
  final wordsConsumedSync = MimicSdGraySync(
    width: sdDataWordCountBits,
    name: 'words_consumed_sync',
  );
  soc.addSubModule(wordsConsumedSync);
  wordsConsumedSync.input('gray_in').srcConnection! <=
      card.output('words_consumed_gray');
  wordsConsumedSync.input('clk').srcConnection! <= sysClk;
  wordsConsumedSync.input('reset').srcConnection! <= sysReset;
  sdCard.input('words_consumed').srcConnection! <=
      wordsConsumedSync.output('count');

  // The activity light. It is not on the bus, so it is a plain submodule on
  // the default clock domain: on an FPGA build that is the PLL domain with
  // the lock-gated reset, so the LED stays dark until the PLL locks.
  //
  // The light is timed in THIS domain and not in the SD clock domain, which
  // the host stops. `sd_activity_toggle` is the crossing: it is a level in
  // the SD domain that inverts once per activity event, and the light holds
  // the two-flop synchroniser and the edge detect that turn each change of
  // it back into one event here.
  //
  // The house patterns of this SoC do not fit a single event. [HarborCdcSync]
  // per bit is for an observation VALUE that may be stale, and a single-bit
  // event carried that way would be missed whenever the source pulse is
  // narrower than the destination clock. [MimicSdGraySync] is for a value
  // that moves every source clock. [HarborCdcHandshake] carries a whole word
  // and waits for an acknowledge, and the SD side cannot acknowledge
  // anything while the host holds the clock still. A TOGGLE needs no
  // acknowledge, has no width to miss and costs one flop on each side.
  if (activityLed) {
    final led = MimicSdActivityLed();
    soc.addSubModule(led);
    final (ledClk, ledReset) = soc.defaultClock;
    led.input('clk').srcConnection! <= ledClk;
    led.input('reset').srcConnection! <= ledReset;
    led.input('activity_toggle').srcConnection! <=
        card.output('sd_activity_toggle');
    soc.exposePin(led, 'led', externalName: mimicLedPinName);
  }

  // Command-level sim ports (test builds only).
  if (tbCmdPorts) {
    const tbPorts = [
      'cmd_data',
      'cmd_valid',
      'resp_ready',
      'cmd_ready',
      'resp_data',
      'resp_valid',
      'resp_last',
      'busy',
    ];
    for (final p in tbPorts) {
      soc.exposePin(device, p, externalName: p);
    }
  }

  soc.buildFabric();
  return soc;
}
