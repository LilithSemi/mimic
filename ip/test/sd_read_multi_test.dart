// CMD18, READ_MULTIPLE_BLOCK, and the setup walk a Linux host makes.
//
// Linux reads multi-block for nearly every request, so a card with CMD17
// alone is a card on the slow path. CMD18 streams block after block from
// the start address until the host sends CMD12.
//
// The card posts ONE RECORD FOR A CHUNK of the stream. The record carries
// a block count, and the card then takes block after block off the data
// channel under the ONE sequence tag of that record until the chunk runs
// out. A stream of 32 blocks therefore costs one record and not 32. See
// the class doc of MimicSdReadPath.
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
const List<int> _scrBytes = [0x02, 0x35, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];

/// Reads [count] blocks with CMD18 from [lba] and stops with CMD12.
///
/// Each block is checked against the image the bench serves, so a card
/// that repeats a block or sends the block of another address fails here.
///
/// It returns the RECORDS the card posted for the whole stream, which is
/// the number the chunk exists to cut down.
Future<int> readMultiBlock(
  SdReadBench b, {
  required int lba,
  required int count,
  int overshoot = 0,
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

  // The runtime that answers the chunk records beside the host. It pushes
  // blocks the host has not read yet, the way the real one does, because
  // the card takes them off the channel as fast as the SD bus drains.
  //
  // [overshoot] is the blocks it pushes PAST the ones the host reads. A
  // host that stops a stream leaves such blocks behind, and the card must
  // throw every one of them away.
  final runtime = SdStreamRuntime(b, lba: lba, limit: count + overshoot);

  for (var i = 0; i < count; i++) {
    final want = sdTestBlockBytesFor(lba + i);
    await runtime.feed();

    final got = await b.host.receiveDataBlock(timeoutClocks: 4000);
    expect(got.timedOut, isFalse, reason: 'block $i never came.');
    expect(got.framingOk, isTrue, reason: 'block $i is not framed.');
    expect(got.crcOk, isTrue, reason: 'block $i carries a bad CRC16.');
    expect(
      got.bytes,
      want,
      reason: 'block $i is not block ${lba + i} of the image.',
    );

    // The card stays in the data state between the blocks of a stream. A
    // card that fell back to tran here would refuse the CMD12 recovery
    // path and would answer no further block.
    //
    // The idle fits inside the gap the card leaves between two blocks of a
    // stream, so it cannot run through the start bit of the next one. See
    // [sdStreamGapClocks].
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

  // The card may have asked for a new chunk before the stop arrived. That
  // record is still on the channel and the runtime takes it off, the way
  // it takes off any record it cannot serve.
  await runtime.drain();
  return runtime.records;
}

void main() {
  tearDown(Simulator.reset);

  test('CMD18 streams consecutive blocks and stops on CMD12', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);
    final records = await readMultiBlock(b, lba: sdTestLba, count: 3);

    expect(
      records,
      1,
      reason: 'a stream inside one chunk must cost exactly one record.',
    );
    expect(
      await wbRead(b, MimicReg.event),
      0,
      reason: 'a stream that worked must raise no event.',
    );
    await Simulator.endSimulation();
  });

  test(
    'a stream longer than one chunk costs one record for each chunk',
    () async {
      // The measurement this chunk exists for. The card posted a record for
      // EVERY block before, so a stream of six blocks cost six records. It
      // now costs the chunks the stream covers.
      //
      // The chunk is 4 here and not [sdStreamRecordBlocks], because a block
      // is 4114 SD clocks and a stream that crossed a boundary of the real
      // chunk would simulate for tens of thousands of them. The card takes
      // the number from a parameter for exactly this.
      const count = 6;
      final b = await setUpSdReadBench(
        streamBlocks: 4,
        capacityBlocks: sdTestLba + count + 64,
      );
      await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
      await walkToTran(b);
      final records = await readMultiBlock(b, lba: sdTestLba, count: count);

      expect(
        records,
        2,
        reason: '$count blocks span two chunks of 4, so they cost two records.',
      );
      expect(
        await wbRead(b, MimicReg.event),
        0,
        reason: 'a stream that worked must raise no event.',
      );
      await Simulator.endSimulation();
    },
  );

  test(
    'blocks left over from a stopped stream never reach the next one',
    () async {
      // The host stops in the middle of a chunk and the runtime has already
      // pushed blocks that nobody will read. The card gives the NEXT read a
      // sequence tag of its own, so every leftover block carries the old tag
      // and the card throws it away. A card that sent one would give the
      // host the bytes of another read with a good CRC16 on them.
      final b = await setUpSdReadBench(capacityBlocks: sdTestLba + 128);
      await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
      await walkToTran(b);

      await readMultiBlock(b, lba: sdTestLba, count: 3, overshoot: 4);
      await readMultiBlock(b, lba: sdTestLba + 40, count: 3);

      expect(
        await wbRead(b, MimicReg.event),
        0,
        reason: 'a stream that worked must raise no event.',
      );
      await Simulator.endSimulation();
    },
  );

  test('CMD18 posts no request beyond NUM_BLOCKS', () async {
    final b = await setUpSdReadBench(capacityBlocks: sdTestLba + 2);
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);
    expect(
      b.bridge.card.subModules
          .whereType<MimicSdCardFsm>()
          .single
          .input('num_blocks')
          .value
          .toInt(),
      sdTestLba + 2,
      reason: 'the SD clock domain must hold the configured capacity',
    );

    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdReadMultipleBlock, sdTestLba);
    final answer = await b.host.receiveResponse(SdResponseKind.r1);
    expect(answer.timedOut, isFalse);
    expect(answer.payload & (1 << sdStatusErrorBit), 0);

    // Two blocks are left on the card, so the ONE record of this stream
    // asks for two and no more. A record that asked for a whole chunk here
    // would name a block the runtime does not hold, and the runtime
    // refuses such a record whole.
    final runtime = SdStreamRuntime(b, lba: sdTestLba, limit: 2);
    for (var offset = 0; offset < 2; offset++) {
      final lba = sdTestLba + offset;
      final want = sdTestBlockBytesFor(lba);
      await runtime.feed();
      final got = await b.host.receiveDataBlock(timeoutClocks: 4000);
      expect(got.timedOut, isFalse, reason: 'block $lba never came');
      expect(got.bytes, want);
      await b.host.idle(8);
    }
    expect(
      runtime.records,
      1,
      reason: 'the two blocks that are left must cost one record.',
    );

    await b.host.idle(8);
    expect(
      b.cardState,
      sdCardStateTran,
      reason: 'the stream must stop after the last block of the card',
    );
    expect(
      await wbRead(b, MimicReg.reqCount),
      0,
      reason: 'the card must not ask the runtime for NUM_BLOCKS',
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

      final records = await readMultiBlock(
        b,
        lba: sdTestLba + run * 16,
        count: 2,
      );
      expect(records, 1, reason: 'run $run: a short stream is one record.');

      expect(
        await wbRead(b, MimicReg.event),
        0,
        reason: 'run $run: the walk raised an event.',
      );
    }
    await Simulator.endSimulation();
  });
}
