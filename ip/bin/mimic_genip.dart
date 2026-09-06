/// Generates the Mimic SoC RTL + device tree / SVD + ECP5 build scripts.
///
/// Composes a [MimicUsbDevice] (USB-device-to-Wishbone MASTER, the SoC's only
/// bus master) with a [MimicSdCard] (Wishbone SLAVE CSR stub) onto a harbor
/// [HarborSoC] Wishbone fabric, then emits synthesizable SystemVerilog (plus
/// DTS, SVD, ECP5 .lpf, synth.tcl and a Makefile) targeting the OrangeCrab
/// ECP5. The output directory IS the flashable build: the SoC is the synthesis
/// top. A nextpnr pre-place script and a `mimic.json` manifest for the host
/// runtime land beside it.
///
/// Net effect: bytes a host streams over USB bulk become Wishbone reads and
/// writes into the SD card's CSR space. The bridge is the bus master; the SD
/// card stub is the only slave. Harbor's [WishboneDecoder] sits between.
///
/// This binary only reads the command line into a [MimicGenIpConfig] and
/// prints the summary. Every derivation lives in that class, so it is
/// reachable from a unit test.
///
/// Usage:
///   dart run bin/mimic_genip.dart -o out
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:harbor/harbor.dart';
import 'package:mimic/mimic.dart';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption(
      'output',
      abbr: 'o',
      defaultsTo: 'out',
      help: 'Output directory.',
    )
    ..addOption(
      'name',
      defaultsTo: 'MimicSoC',
      help:
          'SoC name (also the generated top module name). The yosys netlist '
          'is named after it (MimicSoC.json), so it never collides with the '
          'mimic.json manifest.',
    )
    ..addOption(
      'board',
      defaultsTo: 'orangecrab-25f',
      help:
          "Target board from Harbor's HarborBoard catalog "
          '(${HarborBoard.byName.keys.join(', ')}). Supplies the '
          'vendor/device/package, the oscillator frequency, the pin sites, '
          'and the program command - so retargeting is one flag, no code '
          'change. --pin overrides individual sites; --target overrides the '
          'whole thing for a board not in the catalog.',
    )
    ..addOption(
      'target',
      help:
          'Escape hatch for a board NOT in the catalog: '
          '"vendor:device:package" (e.g. ecp5:25f:CSFBGA285) with pin sites '
          'from --pin. Overrides --board when set.',
    )
    ..addMultiOption(
      'pin',
      abbr: 'p',
      help:
          'Pin assignment "name=SITE [IO_TYPE] [ATTR=VAL...]" (e.g. clk=A9, '
          'usb_dp=N1). Repeatable. Each one replaces the board catalog entry '
          'of the same name and leaves the other catalog pins alone. The '
          'value goes through verbatim, so the IO type defaults to LVCMOS33 '
          'when it is not stated.',
    )
    ..addOption(
      'osc-freq',
      help:
          'Board oscillator frequency in Hz. Defaults to the --board catalog '
          'rate, and to $mimicClockHz on the --target path where no board '
          'states it.',
    )
    ..addOption(
      'transport',
      defaultsTo: 'usb',
      allowed: MimicGenIpConfig.supportedTransports,
      help: 'Host transport.',
    )
    ..addFlag(
      'enumerate-only',
      negatable: false,
      help:
          'Build the control-only USB variant (bulkEndpoints: false): EP0 '
          'enumeration without the bulk endpoints, for enumeration isolation.',
    )
    ..addOption(
      'cache-blocks',
      defaultsTo: '8',
      help:
          'Host cache size in 512-byte blocks (manifest only in phase 1). '
          '0 is allowed. There is no upper limit check: yosys and nextpnr '
          'are the authority.',
    )
    ..addOption(
      'sd-mode',
      defaultsTo: 'served',
      allowed: MimicGenIpConfig.supportedSdModes,
      help: 'SD data mode. "loopback" is reserved for a later phase.',
    )
    ..addOption(
      'cache-lines',
      defaultsTo: '$sdCacheDefaultLines',
      help:
          'Lines in the BLOCK CACHE of the card, one 512-byte block each. '
          'It must be a power of two, because the index of a direct mapped '
          'store is the low bits of the block address and any other count '
          'needs a divider in the lookup path. This is the store in the '
          'gateware, not the host cache that --cache-blocks names.',
    )
    ..addOption(
      'vid',
      defaultsTo: '0x1209',
      help: 'USB idVendor, hex (default 0x1209, the pid.codes open VID).',
    )
    ..addOption(
      'pid',
      defaultsTo: '0x10C1',
      help: 'USB idProduct, hex (default 0x10C1, Mimic under that VID).',
    )
    ..addOption(
      'serial',
      help: 'USB serial number string (iSerialNumber). No serial when omitted.',
    )
    ..addOption(
      'manufacture-date',
      help:
          'The manufacture date the card reports in the MDT field of its '
          'CID, as ${MimicManufactureDate.formatHelp} With no flag the '
          'generator reads '
          '${MimicManufactureDate.sourceDateEpochVariable}, and with no '
          'variable either it reads the clock, so a card always carries a '
          'date.',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage.');

  final args = parser.parse(argv);
  if (args.flag('help')) {
    stdout.writeln(
      'mimic_genip - generate Mimic SoC RTL + DTS/SVD + ECP5 flow\n',
    );
    stdout.writeln(parser.usage);
    return;
  }

  final oscFreq = args.option('osc-freq');
  // Declarative target + pins (River-style): nothing about the device,
  // package, or pinout is hardcoded in the SoC - it all comes from the CLI,
  // so the same SoC retargets by changing flags.
  final config = MimicGenIpConfig(
    name: args.option('name')!,
    boardName: args.option('board'),
    targetSpec: args.option('target'),
    pinSpecs: args.multiOption('pin'),
    oscHz: oscFreq == null ? null : int.parse(oscFreq),
    transport: args.option('transport')!,
    sdMode: args.option('sd-mode')!,
    cacheBlocks: int.parse(args.option('cache-blocks')!),
    cacheLines: int.parse(args.option('cache-lines')!),
    idVendor: MimicUsbDeviceConfig.parseUsbId(args.option('vid')!, '--vid'),
    idProduct: MimicUsbDeviceConfig.parseUsbId(args.option('pid')!, '--pid'),
    serialNumber: args.option('serial'),
    enumerateOnly: args.flag('enumerate-only'),
    // The flag, then SOURCE_DATE_EPOCH, then the clock. All three levels
    // stay, so no path builds a card with no date. See
    // [MimicManufactureDate].
    manufactureDate: _resolveDate(args.option('manufacture-date')),
  );

  final output = args.option('output')!;
  await config.generateAll(Directory(output));

  stdout.writeln(
    'Generated Mimic SoC (${config.targetDescription}) into $output '
    '(bulk endpoints: ${!config.enumerateOnly}, '
    'card made ${config.manufactureDate})',
  );
  final dir = Directory(output);
  final entries = dir.listSync(recursive: true, followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entry in entries) {
    if (entry is File) {
      stdout.writeln('  ${entry.path}');
    }
  }
}

/// Reads the manufacture date, and stops with a MESSAGE, not a stack trace.
///
/// A bad `--manufacture-date` is an operator mistake, so the tool says what
/// the field accepts and exits 2. A stack trace tells the operator nothing
/// that the message does not.
MimicManufactureDate _resolveDate(String? flag) {
  try {
    final date = MimicManufactureDate.resolve(flag: flag);
    // The range check lives in the build of the CID register, so ask for it
    // HERE. Without this a date that parses but the MDT field cannot hold
    // reaches the generator and stops it with a stack trace instead.
    date.validate();
    return date;
  } on ArgumentError catch (e) {
    stderr.writeln('error: ${e.message}');
    stderr.writeln('       ${MimicManufactureDate.formatHelp}');
    exit(2);
  } on FormatException catch (e) {
    stderr.writeln('error: ${e.message}');
    stderr.writeln('       ${MimicManufactureDate.formatHelp}');
    exit(2);
  }
}
