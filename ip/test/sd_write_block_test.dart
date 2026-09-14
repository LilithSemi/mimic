// The block half of the block WRITE path.
//
// The host sends CMD24 and 512 bytes on DAT0. The card checks the CRC16,
// sends the CRC status token, holds DAT0 LOW for busy and releases the
// host only after the runtime has taken the block.
//
// One block is 4114 SD clocks, so these tests are the slow ones.
//
// The CRC16 is computed by the host model in software. The card never
// tells the host what it thinks the CRC is.
@Timeout(Duration(minutes: 10))
library;

import 'dart:async';

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';
import 'sd_read_bench.dart';

/// The ERROR bit of a card status, bit 19.
const int _statusErrorBit = 1 << 19;

/// A sequence tag that names no record of a card that took one write.
///
/// The first write of a card carries tag 1, so this value matches nothing.
/// It is not 0 either, because 0 names no record by contract and a write of
/// it must do nothing at all.
const int _strayTag = 0xFE;

/// Counts the pushes into the acknowledge channel.
///
/// The channel gives a test nothing back, because the card pops every entry
/// on its own. This watches the push itself, which is the only place where
/// a write of WRITE_ACK that the CSR slave threw away can be told apart
/// from one that it took.
class _AckPushMonitor {
  /// The bench under test.
  final SdReadBench bench;

  /// Rising edges of `ack_push`, which is one for each entry pushed.
  int pushes = 0;

  bool _wasHigh = false;
  late final StreamSubscription<void> _sub;

  _AckPushMonitor(this.bench) {
    _sub = Simulator.postTick.listen((_) {
      final high = bench.ackPush;
      if (high && !_wasHigh) pushes++;
      _wasHigh = high;
    });
  }

  /// Stops the monitor.
  Future<void> stop() => _sub.cancel();
}

/// Leaves ONE whole block on the write channel with the card at rest.
///
/// A block whose CRC16 failed does exactly that: the card sends the 101
/// token, holds the host on nothing, and posts a DISCARD record. The 128
/// words of the block stay on the channel until the runtime takes them.
/// This is the one state where the card is free and a block is still
/// waiting, so every test of the channel guard starts here.
///
/// It gives back the record that the card posted.
Future<({int word0, int lba, int seq, int epoch})> leaveBlockOnChannel(
  SdReadBench b,
) async {
  final first = await sendWriteCommand(b, sdTestLba);
  expect(first.timedOut, isFalse, reason: 'CMD24 gave no response.');
  expect(
    first.payload & _statusErrorBit,
    0,
    reason: 'the first write of a clear card must be taken.',
  );

  await b.host.idle(4);
  await b.host.sendDataBlock(writeTestBlock(), crcOverride: 0xBEEF);
  final token = await b.host.receiveStatusToken();
  expect(
    token.token,
    SdStatusToken.crcError,
    reason: 'a bad CRC16 must give the 101 token.',
  );

  final record = await takeRecord(b);
  expect(sdRecordOp(record.word0), sdRequestOpWriteDiscard);
  expect(
    await wbRead(b, MimicReg.dataOutCount),
    sdBlockWords,
    reason: 'the whole block must still be on the channel.',
  );
  return record;
}

/// The bytes of a block that no other test block matches.
///
/// The first four bytes and the last one are LITERAL in the tests below, so
/// a packing that is wrong in both directions cannot pass.
List<int> writeTestBlock() => [
  0x11,
  0x22,
  0x33,
  0x44,
  for (var i = 4; i < sdBlockBytes - 1; i++) (i * 7 + 3) & 0xFF,
  0x9C,
];

/// Sends CMD24 for [lba] and then the block, and gives the R1 back.
Future<SdResponse> sendWriteCommand(SdReadBench b, int lba) async {
  await b.host.idle(sdCommandGapClocks);
  await b.host.sendCommand(sdCmdWriteBlock, lba);
  return b.host.receiveResponse(SdResponseKind.r1);
}

void main() {
  tearDown(Simulator.reset);

  test(
    'the card takes the block, accepts it and holds the host on busy',
    () async {
      final b = await setUpSdReadBench();
      await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
      await walkToTran(b);

      final r1 = await sendWriteCommand(b, sdTestLba);
      expect(r1.timedOut, isFalse, reason: 'CMD24 gave no response.');
      expect(
        r1.payload & (1 << 19),
        0,
        reason: 'a CMD24 the card takes must not set the ERROR bit.',
      );

      final block = writeTestBlock();
      await b.host.idle(4);
      await b.host.sendDataBlock(block);

      final token = await b.host.receiveStatusToken();
      expect(token.timedOut, isFalse, reason: 'the card sent no status token.');
      expect(token.framingOk, isTrue);
      expect(
        token.token,
        SdStatusToken.accepted,
        reason: 'a good CRC16 must give the 010 token.',
      );
      expect(token.code, 0x2, reason: 'the accepted code is 010.');

      // The card is on busy now. DAT0 must stay LOW while the runtime works.
      await b.host.park(8);
      expect(
        b.host.datLine[0],
        LogicValue.zero,
        reason: 'the card must hold DAT0 low for busy after the token.',
      );
      expect(
        b.cardState,
        sdCardStatePrg,
        reason: 'the card must be in prg while it holds the host on busy.',
      );

      // The runtime takes the record and the block.
      final record = await takeRecord(b);
      expect(record.lba, sdTestLba);
      expect(record.seq, 1, reason: 'the first write of a card carries tag 1.');
      expect(
        sdRecordOp(record.word0),
        sdRequestOpWriteBlocks,
        reason: 'a good block must post a write_blocks record.',
      );
      expect(
        await wbRead(b, MimicReg.dataOutCount),
        sdBlockWords,
        reason: 'a whole block must be waiting on the write channel.',
      );

      // The read of DATA_OUT has NO side effect: two reads in a row give the
      // same word, and only the write of DATA_OUT_POP takes it away.
      final first = await wbRead(b, MimicReg.dataOut);
      expect(
        await wbRead(b, MimicReg.dataOut),
        first,
        reason: 'a read of DATA_OUT must not pop.',
      );
      expect(
        await wbRead(b, MimicReg.dataOutCount),
        sdBlockWords,
        reason: 'two reads of DATA_OUT must take no word off the channel.',
      );

      final words = await pullWriteWords(b, sdBlockWords);
      expect(words.first, first);
      // Literals, so a packing that is wrong in both directions cannot pass.
      expect(words.first, 0x44332211, reason: 'the packing is little endian.');
      final bytes = sdBytesOfWords(words);
      expect(bytes.length, sdBlockBytes);
      expect(bytes[0], 0x11);
      expect(bytes[1], 0x22);
      expect(bytes[2], 0x33);
      expect(bytes[3], 0x44);
      expect(bytes[sdBlockBytes - 1], 0x9C);
      expect(bytes, block, reason: 'the runtime got other bytes.');
      expect(
        await wbRead(b, MimicReg.dataOutCount),
        0,
        reason: 'the channel must be empty once the block is taken.',
      );

      // The block is out, and the card is STILL on busy. Nothing but the
      // acknowledgement releases the host.
      await b.host.park(8);
      expect(
        b.host.datLine[0],
        LogicValue.zero,
        reason: 'taking the block off the channel must not release busy.',
      );

      await ackWrite(b, record.seq);
      final busy = await b.host.waitBusy(timeoutClocks: 64);
      expect(busy.timedOut, isFalse, reason: 'the card never released busy.');

      await b.host.idle(4);
      expect(
        b.cardState,
        sdCardStateTran,
        reason: 'the card must return to tran after a write.',
      );
      expect(
        await wbRead(b, MimicReg.event),
        0,
        reason: 'a write that worked must raise no event.',
      );
      await Simulator.endSimulation();
    },
  );

  test(
    'a block with a bad CRC16 gets the 101 token and is not written',
    () async {
      final b = await setUpSdReadBench();
      await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
      await walkToTran(b);

      final r1 = await sendWriteCommand(b, sdTestLba);
      expect(r1.timedOut, isFalse);

      final block = writeTestBlock();
      await b.host.idle(4);
      // The payload is whole and the CRC16 is wrong, which is what a line
      // fault looks like to a card.
      await b.host.sendDataBlock(block, crcOverride: 0xBEEF);

      final token = await b.host.receiveStatusToken();
      expect(token.timedOut, isFalse, reason: 'the card sent no status token.');
      expect(
        token.token,
        SdStatusToken.crcError,
        reason: 'a bad CRC16 must give the 101 token.',
      );
      expect(token.code, 0x5, reason: 'the CRC error code is 101.');

      // A bad block gets NO busy. A real card refuses it and programs
      // nothing, so the host is free at once.
      await b.host.park(8);
      expect(
        b.host.datLine[0],
        LogicValue.one,
        reason: 'a block the card refused must not hold the host on busy.',
      );
      expect(
        b.cardState,
        isNot(sdCardStatePrg),
        reason: 'the card programs nothing after a bad CRC16.',
      );

      final record = await takeRecord(b);
      expect(
        sdRecordOp(record.word0),
        sdRequestOpWriteDiscard,
        reason:
            'a bad block must post a DISCARD record, so the runtime drops the '
            'bytes and the channel comes back into step.',
      );
      expect(record.lba, sdTestLba);

      // The card refuses the next write while the bad block is still on the
      // channel, because the channel holds exactly one block.
      final refused = await sendWriteCommand(b, sdTestLba + 1);
      expect(refused.timedOut, isFalse, reason: 'CMD24 gave no response.');
      expect(
        refused.payload & (1 << 19),
        isNot(0),
        reason:
            'a write the card cannot take must answer R1 with the ERROR bit.',
      );

      // The runtime drops the block and acknowledges, and the card is free.
      await pullWriteWords(b, sdBlockWords);
      await ackWrite(b, record.seq);
      await b.host.idle(8);
      final again = await sendWriteCommand(b, sdTestLba + 1);
      expect(
        again.payload & (1 << 19),
        0,
        reason: 'the card must take a write once the channel is clear.',
      );
      await Simulator.endSimulation();
    },
  );

  test('CMD24 outside tran is refused and posts no record', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);

    // The card is in idle. CMD24 belongs to tran alone, so the card
    // answers nothing at all and posts nothing.
    expect(b.cardState, sdCardStateIdle);
    final answer = await sendWriteCommand(b, sdTestLba);
    expect(
      answer.timedOut,
      isTrue,
      reason: 'CMD24 out of tran must give no answer at all.',
    );
    expect(
      b.cardState,
      sdCardStateIdle,
      reason: 'a refused CMD24 must not move the card.',
    );
    expect(
      await wbRead(b, MimicReg.reqCount),
      0,
      reason: 'a CMD24 out of tran must post no record.',
    );

    // The card must also take no block. The host sends one and the card
    // ignores it, so nothing reaches the write channel.
    await b.host.idle(4);
    await b.host.sendDataBlock(writeTestBlock());
    await b.host.idle(8);
    expect(
      await wbRead(b, MimicReg.reqCount),
      0,
      reason: 'a card that took no write must post no record.',
    );
    expect(
      await wbRead(b, MimicReg.dataOutCount),
      0,
      reason: 'a card that took no write must push no word.',
    );
    await Simulator.endSimulation();
  });

  test(
    'the block cannot be observed torn: the FIFO is what carries it',
    () async {
      // The negative control. The words the card pushes bypass the FIFO
      // and cross through one register instead, which is the crossing a
      // stream must not have. The card still posts the record, so the
      // runtime still reads 128 words, and they are not the bytes the host
      // sent.
      final b = await setUpSdReadBench(breakWriteCrossing: true);
      await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
      await walkToTran(b);

      final r1 = await sendWriteCommand(b, sdTestLba);
      expect(r1.timedOut, isFalse);

      final block = writeTestBlock();
      await b.host.idle(4);
      await b.host.sendDataBlock(block);
      final token = await b.host.receiveStatusToken();
      expect(
        token.token,
        SdStatusToken.accepted,
        reason:
            'the broken bench must still take the block, or it proves '
            'nothing about the words.',
      );

      final record = await takeRecord(b);
      final words = await pullWriteWords(b, sdBlockWords);

      // The block itself must be able to show a fault of ORDER, else
      // nothing below proves anything. It holds many different words, and
      // it is not the same read backwards, so a crossing that kept every
      // word and lost the order of them would fail the check in the test
      // above.
      final pushed = sdBlockWordsOf(block);
      expect(
        pushed.toSet().length,
        greaterThan(1),
        reason:
            'a block of one repeated word cannot tell a stream from a '
            'single register.',
      );
      expect(
        pushed.reversed.toList(),
        isNot(pushed),
        reason: 'the test block is not the same read backwards.',
      );

      // What the broken crossing gave back. It is ONE word, repeated: the
      // register holds the last value the card put on `out_word` and the
      // SD clock stands still while the runtime reads, so every read gives
      // the same word. A FIFO cannot do that with a block of 128 different
      // words, so this is the shape of a crossing that carries no stream
      // and therefore no order at all.
      expect(
        words.toSet(),
        hasLength(1),
        reason:
            'the broken crossing gave more than one word, so it carried '
            'something of the stream after all and this control is not the '
            'control it says it is.',
      );
      expect(
        words.toSet().single,
        isNot(pushed.first),
        reason:
            'the one word the broken crossing gave is word 0 of the block, '
            'so a runtime that read one word would still be right.',
      );
      expect(
        sdBytesOfWords(words),
        isNot(block),
        reason:
            'the broken crossing gave the runtime the right block. The FIFO '
            'is then not what carries it and this control has no teeth.',
      );
      await ackWrite(b, record.seq);
      await Simulator.endSimulation();
    },
  );

  // The two regression tests below are the write channel guard. Both of
  // them opened the card to a second write while the first block was still
  // on the channel, and the 128 pushes of that second block went into a
  // FULL channel, which drops them. The runtime then read the FIRST block
  // and wrote it at the address of the SECOND.

  test(
    'a stray acknowledgement leaves the card shut while a block waits',
    () async {
      final b = await setUpSdReadBench();
      await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
      await walkToTran(b);

      final record = await leaveBlockOnChannel(b);

      // A write of WRITE_ACK that names NO record of this card. The
      // runtime has taken no word off the channel, so the block is still
      // there and the card must still be shut.
      await ackWrite(b, _strayTag);
      await b.host.idle(8);
      expect(
        await wbRead(b, MimicReg.dataOutCount),
        sdBlockWords,
        reason: 'a write of WRITE_ACK must take no word off the channel.',
      );

      final refused = await sendWriteCommand(b, sdTestLba + 1);
      expect(refused.timedOut, isFalse, reason: 'CMD24 gave no response.');
      expect(
        refused.payload & _statusErrorBit,
        isNot(0),
        reason:
            'the card took a second write while the first block was still '
            'on the channel. The pushes of the second block go into a full '
            'channel, which drops them, and the runtime then writes the '
            'FIRST block at the address of the SECOND.',
      );

      // The channel still holds the FIRST block, whole and in order.
      final words = await pullWriteWords(b, sdBlockWords);
      expect(
        sdBytesOfWords(words),
        writeTestBlock(),
        reason: 'the block on the channel is the block the host sent.',
      );

      // The card comes back as soon as the runtime really takes the block.
      await ackWrite(b, record.seq);
      await b.host.idle(8);
      final again = await sendWriteCommand(b, sdTestLba + 1);
      expect(
        again.payload & _statusErrorBit,
        0,
        reason: 'the card must take a write once the channel is clear.',
      );
      await Simulator.endSimulation();
    },
  );

  test(
    'a WRITE_ACK of zero leaves the card shut while a block waits',
    () async {
      // Tag 0 names no record: the sequence counter steps over it. REQ_POP
      // and DATA_OUT_POP both make a write of 0 a no-op, and WRITE_ACK
      // must do the same, else a reader that clears the register retires a
      // block that nobody took.
      final b = await setUpSdReadBench();
      await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
      await walkToTran(b);

      final record = await leaveBlockOnChannel(b);

      await wbWrite(b, MimicReg.writeAck, 0);
      await b.host.idle(8);

      final refused = await sendWriteCommand(b, sdTestLba + 1);
      expect(refused.timedOut, isFalse, reason: 'CMD24 gave no response.');
      expect(
        refused.payload & _statusErrorBit,
        isNot(0),
        reason:
            'a write of 0 to WRITE_ACK retired a block. Tag 0 names no '
            'record, so the write must do nothing at all.',
      );

      await pullWriteWords(b, sdBlockWords);
      await ackWrite(b, record.seq);
      await Simulator.endSimulation();
    },
  );

  test('WRITE_ACK pushes nothing when the tag names no record', () async {
    // The bit gate of WRITE_ACK, read at the push itself. No block moves
    // here, so this test is one of the fast ones.
    final b = await setUpSdReadBench();
    final mon = _AckPushMonitor(b);

    await wbWrite(b, MimicReg.writeAck, 0);
    expect(
      mon.pushes,
      0,
      reason: 'tag 0 names no record, so a write of it pushes nothing.',
    );

    await wbWrite(b, MimicReg.writeAck, MimicWriteAck.fail);
    expect(
      mon.pushes,
      0,
      reason: 'the fail bit with tag 0 still names no record.',
    );

    await wbWrite(b, MimicReg.writeAck, 1);
    expect(
      mon.pushes,
      1,
      reason: 'a tag that names a record must reach the channel.',
    );

    await wbWrite(b, MimicReg.writeAck, _strayTag | MimicWriteAck.fail);
    expect(
      mon.pushes,
      2,
      reason: 'a failed write with a real tag must reach the channel too.',
    );

    await mon.stop();
    await Simulator.endSimulation();
  });
}
