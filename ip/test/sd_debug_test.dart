// The SD bring-up counters and the gray crossing that carries them.
//
// The failure this file is written for: an SD host fails at CMD0 and the
// only observation register of the card, CARD_STATE, reads `idle`. Three
// faults give that same reading and each one needs a different repair. No
// SD clock reaches the fabric; the clock arrives and no command is framed;
// commands are framed and fail CRC7. The four counters separate them, and
// a counter that reports a number the hardware never held would send a
// person after a fault that never happened. Every check below therefore
// holds one of two things: what a counter counts, or that a bus read of it
// cannot be torn.
//
// The bench is the SoC path in the small: the card in the SD clock domain,
// the reset synchroniser that gives that domain its reset, the four gray
// crossings, and the CSR slave in the bus clock domain. The two clocks are
// separate ports, so the test drives the bus clock with a generator and the
// SD clock by hand.

@TestOn('vm')
library;

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';

/// SD clocks the bench idles before it reads a counter back.
///
/// The crossing costs two bus clocks on the destination side. The bus
/// clock runs far faster than this gap, so the count a read gives after it
/// is the count the SD domain holds.
const int _settleClocks = 8;

/// SD clocks the clock-counter test runs between its two reads.
///
/// The number is a plain literal. The test reads the counter, drives
/// exactly this many clocks and reads it again, so the expected difference
/// comes from the count of clocks the test itself drove and never from the
/// design.
const int _clockRunClocks = 100;

/// Resets the simulator between tests, safely for an ASYNCHRONOUS reset.
///
/// A `Sequential` with an asynchronous reset watches its reset signal the
/// same way it watches its clock, and elaboration alone makes that signal
/// move. ROHD then waits for the next clock-stable event, and
/// `Simulator.reset()` closes that event stream while the wait stands. One
/// tick of the simulator retires the wait before the reset lands.
Future<void> _resetSimulator() async {
  if (!Simulator.simulationHasEnded) {
    Simulator.setMaxSimTime(1);
    await Simulator.run();
  }
  await Simulator.reset();
}

/// The SoC path around the bring-up counters, in the small.
///
/// It holds what the SoC holds on that path and wires it the same way: the
/// card in the SD clock domain, [MimicResetSync] to give that domain a
/// reset that asserts with no clock, one [MimicSdGraySync] per counter, and
/// the CSR slave in the bus clock domain. `card_state` and the CSD take the
/// same roads they take in the SoC, because the CSR slave and the card need
/// those inputs driven.
class _DebugBridge extends BridgeModule {
  /// The CSR slave a runtime reads the counters from.
  late final MimicSdCard csr;

  /// The card personality on the SD bus. It holds the four counters.
  late final MimicSdCardDevice card;

  /// The reset of the SD clock domain.
  late final MimicResetSync sdResetSync;

  /// The destination side of each crossing, by CSR port name.
  final Map<String, MimicSdGraySync> graySyncs = {};

  _DebugBridge({String name = 'debug_bridge'})
    : super('DebugBridge', name: name) {
    createPort('sys_clk', PortDirection.input);
    createPort('sd_clk', PortDirection.input);
    createPort('sys_reset', PortDirection.input);
    createPort('wb_cyc', PortDirection.input);
    createPort('wb_stb', PortDirection.input);
    createPort('wb_we', PortDirection.input);
    createPort('wb_adr', PortDirection.input, width: 12);
    createPort('wb_dat', PortDirection.input, width: 32);
    createPort('wb_sel', PortDirection.input, width: 4);
    createPort('sd_cmd_in', PortDirection.input);
    createPort('sd_dat_in', PortDirection.input);
    addOutput('wb_ack');
    addOutput('wb_miso', width: 32);
    addOutput('sd_cmd_out');
    addOutput('sd_cmd_oe');
    addOutput('sd_dat_out');
    addOutput('sd_dat_oe');

    final sysClk = input('sys_clk');
    final sdClk = input('sd_clk');
    final sysReset = input('sys_reset');

    // The reset of the SD clock domain. It goes high with no SD clock at
    // all and drops two SD clock edges after the SoC releases it, which is
    // what the SoC gives the card.
    sdResetSync = MimicResetSync(name: 'sd_reset_sync');
    addSubModule(sdResetSync);
    sdResetSync.input('clk').srcConnection! <= sdClk;
    sdResetSync.input('async_reset').srcConnection! <= sysReset;
    final sdReset = sdResetSync.output('reset');

    csr = MimicSdCard(baseAddress: 0, name: 'mimic_sd_card');
    addSubModule(csr);
    card = MimicSdCardDevice(name: 'sd_card_device');
    addSubModule(card);

    csr.input('clk').srcConnection! <= sysClk;
    csr.input('reset').srcConnection! <= sysReset;
    csr.input('bus_CYC').srcConnection! <= input('wb_cyc');
    csr.input('bus_STB').srcConnection! <= input('wb_stb');
    csr.input('bus_WE').srcConnection! <= input('wb_we');
    csr.input('bus_ADR').srcConnection! <= input('wb_adr');
    csr.input('bus_DAT_MOSI').srcConnection! <= input('wb_dat');
    csr.input('bus_SEL').srcConnection! <= input('wb_sel');
    output('wb_ack') <= csr.output('bus_ACK');
    output('wb_miso') <= csr.output('bus_DAT_MISO');

    card.input('clk').srcConnection! <= sdClk;
    card.input('reset').srcConnection! <= sdReset;
    card.input('sd_cmd_in').srcConnection! <= input('sd_cmd_in');
    card.input('sd_dat_in').srcConnection! <= input('sd_dat_in');
    output('sd_cmd_out') <= card.output('sd_cmd_out');
    output('sd_cmd_oe') <= card.output('sd_cmd_oe');
    output('sd_dat_out') <= card.output('sd_dat_out');
    output('sd_dat_oe') <= card.output('sd_dat_oe');

    final stateBits = <Logic>[];
    for (var i = 0; i < sdCardStateBits; i++) {
      final sync = HarborCdcSync(name: 'card_state_sync_$i');
      addSubModule(sync);
      sync.input('async_in').srcConnection! <= card.output('card_state')[i];
      sync.input('dst_clk').srcConnection! <= sysClk;
      sync.input('dst_reset').srcConnection! <= sysReset;
      stateBits.add(sync.output('sync_out'));
    }
    csr.input('card_state').srcConnection! <= stateBits.rswizzle();

    // The four counters, each one crossed as a gray code.
    final dbg = <String, ({String cardPort, int width})>{
      'dbg_sd_clk': (cardPort: 'dbg_sd_clk_gray', width: sdDbgClkBits),
      'dbg_sd_cmd': (cardPort: 'dbg_sd_cmd_gray', width: sdDbgEventBits),
      'dbg_sd_crc_err': (
        cardPort: 'dbg_sd_crc_err_gray',
        width: sdDbgEventBits,
      ),
      'dbg_sd_resp': (cardPort: 'dbg_sd_resp_gray', width: sdDbgEventBits),
    };
    dbg.forEach((csrPort, spec) {
      final sync = MimicSdGraySync(width: spec.width, name: '${csrPort}_sync');
      addSubModule(sync);
      sync.input('gray_in').srcConnection! <= card.output(spec.cardPort);
      sync.input('clk').srcConnection! <= sysClk;
      sync.input('reset').srcConnection! <= sysReset;
      csr.input(csrPort).srcConnection! <= sync.output('count');
      graySyncs[csrPort] = sync;
    });

    // The CSD path. Nothing here reads the CSD, and the card needs both
    // inputs driven or they hold X.
    final cdc = HarborCdcHandshake(
      dataWidth: sdResponseRegBits,
      name: 'csd_cdc',
    );
    addSubModule(cdc);
    cdc.input('src_clk').srcConnection! <= sysClk;
    cdc.input('src_reset').srcConnection! <= sysReset;
    cdc.input('src_data').srcConnection! <= csr.output('csd');
    cdc.input('src_valid').srcConnection! <= Const(1);
    cdc.input('dst_clk').srcConnection! <= sdClk;
    cdc.input('dst_reset').srcConnection! <= sdReset;
    cdc.input('dst_ready').srcConnection! <= ~cdc.output('dst_valid');
    card.input('csd').srcConnection! <= cdc.output('dst_data');
    card.input('csd_valid').srcConnection! <= cdc.output('dst_valid');

    // The block read path is off in this bench. Every input needs a
    // driver, because an input that nothing drives holds X and the X
    // reaches the registers of the read path.
    card.input('card_enable').srcConnection! <= Const(0);
    card.input('data_word').srcConnection! <= Const(0, width: 32);
    card.input('data_empty').srcConnection! <= Const(1);
    card.input('data_blocks_pushed_gray').srcConnection! <=
        Const(0, width: sdBlockCountBits);
    // The tag channel of the block read path. No test here reads a block,
    // so the channel is empty and its tag names no request.
    card.input('data_tag').srcConnection! <= Const(0, width: sdRequestSeqBits);
    card.input('data_tag_empty').srcConnection! <= Const(1);

    // The runtime end of the block read channels. This bench holds no
    // FIFO, so the request channel reads empty and the data channel never
    // fills.
    csr.input('req_data').srcConnection! <= Const(0, width: sdRequestBits);
    csr.input('req_empty').srcConnection! <= Const(1);
    csr.input('data_full').srcConnection! <= Const(0);
    csr.input('data_blocked').srcConnection! <= Const(0);
    csr.input('tag_full').srcConnection! <= Const(0);
    csr.input('words_consumed').srcConnection! <=
        Const(0, width: sdDataWordCountBits);
    csr.input('sd_read_timeout_toggle').srcConnection! <= Const(0);
  }
}

/// The bench: the modules, the two clocks and the bus a test drives.
class _Bench {
  /// The design under test.
  final _DebugBridge bridge;

  /// The host that drives the SD bus. It is null in a test that gives the
  /// card no SD clock at all.
  final SdHost? host;

  /// The free-running bus clock. It is asynchronous to the SD clock.
  final Logic sysClk;

  /// The SD clock. The test or the host model drives it by hand.
  final Logic sdClk;

  /// The Wishbone master signals.
  final Logic cyc;
  final Logic stb;
  final Logic we;
  final Logic adr;

  _Bench({
    required this.bridge,
    required this.host,
    required this.sysClk,
    required this.sdClk,
    required this.cyc,
    required this.stb,
    required this.we,
    required this.adr,
  });
}

/// Builds the bench and releases the reset.
///
/// The bus clock period is 6 and one SD clock period is 10, so the two
/// domains drift against each other the way two real clocks do and no SD
/// clock edge ever lands on a bus clock edge.
///
/// With [runSdClock] false the SD clock stays at 0 and NEVER ticks, and the
/// bench builds no host model. That is the board this whole file is written
/// for: the pad is dead, or the clock buffer is dead, or the host never
/// clocks the card.
Future<_Bench> _setUp({bool runSdClock = true}) async {
  final bridge = _DebugBridge();
  final sdClk = Logic(name: 'sd_clk');
  final sysReset = Logic(name: 'sys_reset');
  final cmdIn = Logic(name: 'sd_cmd_in');
  final datIn = Logic(name: 'sd_dat_in');
  final cyc = Logic(name: 'wb_cyc');
  final stb = Logic(name: 'wb_stb');
  final we = Logic(name: 'wb_we');
  final adr = Logic(name: 'wb_adr', width: 12);
  final dat = Logic(name: 'wb_dat', width: 32);
  final sel = Logic(name: 'wb_sel', width: 4);
  final sysClk = SimpleClockGenerator(6).clk;

  bridge.input('sys_clk').srcConnection! <= sysClk;
  bridge.input('sd_clk').srcConnection! <= sdClk;
  bridge.input('sys_reset').srcConnection! <= sysReset;
  bridge.input('sd_cmd_in').srcConnection! <= cmdIn;
  bridge.input('sd_dat_in').srcConnection! <= datIn;
  bridge.input('wb_cyc').srcConnection! <= cyc;
  bridge.input('wb_stb').srcConnection! <= stb;
  bridge.input('wb_we').srcConnection! <= we;
  bridge.input('wb_adr').srcConnection! <= adr;
  bridge.input('wb_dat').srcConnection! <= dat;
  bridge.input('wb_sel').srcConnection! <= sel;
  await bridge.build();

  final host = runSdClock
      ? SdHost(
          clk: sdClk,
          cmdOut: cmdIn,
          datOut: datIn,
          cardCmd: bridge.output('sd_cmd_out'),
          cardCmdOe: bridge.output('sd_cmd_oe'),
          cardDat: bridge.output('sd_dat_out'),
          cardDatOe: bridge.output('sd_dat_oe'),
        )
      : null;

  sdClk.inject(0);
  sysReset.inject(0);
  cmdIn.inject(1);
  datIn.inject(1);
  cyc.inject(0);
  stb.inject(0);
  we.inject(0);
  adr.inject(0);
  dat.inject(0);
  sel.inject(0xF);
  Simulator.setMaxSimTime(4000000);
  unawaited(Simulator.run());
  // Let the injected values settle before the reset moves. ROHD drives X
  // when two triggers of one Sequential move in the same time step.
  await _wait(20);

  sysReset.inject(1);
  await _wait(60);
  sysReset.inject(0);
  if (host != null) {
    // The SD domain needs edges before its reset releases, and the framer
    // arms only after CMD stays high for the command gap.
    await host.idle(sdCommandGapClocks);
  } else {
    await _wait(60);
  }
  return _Bench(
    bridge: bridge,
    host: host,
    sysClk: sysClk,
    sdClk: sdClk,
    cyc: cyc,
    stb: stb,
    we: we,
    adr: adr,
  );
}

/// Waits [amount] simulated time units with no hand-driven clock running.
Future<void> _wait(int amount) {
  final done = Completer<void>();
  Simulator.registerAction(Simulator.time + amount, done.complete);
  return done.future;
}

/// Runs one Wishbone read cycle on the bus clock and returns the raw word.
///
/// The result is the [LogicValue] and not an int, so a caller can tell an X
/// from a 0. A register that reads X is the failure this file exists to
/// stop: a runtime cannot act on it and it looks like nothing at all in a
/// hex dump.
Future<LogicValue> _wbReadValue(_Bench b, int addr) async {
  await b.sysClk.nextPosedge;
  b.adr.inject(addr);
  b.we.inject(0);
  b.cyc.inject(1);
  b.stb.inject(1);
  for (var i = 0; i < 16; i++) {
    await b.sysClk.nextPosedge;
    if (b.bridge.output('wb_ack').value == LogicValue.one) {
      b.cyc.inject(0);
      b.stb.inject(0);
      return b.bridge.output('wb_miso').value;
    }
  }
  fail('the CSR slave gave no ACK in 16 bus clocks');
}

/// Runs one Wishbone read cycle and returns the word as a number.
Future<int> _wbRead(_Bench b, int addr) async {
  final value = await _wbReadValue(b, addr);
  expect(
    value.isValid,
    isTrue,
    reason:
        'the CSR at 0x${addr.toRadixString(16)} read $value. A counter that '
        'reads X says nothing a runtime can act on.',
  );
  return value.toInt();
}

/// Sends one command frame byte by byte, with no CRC7 of its own.
///
/// [bytes] is the whole 48-bit frame, most significant byte first. A test
/// that wants a bad CRC7 builds the frame with [sdCommandFrame] and changes
/// the last byte, so the frame is legal in every other way and only the
/// CRC7 field is wrong.
Future<void> _sendFrame(SdHost host, List<int> bytes) async {
  for (final b in bytes) {
    for (var i = 7; i >= 0; i--) {
      host.driveCmd((b >> i) & 1);
      await host.tick();
    }
  }
  host.driveCmd(1);
}

/// The number of bits that differ between [a] and [b].
int _hammingDistance(LogicValue a, LogicValue b) {
  expect(a.width, equals(b.width));
  var count = 0;
  for (var i = 0; i < a.width; i++) {
    if (a[i] != b[i]) count++;
  }
  return count;
}

/// Every value [signal] held, in order, with a repeat of one value removed.
///
/// The samples come from `postTick`, which runs after every signal of a
/// time step has settled, so no entry is a value caught halfway through a
/// propagation.
class _ValueTrace {
  final List<LogicValue> values = [];
  late final StreamSubscription<void> _sub;

  _ValueTrace(Logic signal) {
    _sub = Simulator.postTick.listen((_) {
      final v = signal.value;
      if (values.isEmpty || values.last != v) values.add(v);
    });
  }

  Future<void> stop() => _sub.cancel();
}

/// A small round trip of the gray helpers, for the unit test below.
class _GrayRoundTrip extends BridgeModule {
  _GrayRoundTrip({required int width})
    : super('GrayRoundTrip_$width', name: 'gray_round_trip') {
    createPort('bin', PortDirection.input, width: width);
    addOutput('gray', width: width);
    addOutput('back', width: width);
    output('gray') <= sdBinaryToGray(input('bin'));
    output('back') <= sdGrayToBinary(sdBinaryToGray(input('bin')));
  }
}

void main() {
  tearDown(_resetSimulator);

  group('the gray code itself', () {
    test('every code round trips and neighbours differ in one bit', () async {
      // 6 bits is 64 values, which is every value of the code. The check
      // walks them all: the round trip must give the number back, and two
      // numbers one apart must differ in EXACTLY one bit. The second is
      // the property the whole crossing rests on.
      const width = 6;
      final dut = _GrayRoundTrip(width: width);
      await dut.build();

      final codes = <int>[];
      for (var value = 0; value < 1 << width; value++) {
        dut.input('bin').put(value);
        expect(
          dut.output('back').value.toInt(),
          equals(value),
          reason: 'the round trip lost the value $value',
        );
        codes.add(dut.output('gray').value.toInt());
      }

      // The expected codes are the ones a person writes down for the first
      // few numbers, not ones this test derives the way the design does.
      expect(codes.sublist(0, 8), equals([0, 1, 3, 2, 6, 7, 5, 4]));
      // Every code is a different number, so the map loses nothing.
      expect(codes.toSet(), hasLength(1 << width));

      for (var i = 1; i < codes.length; i++) {
        final differing = (codes[i] ^ codes[i - 1]).toRadixString(2).split('');
        expect(
          differing.where((c) => c == '1').length,
          equals(1),
          reason:
              'the codes of ${i - 1} and $i differ in more than one bit, so '
              'a crossing of them could tear',
        );
      }
      // The wrap is one more step, and it also changes one bit. A counter
      // wraps in the field, so this is not a corner that never runs.
      expect(codes.first ^ codes.last, equals(1 << (width - 1)));
    });

    test('a counter of one bit is refused', () {
      expect(() => MimicSdGrayCounter(width: 1), throwsArgumentError);
      expect(() => MimicSdGraySync(width: 1), throwsArgumentError);
      expect(
        () => MimicSdGraySync(width: 8, stages: 1),
        throwsArgumentError,
        reason: 'one flop gives a moving bit no time to settle',
      );
    });
  });

  group('a card whose SD clock never ticks', () {
    test('every counter reads exactly 0, and never X', () async {
      // This is the case the whole feature is for. The suspicion on the
      // bench is that no SD clock reaches the fabric at all. DBG_SD_CLK
      // then has to read 0, because a runtime that polls it twice and sees
      // 0 both times has its diagnosis. An X would look like a dead read
      // path instead, and would send a person after the wrong fault.
      //
      // The card is clocked by the SD clock and it never gets an edge, so
      // nothing in the SD domain can reset synchronously. Only the
      // ASYNCHRONOUS assert inside the counters puts the 0 there.
      final b = await _setUp(runSdClock: false);
      expect(
        b.sdClk.value,
        LogicValue.zero,
        reason: 'this bench must give the card no clock edge at all',
      );

      for (final reg in MimicReg.dbgSd) {
        final value = await _wbReadValue(b, reg);
        expect(
          value.isValid,
          isTrue,
          reason:
              'the counter at 0x${reg.toRadixString(16)} read $value with no '
              'SD clock. X is the one answer a bring-up cannot use.',
        );
        expect(
          value.toInt(),
          equals(0),
          reason:
              'the counter at 0x${reg.toRadixString(16)} counted something '
              'with no SD clock at all',
        );
      }

      // Time passes on the bus side and nothing changes, because nothing
      // in the SD domain can move.
      await _wait(500);
      for (final reg in MimicReg.dbgSd) {
        expect(await _wbRead(b, reg), equals(0));
      }
      await Simulator.endSimulation();
    });
  });

  group('DBG_SD_CLK', () {
    test('it counts clock ticks while nothing else happens', () async {
      final b = await _setUp();
      final host = b.host!;

      final before = await _wbRead(b, MimicReg.dbgSdClk);
      // Exactly this many clocks, with CMD released the whole time. No
      // command is framed and the card answers nothing, so only the clock
      // counter may move.
      await host.idle(_clockRunClocks);
      await host.idle(_settleClocks);
      final after = await _wbRead(b, MimicReg.dbgSdClk);

      final ticks = after - before;
      // The expected number is the number of clocks the test drove, plus
      // the settle idle. The crossing costs two bus clocks, which is less
      // than one SD clock period, so the reading can lag by one tick and
      // no more.
      const driven = _clockRunClocks + _settleClocks;
      expect(
        ticks,
        inInclusiveRange(driven - 1, driven),
        reason: 'the counter must follow the clocks the host drove',
      );

      // Nothing else moved. This is what makes the register a clock probe
      // and not a traffic probe.
      expect(await _wbRead(b, MimicReg.dbgSdCmd), equals(0));
      expect(await _wbRead(b, MimicReg.dbgSdCrcErr), equals(0));
      expect(await _wbRead(b, MimicReg.dbgSdResp), equals(0));

      // It keeps going. A counter that stopped after one read would still
      // pass a single check.
      await host.idle(_clockRunClocks);
      await host.idle(_settleClocks);
      expect(await _wbRead(b, MimicReg.dbgSdClk), greaterThan(after));
      await Simulator.endSimulation();
    });

    test('it stops while the host holds the clock still', () async {
      // A host that stops the clock stops the counter, and the value
      // stands. That is what tells a person the clock stopped rather than
      // the read path breaking.
      final b = await _setUp();
      final host = b.host!;
      await host.idle(20);
      final parked = await _wbRead(b, MimicReg.dbgSdClk);
      // The bus clock runs the whole time, so many bus reads happen with
      // no SD clock edge under them.
      await host.park(400);
      expect(await _wbRead(b, MimicReg.dbgSdClk), equals(parked));
      expect(await _wbRead(b, MimicReg.dbgSdClk), equals(parked));
      await host.idle(20);
      expect(await _wbRead(b, MimicReg.dbgSdClk), greaterThan(parked));
      await Simulator.endSimulation();
    });
  });

  group('DBG_SD_CMD, DBG_SD_CRC_ERR and DBG_SD_RESP', () {
    test('one count per framed command, and none for idle clocks', () async {
      final b = await _setUp();
      final host = b.host!;

      // CMD0 is a broadcast command and the card answers nothing, so this
      // separates the command counter from the response counter.
      for (var i = 1; i <= 3; i++) {
        await host.idle(sdCommandGapClocks);
        await host.sendCommand(sdCmdGoIdleState, 0);
        await host.idle(_settleClocks);
        expect(
          await _wbRead(b, MimicReg.dbgSdCmd),
          equals(i),
          reason: 'the counter must add one per framed command',
        );
      }
      expect(
        await _wbRead(b, MimicReg.dbgSdCrcErr),
        equals(0),
        reason: 'the host model sends a correct CRC7',
      );
      expect(
        await _wbRead(b, MimicReg.dbgSdResp),
        equals(0),
        reason: 'CMD0 is a broadcast command and gets no response',
      );

      // Clocks with CMD released frame nothing.
      await host.idle(64);
      expect(await _wbRead(b, MimicReg.dbgSdCmd), equals(3));
      await Simulator.endSimulation();
    });

    test('a bad CRC7 raises DBG_SD_CRC_ERR and nothing else', () async {
      final b = await _setUp();
      final host = b.host!;

      // One good command first, so the two counters can be told apart.
      await host.idle(sdCommandGapClocks);
      await host.sendCommand(sdCmdGoIdleState, 0);
      await host.idle(_settleClocks);
      expect(await _wbRead(b, MimicReg.dbgSdCmd), equals(1));
      expect(await _wbRead(b, MimicReg.dbgSdCrcErr), equals(0));

      // The same command with the CRC7 field turned over. The frame keeps
      // its start bit, its transmission bit, its index, its argument and
      // its end bit, so the link still frames it and only the CRC7 check
      // can fail.
      final frame = sdCommandFrame(sdCmdGoIdleState, 0);
      final broken = [...frame.sublist(0, frame.length - 1), frame.last ^ 0x02];
      expect(
        broken.last,
        isNot(equals(frame.last)),
        reason: 'the broken frame must really carry another CRC7',
      );
      expect(
        broken.last & 0x01,
        equals(1),
        reason: 'the end bit must stay 1, or the link drops the frame',
      );
      await host.idle(sdCommandGapClocks);
      await _sendFrame(host, broken);
      await host.idle(_settleClocks);

      expect(
        await _wbRead(b, MimicReg.dbgSdCmd),
        equals(2),
        reason: 'a framed command counts whatever its CRC7',
      );
      expect(
        await _wbRead(b, MimicReg.dbgSdCrcErr),
        equals(1),
        reason: 'only the frame with the wrong CRC7 counts here',
      );
      expect(
        await _wbRead(b, MimicReg.dbgSdResp),
        equals(0),
        reason: 'the card must not answer a command it could not check',
      );

      // A good command after it still counts as good, so the register is
      // not a sticky flag.
      await host.idle(sdCommandGapClocks);
      await host.sendCommand(sdCmdGoIdleState, 0);
      await host.idle(_settleClocks);
      expect(await _wbRead(b, MimicReg.dbgSdCmd), equals(3));
      expect(await _wbRead(b, MimicReg.dbgSdCrcErr), equals(1));
      await Simulator.endSimulation();
    });

    test('one count per response the card started to send', () async {
      final b = await _setUp();
      final host = b.host!;

      // CMD0 first: framed, and answered by nothing.
      await host.idle(sdCommandGapClocks);
      await host.sendCommand(sdCmdGoIdleState, 0);
      await host.idle(_settleClocks);
      expect(await _wbRead(b, MimicReg.dbgSdCmd), equals(1));
      expect(await _wbRead(b, MimicReg.dbgSdResp), equals(0));

      // CMD8 is answered with an R7. The host reads the frame off the
      // wire, so the count is checked against a response that really
      // reached the host and not against an internal signal.
      await host.idle(sdCommandGapClocks);
      await host.sendCommand(sdCmdSendIfCond, 0x000001AA);
      final ifCond = await host.receiveResponse(SdResponseKind.r1);
      expect(ifCond.timedOut, isFalse, reason: 'CMD8 must be answered');
      expect(ifCond.payload, equals(0x000001AA));
      await host.idle(_settleClocks);
      expect(await _wbRead(b, MimicReg.dbgSdCmd), equals(2));
      expect(
        await _wbRead(b, MimicReg.dbgSdResp),
        equals(1),
        reason: 'the card started exactly one response',
      );

      // A second CMD8 gives a second response.
      await host.idle(sdCommandGapClocks);
      await host.sendCommand(sdCmdSendIfCond, 0x000001AA);
      await host.receiveResponse(SdResponseKind.r1);
      await host.idle(_settleClocks);
      expect(await _wbRead(b, MimicReg.dbgSdResp), equals(2));
      expect(await _wbRead(b, MimicReg.dbgSdCrcErr), equals(0));
      await Simulator.endSimulation();
    });
  });

  group('the crossing cannot be observed torn', () {
    test('one bit at a time out, and one step at a time in', () async {
      // The property that makes the crossing safe: the word the SD domain
      // publishes changes ONE BIT at a time. A bus clock that samples it
      // while a bit is moving therefore reads the old count or the new
      // count, and both are counts the counter really held. There is no
      // third reading to tear into.
      //
      // The check watches the real ports of the design. `gray` is what
      // leaves the SD clock domain and `count` is what the CSR reads.
      final b = await _setUp();
      final host = b.host!;

      final gray = _ValueTrace(b.bridge.card.output('dbg_sd_clk_gray'));
      final count = _ValueTrace(
        b.bridge.graySyncs['dbg_sd_clk']!.output('count'),
      );
      // Long enough that the counter carries through several of its low
      // bits, where the binary count changes many bits at once.
      await host.idle(300);
      await gray.stop();
      await count.stop();

      expect(
        gray.values.length,
        greaterThan(64),
        reason: 'the counter must really have moved during the watch',
      );
      for (var i = 1; i < gray.values.length; i++) {
        expect(
          _hammingDistance(gray.values[i - 1], gray.values[i]),
          equals(1),
          reason:
              'the published word went from ${gray.values[i - 1]} to '
              '${gray.values[i]}, which changes more than one bit. A bus '
              'clock in that window could read a count that never existed.',
        );
      }

      // What the CSR side reads. Every step is exactly one count up, so no
      // read skipped a value, went backwards or landed between two counts.
      expect(count.values.length, greaterThan(64));
      for (var i = 1; i < count.values.length; i++) {
        expect(count.values[i].isValid, isTrue);
        expect(
          count.values[i].toInt() - count.values[i - 1].toInt(),
          equals(1),
          reason:
              'the CSR side went from ${count.values[i - 1].toInt()} to '
              '${count.values[i].toInt()}, which is not one count up',
        );
      }
      await Simulator.endSimulation();
    });

    test(
      'the same check on a RAW BINARY count fails, so it has teeth',
      () async {
        // The negative control. The check above only means something if it
        // can fail, and the thing it must fail on is the crossing a person
        // would reach for first: one synchroniser per bit of the RAW BINARY
        // counter, the way `card_state` crosses.
        //
        // This decodes the published gray word back to binary and runs the
        // SAME one-bit check on it. A binary counter changes several bits on
        // one increment (3 to 4 changes three of them), so the check must
        // find a step that breaks it. If it does not, the check above proves
        // nothing and this test says so.
        final b = await _setUp();
        final host = b.host!;

        final gray = _ValueTrace(b.bridge.card.output('dbg_sd_clk_gray'));
        await host.idle(300);
        await gray.stop();

        // The test does its own decode in Dart. It does not read a signal of
        // the design, so a design that decoded wrongly cannot hide here.
        int decode(LogicValue value) {
          var running = 0;
          var out = 0;
          for (var i = value.width - 1; i >= 0; i--) {
            running ^= value[i] == LogicValue.one ? 1 : 0;
            out |= running << i;
          }
          return out;
        }

        final binary = [for (final v in gray.values) decode(v)];
        // The decode agrees with the counter it came from: consecutive
        // published words are consecutive counts.
        for (var i = 1; i < binary.length; i++) {
          expect(binary[i] - binary[i - 1], equals(1));
        }

        final multiBitSteps = [
          for (var i = 1; i < binary.length; i++)
            if ((binary[i] ^ binary[i - 1])
                    .toRadixString(2)
                    .replaceAll('0', '')
                    .length >
                1)
              binary[i],
        ];
        expect(
          multiBitSteps,
          isNotEmpty,
          reason:
              'a raw binary count of this run never changed more than one bit '
              'at once, so the one-bit check above proves nothing. Run it for '
              'longer.',
        );
        // It is not a rare corner either: a quarter of all steps carry.
        expect(multiBitSteps.length, greaterThan(binary.length ~/ 4));
        await Simulator.endSimulation();
      },
    );
  });
}
