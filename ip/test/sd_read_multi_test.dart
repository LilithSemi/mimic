// CMD18, READ_MULTIPLE_BLOCK, and the setup walk a Linux host makes.
//
// Linux reads multi-block for nearly every request, so a card with CMD17
// alone is a card on the slow path. CMD18 streams block after block from
// the start address until the host sends CMD12.
//
// The card posts ONE RECORD FOR EACH BLOCK. The record is the record CMD17
// posts, with the address moved on by one and a sequence tag of its own,
// so the runtime answers a stream with the loop it already runs for a
// single block read. See the class doc of MimicSdReadPath.
//
// The last test runs the whole walk TWICE on one card. A sequence that
// runs once cannot see state that the first run left behind.
@Timeout(Duration(minutes: 30))
library;

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';
import 'sd_read_bench.dart';

/// The 8 bytes of the SCR this card sends, as LITERALS. See
/// sd_setup_commands_test.dart, which holds the same list for the same
/// reason.
const List<int> _scrBytes = [0x02, 0x31, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];

/// Reads [count] blocks with CMD18 from [lba] and stops with CMD12.
///
/// Each block is checked against the image the bench serves, so a card
/// that repeats a block or sends the block of another address fails here.
Future<void> readMultiBlock(
  SdReadBench b, {
  required int lba,
  required int count,
}) async {
  await b.host.idle(sdCommandGapClocks);
  await b.host.sendCommand(sdCmdReadMultipleBlock, lba);
  final answer = await b.host.receiveResponse(SdResponseKind.r1);
  expect(answer.timedOut, isFalse, reason: 'CMD18 gave no response.');
  expect(answer.field, sdCmdReadMultipleBlock);
  expect(
    answer.payload & (1 << 19),
    0,
    reason: 'CMD18 answered R1 with ERROR, so no block follows.',
  );

  for (var i = 0; i < count; i++) {
    final want = sdTestBlockBytesFor(lba + i);
    await answerRecord(b, want, expectLba: lba + i);

    final got = await b.host.receiveDataBlock(timeoutClocks: 400);
    expect(got.timedOut, isFalse, reason: 'block $i never came.');
    expect(got.framingOk, isTrue, reason: 'block $i is not framed.');
    expect(got.crcOk, isTrue, reason: 'block $i carries a bad CRC16.');
    expect(
      got.bytes,
      want,
      reason: 'block $i is not block ${lba + i} of the image.',
    );

    // The card asks for the block after this one on the clock the link
    // reports the end bit, so it stays in the data state between blocks.
    // A card that fell back to tran here would refuse the CMD12 recovery
    // path and would answer no further block.
    await b.host.idle(8);
    expect(
      b.cardState,
      sdCardStateData,
      reason: 'the card left the data state in the middle of a stream.',
    );
  }

  // CMD12 stops the stream. The card answers R1 and returns to tran.
  await b.host.idle(sdCommandGapClocks);
  await b.host.sendCommand(sdCmdStopTransmission, 0);
  final stop = await b.host.receiveResponse(SdResponseKind.r1);
  expect(stop.timedOut, isFalse, reason: 'CMD12 gave no response.');
  expect(
    stop.payload & (1 << 19),
    0,
    reason: 'CMD12 answered with ERROR, which fails the whole request.',
  );

  await b.host.idle(16);
  expect(
    b.cardState,
    sdCardStateTran,
    reason: 'CMD12 must return the card to tran.',
  );

  // The card asked for one more block before the stop arrived. That
  // record is still on the channel and the runtime takes it off, the way
  // it takes off any record it cannot serve.
  final left = await wbRead(b, MimicReg.reqCount);
  if (left != 0) {
    await takeRecord(b);
  }
}

void main() {
  tearDown(Simulator.reset);

  test('CMD18 streams consecutive blocks and stops on CMD12', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    await readMultiBlock(b, lba: sdTestLba, count: 3);

    expect(
      await wbRead(b, MimicReg.event),
      0,
      reason: 'a stream that worked must raise no event.',
    );
    await Simulator.endSimulation();
  });

  test('the whole setup walk and a stream, run TWICE', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);

    for (var run = 0; run < 2; run++) {
      // CMD0 is the first command of the walk, so the second run starts
      // from idle the way the first one did.
      await walkToTran(b);

      final scr = await readScr(b);
      expect(scr.timedOut, isFalse, reason: 'run $run: ACMD51 sent nothing.');
      expect(scr.crcOk, isTrue, reason: 'run $run: the SCR CRC16 is bad.');
      expect(scr.bytes, _scrBytes, reason: 'run $run: the SCR is not the SCR.');

      await b.host.idle(sdCommandGapClocks);
      await b.host.sendCommand(sdCmdSetBlocklen, 512);
      final blockLen = await b.host.receiveResponse(SdResponseKind.r1);
      expect(
        blockLen.payload & (1 << 29),
        0,
        reason: 'run $run: CMD16 refused 512 bytes.',
      );

      final busWidth = await appCommand(b, sdAcmdSetBusWidth, 0);
      expect(
        busWidth.payload & (1 << 19),
        0,
        reason: 'run $run: ACMD6 refused the 1-bit bus.',
      );

      await readMultiBlock(b, lba: sdTestLba + run * 16, count: 2);

      expect(
        await wbRead(b, MimicReg.event),
        0,
        reason: 'run $run: the walk raised an event.',
      );
    }
    await Simulator.endSimulation();
  });
}
