// CMD18 and the block cache.
//
// A stream asks the cache for each block. A hit sends the block from the
// cache and posts no record. The first miss posts a chunk record that
// starts at that block. The runtime answers such a record with the block
// that the card waits for under the tag of the record and with every block
// after it as a FILL, so a block that the host does not read goes into the
// cache, and the next CMD18 that starts where the last one stopped hits it.
//
// The last two tests are about WRITES. A fill that waits on the channel
// when the host writes its block holds the old bytes. The card takes it into
// the cache after it invalidated the line, so the write protocol of the
// runtime pushes the new bytes behind it and waits for the channel to
// empty before the acknowledgement.
@Timeout(Duration(minutes: 40))
library;

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';
import 'sd_read_bench.dart';

/// SD clocks that one block of a stream needs to start after the end bit
/// of the block before it: the gap, a block taken off the channel and the
/// lookup.
const int _blockStartClocks = sdBlockWords + 400;

/// The blocks that a record of these tests asks for.
const int _chunk = 6;

Future<SdReadBench> _bench() async {
  final b = await setUpSdReadBench(streamBlocks: _chunk);
  await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
  await walkToTran(b);
  return b;
}

Future<void> _startStream(SdReadBench b, int lba) async {
  await b.host.idle(sdCommandGapClocks);
  await b.host.sendCommand(sdCmdReadMultipleBlock, lba);
  final r1 = await b.host.receiveResponse(SdResponseKind.r1);
  expect(r1.timedOut, isFalse, reason: 'CMD18 gave no response.');
  expect(r1.payload & (1 << 19), 0, reason: 'CMD18 answered with ERROR.');
}

Future<void> _expectBlock(SdReadBench b, int lba, {int? timeout}) async {
  final got = await b.host.receiveDataBlock(
    timeoutClocks: timeout ?? _blockStartClocks,
  );
  expect(got.timedOut, isFalse, reason: 'block $lba never came.');
  expect(got.crcOk, isTrue, reason: 'block $lba carries a bad CRC16.');
  expect(
    got.bytes,
    sdTestBlockBytesFor(lba),
    reason: 'the card sent other bytes than block $lba.',
  );
  await b.host.idle(8);
}

Future<void> _stopStream(SdReadBench b) async {
  await b.host.idle(sdCommandGapClocks);
  await b.host.sendCommand(sdCmdStopTransmission, 0);
  final stop = await b.host.receiveResponse(SdResponseKind.r1);
  expect(stop.timedOut, isFalse, reason: 'CMD12 gave no response.');
  expect(stop.payload & (1 << 19), 0, reason: 'CMD12 answered with ERROR.');
  await b.host.idle(16);
  expect(b.cardState, sdCardStateTran, reason: 'CMD12 must end the stream.');
}

/// Pushes the block that the card waits for under [tag], the way the
/// runtime does.
Future<void> _pushAnswer(SdReadBench b, int lba, int tag) =>
    pushBlock(b, sdBlockWordsOf(sdTestBlockBytesFor(lba)), tag: tag);

/// Pushes block [lba] as a fill.
Future<void> _pushFill(SdReadBench b, int lba) =>
    pushFillNoDrain(b, sdTestBlockBytesFor(lba), lba: lba);

void main() {
  tearDown(Simulator.reset);

  test('a CMD18 hits from its first block and posts no record', () async {
    final b = await _bench();
    const lba = sdTestLba;

    await pushFill(b, sdTestBlockBytesFor(lba), lba: lba);
    await pushFill(b, sdTestBlockBytesFor(lba + 1), lba: lba + 1);

    await _startStream(b, lba);
    expect(
      await wbRead(b, MimicReg.reqCount),
      0,
      reason: 'the cache holds the first block, so CMD18 must post nothing.',
    );
    await _expectBlock(b, lba);
    expect(
      await wbRead(b, MimicReg.reqCount),
      0,
      reason: 'the cache holds the second block, so the stream posts nothing.',
    );
    await _expectBlock(b, lba + 1);

    // The block after the two is not in the cache. The card looks it up at
    // the end bit of the block before it and posts the record at once, so
    // the round trip runs while the host sends CMD12 and its next CMD18.
    await b.host.idle(32);
    expect(await wbRead(b, MimicReg.reqCount), 1);
    final record = await takeRecord(b);
    expect(record.lba, lba + 2, reason: 'the record names another block.');
    expect(sdRecordOp(record.word0), sdRequestOpReadBlocks);
    expect(
      (record.word0 >> 16) & 0xFFFF,
      _chunk,
      reason: 'a miss of a stream asks for a whole chunk.',
    );

    await _stopStream(b);
    expect(await cacheCounters(b), (hit: 2, miss: 1, fill: 2));
    expect(
      await wbRead(b, MimicReg.event),
      0,
      reason: 'a stream that the host stopped must raise no event.',
    );
    await Simulator.endSimulation();
  });

  test('a stream that hits and then misses is answered at the miss', () async {
    final b = await _bench();
    const lba = sdTestLba + 8;

    await pushFill(b, sdTestBlockBytesFor(lba), lba: lba);
    await pushFill(b, sdTestBlockBytesFor(lba + 1), lba: lba + 1);

    await _startStream(b, lba);
    await _expectBlock(b, lba);
    await _expectBlock(b, lba + 1);

    // The runtime takes the record for the first block the cache lacks. The
    // block that the card waits for carries the tag of the record, and the
    // block after it is a fill with its own address.
    await b.host.idle(32);
    final record = await takeRecord(b);
    expect(record.lba, lba + 2);
    await _pushAnswer(b, lba + 2, record.seq);
    await _pushFill(b, lba + 3);

    await _expectBlock(b, lba + 2);
    await _expectBlock(b, lba + 3);
    expect(
      await wbRead(b, MimicReg.reqCount),
      0,
      reason: 'the chunk still owes blocks, so the card must not ask again.',
    );

    await _stopStream(b);
    expect(await cacheCounters(b), (hit: 2, miss: 1, fill: 2));
    expect(await wbRead(b, MimicReg.event), 0);
    await Simulator.endSimulation();
  });

  test('back to back streams push as many blocks as the host reads', () async {
    final b = await _bench();
    const lba = sdTestLba + 16;
    var pushed = 0;
    var consumed = 0;

    // The first stream misses, so the card asks for a chunk. The runtime
    // sends block 0 under the tag and the others as fills, and it sends them
    // as the channel makes room.
    await _startStream(b, lba);
    expect(await wbRead(b, MimicReg.reqCount), 1);
    final record = await takeRecord(b);
    expect(record.lba, lba);
    expect((record.word0 >> 16) & 0xFFFF, _chunk);

    Future<void> feed() async {
      while (pushed < _chunk &&
          await wbRead(b, MimicReg.dataInCount) >= sdBlockWords) {
        if (pushed == 0) {
          await _pushAnswer(b, lba, record.seq);
        } else {
          await _pushFill(b, lba + pushed);
        }
        pushed++;
      }
    }

    await feed();
    for (var i = 0; i < 3; i++) {
      await _expectBlock(b, lba + i);
      consumed++;
      await feed();
    }

    // The host stops after three blocks. The three blocks that it did not
    // read are fills, so the card keeps them as the runtime pushes the
    // rest and the clock runs.
    await _stopStream(b);
    while (pushed < _chunk) {
      await feed();
      await b.host.idle(sdBlockWords + 64);
    }
    await b.host.idle(4 * sdBlockWords);
    expect(
      await wbRead(b, MimicReg.dataInCount),
      sdDataInFifoWords,
      reason: 'the card must have taken every fill off the channel.',
    );
    expect(await wbRead(b, MimicReg.reqCount), 0);

    // The second stream starts where the first one stopped. Every block of
    // it is in the cache, so the card posts nothing until the chunk ends.
    await _startStream(b, lba + 3);
    expect(await wbRead(b, MimicReg.reqCount), 0);
    for (var i = 3; i < _chunk; i++) {
      await _expectBlock(b, lba + i);
      consumed++;
      if (i < _chunk - 1) {
        expect(await wbRead(b, MimicReg.reqCount), 0);
      }
    }

    // The card asks for the chunk after this one at the end of the last
    // block, while the host still has to send CMD12.
    await b.host.idle(32);
    expect(await wbRead(b, MimicReg.reqCount), 1);
    final next = await takeRecord(b);
    expect(next.lba, lba + _chunk);
    await _stopStream(b);

    expect(pushed, consumed, reason: 'the runtime sent a block nobody read.');
    expect(await cacheCounters(b), (hit: 3, miss: 2, fill: 3));
    expect(await wbRead(b, MimicReg.event), 0);
    await Simulator.endSimulation();
  });

  group('a write that races with a fill', () {
    const lba = sdTestLba + 32;

    // The host writes [fresh] to [lba] while a fill of [stale] waits on the
    // channel. [protect] says whether the runtime follows the protocol of
    // `Server.fenceWrite`: push the new bytes as a fill, wait until the
    // channel is empty, and only then acknowledge the write.
    Future<SdDataBlock> race(SdReadBench b, {required bool protect}) async {
      final stale = sdTestBlockBytesFor(lba);
      final fresh = [for (final byte in stale) byte ^ 0xFF];

      // The fill is on the channel and the card has taken no clock, so it is
      // in flight when the write arrives.
      await pushFillNoDrain(b, stale, lba: lba);

      await b.host.idle(sdCommandGapClocks);
      await b.host.sendCommand(sdCmdWriteBlock, lba);
      final r1 = await b.host.receiveResponse(SdResponseKind.r1);
      expect(r1.timedOut, isFalse, reason: 'CMD24 gave no response.');
      expect(r1.payload & (1 << 19), 0, reason: 'the card refused the write.');
      await b.host.idle(4);
      await b.host.sendDataBlock(fresh);
      final token = await b.host.receiveStatusToken();
      expect(token.token, SdStatusToken.accepted);

      final record = await takeRecord(b);
      expect(sdRecordOp(record.word0), sdRequestOpWriteBlocks);
      expect(record.lba, lba);
      final words = await pullWriteWords(b, sdBlockWords);
      expect(sdBytesOfWords(words), fresh);

      if (protect) {
        await pushFillNoDrain(b, fresh, lba: lba);
        var polls = 0;
        while (await wbRead(b, MimicReg.dataInCount) < sdDataInFifoWords) {
          expect(++polls, lessThan(16), reason: 'the channel never emptied.');
          await b.host.idle(sdBlockWords + 64);
        }
      }
      await ackWrite(b, record.seq);
      final busy = await b.host.waitBusy(timeoutClocks: 256);
      expect(busy.timedOut, isFalse, reason: 'the card never released busy.');
      await b.host.idle(8);

      return readCachedBlock(b, lba, reason: 'after the write:');
    }

    test('the fence leaves the new bytes in the cache', () async {
      final b = await _bench();
      final got = await race(b, protect: true);
      final stale = sdTestBlockBytesFor(lba);
      expect(got.bytes, [
        for (final byte in stale) byte ^ 0xFF,
      ], reason: 'the cache served the bytes from before the write.');
      expect(got.bytes, isNot(stale));
      expect(await wbRead(b, MimicReg.event), 0);
      await Simulator.endSimulation();
    });

    test('without the fence the old bytes survive the write', () async {
      // The negative control. It shows that the race is real: a runtime that
      // acknowledges the write and pushes nothing leaves the old bytes in
      // the cache, with a good CRC16 on them.
      final b = await _bench();
      final got = await race(b, protect: false);
      expect(
        got.bytes,
        sdTestBlockBytesFor(lba),
        reason:
            'the card no longer takes the old fill after the write, so the '
            'fence of the runtime is not needed and can go.',
      );
      await Simulator.endSimulation();
    });
  });
}
