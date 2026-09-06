// What the card does when nothing answers a record, and the read path run
// twice on one card.
//
// A record that the runtime refuses gets ZERO words back, so the card has
// to give up rather than leave the host waiting for a start bit that never
// comes. The first test drives that whole path: the timeout, the event the
// card reports, the read it takes straight afterwards, and the late answer
// that it throws away because the tag names the record it gave up on.
//
// The second test runs a full identification walk and a read TWICE, which
// is what finds state that the first run left behind. The rest cover the
// abort path, the release of a waiting host, and the recovery commands.
@Timeout(Duration(minutes: 10))
library;

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';
import 'sd_read_bench.dart';

/// Bit 19 of the card status, ERROR.
const int _statusError = 1 << 19;

/// The 512 bytes of the block that answers the read of [lba].
///
/// Each address gives a pattern of its own, so a card that sends the block
/// of another read cannot pass.
List<int> _blockOf(int lba) => [
  for (var i = 0; i < sdBlockBytes; i++) (i * 3 + lba) & 0xFF,
];

void main() {
  tearDown(Simulator.reset);

  test(
    'a record that nothing answers times out and reports the fault',
    () async {
      final b = await setUpSdReadBench(readTimeoutClocks: sdTestTimeoutClocks);
      await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
      await walkToTran(b);

      await b.host.idle(sdCommandGapClocks);
      await b.host.sendCommand(sdCmdReadSingleBlock, sdTestLba);
      await b.host.receiveResponse(SdResponseKind.r1);
      final record = await takeRecord(b);
      expect(record.lba, sdTestLba);
      expect(record.seq, 1);

      // The runtime refuses the record, so it pushes nothing at all. The
      // host waits, and the card must give up rather than leave it waiting.
      final got = await b.host.receiveDataBlock(
        timeoutClocks: sdTestTimeoutClocks + 200,
        strict: false,
      );
      expect(
        got.timedOut,
        isTrue,
        reason: 'a card with no data must send nothing on DAT.',
      );
      expect(
        b.cardState,
        sdCardStateTran,
        reason: 'a read that timed out must return the card to tran.',
      );
      expect(
        await wbRead(b, MimicReg.event),
        1,
        reason: 'EVENT bit 0 must report the read that nothing answered.',
      );

      // A write of 1 clears the event.
      await wbWrite(b, MimicReg.event, 1);
      expect(
        await wbRead(b, MimicReg.event),
        0,
        reason: 'EVENT is write-one-to-clear.',
      );

      // The NEW intent of this check. The card used to refuse the next
      // read with an ERROR for a whole timeout period, because it could
      // not say whether a block that arrived belonged to the record it
      // gave up on. The tag says which, so the card takes the next read at
      // once and no host loses a read it could have had.
      await b.host.idle(sdCommandGapClocks);
      await b.host.sendCommand(sdCmdReadSingleBlock, 0x22);
      final again = await b.host.receiveResponse(SdResponseKind.r1);
      expect(again.timedOut, isFalse, reason: 'CMD17 gave no response.');
      expect(
        again.payload & _statusError,
        0,
        reason: 'the card must take the next read at once.',
      );
      expect(b.cardState, sdCardStateData);
      final second = await takeRecord(b);
      expect(second.lba, 0x22);
      expect(
        second.seq,
        2,
        reason: 'the second read of a card carries the tag after the first.',
      );
      await Simulator.endSimulation();
    },
  );

  // The regression test of Critical 1 of the read path review. The card
  // gave up on the read of 0x1111, took the read of 0x2222, and then sent
  // the LATE block of 0x1111 to the host as the answer to 0x2222, framed
  // with a good CRC16 that the host had no way to doubt.
  test('a late block is thrown away and never answers the next read', () async {
    final b = await setUpSdReadBench(readTimeoutClocks: sdTestTimeoutClocks);
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    // Read one. Nothing answers it in time, so the card gives up.
    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdReadSingleBlock, 0x1111);
    await b.host.receiveResponse(SdResponseKind.r1);
    final first = await takeRecord(b);
    expect(first.lba, 0x1111);
    expect(first.seq, 1);

    final none = await b.host.receiveDataBlock(
      timeoutClocks: sdTestTimeoutClocks + 200,
      strict: false,
    );
    expect(none.timedOut, isTrue, reason: 'the card must send nothing.');
    expect(b.cardState, sdCardStateTran);

    // Read two, which the card takes at once.
    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdReadSingleBlock, 0x2222);
    final taken = await b.host.receiveResponse(SdResponseKind.r1);
    expect(taken.timedOut, isFalse);
    expect(taken.payload & _statusError, 0);
    final second = await takeRecord(b);
    expect(second.lba, 0x2222);
    expect(second.seq, 2, reason: 'read two must carry a tag of its own.');

    // The late answer to read one arrives now, with the tag of read one.
    // The card must throw it away and send nothing.
    await pushBlock(b, sdBlockWordsOf(_blockOf(0x11)), tag: first.seq);
    // Long enough for the card to take the whole 128 word block off the
    // channel and throw it away, and short enough that the wait for the
    // block of read two has not run out when the right block arrives.
    final late = await b.host.receiveDataBlock(
      timeoutClocks: 300,
      strict: false,
    );
    expect(
      late.timedOut,
      isTrue,
      reason:
          'the card sent the block of read one as the answer to read two. '
          'The tag of the block names read one, so it must be thrown away.',
    );

    // The right answer arrives, and the card sends that one.
    await pushBlock(b, sdBlockWordsOf(_blockOf(0x22)), tag: second.seq);
    final good = await b.host.receiveDataBlock(timeoutClocks: 400);
    expect(good.timedOut, isFalse, reason: 'the card sent no block.');
    expect(good.crcOk, isTrue, reason: 'bad CRC16.');
    expect(
      good.bytes,
      _blockOf(0x22),
      reason: 'the card must send the block that the tag of read two names.',
    );
    await b.host.idle(4);
    expect(b.cardState, sdCardStateTran);

    // The channel is back in step: the two blocks both left it.
    expect(
      await wbRead(b, MimicReg.dataInCount),
      sdDataInFifoWords,
      reason: 'both blocks must be off the channel.',
    );
    await Simulator.endSimulation();
  });

  // The other branch that a late block reaches. CMD0 takes the card out of
  // the data state while it waits, so the record it posted still stands.
  test('CMD0 aborts a read and the late block is thrown away', () async {
    final b = await setUpSdReadBench(readTimeoutClocks: sdTestTimeoutClocks);
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdReadSingleBlock, 0x3333);
    await b.host.receiveResponse(SdResponseKind.r1);
    expect(b.cardState, sdCardStateData);
    final aborted = await takeRecord(b);
    expect(aborted.lba, 0x3333);
    expect(aborted.seq, 1);

    // CMD0 while the card waits for the block. It leaves the data state,
    // so the answer to the record is now late.
    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdGoIdleState, 0);
    await b.host.receiveResponse(SdResponseKind.r1, timeoutClocks: 16);
    expect(
      b.cardState,
      sdCardStateIdle,
      reason: 'CMD0 must take the card to idle from the data state.',
    );

    // The late block of the aborted read arrives while the card is idle.
    await pushBlock(b, sdBlockWordsOf(_blockOf(0x33)), tag: aborted.seq);

    // The host walks the card back to tran and reads again.
    await walkToTran(b);
    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdReadSingleBlock, 0x4444);
    final next = await b.host.receiveResponse(SdResponseKind.r1);
    expect(next.timedOut, isFalse, reason: 'CMD17 gave no response.');
    expect(next.payload & _statusError, 0, reason: 'the read was refused.');
    final served = await takeRecord(b);
    expect(served.lba, 0x4444);
    expect(
      served.seq,
      2,
      reason: 'the read after an abort carries a tag of its own.',
    );

    await pushBlock(b, sdBlockWordsOf(_blockOf(0x44)), tag: served.seq);
    final got = await b.host.receiveDataBlock(timeoutClocks: 400);
    expect(got.timedOut, isFalse, reason: 'the card sent no block.');
    expect(got.crcOk, isTrue, reason: 'bad CRC16.');
    expect(
      got.bytes,
      _blockOf(0x44),
      reason: 'the card sent the block of the read it aborted.',
    );
    await Simulator.endSimulation();
  });

  // CTRL bit 0 is what a runtime clears when it exits. A host that is
  // waiting for a block must be released by that, and not left to wait out
  // the whole timeout.
  test('clearing CTRL bit 0 releases a host mid transfer', () async {
    // The timeout is long here on purpose. A card that waited it out would
    // hold the host far past the check below.
    final b = await setUpSdReadBench(readTimeoutClocks: 20000);
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdReadSingleBlock, sdTestLba);
    await b.host.receiveResponse(SdResponseKind.r1);
    await takeRecord(b);
    expect(b.cardState, sdCardStateData);

    // The runtime exits and clears the enable bit.
    await wbWrite(b, MimicReg.ctrl, 0);

    // The card leaves the data state within the few clocks the crossing
    // needs, and far inside the timeout.
    await b.host.idle(64);
    expect(
      b.cardState,
      sdCardStateTran,
      reason:
          'a card that the runtime disabled must release the host at once, '
          'and not hold it for the whole read timeout.',
    );
    expect(
      await wbRead(b, MimicReg.event),
      0,
      reason:
          'EVENT bit 0 reports a runtime that never answered. An operator '
          'that stopped the card is not that.',
    );
    await Simulator.endSimulation();
  });

  // The recovery path of a Linux host whose read gave it no data: CMD12
  // and then a CMD13 poll.
  test('CMD12 and CMD13 let a host recover from a read timeout', () async {
    final b = await setUpSdReadBench(readTimeoutClocks: sdTestTimeoutClocks);
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdReadSingleBlock, sdTestLba);
    await b.host.receiveResponse(SdResponseKind.r1);
    await takeRecord(b);

    // Nothing answers, so the card gives up and returns to tran.
    final none = await b.host.receiveDataBlock(
      timeoutClocks: sdTestTimeoutClocks + 200,
      strict: false,
    );
    expect(none.timedOut, isTrue);
    expect(b.cardState, sdCardStateTran);

    // CMD12, the first command of the recovery.
    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdStopTransmission, 0);
    final stop = await b.host.receiveResponse(SdResponseKind.r1);
    expect(stop.timedOut, isFalse, reason: 'CMD12 gave no response.');
    expect(stop.field, sdCmdStopTransmission, reason: 'the index must echo.');
    expect(
      stop.payload & _statusError,
      0,
      reason: 'an error here makes the recovery of the host fail.',
    );
    expect(
      stop.payload & (1 << 22),
      0,
      reason:
          'ILLEGAL_COMMAND here makes __mmc_blk_err_check fail the request '
          'that the recovery was meant to save.',
    );

    // CMD13, the status poll that follows it.
    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdSendStatus, sdCardRca << 16);
    final status = await b.host.receiveResponse(SdResponseKind.r1);
    expect(status.timedOut, isFalse, reason: 'CMD13 gave no response.');
    expect(status.field, sdCmdSendStatus, reason: 'the index must echo.');
    expect(
      (status.payload >> 9) & 0xF,
      sdCardStateTran,
      reason: 'CMD13 must report the state the card is in.',
    );
    expect(
      status.payload & (1 << 8),
      isNot(0),
      reason: 'READY_FOR_DATA must be high on a card that is not writing.',
    );
    expect(
      b.cardState,
      sdCardStateTran,
      reason: 'CMD13 must not move the card.',
    );

    // The read that follows the recovery works.
    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdReadSingleBlock, 0x55);
    final again = await b.host.receiveResponse(SdResponseKind.r1);
    expect(again.timedOut, isFalse);
    expect(again.payload & _statusError, 0);
    final record = await takeRecord(b);
    expect(record.lba, 0x55);
    await pushBlock(b, sdBlockWordsOf(_blockOf(0x55)), tag: record.seq);
    final got = await b.host.receiveDataBlock(timeoutClocks: 400);
    expect(got.timedOut, isFalse);
    expect(got.bytes, _blockOf(0x55));
    await Simulator.endSimulation();
  });

  test('CMD12 takes the card out of the data state', () async {
    final b = await setUpSdReadBench(readTimeoutClocks: 20000);
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdReadSingleBlock, sdTestLba);
    await b.host.receiveResponse(SdResponseKind.r1);
    expect(b.cardState, sdCardStateData);
    final record = await takeRecord(b);

    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdStopTransmission, 0);
    final stop = await b.host.receiveResponse(SdResponseKind.r1);
    expect(stop.timedOut, isFalse, reason: 'CMD12 gave no response.');
    expect(
      b.cardState,
      sdCardStateTran,
      reason: 'CMD12 must take the card out of the data state.',
    );

    // The block of the read that CMD12 stopped is late, so the card throws
    // it away and the next read still gets its own bytes.
    await pushBlock(b, sdBlockWordsOf(_blockOf(0x66)), tag: record.seq);
    // The card takes the block it throws away off the channel one word at
    // a time, which is [sdBlockWords] SD clocks, and it refuses a read
    // while a block it did not ask for is still on the channel. That is
    // 5 us at 25 MHz, and a host that meets it reads an error and retries.
    await b.host.idle(sdBlockWords + 32);
    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdReadSingleBlock, 0x77);
    final next = await b.host.receiveResponse(SdResponseKind.r1);
    expect(next.timedOut, isFalse);
    final served = await takeRecord(b);
    expect(served.lba, 0x77);
    await pushBlock(b, sdBlockWordsOf(_blockOf(0x77)), tag: served.seq);
    final got = await b.host.receiveDataBlock(timeoutClocks: 2 * sdBlockBytes);
    expect(got.timedOut, isFalse, reason: 'the card sent no block.');
    expect(
      got.bytes,
      _blockOf(0x77),
      reason: 'the card sent the block of the read that CMD12 stopped.',
    );
    await Simulator.endSimulation();
  });

  // The card must publish values a reset gives, and never X, on a board
  // whose host never starts the SD clock. An asynchronous reset in ROHD
  // fires on the EDGE of the reset alone, so a bench that goes from X to 1
  // gives no edge and every such register holds X. This test parks the SD
  // clock for the whole reset, which is what that board gives.
  test('a card whose SD clock never ticks reads 0, and never X', () async {
    final b = await setUpSdReadBench(parkSdClock: true);

    // No SD clock has ticked at any time, so the SD domain still holds its
    // reset and the two registers a bring-up reads must both be defined.
    expect(
      await wbRead(b, MimicReg.event),
      0,
      reason:
          'EVENT read X. The read timeout toggle takes an asynchronous '
          'reset, and a reset with no 0 to 1 edge never loads it.',
    );
    expect(
      await wbRead(b, MimicReg.cardState),
      sdCardStateIdle,
      reason: 'a card that no host has clocked is idle.',
    );
    expect(
      await wbRead(b, MimicReg.dbgSdClk),
      0,
      reason: 'a clock that never ticks counts 0.',
    );
    expect(await wbRead(b, MimicReg.id), MimicRegValue.id);
    await Simulator.endSimulation();
  });

  test('a walk and a read run twice on one card', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    final block = sdTestBlockBytes();

    for (var run = 0; run < 2; run++) {
      await walkToTran(b);
      await b.host.idle(sdCommandGapClocks);
      await b.host.sendCommand(sdCmdReadSingleBlock, sdTestLba + run);
      final response = await b.host.receiveResponse(SdResponseKind.r1);
      expect(response.timedOut, isFalse, reason: 'run $run: CMD17 timed out.');

      final record = await takeRecord(b);
      expect(
        record.word0,
        sdRecordWord0(run + 1),
        reason: 'run $run: bad record word.',
      );
      expect(
        record.lba,
        sdTestLba + run,
        reason: 'run $run: the record holds the wrong address.',
      );
      expect(
        await wbRead(b, MimicReg.dataInCount),
        sdDataInFifoWords,
        reason: 'run $run: the channel must be free before the push.',
      );

      // Each run sends a block of its own, so a card that holds a stale
      // block cannot pass the second run.
      final runBlock = [for (final byte in block) (byte + run) & 0xFF];
      await pushBlock(b, sdBlockWordsOf(runBlock), tag: record.seq);

      final got = await b.host.receiveDataBlock(timeoutClocks: 200);
      expect(got.timedOut, isFalse, reason: 'run $run: the card sent nothing.');
      expect(got.crcOk, isTrue, reason: 'run $run: bad CRC16.');
      expect(
        got.bytes,
        runBlock,
        reason: 'run $run: the card sent other bytes.',
      );
      await b.host.idle(4);
      expect(
        b.cardState,
        sdCardStateTran,
        reason: 'run $run: the card must return to tran.',
      );
    }
    await Simulator.endSimulation();
  });
}
