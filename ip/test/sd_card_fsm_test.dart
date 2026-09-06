// Tests for MimicSdCardFsm, the card state machine.
//
// The tests drive the link side ports by hand: they raise cmd_valid for one
// clock with an index, an argument and a CRC verdict, and they read
// card_state, resp_start, resp_kind and resp_data back. There is no link
// and no bus here, because this module owns no framing.
//
// Two decodes below replace the command set, so that the response
// handshake can be driven with a rule that the test picks. The tests of
// the command set itself build the card with its own decode.

import 'dart:async';

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// A decode that answers every command that the link accepts.
///
/// The command set of the card answers a few indices only, and it moves
/// the card through the states that the specification gives. A handshake
/// test needs neither. This decode answers each accepted command with an
/// R1 that carries the command index and the card status, and it moves the
/// card to the state in the last four bits of the argument.
///
/// The status in the response is built before the move, which is what the
/// specification asks for: CURRENT_STATE reports the state that the card
/// was in when the command arrived.
SdCommandDecision _echoDecode(SdDecodeInputs inputs) => SdCommandDecision(
  respond: Const(1),
  kind: Const(sdRespKindR1, width: sdRespKindBits),
  data: [
    Const(0, width: sdResponseRegBits - sdCommandIndexBits - sdCardStatusBits),
    inputs.index,
    inputs.status,
  ].swizzle(),
  nextState: inputs.arg.slice(sdCardStateBits - 1, 0),
);

/// A decode that moves the card and answers nothing.
///
/// This is the shape of a broadcast command such as CMD0: it changes the
/// card state and gives the host no response. The card must act on it even
/// while the link is busy, because there is no answer to hold back.
SdCommandDecision _silentDecode(SdDecodeInputs inputs) => SdCommandDecision(
  respond: Const(0),
  kind: Const(sdRespKindR1, width: sdRespKindBits),
  data: Const(0, width: sdResponseRegBits),
  nextState: inputs.arg.slice(sdCardStateBits - 1, 0),
);

/// The resp_busy output of MimicSdLink, in the small.
///
/// The link raises `resp_busy` on the clock edge that samples `resp_start`
/// and holds it for every bit of the frame. A test that sends two
/// responses without a gap needs that clock, because the one clock width
/// of `resp_start` comes from the pair and not from the card alone. The
/// number of clocks is not the length of a real frame, only long enough to
/// show the gap.
class _LinkBusyModel {
  /// The busy line that the card reads.
  final Logic respBusy = Logic(name: 'link_resp_busy');

  _LinkBusyModel(
    Logic clk,
    Logic reset,
    Logic respStart, {
    required int clocks,
  }) {
    final width = clocks.bitLength;
    final count = Logic(name: 'link_busy_count', width: width);
    Sequential(
      clk,
      reset: reset,
      resetValues: {
        respBusy: Const(0),
        count: Const(0, width: width),
      },
      [
        If(
          count.gt(Const(0, width: width)),
          then: [
            count < count - 1,
            If(count.eq(Const(1, width: width)), then: [respBusy < Const(0)]),
          ],
          orElse: [
            If(
              respStart,
              then: [
                respBusy < Const(1),
                count < Const(clocks, width: width),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// The card under test with a hand-driven clock on its link side ports.
///
/// The clock is driven by hand and not by a generator, so a test can hold
/// the card still and read a port between two edges. The bench changes
/// every input while the clock is low, so the card samples a value that
/// stands still over the rising edge.
class _Bench {
  final MimicSdCardFsm dut;
  final Logic clk = Logic(name: 'sd_clk');
  final Logic reset = Logic(name: 'sd_reset');
  final Logic cmdIndex = Logic(name: 'cmd_index', width: sdCommandIndexBits);
  final Logic cmdArg = Logic(name: 'cmd_arg', width: sdCommandArgBits);
  final Logic cmdValid = Logic(name: 'cmd_valid');
  final Logic cmdCrcOk = Logic(name: 'cmd_crc_ok');

  /// The CSD that the card answers CMD9 with.
  ///
  /// The card holds no CSD of its own. The SoC gives it one, already
  /// settled in the SD clock domain, so this bench drives the port the way
  /// the SoC does. It starts at the default CSD, which is the reset value
  /// of the register that feeds this port in the real design.
  final Logic csd = Logic(name: 'csd', width: sdResponseRegBits);

  /// The block read path, as the card sees it.
  ///
  /// The card is enabled and the read path can take a read, so a CMD17
  /// in tran is answered. `readDone` and `readFailed` are the two
  /// pulses that end a read and return the card to tran.
  final Logic readReady = Logic(name: 'read_ready');
  final Logic cardEnable = Logic(name: 'card_enable');
  final Logic readDone = Logic(name: 'read_done');
  final Logic readFailed = Logic(name: 'read_failed');

  /// The block WRITE path, as the card sees it.
  ///
  /// The path can take a write, so a CMD24 in tran is answered and not
  /// refused. `writePrg` is the level that moves the card from rcv to prg,
  /// and `writeDone` and `writeFailed` are the two pulses that end a write
  /// and return the card to tran. Every input needs a driver, because an
  /// input that nothing drives holds X, and an X here reaches the state
  /// register of the card.
  final Logic writeReady = Logic(name: 'write_ready');
  final Logic writeDone = Logic(name: 'write_done');
  final Logic writeFailed = Logic(name: 'write_failed');
  final Logic writePrg = Logic(name: 'write_prg');

  /// The card register sender, as the card sees it. It is free, so an
  /// ACMD51 in tran is answered and not refused.
  final Logic regReady = Logic(name: 'reg_ready');

  /// The resp_busy input of the card.
  ///
  /// A test that drives the line by hand injects this signal. A test that
  /// asks [_setUp] for a link model gets the output of that model here,
  /// and must not inject it.
  late final Logic respBusy;

  _Bench(this.dut);

  /// The card state that the card reports now.
  int get cardState => dut.output('card_state').value.toInt();

  /// True while the card asks the link to send a response.
  bool get respStart => dut.output('resp_start').value == LogicValue.one;

  /// The 32-bit card status that the response holds.
  int get respStatus =>
      dut.output('resp_data').value.getRange(0, sdCardStatusBits).toInt();

  /// The command index that the response holds.
  int get respIndex => dut
      .output('resp_data')
      .value
      .getRange(sdCardStatusBits, sdCardStatusBits + sdCommandIndexBits)
      .toInt();

  /// The response kind that the card asks the link to send.
  int get respKind => dut.output('resp_kind').value.toInt();

  /// True while the card asks the write path to start a block write.
  bool get writeStart => dut.output('write_start').value == LogicValue.one;

  /// The block address that the card gave the write path.
  int get writeLba => dut.output('write_lba').value.toInt();

  /// True while the card tells the write path that the write is over.
  bool get writeAbort => dut.output('write_abort').value == LogicValue.one;

  /// The whole response word, which an R2 fills with a register.
  ///
  /// The word is as wide as the `resp_data` port, which is wider than an
  /// int, so the value is a [BigInt].
  BigInt get respWord => dut.output('resp_data').value.toBigInt();

  /// One full clock period, low then high.
  Future<void> tick() async {
    clk.inject(0);
    await _wait(5);
    clk.inject(1);
    await _wait(5);
  }

  /// Holds every command port idle for [cycles] clocks.
  Future<void> idle(int cycles) async {
    cmdValid.inject(0);
    cmdCrcOk.inject(0);
    for (var i = 0; i < cycles; i++) {
      await tick();
    }
  }

  /// Raises cmd_valid for one clock with [index], [arg] and [crcOk].
  ///
  /// This is the pulse that MimicSdLink gives after it frames a command.
  /// The bench drops the three ports again after the clock, because the
  /// link holds cmd_crc_ok low in every other cycle.
  Future<void> sendCommand(int index, int arg, {bool crcOk = true}) async {
    cmdIndex.inject(index);
    cmdArg.inject(arg);
    cmdCrcOk.inject(crcOk ? 1 : 0);
    cmdValid.inject(1);
    await tick();
    cmdValid.inject(0);
    cmdCrcOk.inject(0);
  }

  Future<void> _wait(int amount) {
    final completer = Completer<void>();
    Simulator.registerAction(Simulator.time + amount, completer.complete);
    return completer.future;
  }
}

/// Watches resp_start over the whole run.
///
/// It reads the ports at the postTick event, which the simulator raises
/// after every value of a clock settles, so resp_start and resp_busy always
/// belong to the same clock.
class _RespMonitor {
  /// The card under test.
  final _Bench bench;

  /// One record for each rising edge of resp_start, in order.
  ///
  /// `status` is the 32-bit payload of a short response and means nothing
  /// in an R2. `word` is the whole response word, which is where an R2
  /// carries its register.
  final List<({int kind, int index, int status, BigInt word})> starts = [];

  /// True if resp_start was ever high while resp_busy was high.
  bool startedWhileBusy = false;

  /// Number of clocks that resp_start held high, over all pulses.
  int highTicks = 0;

  bool _wasStart = false;
  late final StreamSubscription<void> _sub;

  _RespMonitor(this.bench) {
    _sub = Simulator.postTick.listen((_) {
      if (!bench.respStart) {
        _wasStart = false;
        return;
      }
      if (bench.respBusy.value == LogicValue.one) {
        startedWhileBusy = true;
      }
      if (!_wasStart) {
        starts.add((
          kind: bench.respKind,
          index: bench.respIndex,
          status: bench.respStatus,
          word: bench.respWord,
        ));
        highTicks++;
      }
      _wasStart = true;
    });
  }

  /// Stops the monitor.
  Future<void> stop() => _sub.cancel();
}

/// Builds [dut] with the bench around it and releases reset.
///
/// Set [holdReset] to keep reset high, so a test can read the card while
/// reset still holds it. Set [linkBusyClocks] to drive `resp_busy` from a
/// model of the link instead of by hand.
Future<_Bench> _setUp(
  MimicSdCardFsm dut, {
  bool holdReset = false,
  int? linkBusyClocks,
}) async {
  final bench = _Bench(dut);
  if (linkBusyClocks == null) {
    bench.respBusy = Logic(name: 'resp_busy');
  } else {
    bench.respBusy = _LinkBusyModel(
      bench.clk,
      bench.reset,
      dut.output('resp_start'),
      clocks: linkBusyClocks,
    ).respBusy;
  }
  dut.input('clk').srcConnection! <= bench.clk;
  dut.input('reset').srcConnection! <= bench.reset;
  dut.input('cmd_index').srcConnection! <= bench.cmdIndex;
  dut.input('cmd_arg').srcConnection! <= bench.cmdArg;
  dut.input('cmd_valid').srcConnection! <= bench.cmdValid;
  dut.input('cmd_crc_ok').srcConnection! <= bench.cmdCrcOk;
  dut.input('resp_busy').srcConnection! <= bench.respBusy;
  dut.input('csd').srcConnection! <= bench.csd;
  // The block read path. A bench that does not drive a read holds a
  // card that CAN take one, so a CMD17 in tran is answered and not
  // refused. Every input needs a driver, because an input that nothing
  // drives holds X.
  dut.input('read_ready').srcConnection! <= bench.readReady;
  dut.input('card_enable').srcConnection! <= bench.cardEnable;
  dut.input('read_done').srcConnection! <= bench.readDone;
  dut.input('read_failed').srcConnection! <= bench.readFailed;
  // The block write path. A bench that drives no write holds a card that
  // CAN take one, the way it does for a read.
  dut.input('write_ready').srcConnection! <= bench.writeReady;
  dut.input('write_done').srcConnection! <= bench.writeDone;
  dut.input('write_failed').srcConnection! <= bench.writeFailed;
  dut.input('write_prg').srcConnection! <= bench.writePrg;
  dut.input('reg_ready').srcConnection! <= bench.regReady;
  await dut.build();

  bench.clk.inject(0);
  bench.reset.inject(1);
  bench.cmdIndex.inject(0);
  bench.cmdArg.inject(0);
  bench.cmdValid.inject(0);
  bench.cmdCrcOk.inject(0);
  bench.csd.inject(sdCardCsdValue);
  bench.readReady.inject(1);
  bench.regReady.inject(1);
  bench.cardEnable.inject(1);
  bench.readDone.inject(0);
  bench.readFailed.inject(0);
  bench.writeReady.inject(1);
  bench.writeDone.inject(0);
  bench.writeFailed.inject(0);
  bench.writePrg.inject(0);
  if (linkBusyClocks == null) {
    bench.respBusy.inject(0);
  }
  Simulator.setMaxSimTime(2000000);
  unawaited(Simulator.run());
  await bench.tick();
  await bench.tick();
  if (!holdReset) {
    bench.reset.inject(0);
    await bench.tick();
  }
  return bench;
}

void main() {
  tearDown(Simulator.reset);

  test('reset leaves the card in idle', () async {
    final bench = await _setUp(MimicSdCardFsm(), holdReset: true);
    expect(
      bench.cardState,
      equals(sdCardStateIdle),
      reason: 'the card holds idle while reset is high',
    );
    expect(bench.respStart, isFalse, reason: 'no response under reset');

    bench.reset.inject(0);
    await bench.idle(4);
    expect(
      bench.cardState,
      equals(sdCardStateIdle),
      reason: 'the card is still in idle after reset falls',
    );
    await Simulator.endSimulation();
  });

  test('the card answers no command that it does not hold', () async {
    // CMD0 is a broadcast command with no answer, and index 41 with no
    // CMD55 in front of it is a command that this card does not hold.
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    await bench.sendCommand(0, 0x00000000);
    await bench.idle(8);
    await bench.sendCommand(sdAcmdSendOpCond, 0xFFFFFFFF);
    await bench.idle(8);
    await mon.stop();

    expect(
      mon.starts,
      isEmpty,
      reason:
          'CMD0 answers nothing, and index 41 with no CMD55 in front of '
          'it is a command that the card does not hold',
    );
    expect(
      bench.cardState,
      equals(sdCardStateIdle),
      reason: 'a command the card ignores does not move it',
    );
    await Simulator.endSimulation();
  });

  test('a command with cmd_crc_ok low is ignored', () async {
    final bench = await _setUp(MimicSdCardFsm(decode: _echoDecode));
    final mon = _RespMonitor(bench);

    await bench.sendCommand(7, sdCardStateTran, crcOk: false);
    await bench.idle(8);
    expect(mon.starts, isEmpty, reason: 'a bad CRC gives no response');
    expect(
      bench.cardState,
      equals(sdCardStateIdle),
      reason: 'a bad CRC does not move the card',
    );

    // The same command with a good CRC does reach the card, so the test
    // above fails for the CRC and not because the bench sent nothing.
    await bench.sendCommand(7, sdCardStateTran);
    await bench.idle(8);
    await mon.stop();
    expect(mon.starts, hasLength(1), reason: 'a good CRC gives one response');
    expect(bench.cardState, equals(sdCardStateTran));
    await Simulator.endSimulation();
  });

  test('resp_start waits for resp_busy to fall', () async {
    final bench = await _setUp(MimicSdCardFsm(decode: _echoDecode));
    final mon = _RespMonitor(bench);

    // The link is sending an earlier response, so it drops any pulse now.
    bench.respBusy.inject(1);
    await bench.sendCommand(17, sdCardStateData);
    await bench.idle(20);
    expect(mon.starts, isEmpty, reason: 'resp_start holds off while busy');
    expect(
      bench.cardState,
      equals(sdCardStateData),
      reason: 'the state moves even while the link is busy',
    );

    bench.respBusy.inject(0);
    await bench.idle(8);
    await mon.stop();

    expect(mon.starts, hasLength(1), reason: 'the response goes out after');
    expect(
      mon.highTicks,
      equals(1),
      reason: 'resp_start is a pulse of one clock',
    );
    expect(
      mon.startedWhileBusy,
      isFalse,
      reason: 'resp_start is never high while resp_busy is high',
    );
    expect(mon.starts.single.kind, equals(sdRespKindR1));
    expect(mon.starts.single.index, equals(17));
    await Simulator.endSimulation();
  });

  test(
    'a command that the card cannot answer does not move the card',
    () async {
      // The answer slot holds the response to the first command, because the
      // link is busy. The second command asks for an answer that the card
      // cannot queue, so the card must drop the whole command. A card that
      // moved on a command it never answered would leave the host with a
      // state that the card no longer holds, and nothing resyncs the two.
      final bench = await _setUp(MimicSdCardFsm(decode: _echoDecode));
      final mon = _RespMonitor(bench);

      bench.respBusy.inject(1);
      await bench.sendCommand(17, sdCardStateData);
      await bench.idle(8);
      expect(
        bench.cardState,
        equals(sdCardStateData),
        reason: 'the first command took the free answer slot',
      );

      await bench.sendCommand(24, sdCardStateRcv);
      await bench.idle(8);
      expect(
        bench.cardState,
        equals(sdCardStateData),
        reason: 'the second command found the slot full, so it did nothing',
      );

      bench.respBusy.inject(0);
      await bench.idle(8);
      await mon.stop();

      expect(
        mon.starts,
        hasLength(1),
        reason: 'only the first command answers',
      );
      expect(mon.starts.single.index, equals(17));
      expect(
        bench.cardState,
        equals(sdCardStateData),
        reason: 'the card still holds the state of the command it answered',
      );
      await Simulator.endSimulation();
    },
  );

  test(
    'a command that answers nothing moves the card while the link is busy',
    () async {
      // A broadcast command such as CMD0 gives no response, so a full answer
      // slot must not hold it back.
      final bench = await _setUp(MimicSdCardFsm(decode: _silentDecode));
      final mon = _RespMonitor(bench);

      bench.respBusy.inject(1);
      await bench.sendCommand(0, sdCardStateIdent);
      await bench.idle(8);
      expect(
        bench.cardState,
        equals(sdCardStateIdent),
        reason: 'a command with no answer moves the card while busy',
      );

      await bench.sendCommand(0, sdCardStateStby);
      await bench.idle(8);
      await mon.stop();
      expect(
        bench.cardState,
        equals(sdCardStateStby),
        reason: 'a second command with no answer moves the card as well',
      );
      expect(mon.starts, isEmpty, reason: 'no answer ever goes out');
      await Simulator.endSimulation();
    },
  );

  test('the card status reports the current state in bits 12 to 9', () async {
    final bench = await _setUp(MimicSdCardFsm(decode: _echoDecode));
    final mon = _RespMonitor(bench);

    await bench.sendCommand(3, sdCardStateStby);
    await bench.idle(8);
    await bench.sendCommand(7, sdCardStateTran);
    await bench.idle(8);
    await mon.stop();

    expect(mon.starts, hasLength(2));
    // The status is built before the command moves the card, so the first
    // response reports idle and the second reports stby.
    expect(
      _currentState(mon.starts[0].status),
      equals(sdCardStateIdle),
      reason: 'the first response reports the state before the move',
    );
    expect(
      _currentState(mon.starts[1].status),
      equals(sdCardStateStby),
      reason: 'the second response reports the state the first one set',
    );
    expect(
      bench.cardState,
      equals(sdCardStateTran),
      reason: 'card_state agrees with the last command',
    );
    // READY_FOR_DATA sits just under CURRENT_STATE and reads 1 in tran.
    expect(
      (mon.starts[1].status >> sdStatusReadyForDataBit) & 1,
      equals(1),
      reason: 'READY_FOR_DATA is bit 8',
    );
    await Simulator.endSimulation();
  });

  test('two commands in a row both land, with no stale state', () async {
    final bench = await _setUp(MimicSdCardFsm(decode: _echoDecode));
    final mon = _RespMonitor(bench);

    await bench.sendCommand(2, sdCardStateIdent);
    await bench.idle(8);
    await bench.sendCommand(9, sdCardStateStby);
    await bench.idle(8);
    await mon.stop();

    expect(mon.starts, hasLength(2), reason: 'both commands got a response');
    expect(mon.highTicks, equals(2), reason: 'each response is one pulse');
    expect(mon.starts[0].index, equals(2));
    expect(mon.starts[1].index, equals(9), reason: 'the second index is fresh');
    expect(_currentState(mon.starts[1].status), equals(sdCardStateIdent));
    expect(bench.cardState, equals(sdCardStateStby));
    expect(mon.startedWhileBusy, isFalse);
    await Simulator.endSimulation();
  });

  // The branch order in the module is load bearing at short command
  // spacing only. At a gap of 0 clocks the decode of the first command and
  // the capture of the second land on the same edge, and the answer of the
  // first is queued on the edge that starts it. A gap of 8 clocks, which
  // every other test uses, never puts two of these in one clock. The link
  // model gives the real resp_busy, because the one clock width of
  // resp_start comes from the pair.
  for (final gap in [0, 1, 2, 8]) {
    test('two commands $gap clocks apart both answer, in order', () async {
      final bench = await _setUp(
        MimicSdCardFsm(decode: _echoDecode),
        linkBusyClocks: 6,
      );
      final mon = _RespMonitor(bench);

      await bench.sendCommand(2, sdCardStateIdent);
      if (gap > 0) {
        await bench.idle(gap);
      }
      await bench.sendCommand(9, sdCardStateStby);
      await bench.idle(40);
      await mon.stop();

      expect(mon.starts, hasLength(2), reason: 'both commands got a response');
      expect(
        mon.highTicks,
        equals(2),
        reason: 'each response is one pulse of one clock',
      );
      expect(
        mon.startedWhileBusy,
        isFalse,
        reason: 'resp_start is never high while resp_busy is high',
      );
      expect(
        mon.starts[0].index,
        equals(2),
        reason: 'the first answer is CMD2',
      );
      expect(
        mon.starts[1].index,
        equals(9),
        reason: 'the second command kept its capture',
      );
      expect(
        _currentState(mon.starts[0].status),
        equals(sdCardStateIdle),
        reason: 'the first answer reports the state before its move',
      );
      expect(
        _currentState(mon.starts[1].status),
        equals(sdCardStateIdent),
        reason: 'the second answer reports the state the first one set',
      );
      expect(bench.cardState, equals(sdCardStateStby));
      await Simulator.endSimulation();
    });
  }

  test('CMD8 answers R7 and echoes the low argument bits', () async {
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    await bench.sendCommand(sdCmdSendIfCond, 0x000001AA);
    await bench.idle(8);
    // A second pattern, so a constant echo cannot pass the test.
    await bench.sendCommand(sdCmdSendIfCond, 0xFFFFF25A);
    await bench.idle(8);
    await mon.stop();

    expect(mon.starts, hasLength(2), reason: 'CMD8 answers every time');
    expect(
      mon.starts[0].kind,
      equals(sdRespKindR1),
      reason: 'an R7 has the frame shape of an R1',
    );
    expect(mon.starts[0].index, equals(sdCmdSendIfCond));
    expect(
      mon.starts[0].status,
      equals(0x1AA),
      reason: 'the echo is VHS and the check pattern, and nothing above',
    );
    expect(
      mon.starts[1].status,
      equals(0x25A),
      reason: 'the echo follows the argument of the second command',
    );
    expect(
      bench.cardState,
      equals(sdCardStateIdle),
      reason: 'CMD8 does not move the card',
    );
    await Simulator.endSimulation();
  });

  test('CMD55 answers R1 with APP_CMD set', () async {
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    await bench.sendCommand(sdCmdAppCmd, 0x00000000);
    await bench.idle(8);
    await mon.stop();

    expect(mon.starts, hasLength(1));
    expect(mon.starts.single.kind, equals(sdRespKindR1));
    expect(mon.starts.single.index, equals(sdCmdAppCmd));
    expect(
      _appCmd(mon.starts.single.status),
      equals(1),
      reason: 'APP_CMD is bit $sdStatusAppCmdBit of the card status',
    );
    expect(
      _currentState(mon.starts.single.status),
      equals(sdCardStateIdle),
      reason: 'CMD55 does not move the card',
    );
    expect(
      _illegalCommand(mon.starts.single.status),
      equals(0),
      reason: 'CMD55 is legal in idle',
    );
    await Simulator.endSimulation();
  });

  test('ACMD41 answers R3 with a busy OCR and then a ready OCR', () async {
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    await _initToReady(bench);
    await mon.stop();

    // Each poll is CMD55 and then ACMD41, so the answers alternate.
    expect(
      mon.starts,
      hasLength((sdOpCondBusyPolls + 1) * 2),
      reason: 'every command of the loop got an answer',
    );
    for (var poll = 0; poll < sdOpCondBusyPolls; poll++) {
      final answer = mon.starts[poll * 2 + 1];
      expect(
        answer.kind,
        equals(sdRespKindR3),
        reason: 'ACMD41 answers R3, which carries the OCR',
      );
      expect(answer.index, equals(sdAcmdSendOpCond));
      expect(
        answer.status,
        equals(sdOcr(ready: false)),
        reason: 'poll $poll finds the card still busy',
      );
    }
    expect(
      mon.starts.last.kind,
      equals(sdRespKindR3),
      reason: 'the last answer is an R3 as well',
    );
    expect(
      mon.starts.last.status,
      equals(sdOcr()),
      reason: 'the card reports the power-up done after the busy polls',
    );
    expect(
      bench.cardState,
      equals(sdCardStateReady),
      reason: 'the answer that reports the power-up done moves the card',
    );
    await Simulator.endSimulation();
  });

  test('index 41 without CMD55 is not an ACMD', () async {
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    await bench.sendCommand(sdAcmdSendOpCond, 0x00000000);
    await bench.idle(8);
    expect(
      mon.starts,
      isEmpty,
      reason: 'index 41 with no CMD55 is a command the card does not hold',
    );
    expect(bench.cardState, equals(sdCardStateIdle));

    // The same index after CMD55 does answer, so the test above fails for
    // the missing CMD55 and not because the bench sent nothing.
    await bench.sendCommand(sdCmdAppCmd, 0x00000000);
    await bench.idle(8);
    await bench.sendCommand(sdAcmdSendOpCond, 0x00000000);
    await bench.idle(8);
    await mon.stop();

    expect(mon.starts, hasLength(2), reason: 'CMD55 and then the ACMD');
    expect(mon.starts[1].kind, equals(sdRespKindR3));
    expect(mon.starts[1].index, equals(sdAcmdSendOpCond));
    await Simulator.endSimulation();
  });

  test('the CMD55 flag clears after the one command that follows', () async {
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    // CMD8 takes the flag, so the index 41 after it is not an ACMD.
    await bench.sendCommand(sdCmdAppCmd, 0x00000000);
    await bench.idle(8);
    await bench.sendCommand(sdCmdSendIfCond, 0x000001AA);
    await bench.idle(8);
    await bench.sendCommand(sdAcmdSendOpCond, 0x00000000);
    await bench.idle(8);
    await mon.stop();

    expect(
      mon.starts,
      hasLength(2),
      reason: 'CMD55 and CMD8 answer, and the index 41 after them does not',
    );
    expect(mon.starts[0].index, equals(sdCmdAppCmd));
    expect(mon.starts[1].index, equals(sdCmdSendIfCond));
    // The R7 payload is the echo alone. It is not a card status, so no
    // APP_CMD bit can reach it.
    expect(
      mon.starts[1].status,
      equals(0x1AA),
      reason: 'the answer to CMD8 is the echo of its argument',
    );
    await Simulator.endSimulation();
  });

  test('the identification sequence runs twice with no stale state', () async {
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    await _initToReady(bench);
    expect(bench.cardState, equals(sdCardStateReady));
    final firstRound = mon.starts.length;

    // CMD0 puts the card back in idle, which is what a host sends when it
    // starts again. The second round must run the same way.
    await bench.sendCommand(sdCmdGoIdleState, 0x00000000);
    await bench.idle(8);
    expect(
      bench.cardState,
      equals(sdCardStateIdle),
      reason: 'CMD0 returns the card to idle from the ready state',
    );
    expect(mon.starts, hasLength(firstRound), reason: 'CMD0 gives no answer');

    await bench.sendCommand(sdCmdAppCmd, 0x00000000);
    await bench.idle(8);
    await bench.sendCommand(sdAcmdSendOpCond, 0x00000000);
    await bench.idle(8);
    await mon.stop();

    expect(mon.starts, hasLength(firstRound + 2));
    expect(
      _appCmd(mon.starts[firstRound].status),
      equals(1),
      reason: 'the second CMD55 sets APP_CMD as the first one did',
    );
    expect(
      mon.starts.last.kind,
      equals(sdRespKindR3),
      reason: 'the flag reached the second ACMD41',
    );
    expect(
      mon.starts.last.status,
      equals(sdOcr()),
      reason: 'the power-up is already done, so the card reports ready',
    );
    expect(
      bench.cardState,
      equals(sdCardStateReady),
      reason: 'the second round leaves the card in ready as the first did',
    );
    await Simulator.endSimulation();
  });

  test('CMD0 returns the card to idle while the answer slot is full', () async {
    // CMD0 is a broadcast command with no answer, so a full answer slot
    // must not hold it back. A card that dropped CMD0 here would sit in a
    // state that the host believes it left, and nothing resyncs the two.
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    await _initToReady(bench);
    expect(bench.cardState, equals(sdCardStateReady));
    final beforeBusy = mon.starts.length;

    // The link is sending, so the answer to CMD55 fills the slot.
    bench.respBusy.inject(1);
    await bench.sendCommand(sdCmdAppCmd, 0x00000000);
    await bench.idle(8);
    expect(
      mon.starts,
      hasLength(beforeBusy),
      reason: 'the answer to CMD55 is in the slot and not on the wire',
    );

    await bench.sendCommand(sdCmdGoIdleState, 0x00000000);
    await bench.idle(8);
    expect(
      bench.cardState,
      equals(sdCardStateIdle),
      reason: 'CMD0 moves the card even while the answer slot is full',
    );

    bench.respBusy.inject(0);
    await bench.idle(8);
    await mon.stop();

    expect(
      mon.starts,
      hasLength(beforeBusy + 1),
      reason: 'the answer that waited goes out, and CMD0 adds none',
    );
    expect(mon.starts.last.index, equals(sdCmdAppCmd));
    expect(
      _illegalCommand(mon.starts.last.status),
      equals(0),
      reason: 'a busy answer slot is not a state violation',
    );
    await Simulator.endSimulation();
  });

  test('CMD8 outside idle answers ILLEGAL_COMMAND', () async {
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    await _initToReady(bench);
    expect(bench.cardState, equals(sdCardStateReady));
    final beforeIllegal = mon.starts.length;

    await bench.sendCommand(sdCmdSendIfCond, 0x000001AA);
    await bench.idle(8);
    expect(mon.starts, hasLength(beforeIllegal + 1));
    expect(
      mon.starts.last.kind,
      equals(sdRespKindR1),
      reason: 'the card reports the error in a card status',
    );
    expect(mon.starts.last.index, equals(sdCmdSendIfCond));
    expect(
      _illegalCommand(mon.starts.last.status),
      equals(1),
      reason: 'CMD8 belongs to the idle state alone',
    );
    expect(
      _currentState(mon.starts.last.status),
      equals(sdCardStateReady),
      reason: 'the answer reports the state that refused the command',
    );
    expect(
      bench.cardState,
      equals(sdCardStateReady),
      reason: 'an illegal command does not move the card',
    );

    // The same command in idle is legal, so the bit above comes from the
    // state and not from CMD8 itself.
    await bench.sendCommand(sdCmdGoIdleState, 0x00000000);
    await bench.idle(8);
    await bench.sendCommand(sdCmdSendIfCond, 0x000001AA);
    await bench.idle(8);
    await mon.stop();

    expect(
      mon.starts.last.status,
      equals(0x1AA),
      reason: 'CMD8 in idle echoes the argument and flags nothing',
    );
    await Simulator.endSimulation();
  });

  test('ACMD41 outside idle answers nothing', () async {
    // A host that sends ACMD41 is reading the OCR, and it counts the bits
    // of an R3 as they come. An R1 in that place is a frame of another
    // shape and another length, so the host reads a wrong OCR and cannot
    // tell that it did. A timeout tells the host more: it sends the
    // command again. CMD8 is the one command that answers out of its
    // state, because ILLEGAL_COMMAND fits in the R1 that CMD8 asks for.
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    await _initToReady(bench);
    expect(bench.cardState, equals(sdCardStateReady));
    final beforeAcmd = mon.starts.length;

    await bench.sendCommand(sdCmdAppCmd, 0x00000000);
    await bench.idle(8);
    await bench.sendCommand(sdAcmdSendOpCond, sdOcr());
    await bench.idle(8);
    expect(
      mon.starts,
      hasLength(beforeAcmd + 1),
      reason: 'CMD55 answers in every state and the ACMD41 after it does not',
    );
    expect(mon.starts.last.index, equals(sdCmdAppCmd));
    expect(
      bench.cardState,
      equals(sdCardStateReady),
      reason: 'a command that the card refuses does not move it',
    );

    // The same command in idle answers R3, so the silence above comes from
    // the state and not from the command.
    await bench.sendCommand(sdCmdGoIdleState, 0x00000000);
    await bench.idle(8);
    await bench.sendCommand(sdCmdAppCmd, 0x00000000);
    await bench.idle(8);
    await bench.sendCommand(sdAcmdSendOpCond, sdOcr());
    await bench.idle(8);
    await mon.stop();

    expect(mon.starts, hasLength(beforeAcmd + 3));
    expect(
      mon.starts.last.kind,
      equals(sdRespKindR3),
      reason: 'ACMD41 in idle answers R3 with the OCR',
    );
    await Simulator.endSimulation();
  });

  test('CMD2 answers R2 with the CID and moves ready to ident', () async {
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    await _initToReady(bench);
    final beforeCid = mon.starts.length;

    await bench.sendCommand(sdCmdAllSendCid, 0x00000000);
    await bench.idle(8);
    await mon.stop();

    expect(mon.starts, hasLength(beforeCid + 1), reason: 'CMD2 answers');
    expect(
      mon.starts.last.kind,
      equals(sdRespKindR2),
      reason: 'a CID does not fit in a short response',
    );
    expect(
      mon.starts.last.word,
      equals(sdRegisterToBigInt(sdCid())),
      reason: 'an R2 carries the register as it stands, CRC7 and all',
    );
    expect(
      bench.cardState,
      equals(sdCardStateIdent),
      reason: 'the card that sent its CID waits for an address',
    );
    await Simulator.endSimulation();
  });

  test('CMD2 outside the ready state answers nothing', () async {
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    await bench.sendCommand(sdCmdAllSendCid, 0x00000000);
    await bench.idle(8);
    expect(
      mon.starts,
      isEmpty,
      reason: 'CMD2 in idle is a command that the state does not hold',
    );
    expect(
      bench.cardState,
      equals(sdCardStateIdle),
      reason: 'a command that the card refuses does not move it',
    );

    // The same command in ready does answer, so the test above fails for
    // the state and not because the bench sent nothing.
    await _initToReady(bench);
    final beforeCid = mon.starts.length;
    await bench.sendCommand(sdCmdAllSendCid, 0x00000000);
    await bench.idle(8);
    await mon.stop();

    expect(mon.starts, hasLength(beforeCid + 1));
    expect(mon.starts.last.kind, equals(sdRespKindR2));
    expect(bench.cardState, equals(sdCardStateIdent));
    await Simulator.endSimulation();
  });

  test('CMD3 answers R6 with the address and moves ident to stby', () async {
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    await _initToReady(bench);
    await bench.sendCommand(sdCmdAllSendCid, 0x00000000);
    await bench.idle(8);
    final beforeRca = mon.starts.length;

    await bench.sendCommand(sdCmdSendRelativeAddr, 0x00000000);
    await bench.idle(8);
    await mon.stop();

    expect(mon.starts, hasLength(beforeRca + 1), reason: 'CMD3 answers');
    expect(
      mon.starts.last.kind,
      equals(sdRespKindR1),
      reason: 'an R6 has the frame shape of an R1',
    );
    expect(mon.starts.last.index, equals(sdCmdSendRelativeAddr));
    expect(
      _r6Rca(mon.starts.last.status),
      equals(sdCardRca),
      reason: 'the card publishes its address in the high half of an R6',
    );
    expect(
      _r6Rca(mon.starts.last.status),
      isNot(equals(0)),
      reason: 'the address 0 deselects every card, so no card holds it',
    );
    expect(
      _currentState(mon.starts.last.status),
      equals(sdCardStateIdent),
      reason:
          'an R6 reports CURRENT_STATE at the bits of an R1, and the '
          'answer reports the state before the move',
    );
    expect(
      bench.cardState,
      equals(sdCardStateStby),
      reason: 'the card that has an address waits to be selected',
    );
    await Simulator.endSimulation();
  });

  test('CMD3 outside the ident state answers nothing', () async {
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    await _initToReady(bench);
    final beforeRca = mon.starts.length;

    // The card is in ready and waits for CMD2, so CMD3 comes too early.
    await bench.sendCommand(sdCmdSendRelativeAddr, 0x00000000);
    await bench.idle(8);
    expect(
      mon.starts,
      hasLength(beforeRca),
      reason: 'CMD3 in ready is a command that the state does not hold',
    );
    expect(
      bench.cardState,
      equals(sdCardStateReady),
      reason: 'a command that the card refuses does not move it',
    );

    // CMD2 first, and then the same CMD3 answers.
    await bench.sendCommand(sdCmdAllSendCid, 0x00000000);
    await bench.idle(8);
    await bench.sendCommand(sdCmdSendRelativeAddr, 0x00000000);
    await bench.idle(8);
    await mon.stop();

    expect(mon.starts, hasLength(beforeRca + 2));
    expect(mon.starts.last.index, equals(sdCmdSendRelativeAddr));
    expect(bench.cardState, equals(sdCardStateStby));
    await Simulator.endSimulation();
  });

  test(
    'CMD9 answers R2 with the CSD when the argument names the card',
    () async {
      final bench = await _setUp(MimicSdCardFsm());
      final mon = _RespMonitor(bench);

      await _initToStby(bench);
      final beforeCsd = mon.starts.length;

      await bench.sendCommand(sdCmdSendCsd, _rcaArg(sdCardRca));
      await bench.idle(8);
      await mon.stop();

      expect(mon.starts, hasLength(beforeCsd + 1), reason: 'CMD9 answers');
      expect(mon.starts.last.kind, equals(sdRespKindR2));
      expect(
        mon.starts.last.word,
        equals(
          sdRegisterToBigInt(sdCsdV2(capacityBlocks: sdCardCapacityBlocks)),
        ),
        reason: 'an R2 carries the CSD as it stands',
      );
      expect(
        sdCsdCapacityBlocks(sdCsdV2(capacityBlocks: sdCardCapacityBlocks)),
        equals(sdCardCapacityBlocks),
        reason: 'the CSD that the card sends reports the capacity that it has',
      );
      expect(
        bench.cardState,
        equals(sdCardStateStby),
        reason: 'CMD9 does not move the card',
      );
      await Simulator.endSimulation();
    },
  );

  test('the image capacity has to be rounded to a C_SIZE step', () {
    // A CSD holds C_SIZE, which counts steps of 1024 blocks, so the raw
    // block count of the image is not a capacity that any CSD can report.
    expect(
      () => sdCsdV2(capacityBlocks: _imageBlocksRaw),
      throwsArgumentError,
      reason: 'the guard in sd_regs.dart must refuse an unaligned count',
    );
    expect(_imageBlocksAligned % sdCsdCapacityUnitBlocks, equals(0));
    expect(
      _imageBlocksAligned,
      lessThanOrEqualTo(_imageBlocksRaw),
      reason: 'the card must not report more blocks than the image holds',
    );
    expect(
      _imageBlocksRaw - _imageBlocksAligned,
      lessThan(sdCsdCapacityUnitBlocks),
      reason: 'the rounding loses less than one C_SIZE step',
    );
    expect(
      sdCsdCSize(sdCsdV2(capacityBlocks: _imageBlocksAligned)),
      _imageCSize,
    );
  });

  test('CMD9 answers the CSD on the port, not a constant, and again after it '
      'changes', () async {
    // The runtime owns the personality of the card, so the card must send
    // what it is given. The two values below are complete CSD registers
    // that sd_regs.dart builds, which is what the runtime writes.
    final runtimeCsd = sdCsdV2(capacityBlocks: _imageBlocksAligned);
    final secondCsd = sdCsdV2(capacityBlocks: _secondCapacityBlocks);

    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    bench.csd.inject(sdRegisterToBigInt(runtimeCsd));
    await _initToStby(bench);
    final beforeCsd = mon.starts.length;

    await bench.sendCommand(sdCmdSendCsd, _rcaArg(sdCardRca));
    await bench.idle(8);

    expect(mon.starts, hasLength(beforeCsd + 1), reason: 'CMD9 answers');
    expect(mon.starts.last.kind, equals(sdRespKindR2));
    expect(
      mon.starts.last.word,
      equals(sdRegisterToBigInt(runtimeCsd)),
      reason: 'the card sends the CSD it was given, bit for bit',
    );
    expect(
      sdCsdCSize(_registerBytes(mon.starts.last.word)),
      equals(_imageCSize),
      reason: 'C_SIZE on the wire is the one the image needs',
    );
    expect(
      sdCsdCapacityBlocks(_registerBytes(mon.starts.last.word)),
      equals(_imageBlocksAligned),
      reason: 'the capacity a host reads back is the capacity written',
    );
    expect(
      _imageBlocksAligned,
      isNot(equals(sdCardCapacityBlocks)),
      reason: 'the test proves nothing if it writes the default back',
    );

    // The same command a second time, with another CSD on the port. The
    // card holds no CSD of its own, so a stale answer would show here.
    bench.csd.inject(sdRegisterToBigInt(secondCsd));
    await bench.sendCommand(sdCmdGoIdleState, 0x00000000);
    await bench.idle(8);
    await _initToStby(bench);
    final beforeSecond = mon.starts.length;

    await bench.sendCommand(sdCmdSendCsd, _rcaArg(sdCardRca));
    await bench.idle(8);
    await mon.stop();

    expect(mon.starts, hasLength(beforeSecond + 1));
    expect(
      mon.starts.last.word,
      equals(sdRegisterToBigInt(secondCsd)),
      reason: 'the second CMD9 carries the second CSD',
    );
    expect(
      sdCsdCapacityBlocks(_registerBytes(mon.starts.last.word)),
      equals(_secondCapacityBlocks),
    );
    await Simulator.endSimulation();
  });

  test('CMD9 answers nothing for an address of another card', () async {
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    await _initToStby(bench);
    final beforeCsd = mon.starts.length;

    await bench.sendCommand(sdCmdSendCsd, _rcaArg(_foreignRca));
    await bench.idle(8);
    expect(
      mon.starts,
      hasLength(beforeCsd),
      reason: 'the CSD belongs to the card that the argument names',
    );

    // The same command with the address of this card does answer.
    await bench.sendCommand(sdCmdSendCsd, _rcaArg(sdCardRca));
    await bench.idle(8);
    await mon.stop();
    expect(mon.starts, hasLength(beforeCsd + 1));
    expect(mon.starts.last.kind, equals(sdRespKindR2));
    await Simulator.endSimulation();
  });

  test('CMD9 outside the stby state answers nothing', () async {
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    await _initToTran(bench);
    final beforeCsd = mon.starts.length;

    await bench.sendCommand(sdCmdSendCsd, _rcaArg(sdCardRca));
    await bench.idle(8);
    await mon.stop();

    expect(
      mon.starts,
      hasLength(beforeCsd),
      reason: 'a selected card reads CMD9 in the stby state alone',
    );
    expect(
      bench.cardState,
      equals(sdCardStateTran),
      reason: 'a command that the card refuses does not move it',
    );
    await Simulator.endSimulation();
  });

  test('CMD7 with the address of the card answers R1 and selects it', () async {
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    await _initToStby(bench);
    final beforeSelect = mon.starts.length;

    await bench.sendCommand(sdCmdSelectCard, _rcaArg(sdCardRca));
    await bench.idle(8);
    await mon.stop();

    expect(mon.starts, hasLength(beforeSelect + 1), reason: 'CMD7 answers');
    expect(mon.starts.last.kind, equals(sdRespKindR1));
    expect(mon.starts.last.index, equals(sdCmdSelectCard));
    expect(
      _currentState(mon.starts.last.status),
      equals(sdCardStateStby),
      reason: 'the answer reports the state before the move',
    );
    expect(
      _illegalCommand(mon.starts.last.status),
      equals(0),
      reason: 'CMD7 is legal for the card that it names',
    );
    expect(
      bench.cardState,
      equals(sdCardStateTran),
      reason: 'the selected card takes a transfer command next',
    );
    await Simulator.endSimulation();
  });

  test('CMD7 for another card answers nothing and deselects', () async {
    // A host selects one card of many with CMD7, and every other card
    // must hold the wire free for that one answer. A card that answered
    // here would drive the wire at the same time as the card that the host
    // asked, and the host would read neither answer.
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    await _initToTran(bench);
    final beforeForeign = mon.starts.length;

    await bench.sendCommand(sdCmdSelectCard, _rcaArg(_foreignRca));
    await bench.idle(8);
    expect(
      mon.starts,
      hasLength(beforeForeign),
      reason: 'the answer belongs to the card that the host selected',
    );
    expect(
      bench.cardState,
      equals(sdCardStateStby),
      reason: 'the card that the host did not select leaves the tran state',
    );

    // The address 0 deselects every card, and no card answers it.
    await bench.sendCommand(sdCmdSelectCard, _rcaArg(sdCardRca));
    await bench.idle(8);
    expect(bench.cardState, equals(sdCardStateTran));
    await bench.sendCommand(sdCmdSelectCard, 0x00000000);
    await bench.idle(8);
    await mon.stop();

    expect(
      bench.cardState,
      equals(sdCardStateStby),
      reason: 'the address 0 deselects the card',
    );
    expect(
      mon.starts,
      hasLength(beforeForeign + 1),
      reason: 'only the CMD7 that named this card answered',
    );
    await Simulator.endSimulation();
  });

  test('the card answers no address that it never published', () async {
    // The address register is the guard for CMD7 and CMD9, and CMD3 is
    // the one command that loads it. A write that ran on every command
    // would give the card its address here, on the CMD8 below, and the
    // CMD7 after it would then select a card that no host ever addressed.
    // The card would answer, move to tran and lose every later CMD3.
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    await bench.sendCommand(sdCmdSendIfCond, 0x000001AA);
    await bench.idle(8);
    expect(mon.starts, hasLength(1), reason: 'CMD8 answers in idle');

    await bench.sendCommand(sdCmdSelectCard, _rcaArg(sdCardRca));
    await bench.idle(8);
    expect(
      mon.starts,
      hasLength(1),
      reason: 'the card holds no address, so CMD7 names another card',
    );
    expect(
      bench.cardState,
      equals(sdCardStateIdle),
      reason: 'a card with no address is not the card that CMD7 selected',
    );

    await bench.sendCommand(sdCmdSendCsd, _rcaArg(sdCardRca));
    await bench.idle(8);
    expect(mon.starts, hasLength(1), reason: 'CMD9 names another card as well');
    expect(bench.cardState, equals(sdCardStateIdle));

    // The address 0 is the deselect that a host broadcasts. A card with no
    // address of its own must not read it as its own address.
    await bench.sendCommand(sdCmdSelectCard, 0x00000000);
    await bench.idle(8);
    await mon.stop();
    expect(
      mon.starts,
      hasLength(1),
      reason: 'a card with no address holds none',
    );
    expect(bench.cardState, equals(sdCardStateIdle));
    await Simulator.endSimulation();
  });

  test('the walk from idle to tran runs twice with no stale state', () async {
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);

    await _initToReady(bench);
    final beforeFirst = mon.starts.length;
    await _identifyToTran(bench);
    final firstWalk = mon.starts.sublist(beforeFirst);

    expect(
      firstWalk,
      hasLength(3),
      reason: 'CMD2, CMD3 and CMD7 each answered',
    );
    expect(
      firstWalk[0].kind,
      equals(sdRespKindR2),
      reason: 'CMD2 answers R2, which has no index field on the wire',
    );
    expect(firstWalk[1].index, equals(sdCmdSendRelativeAddr));
    expect(firstWalk[2].index, equals(sdCmdSelectCard));
    expect(
      bench.cardState,
      equals(sdCardStateTran),
      reason: 'the first walk ends in the transfer state',
    );

    // CMD0 is what a host sends when it starts again. It returns the card
    // to idle and takes the address back with it.
    await bench.sendCommand(sdCmdGoIdleState, 0x00000000);
    await bench.idle(8);
    expect(bench.cardState, equals(sdCardStateIdle));
    final afterReset = mon.starts.length;
    expect(afterReset, equals(beforeFirst + 3), reason: 'CMD0 gives no answer');

    await bench.sendCommand(sdCmdSelectCard, _rcaArg(sdCardRca));
    await bench.idle(8);
    expect(
      mon.starts,
      hasLength(afterReset),
      reason: 'CMD0 took the address back, so CMD7 now names another card',
    );
    expect(
      bench.cardState,
      equals(sdCardStateIdle),
      reason: 'a card in idle holds no address to be selected by',
    );

    // The whole walk again, from the same idle state.
    await _initToReady(bench);
    final beforeSecond = mon.starts.length;
    await _identifyToTran(bench);
    final secondWalk = mon.starts.sublist(beforeSecond);
    await mon.stop();

    expect(
      secondWalk,
      equals(firstWalk),
      reason:
          'the second walk answers the same three commands with the '
          'same kinds, the same registers and the same card status, so no '
          'state of the first walk stayed behind',
    );
    expect(
      bench.cardState,
      equals(sdCardStateTran),
      reason: 'the second walk ends in the transfer state as the first did',
    );
    await Simulator.endSimulation();
  });

  // The block write. CMD24 takes the card from tran to rcv, the write path
  // moves it on to prg while it programs the block, and the end of the
  // write returns it to tran.

  test('CMD24 in tran starts a write and takes the card to rcv', () async {
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);
    await _initToTran(bench);
    final before = mon.starts.length;

    await bench.sendCommand(sdCmdWriteBlock, _writeLba);
    // The start is a pulse of ONE clock, on the clock the decode commits.
    await bench.tick();
    expect(bench.writeStart, isTrue, reason: 'the decode raises write_start');
    expect(
      bench.writeLba,
      equals(_writeLba),
      reason: 'the write path gets the block address of the command',
    );
    await bench.tick();
    expect(
      bench.writeStart,
      isFalse,
      reason: 'write_start is one clock wide, the way read_start is',
    );

    await bench.idle(8);
    await mon.stop();
    expect(mon.starts, hasLength(before + 1), reason: 'CMD24 answers R1');
    expect(mon.starts.last.index, equals(sdCmdWriteBlock));
    expect(
      _currentState(mon.starts.last.status),
      equals(sdCardStateTran),
      reason: 'the answer reports the state before the move',
    );
    expect(
      _illegalCommand(mon.starts.last.status),
      equals(0),
      reason: 'CMD24 in tran is a legal command',
    );
    expect(
      bench.cardState,
      equals(sdCardStateRcv),
      reason: 'a card that took a write waits for the block in rcv',
    );
    await Simulator.endSimulation();
  });

  test('CMD24 is refused while the write path cannot take a block', () async {
    // A block that the runtime has not taken is still on the write
    // channel. The card must say so at once, because a host that gets no
    // answer waits out its own timeout instead.
    final bench = await _setUp(MimicSdCardFsm());
    final mon = _RespMonitor(bench);
    await _initToTran(bench);
    final before = mon.starts.length;

    bench.writeReady.inject(0);
    await bench.sendCommand(sdCmdWriteBlock, _writeLba);
    await bench.tick();
    expect(
      bench.writeStart,
      isFalse,
      reason: 'a refused CMD24 must not start the write path',
    );
    await bench.idle(8);
    await mon.stop();

    expect(mon.starts, hasLength(before + 1), reason: 'CMD24 still answers');
    expect(
      _cardError(mon.starts.last.status),
      equals(1),
      reason: 'a write the card cannot take answers R1 with the ERROR bit',
    );
    expect(
      bench.cardState,
      equals(sdCardStateTran),
      reason: 'a refused write does not move the card',
    );
    await Simulator.endSimulation();
  });

  test('the card walks tran, rcv, prg and back to tran', () async {
    final bench = await _setUp(MimicSdCardFsm());
    await _initToTran(bench);

    await bench.sendCommand(sdCmdWriteBlock, _writeLba);
    await bench.idle(4);
    expect(bench.cardState, equals(sdCardStateRcv));

    // The write path took the whole block and programs it now.
    bench.writePrg.inject(1);
    await bench.idle(2);
    expect(
      bench.cardState,
      equals(sdCardStatePrg),
      reason: 'the card is programming while the write path holds in_prg',
    );

    // The runtime answered. `write_done` is one clock wide, and `in_prg`
    // still stands on that clock, the way the write path drives them.
    bench.writeDone.inject(1);
    await bench.tick();
    bench.writeDone.inject(0);
    bench.writePrg.inject(0);
    await bench.idle(4);
    expect(
      bench.cardState,
      equals(sdCardStateTran),
      reason: 'a write ends where it started, in the transfer state',
    );

    // The card takes the next write, which proves nothing of the first one
    // stayed behind.
    await bench.sendCommand(sdCmdWriteBlock, _writeLba + 1);
    await bench.idle(4);
    expect(bench.cardState, equals(sdCardStateRcv));
    await Simulator.endSimulation();
  });

  test('a write that fails returns the card to tran as well', () async {
    final bench = await _setUp(MimicSdCardFsm());
    await _initToTran(bench);

    await bench.sendCommand(sdCmdWriteBlock, _writeLba);
    await bench.idle(4);
    expect(bench.cardState, equals(sdCardStateRcv));

    // The host never sent the block, so the write path gave up in rcv and
    // the card never reached prg.
    bench.writeFailed.inject(1);
    await bench.tick();
    bench.writeFailed.inject(0);
    await bench.idle(4);
    expect(
      bench.cardState,
      equals(sdCardStateTran),
      reason: 'a write that failed ends in the transfer state too',
    );
    await Simulator.endSimulation();
  });

  test(
    'a command that takes the card out of a write raises write_abort',
    () async {
      // CMD0 belongs to every state. The record that the card posted still
      // stands and the host has stopped waiting, so the write path has to
      // hear about it.
      final bench = await _setUp(MimicSdCardFsm());
      await _initToTran(bench);

      await bench.sendCommand(sdCmdWriteBlock, _writeLba);
      await bench.idle(4);
      expect(bench.cardState, equals(sdCardStateRcv));
      expect(
        bench.writeAbort,
        isFalse,
        reason: 'nothing aborts a write that is running',
      );

      await bench.sendCommand(sdCmdGoIdleState, 0x00000000);
      expect(
        bench.writeAbort,
        isTrue,
        reason: 'the clock that decodes CMD0 in rcv raises write_abort',
      );
      await bench.idle(4);
      expect(
        bench.cardState,
        equals(sdCardStateIdle),
        reason: 'CMD0 takes the card to idle from a write as well',
      );
      expect(bench.writeAbort, isFalse, reason: 'the abort is one clock wide');
      await Simulator.endSimulation();
    },
  );

  // The end of a transfer against a command that arrives on the same clock.
  //
  // A Linux host without MMC_CAP_WAIT_WHILE_BUSY polls CMD13 through the
  // whole busy window, so a CMD13 that lands on the clock a write ends is
  // routine. CMD13 does NOT move the card, so a card that let the decode
  // beat the end of the transfer wrote prg back over the tran that the
  // completion had just written, and the one clock pulse was gone. CMD12
  // is not accepted in prg, so only CMD0 recovered the card.

  for (var offset = 0; offset < 6; offset++) {
    test(
      'CMD13 $offset clocks from the end of a write leaves the card in tran',
      () async {
        final bench = await _setUp(MimicSdCardFsm());
        await _initToTran(bench);
        await _toPrg(bench);

        // Offset 0 puts `write_done` on the clock that commits the decode
        // of CMD13, which is the collision. The offsets above it walk the
        // pulse away from that clock.
        await _pulseAfterCommand(
          bench,
          sdCmdSendStatus,
          _rcaArg(sdCardRca),
          bench.writeDone,
          offset,
        );
        bench.writePrg.inject(0);
        await bench.idle(8);

        expect(
          bench.cardState,
          equals(sdCardStateTran),
          reason:
              'CMD13 reports the card and moves nothing, so the end of the '
              'write must still take the card out of prg. A card that stays '
              'in prg holds the host on a poll that never ends, and only '
              'CMD0 recovers it.',
        );
        await Simulator.endSimulation();
      },
    );
  }

  for (var offset = 0; offset < 6; offset++) {
    test(
      'CMD13 $offset clocks from the end of a read leaves the card in tran',
      () async {
        // The read path has the same shape as the write path above, so it
        // has the same collision.
        final bench = await _setUp(MimicSdCardFsm());
        await _initToTran(bench);

        await bench.sendCommand(sdCmdReadSingleBlock, _writeLba);
        await bench.idle(4);
        expect(bench.cardState, equals(sdCardStateData));

        await _pulseAfterCommand(
          bench,
          sdCmdSendStatus,
          _rcaArg(sdCardRca),
          bench.readDone,
          offset,
        );
        await bench.idle(8);

        expect(
          bench.cardState,
          equals(sdCardStateTran),
          reason: 'the end of a read must take the card out of the data state',
        );
        await Simulator.endSimulation();
      },
    );
  }

  test('CMD0 on the clock a write ends still takes the card to idle', () async {
    // The other half of the rule. A command that really MOVES the card
    // wins over the end of the transfer, so a CMD0 that lands as the write
    // finishes must give idle and not tran.
    final bench = await _setUp(MimicSdCardFsm());
    await _initToTran(bench);
    await _toPrg(bench);

    await _pulseAfterCommand(
      bench,
      sdCmdGoIdleState,
      0x00000000,
      bench.writeDone,
      0,
    );
    bench.writePrg.inject(0);
    await bench.idle(8);

    expect(
      bench.cardState,
      equals(sdCardStateIdle),
      reason: 'CMD0 moves the card, so it beats the end of the write',
    );
    await Simulator.endSimulation();
  });

  test('CMD0 on the clock a read ends still takes the card to idle', () async {
    final bench = await _setUp(MimicSdCardFsm());
    await _initToTran(bench);

    await bench.sendCommand(sdCmdReadSingleBlock, _writeLba);
    await bench.idle(4);
    expect(bench.cardState, equals(sdCardStateData));

    await _pulseAfterCommand(
      bench,
      sdCmdGoIdleState,
      0x00000000,
      bench.readDone,
      0,
    );
    await bench.idle(8);

    expect(
      bench.cardState,
      equals(sdCardStateIdle),
      reason: 'CMD0 moves the card, so it beats the end of the read',
    );
    await Simulator.endSimulation();
  });
}

/// The block address that the write tests use.
///
/// It is not 0, so a card that gave the write path a fixed address cannot
/// pass.
const int _writeLba = 0x0000ABCD;

/// The ERROR bit of a card [status].
int _cardError(int status) => (status >> sdStatusErrorBit) & 1;

/// Drives the card from tran into the prg state through one CMD24.
///
/// It leaves `write_prg` HIGH, which is what the write path holds while it
/// waits for the runtime.
Future<void> _toPrg(_Bench bench) async {
  await bench.sendCommand(sdCmdWriteBlock, _writeLba);
  await bench.idle(4);
  expect(bench.cardState, equals(sdCardStateRcv));
  bench.writePrg.inject(1);
  await bench.idle(2);
  expect(bench.cardState, equals(sdCardStatePrg));
}

/// Sends [index] and raises [pulse] for one clock, [offset] clocks later.
///
/// Offset 0 is the clock that COMMITS the decode of the command, which is
/// the clock after the one that carried it. That is the collision: the
/// decode and the end of the transfer both write the state register on one
/// edge.
Future<void> _pulseAfterCommand(
  _Bench bench,
  int index,
  int arg,
  Logic pulse,
  int offset,
) async {
  await bench.sendCommand(index, arg);
  for (var i = 0; i < offset; i++) {
    await bench.tick();
  }
  pulse.inject(1);
  await bench.tick();
  pulse.inject(0);
}

/// Drives CMD55 and ACMD41 until the card reports the power-up done.
///
/// The card answers busy for [sdOpCondBusyPolls] polls, so the loop runs
/// one time more than that. It leaves the card in the ready state, which
/// is the only way that a test reaches a state above idle today.
Future<void> _initToReady(_Bench bench) async {
  for (var poll = 0; poll <= sdOpCondBusyPolls; poll++) {
    await bench.sendCommand(sdCmdAppCmd, 0x00000000);
    await bench.idle(8);
    await bench.sendCommand(sdAcmdSendOpCond, sdOcr());
    await bench.idle(8);
  }
}

/// The APP_CMD bit of a card [status].
int _appCmd(int status) => (status >> sdStatusAppCmdBit) & 1;

/// The ILLEGAL_COMMAND bit of a card [status].
int _illegalCommand(int status) => (status >> sdStatusIllegalCommandBit) & 1;

/// The CURRENT_STATE field of a card [status].
int _currentState(int status) =>
    (status >> sdStatusCurrentStateLsb) & ((1 << sdCardStateBits) - 1);

/// Drives the card from idle to the stby state.
///
/// The card leaves this in the state where it has an address and waits for
/// CMD7 to select it.
Future<void> _initToStby(_Bench bench) async {
  await _initToReady(bench);
  await bench.sendCommand(sdCmdAllSendCid, 0x00000000);
  await bench.idle(8);
  await bench.sendCommand(sdCmdSendRelativeAddr, 0x00000000);
  await bench.idle(8);
}

/// Drives the card from the ready state to the tran state.
///
/// These are the three commands that give the card an address and select
/// it. The card must answer all three, and it ends selected.
Future<void> _identifyToTran(_Bench bench) async {
  await bench.sendCommand(sdCmdAllSendCid, 0x00000000);
  await bench.idle(8);
  await bench.sendCommand(sdCmdSendRelativeAddr, 0x00000000);
  await bench.idle(8);
  await bench.sendCommand(sdCmdSelectCard, _rcaArg(sdCardRca));
  await bench.idle(8);
}

/// Drives the card from idle to the tran state.
///
/// This is the whole identification walk that a host runs before it reads
/// one block.
Future<void> _initToTran(_Bench bench) async {
  await _initToReady(bench);
  await _identifyToTran(bench);
}

/// An address that this card never publishes.
///
/// A host with more than one card on the bus gives this address to another
/// card, and this card must then hold the wire free.
const int _foreignRca = 0xBEEF;

/// Number of 512-byte blocks in the disk image that Mimic must serve.
///
/// The number is the raw block count of a real image. A version 2.0 CSD
/// cannot hold it: C_SIZE counts steps of [sdCsdCapacityUnitBlocks] blocks,
/// and this count is not a whole number of steps.
const int _imageBlocksRaw = 3309569;

/// The capacity that the CSD reports for the image above, rounded DOWN.
///
/// This is the largest whole number of C_SIZE steps that fits in the image.
/// The last block of the image is then out of reach of the host, which is
/// the safe direction: the other choice is to report a capacity larger than
/// the image and let a host read past its end.
const int _imageBlocksAligned = 3309568;

/// The C_SIZE field that [_imageBlocksAligned] gives.
///
/// C_SIZE counts steps of 1024 blocks and starts at 0, so the field is one
/// less than the number of steps: 3309568 / 1024 - 1.
const int _imageCSize = 3231;

/// A second capacity, for the test that changes the CSD twice.
///
/// It is not the default and not [_imageBlocksAligned], so an answer that
/// carries it can only have come from the second write.
const int _secondCapacityBlocks = 2 * 1024 * 1024;

/// The 16 bytes of a register that an R2 carried, most significant first.
List<int> _registerBytes(BigInt value) => [
  for (var shift = (sdRegisterBytes - 1) * 8; shift >= 0; shift -= 8)
    ((value >> shift) & BigInt.from(0xFF)).toInt(),
];

/// The argument of a command that names the card at [rca].
///
/// The address sits in the high bits of the argument, and the low bits are
/// 0 in CMD7 and in CMD9.
int _rcaArg(int rca) => rca << (sdCommandArgBits - sdRcaBits);

/// The address field of an R6 payload.
int _r6Rca(int payload) =>
    (payload >> (sdCardStatusBits - sdRcaBits)) & ((1 << sdRcaBits) - 1);
