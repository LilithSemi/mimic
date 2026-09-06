// The FILL path of the block cache: a block nobody asked for.
//
// The runtime chooses what occupies every line, so it must be able to put a
// block into the card that no host has read yet. A fill carries the tag
// that names NO record, [MimicDataTag.fill], and the block address travels
// beside that tag in DATA_FILL_LBA. The card writes the block into the line
// the address maps to and sends nothing at all on the SD bus.
//
// The second test is the one that proves the store is DIRECT MAPPED: two
// block addresses that share one line cannot both be held, and the second
// fill takes the line of the first.
@Timeout(Duration(minutes: 25))
library;

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_read_bench.dart';

void main() {
  tearDown(Simulator.reset);

  test('a full tag channel refuses the data half of a block', () async {
    final b = await setUpSdReadBench(forceTagFull: true);

    await wbWrite(b, MimicReg.dataTag, 1);
    await wbWrite(b, MimicReg.dataIn, sdBlockWord0);

    expect(
      await wbRead(b, MimicReg.dataInCount),
      sdDataInFifoWords,
      reason: 'data moved even though its tag could not be reserved.',
    );
    expect(
      await wbRead(b, MimicReg.event) & MimicEvent.dataInOverflow,
      MimicEvent.dataInOverflow,
      reason: 'the refused data word was not reported.',
    );
    await Simulator.endSimulation();
  });

  test('a fill nobody asked for makes the next read a hit', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    final block = sdTestBlockBytes();
    await pushFill(b, block, lba: sdTestLba);

    expect(
      await wbRead(b, MimicReg.reqCount),
      0,
      reason: 'a fill answers no request, so the card must post none.',
    );
    expect(await cacheCounters(b), (
      hit: 0,
      miss: 0,
      fill: 1,
    ), reason: 'the fill filled one line and nothing was read.');
    expect(
      await wbRead(b, MimicReg.dataInCount),
      sdDataInFifoWords,
      reason: 'the card must take the whole fill off the data channel.',
    );

    final got = await readCachedBlock(b, sdTestLba, reason: 'fill:');
    expect(got.bytes.length, sdBlockBytes);
    // Literals, so a fill path that wrote the words in the wrong order
    // cannot pass.
    expect(got.bytes[0], 0x0B);
    expect(got.bytes[1], 0x0E);
    expect(got.bytes[2], 0x11);
    expect(got.bytes[3], 0x14);
    expect(got.bytes[sdBlockBytes - 1], 0x08);
    expect(got.bytes, block, reason: 'the cache holds other bytes.');

    expect(await cacheCounters(b), (
      hit: 1,
      miss: 0,
      fill: 1,
    ), reason: 'the read hit, so the card asked the runtime for nothing.');
    await Simulator.endSimulation();
  });

  test('a block with the fill tag and no address is thrown away', () async {
    // The address is what places a fill. A block that carries the tag that
    // names no record with NO address before it cannot be placed at all,
    // and the card throws it away, which is what it has always done with
    // an untagged block. The negative control of the fill path.
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    await wbWrite(b, MimicReg.dataTag, MimicDataTag.fill);
    for (final word in sdBlockWordsOf(sdTestBlockBytes())) {
      await wbWrite(b, MimicReg.dataIn, word);
    }
    await b.host.idle(sdBlockWords + 64);

    expect(await cacheCounters(b), (
      hit: 0,
      miss: 0,
      fill: 0,
    ), reason: 'a block that names no line must fill none.');
    expect(
      await wbRead(b, MimicReg.dataInCount),
      sdDataInFifoWords,
      reason: 'the card must still take the block off the channel.',
    );

    // The read then misses, which is what proves nothing was written.
    final block = sdTestBlockBytes();
    await readMissedBlock(b, sdTestLba, block, reason: 'after bad fill:');
    await Simulator.endSimulation();
  });

  test('two blocks that map to one line: the second takes it', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    // Direct mapped, so the index is the LOW bits of the block address.
    // Two addresses that differ by the line count share one line.
    const first = sdTestLba;
    const second = sdTestLba + sdCacheDefaultLines;
    final firstBytes = sdTestBlockBytesFor(first);
    final secondBytes = sdTestBlockBytesFor(second);
    expect(
      firstBytes[0],
      isNot(secondBytes[0]),
      reason: 'the two blocks must differ, or this test proves nothing.',
    );

    await pushFill(b, firstBytes, lba: first);
    final firstHit = await readCachedBlock(b, first, reason: 'first fill:');
    expect(firstHit.bytes, firstBytes);

    // The second fill lands in the SAME line, so the first block is gone.
    await pushFill(b, secondBytes, lba: second);
    expect(await cacheCounters(b), (
      hit: 1,
      miss: 0,
      fill: 2,
    ), reason: 'two fills and one hit.');

    final secondHit = await readCachedBlock(b, second, reason: 'second fill:');
    expect(
      secondHit.bytes,
      secondBytes,
      reason: 'the line does not hold the block the second fill wrote.',
    );

    // The first block MISSES now. A store that answered it would be
    // holding two blocks in one line, which no direct mapped store can.
    final again = await readMissedBlock(
      b,
      first,
      firstBytes,
      reason: 'replaced:',
    );
    expect(
      again.bytes,
      firstBytes,
      reason: 'the runtime answered the miss with other bytes.',
    );
    expect(
      await cacheCounters(b),
      (hit: 2, miss: 1, fill: 3),
      reason:
          'the read of the replaced block missed, and the answer to it '
          'filled the line again.',
    );
    await Simulator.endSimulation();
  });

  test(
    'a fill that does not fit cannot separate its tag from its data',
    () async {
      final b = await setUpSdReadBench();
      await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
      await walkToTran(b);

      // Fill the crossing while the SD clock stands still. Each address uses
      // another cache line, so a later lookup can identify exactly which tag
      // was paired with each payload.
      for (var i = 0; i < sdDataInFifoBlocks; i++) {
        final lba = sdTestLba + i;
        await wbWrite(b, MimicReg.dataFillLba, lba);
        await wbWrite(b, MimicReg.dataTag, MimicDataTag.fill);
        for (final word in sdBlockWordsOf(sdTestBlockBytesFor(lba))) {
          await wbWrite(b, MimicReg.dataIn, word);
        }
      }
      expect(await wbRead(b, MimicReg.dataInCount), 0);

      // Let the card take only part of the first block. There is now room for
      // some words but not a whole block. A tag accepted here must not get in
      // front of a payload that the data FIFO cannot accept.
      var partialRoom = 0;
      for (var i = 0; i < sdBlockWords; i++) {
        await b.host.idle(1);
        partialRoom = await wbRead(b, MimicReg.dataInCount);
        if (partialRoom > 0) break;
      }
      expect(partialRoom, inInclusiveRange(1, sdBlockWords - 1));

      final refusedLba = sdTestLba + sdDataInFifoBlocks + 1;
      await wbWrite(b, MimicReg.dataFillLba, refusedLba);
      await wbWrite(b, MimicReg.dataTag, MimicDataTag.fill);
      for (final word in sdBlockWordsOf(sdTestBlockBytesFor(refusedLba))) {
        await wbWrite(b, MimicReg.dataIn, word);
      }

      // Drain every complete block, then offer one block when it really fits.
      // In the broken design this payload completes the refused partial block,
      // and its bytes are committed under the refused tag.
      await b.host.idle(sdDataInFifoWords + 128);
      expect(
        await wbRead(b, MimicReg.dataInCount),
        sdDataInFifoWords,
        reason: 'the refused fill must leave no orphan data word.',
      );

      final acceptedLba = refusedLba + 1;
      final acceptedBytes = sdTestBlockBytesFor(acceptedLba);
      await pushFill(b, acceptedBytes, lba: acceptedLba);

      final accepted = await readCachedBlock(
        b,
        acceptedLba,
        reason: 'fill after refused partial:',
      );
      expect(
        accepted.bytes,
        acceptedBytes,
        reason: 'the accepted fill was paired with another fill tag.',
      );

      final refusedBytes = sdTestBlockBytesFor(refusedLba);
      final refused = await readMissedBlock(
        b,
        refusedLba,
        refusedBytes,
        reason: 'refused partial:',
      );
      expect(
        refused.bytes,
        refusedBytes,
        reason: 'a fill that did not fit must not become a cache hit.',
      );
      await Simulator.endSimulation();
    },
  );
}
