// Elaboration smoke tests: build the full Mimic SoC for the OrangeCrab
// ECP5 target and a Verilator sim target, generate synthesizable
// SystemVerilog, and assert the netlist carries the MimicSdCard module and
// the USB command engine. Modeled on river's dbg_elab_test pattern.

@TestOn('vm')
library;

import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:mimic/mimic.dart';
import 'package:test/test.dart';

/// The default target a `mimic_genip` build resolves: the orangecrab-25f
/// board catalog entry, whose pins carry the OrangeCrab USB pinout.
HarborFpgaTarget _orangeCrabTarget() =>
    resolveMimicTarget(board: 'orangecrab-25f');

void main() {
  group('buildMimicSoc elaboration', () {
    test(
      'orangecrab ecp5 target generates the SD card + USB engine RTL',
      () async {
        final soc = buildMimicSoc(
          name: 'mimic_elab',
          target: _orangeCrabTarget(),
        );
        await soc.build();
        final sv = soc.generateSynth();
        expect(sv, isNotEmpty);
        expect(sv, contains('MimicSdCard'));
        expect(sv, contains('MimicUsbDevice'));
        expect(sv, contains('MimicUsbCmdEngine'));
        expect(sv, contains('HarborUsbFsDevice'));
        expect(sv, contains('WishboneDecoder'));
      },
    );

    test(
      'verilator sim target generates the SD card + USB engine RTL',
      () async {
        final soc = buildMimicSoc(
          name: 'mimic_sim_elab',
          target: const HarborSimTarget(
            topCell: 'mimic_sim_elab',
            frequency: 48000000,
          ),
        );
        await soc.build();
        final sv = soc.generateSynth();
        expect(sv, isNotEmpty);
        expect(sv, contains('MimicSdCard'));
        expect(sv, contains('MimicUsbDevice'));
        expect(sv, contains('MimicUsbCmdEngine'));
      },
    );

    test(
      'enumerate-only variant elaborates without the EP1 bulk logic',
      () async {
        final soc = buildMimicSoc(
          name: 'mimic_enum_elab',
          target: _orangeCrabTarget(),
          bulkEndpoints: false,
        );
        await soc.build();
        final sv = soc.generateSynth();
        expect(sv, contains('MimicSdCard'));
        expect(sv, contains('MimicUsbCmdEngine'));
      },
    );

    test(
      'ownPads gives the USB device real bidirectional D+/D- ports',
      () async {
        final device = MimicUsbDevice(
          config: MimicUsbDeviceConfig(
            busAddressWidth: mimicBusAddressWidth,
            busDataWidth: 32,
          ),
          tbCmdPorts: false,
          ownPads: true,
        );
        await device.build();
        final sv = device.generateSynth();
        // The port list of the device itself, not of the engines below it.
        final start = sv.indexOf('module MimicUsbDevice (');
        expect(start, greaterThanOrEqualTo(0));
        final ports = sv.substring(start, sv.indexOf(');', start));
        // Real inout ports, one ball per line, and no split driver ports left.
        expect(ports, contains('inout wire usb_dp'));
        expect(ports, contains('inout wire usb_dm'));
        expect(ports, isNot(contains('dp_out')));
        expect(ports, isNot(contains('dm_out')));
        expect(ports, isNot(contains('logic oe')));
        // The tristate drivers really are in the emitted body.
        expect(sv, contains("assign usb_dp = oe ? dp_out : 1'bz"));
        expect(sv, contains("assign usb_dm = oe ? dm_out : 1'bz"));
      },
    );

    test('MimicSdLink generates synthesizable SystemVerilog', () async {
      // Nothing else builds the link today, so this test is the only proof
      // that it emits SystemVerilog and that its split port names survive.
      final link = MimicSdLink(name: 'sd_link_elab');
      await link.build();
      final sv = link.generateSynth();
      expect(sv, isNotEmpty);

      // The port list of the link itself, not of anything below it.
      final start = sv.indexOf('module MimicSdLink (');
      expect(start, greaterThanOrEqualTo(0));
      final ports = sv.substring(start, sv.indexOf(');', start));

      // The ports stay split. The parent owns the tristate, so the link
      // carries no inout of its own.
      expect(ports, contains('input logic cmd_in'));
      expect(ports, contains('output logic cmd_out'));
      expect(ports, contains('output logic cmd_oe'));
      expect(ports, contains('input logic dat_in'));
      expect(ports, contains('output logic dat_out'));
      expect(ports, contains('output logic dat_oe'));
      expect(ports, isNot(contains('inout')));
    });

    test('MimicSdCardFsm generates synthesizable SystemVerilog', () async {
      // Nothing else builds the card state machine today, so this test is
      // the only proof that it emits SystemVerilog and that its split port
      // names and widths survive.
      final fsm = MimicSdCardFsm(name: 'sd_card_fsm_elab');
      await fsm.build();
      final sv = fsm.generateSynth();
      expect(sv, isNotEmpty);

      // The port list of the state machine itself.
      final start = sv.indexOf('module MimicSdCardFsm (');
      expect(start, greaterThanOrEqualTo(0));
      final ports = sv.substring(start, sv.indexOf(');', start));

      // The link side of the module, with the widths that sd_link.dart
      // gives. The card side carries no wire, so there is no inout here.
      expect(ports, contains('input logic clk'));
      expect(ports, contains('input logic reset'));
      expect(ports, contains('input logic [5:0] cmd_index'));
      expect(ports, contains('input logic [31:0] cmd_arg'));
      expect(ports, contains('input logic cmd_valid'));
      expect(ports, contains('input logic cmd_crc_ok'));
      expect(ports, contains('input logic resp_busy'));
      // The CSD is an input. The card holds no CSD of its own, because the
      // runtime owns the personality.
      expect(ports, contains('input logic [127:0] csd'));
      expect(ports, contains('output logic resp_start'));
      expect(ports, contains('output logic [127:0] resp_data'));
      expect(ports, contains('output logic [1:0] resp_kind'));
      expect(ports, contains('output logic [3:0] card_state'));
      expect(ports, isNot(contains('inout')));
    });

    test('MimicSdWritePath generates synthesizable SystemVerilog', () async {
      // The block write sequencer. It is built inside MimicSdCardDevice as
      // well, and this test is what pins its own port list, which is the
      // contract that the SoC wires the two write channels to.
      final path = MimicSdWritePath(name: 'sd_write_path_elab');
      await path.build();
      final sv = path.generateSynth();
      expect(sv, isNotEmpty);

      final start = sv.indexOf('module MimicSdWritePath (');
      expect(start, greaterThanOrEqualTo(0));
      final ports = sv.substring(start, sv.indexOf(');', start));

      expect(ports, contains('input logic clk'));
      expect(ports, contains('input logic reset'));
      expect(ports, contains('input logic enable'));
      expect(ports, contains('input logic start'));
      expect(ports, contains('input logic [31:0] lba'));
      // The room on the write data channel. The card reads the FIFO
      // itself, so a block that the runtime has not taken holds the next
      // write off.
      expect(ports, contains('input logic out_room'));
      expect(ports, contains('output logic [31:0] out_word'));
      expect(ports, contains('output logic out_push'));
      expect(ports, contains('output logic ready'));
      expect(ports, contains('output logic dat_busy'));
      expect(ports, isNot(contains('inout')));
    });

    test('MimicSdCardDevice generates synthesizable SystemVerilog', () async {
      // The card personality is the link and the state machine together.
      // Nothing else builds it today, so this test is the only proof that
      // the pair emits SystemVerilog and that both modules land in it.
      final card = MimicSdCardDevice(name: 'sd_card_device_elab');
      await card.build();
      final sv = card.generateSynth();
      expect(sv, isNotEmpty);

      // Every submodule is in the netlist of the device.
      expect(sv, contains('module MimicSdLink'));
      expect(sv, contains('module MimicSdCardFsm'));
      expect(sv, contains('module MimicSdReadPath'));
      expect(sv, contains('module MimicSdWritePath'));
      // The card register sender, which puts the SCR on DAT for ACMD51.
      // Nothing else builds it today, so this is the only proof that it
      // emits SystemVerilog.
      expect(sv, contains('module MimicSdRegTx'));

      // The port list of the device itself, not of the modules below it.
      final start = sv.indexOf('module MimicSdCardDevice (');
      expect(start, greaterThanOrEqualTo(0));
      final ports = sv.substring(start, sv.indexOf(');', start));

      // The pins stay split. The board level owns the tristate, so the
      // device carries no inout of its own.
      expect(ports, contains('input logic clk'));
      expect(ports, contains('input logic reset'));
      expect(ports, contains('input logic sd_cmd_in'));
      expect(ports, contains('output logic sd_cmd_out'));
      expect(ports, contains('output logic sd_cmd_oe'));
      expect(ports, contains('input logic sd_dat_in'));
      expect(ports, contains('output logic sd_dat_out'));
      expect(ports, contains('output logic sd_dat_oe'));
      // The far side of the CSD crossing: the value and the one clock that
      // loads it.
      expect(ports, contains('input logic [127:0] csd'));
      expect(ports, contains('input logic csd_valid'));
      // The capacity uses a separate coherent snapshot. The command decoder
      // must reject an address before it starts a data transfer.
      expect(ports, contains('input logic [31:0] num_blocks'));
      expect(ports, contains('input logic num_blocks_valid'));
      expect(ports, contains('output logic [3:0] card_state'));
      expect(ports, isNot(contains('inout')));
    });

    test(
      'the board build binds the SD pads and buffers the SD clock',
      () async {
        // The board build is the only one that owns pads. CMD and DAT0 become
        // one bidirectional ball each, and the SD clock reaches the global
        // clock net through a DCCA, because the OrangeCrab puts sd_clk on K1
        // and the board definition does not list K1 as clock capable.
        final soc = buildMimicSoc(
          name: 'mimic_sd_pads_elab',
          target: _orangeCrabTarget(),
          board: HarborBoard.get('orangecrab-25f'),
          ownPads: true,
        );
        await soc.build();
        final sv = soc.generateSynth();

        final start = sv.indexOf('module mimic_sd_pads_elab (');
        expect(start, greaterThanOrEqualTo(0));
        final ports = sv.substring(start, sv.indexOf(');', start));
        expect(ports, contains('input logic sd_clk'));
        expect(ports, contains('inout wire sd_cmd'));
        expect(ports, contains('inout wire sd_dat0'));
        // The split driver ports stay inside. Only the balls reach the top.
        expect(ports, isNot(contains('sd_cmd_out')));
        expect(ports, isNot(contains('sd_dat_oe')));

        // The tristate drivers, one per ball.
        expect(sv, contains("assign sd_cmd = sd_cmd_oe ? sd_cmd_out : 1'bz"));
        expect(sv, contains("assign sd_dat0 = sd_dat_oe ? sd_dat_out : 1'bz"));

        // The clock buffer, and the card clocked from its output and not from
        // the raw pad.
        expect(sv, contains('DCCA  sd_clk_buf(.CLKI(sd_clk)'));
        expect(
          sv,
          contains('MimicSdCardDevice  sd_card_device(.clk(sd_clk_buf_clk)'),
        );
      },
    );

    test('DAT1 to DAT3 are ports, so their pads take the pull-up', () async {
      // The hardware failure this holds: an SD host keeps its command
      // inhibit while DAT[3:0] read busy. A real card holds all four data
      // lines high through pull-ups. The 1-bit datapath reads DAT0 alone,
      // so DAT1 to DAT3 have no logic behind them, and a ball with no
      // constraint has no pull-up and floats. The host then reads a card
      // that is permanently busy and sends no command at all, which looks
      // exactly like a card that never hears the clock.
      //
      // A constraint needs a port. These three ports are what carries the
      // PULLMODE=UP of the board catalog to the ball.
      final board = HarborBoard.get('orangecrab-25f');
      final target = resolveMimicTarget(board: 'orangecrab-25f');
      final soc = buildMimicSoc(
        name: 'mimic_sd_pullup_elab',
        target: target,
        board: board,
        ownPads: true,
      );
      await soc.build();

      for (final pin in mimicSdDatPullupPinNames) {
        expect(
          soc.inputs.keys,
          contains(pin),
          reason: '$pin must be a top-level port or its site is dropped',
        );
      }
      // They are inputs and never balls the design drives.
      expect(soc.outputs.keys, isNot(contains('sd_dat1')));
      expect(soc.inOuts.keys, isNot(contains('sd_dat1')));

      // The port list of the emitted top module carries all three, so the
      // synthesis tool sees a port and builds a pad for it.
      final sv = soc.generateSynth();
      final start = sv.indexOf('module mimic_sd_pullup_elab (');
      expect(start, greaterThanOrEqualTo(0));
      final ports = sv.substring(start, sv.indexOf(');', start));
      expect(ports, contains('input logic sd_dat1'));
      expect(ports, contains('input logic sd_dat2'));
      expect(ports, contains('input logic sd_dat3'));

      // The sites and the pull-up reach the LPF that the build writes.
      // Sites come from the litex-boards gsd_orangecrab r0.2 table.
      final lpf = target.generateConstraints();
      expect(lpf, contains('LOCATE COMP "sd_dat1" SITE "K3";'));
      expect(lpf, contains('LOCATE COMP "sd_dat2" SITE "L3";'));
      expect(lpf, contains('LOCATE COMP "sd_dat3" SITE "M1";'));
      for (final pin in mimicSdDatPullupPinNames) {
        expect(
          lpf,
          contains('IOBUF PORT "$pin" IO_TYPE=LVCMOS33 PULLMODE=UP;'),
          reason: 'without PULLMODE=UP the ball floats and reads busy',
        );
      }

      // The card itself reads none of them. Only DAT0 reaches the card.
      final cardArgs = _instanceArgs(sv, 'MimicSdCardDevice  sd_card_device(');
      expect(cardArgs, isNot(contains('sd_dat1')));
      expect(cardArgs, isNot(contains('sd_dat2')));
      expect(cardArgs, isNot(contains('sd_dat3')));
    });

    test('a board that states a clock-capable SD ball takes no DCCA', () async {
      // The switch reads the board DEFINITION. This board is not in the
      // catalog and its name says nothing, so only [clockCapableSites] can
      // decide. Its sd_clk ball is listed, so the pad drives the card
      // directly and no clock buffer is built.
      const dedicated = HarborBoard(
        name: 'sd-clk-on-a-clock-ball',
        vendor: HarborFpgaVendor.ecp5,
        device: 'lfe5u-25f',
        package: 'CSFBGA285',
        oscillatorHz: mimicClockHz,
        pins: {'clk': 'A9 LVCMOS33', 'sd_clk': 'A10 LVCMOS33'},
        clockCapableSites: {'A9', 'A10'},
      );
      final soc = buildMimicSoc(
        name: 'mimic_sd_dedicated_elab',
        target: dedicated.fpgaTarget(),
        board: dedicated,
      );
      await soc.build();
      final sv = soc.generateSynth();
      expect(sv, isNot(contains('DCCA')));
      expect(sv, contains('MimicSdCardDevice  sd_card_device(.clk(sd_clk)'));
    });

    test('card_state crosses to the bus domain and reaches the CSR', () async {
      final soc = buildMimicSoc(
        name: 'mimic_sd_cdc_elab',
        target: _orangeCrabTarget(),
        board: HarborBoard.get('orangecrab-25f'),
      );
      await soc.build();
      final sv = soc.generateSynth();

      // One two-flop synchroniser per state bit, every one of them clocked
      // by the BUS domain and fed from the SD domain.
      expect(sv, contains('module HarborCdcSync'));
      for (var i = 0; i < sdCardStateBits; i++) {
        expect(
          sv,
          contains(
            'HarborCdcSync  card_state_sync_$i(.async_in((card_state[$i]))',
          ),
        );
      }
      // The CSR slave takes the synchronised bits, not the raw ones.
      final args = _instanceArgs(sv, 'MimicSdCard  mimic_sd_card(');
      expect(args, contains('.card_state('));
      expect(args, contains('sync_out'));

      // Bit i of the CSR input must be the synchroniser of bit i of the
      // card state. The rswizzle that builds the bus is the only thing
      // that decides this, and a reversed rswizzle still instantiates
      // every synchroniser and still ties every one of them to the CSR,
      // so nothing above catches it. CARD_STATE would then report a state
      // that the card was never in.
      final syncNets = [
        for (var i = 0; i < sdCardStateBits; i++)
          _argNet(
            _instanceArgs(sv, 'HarborCdcSync  card_state_sync_$i('),
            'sync_out',
          ),
      ];
      expect(
        syncNets.toSet(),
        hasLength(sdCardStateBits),
        reason: 'every synchroniser drives a net of its own',
      );
      expect(
        _argBusNets(args, 'card_state'),
        equals(syncNets.reversed.toList()),
        reason:
            'card_state[0] must be the synchroniser of card state bit 0, '
            'and the SystemVerilog concatenation runs from the most '
            'significant bit down',
      );

      // The slave really decodes the CARD_STATE offset onto that input.
      expect(sv, contains("8'h44 :"));
    });

    test('the SD counters cross as gray codes and reach the CSR', () async {
      final soc = buildMimicSoc(
        name: 'mimic_dbg_cdc_elab',
        target: _orangeCrabTarget(),
        board: HarborBoard.get('orangecrab-25f'),
      );
      await soc.build();
      final sv = soc.generateSynth();

      // The counters live in the SD clock domain, inside the card.
      expect(sv, contains('module MimicSdGrayCounter_$sdDbgClkBits'));
      expect(sv, contains('module MimicSdGrayCounter_$sdDbgEventBits'));
      final cardSv = sv.substring(sv.indexOf('module MimicSdCardDevice'));
      final cardBody = cardSv.substring(0, cardSv.indexOf('\nmodule '));
      final cardArgs = _instanceArgs(sv, 'MimicSdCardDevice  sd_card_device(');
      expect(
        _argNet(cardArgs, 'clk'),
        equals('sd_clk_buf_clk'),
        reason: 'the counters must count the SD clock, not the bus clock',
      );

      // Each counter takes the clock and the reset of the card, which is
      // the SD clock and the MimicResetSync output. A counter on any other
      // reset would come up holding a count nobody made.
      for (final port in const [
        'dbg_sd_clk',
        'dbg_sd_cmd',
        'dbg_sd_crc_err',
        'dbg_sd_resp',
      ]) {
        final args = _instanceArgs(
          cardBody,
          'MimicSdGrayCounter_${port == 'dbg_sd_clk' ? sdDbgClkBits : sdDbgEventBits}  ${port}_counter(',
        );
        expect(
          _argNet(args, 'clk'),
          equals('clk'),
          reason: '$port must count in the SD clock domain',
        );
        expect(
          _argNet(args, 'reset'),
          equals('reset'),
          reason: '$port must take the reset the card takes',
        );
      }

      // The assert of that reset needs no clock, so a card that never sees
      // an SD clock still publishes 0 and not X.
      final counterSv = sv.substring(
        sv.indexOf('module MimicSdGrayCounter_$sdDbgClkBits'),
      );
      expect(
        counterSv.substring(0, counterSv.indexOf('endmodule')),
        contains('always_ff @(posedge clk or posedge reset)'),
        reason: 'the counters must reset with no clock edge at all',
      );

      // The clock counter is gated by nothing. A counter with a condition
      // on its increment could not prove that the clock arrives.
      expect(
        cardBody,
        contains(
          "MimicSdGrayCounter_$sdDbgClkBits  dbg_sd_clk_counter(.clk(clk),"
          ".reset(reset),.inc(1'h1)",
        ),
        reason: 'DBG_SD_CLK must count every clock and nothing must gate it',
      );

      // One crossing per counter, on the bus clock, fed from the card.
      final csrArgs = _instanceArgs(sv, 'MimicSdCard  mimic_sd_card(');
      final csrClk = _argNet(csrArgs, 'clk');
      for (final port in const [
        'dbg_sd_clk',
        'dbg_sd_cmd',
        'dbg_sd_crc_err',
        'dbg_sd_resp',
      ]) {
        final syncArgs = _instanceArgs(
          sv,
          RegExp('MimicSdGraySync_\\d+_\\d+  ${port}_sync\\(')
              .firstMatch(sv)!
              .group(0)!,
        );
        expect(
          _argNet(syncArgs, 'clk'),
          equals(csrClk),
          reason: 'the destination side of $port runs on the bus clock',
        );
        // The source of the crossing is the GRAY output of the card and
        // not a binary count. A binary count crossed per bit would tear.
        expect(
          _argNet(syncArgs, 'gray_in'),
          equals(_argNet(cardArgs, '${port}_gray')),
          reason: 'the crossing must take the gray word the card publishes',
        );
        // The CSR reads the converted count, which is the OUTPUT of the
        // crossing and never the word that goes into it.
        expect(
          _argNet(csrArgs, port),
          equals(_argNet(syncArgs, 'count')),
          reason: 'the CSR must read the settled count of the crossing',
        );
        expect(
          _argNet(csrArgs, port),
          isNot(equals(_argNet(cardArgs, '${port}_gray'))),
          reason: 'a CSR fed the gray word would report a wrong number',
        );
      }

      // Every synchroniser bit is a HarborCdcSync, the same two-flop cell
      // the card state uses.
      expect(sv, contains('module MimicSdGraySync_'));
      expect(sv, contains('HarborCdcSync  gray_sync_0('));

      // The slave really decodes the four offsets.
      expect(sv, contains("8'h58 :"));
      expect(sv, contains("8'h5c :"));
      expect(sv, contains("8'h60 :"));
      expect(sv, contains("8'h64 :"));
    });

    test('the CSD and capacity cross through handshakes', () async {
      final soc = buildMimicSoc(
        name: 'mimic_csd_cdc_elab',
        target: _orangeCrabTarget(),
        board: HarborBoard.get('orangecrab-25f'),
      );
      await soc.build();
      final sv = soc.generateSynth();

      // One handshake, not 128 synchronisers. A per-bit crossing would let
      // the card read a CSD that is part old and part new.
      expect(sv, contains('module HarborCdcHandshake'));
      final cdcArgs = _instanceArgs(sv, 'HarborCdcHandshake  csd_cdc(');
      final capacityArgs = _instanceArgs(
        sv,
        'HarborCdcHandshake  num_blocks_cdc(',
      );
      final csrArgs = _instanceArgs(sv, 'MimicSdCard  mimic_sd_card(');
      final cardArgs = _instanceArgs(sv, 'MimicSdCardDevice  sd_card_device(');

      expect(
        cdcArgs,
        contains(".src_valid(1'h1)"),
        reason: 'the request stands, so a write always reaches the card',
      );
      expect(
        _argNet(cdcArgs, 'dst_clk'),
        equals('sd_clk_buf_clk'),
        reason: 'the destination of the crossing is the SD clock domain',
      );

      // I2: `dst_ready` is `~dst_valid` and NOT a constant. Tied high, the
      // acknowledge of the destination would drop on the very next SD
      // clock and rise again while the request still stands, which is a
      // square wave and not a handshake. `~dst_valid` holds the
      // acknowledge as a level until the request drops, which is the four
      // phase contract and gives the source a stable capture window.
      expect(
        cdcArgs,
        isNot(contains(".dst_ready(1'h1)")),
        reason: 'a constant ready breaks the four phase handshake',
      );
      expect(
        cdcArgs,
        contains(".dst_ready((~${_argNet(cdcArgs, 'dst_valid')}))"),
        reason: 'the acknowledge stands until the request drops',
      );

      // The CSR slave gives the 128-bit CSD to the source side, and the card
      // takes the far side of the crossing and not the raw register.
      expect(_argNet(cdcArgs, 'src_data'), equals(_argNet(csrArgs, 'csd')));
      expect(_argNet(cdcArgs, 'dst_data'), equals(_argNet(cardArgs, 'csd')));
      expect(
        _argNet(cdcArgs, 'dst_valid'),
        equals(_argNet(cardArgs, 'csd_valid')),
      );
      expect(
        _argNet(capacityArgs, 'dst_valid'),
        equals(_argNet(cardArgs, 'num_blocks_valid')),
      );
      expect(
        _argNet(capacityArgs, 'dst_clk'),
        equals(_argNet(cdcArgs, 'dst_clk')),
      );

      // The slave really decodes the four CSD offsets.
      for (final offset in MimicReg.csd) {
        expect(sv, contains("8'h${offset.toRadixString(16)} :"));
      }
    });

    test(
      'generateAll writes the rtl filelist, constraints and scripts',
      () async {
        final dir = Directory.systemTemp.createTempSync('mimic_elab');
        addTearDown(() => dir.deleteSync(recursive: true));

        final soc = buildMimicSoc(
          name: 'mimic_gen_elab',
          target: _orangeCrabTarget(),
        );
        await soc.generateAll(dir);

        // RTL filelist references every generated module.
        final filelist = File('${dir.path}/filelist.f').readAsStringSync();
        expect(filelist, contains('MimicSdCard'));
        expect(filelist, contains('MimicUsbDevice'));
        expect(filelist, contains('MimicUsbCmdEngine'));
        expect(filelist, contains('HarborUsbFsDevice'));

        // The emitted SD card RTL really is the CSR stub.
        final rtlDir = Directory('${dir.path}/rtl');
        final sdFile = rtlDir.listSync().firstWhere(
          (f) => f.path.endsWith('.sv') && f.path.contains('MimicSdCard'),
        );
        expect(sdFile, isNotNull);
        final sdSv = File(sdFile.path).readAsStringSync();
        expect(sdSv, contains('module MimicSdCard'));

        // DTS / SVD / constraints / scripts land beside the RTL.
        expect(File('${dir.path}/mimic_gen_elab.dts').existsSync(), isTrue);
        expect(File('${dir.path}/mimic_gen_elab.svd').existsSync(), isTrue);
        final lpf = File('${dir.path}/mimic_gen_elab.lpf').readAsStringSync();
        expect(lpf, contains('usb_dp'));
        expect(lpf, contains('N1'));
        expect(lpf, contains('usb_pullup'));
        expect(lpf, contains('A9'));
        expect(File('${dir.path}/synth.tcl').existsSync(), isTrue);
        expect(File('${dir.path}/Makefile').existsSync(), isTrue);

        // The device tree carries the mimic compatible string and the CSR
        // reg window at the fabric base.
        final dts = File('${dir.path}/mimic_gen_elab.dts').readAsStringSync();
        expect(dts, contains('lilithsemi,mimic'));
        expect(dts, contains('lilithsemi,mimic-sd-card'));
      },
    );
  });
}

/// The port list of one module instance in emitted SystemVerilog.
///
/// [head] is the text that starts the instance, such as
/// `MimicSdCard  mimic_sd_card(`. The result is everything up to the
/// closing parenthesis of the instance.
String _instanceArgs(String sv, String head) {
  final start = sv.indexOf(head);
  expect(start, greaterThanOrEqualTo(0), reason: 'no instance $head');
  final rest = sv.substring(start);
  return rest.substring(0, rest.indexOf(');'));
}

/// The nets that [args] ties to a CONCATENATED [port], most significant
/// first. That is the order SystemVerilog writes a concatenation in.
List<String> _argBusNets(String args, String port) {
  final at = args.indexOf('.$port(');
  expect(at, greaterThanOrEqualTo(0), reason: 'no port $port in $args');
  final open = args.indexOf('{', at);
  final close = args.indexOf('}', open);
  expect(open, greaterThanOrEqualTo(0), reason: '$port is not a bus');
  expect(close, greaterThan(open), reason: '$port has no end');
  return args
      .substring(open + 1, close)
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}

/// The net that [args] ties to [port].
String _argNet(String args, String port) {
  final match = RegExp('\\.$port\\(([A-Za-z0-9_\\[\\]:]*)\\)').firstMatch(args);
  expect(match, isNotNull, reason: 'no port $port in $args');
  return match!.group(1)!;
}
