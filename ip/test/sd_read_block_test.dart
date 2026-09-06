// The block half of the block read path.
//
// The card takes 512 bytes off the data channel and puts them on DAT0 with
// a CRC16. One block is 4114 SD clocks, so these tests are the slow ones.
//
// The second test is the NEGATIVE CONTROL for the crossing: it breaks the
// data FIFO and shows that the block the host reads is then not the block
// the runtime pushed.
//
// The CRC16 is checked by the host model, which computes it in software
// and never asks the card what it thinks the CRC is.
@Timeout(Duration(minutes: 10))
library;

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';
import 'sd_read_bench.dart';

void main() {
  tearDown(Simulator.reset);

  test('the card sends the block it was given, with a good CRC16', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdReadSingleBlock, sdTestLba);
    await b.host.receiveResponse(SdResponseKind.r1);

    final record = await takeRecord(b);
    expect(record.lba, sdTestLba);
    expect(record.seq, 1, reason: 'the first read of a card carries tag 1.');

    expect(
      await wbRead(b, MimicReg.dataInCount),
      sdDataInFifoWords,
      reason: 'an empty data channel must report all of its space.',
    );

    final block = sdTestBlockBytes();
    final words = sdBlockWordsOf(block);
    expect(words.length, sdBlockWords);
    expect(words.first, sdBlockWord0, reason: 'the packing is little endian.');
    expect(words.last, sdBlockWord127);
    await pushBlock(b, words, tag: record.seq);

    expect(
      await wbRead(b, MimicReg.dataInCount),
      sdDataInFifoWords - sdBlockWords,
      reason: 'one queued block must consume one block of free space.',
    );

    final got = await b.host.receiveDataBlock(timeoutClocks: 200);
    expect(got.timedOut, isFalse, reason: 'the card sent no block.');
    expect(got.framingOk, isTrue, reason: 'the block is not framed.');
    expect(got.crcOk, isTrue, reason: 'the block carries a bad CRC16.');
    expect(got.bytes.length, sdBlockBytes);
    // Literals, so a packing that is wrong in both directions cannot pass.
    expect(got.bytes[0], 0x0B);
    expect(got.bytes[1], 0x0E);
    expect(got.bytes[2], 0x11);
    expect(got.bytes[3], 0x14);
    expect(got.bytes[sdBlockBytes - 1], 0x08);
    expect(got.bytes, block, reason: 'the card sent other bytes.');

    // The card is back where a read starts, and the channel is free again.
    await b.host.idle(4);
    expect(
      b.cardState,
      sdCardStateTran,
      reason: 'the card must return to tran after the block.',
    );
    expect(
      await wbRead(b, MimicReg.dataInCount),
      sdDataInFifoWords,
      reason: 'the whole block must be free again once the card sent it.',
    );
    expect(
      await wbRead(b, MimicReg.event),
      0,
      reason: 'a read that worked must raise no event.',
    );
    await Simulator.endSimulation();
  });

  test(
    'the block cannot be observed torn: the FIFO is what carries it',
    () async {
      // The negative control. The data words bypass the FIFO and cross
      // through one register instead, which is the crossing a stream must
      // not have. The card still hears that a block arrived, so it sends
      // one, and the bytes are not the bytes the runtime pushed.
      final b = await setUpSdReadBench(breakDataCrossing: true);
      await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
      await walkToTran(b);

      await b.host.idle(sdCommandGapClocks);
      await b.host.sendCommand(sdCmdReadSingleBlock, sdTestLba);
      await b.host.receiveResponse(SdResponseKind.r1);
      final record = await takeRecord(b);

      final block = sdTestBlockBytes();
      await pushBlock(b, sdBlockWordsOf(block), tag: record.seq);

      final got = await b.host.receiveDataBlock(
        timeoutClocks: 200,
        strict: false,
      );
      expect(
        got.timedOut,
        isFalse,
        reason:
            'the broken bench must still send a block, or it proves '
            'nothing about the words.',
      );
      expect(
        got.bytes,
        isNot(block),
        reason:
            'the broken crossing gave the card the right block. The FIFO is '
            'then not what carries it and this control has no teeth.',
      );
      await Simulator.endSimulation();
    },
  );
}
