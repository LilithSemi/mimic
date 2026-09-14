// The block cache: a read the host has seen before costs no round trip.
//
// The card holds whole blocks tagged by block address. The FIRST read of a
// block misses, posts one record and is answered by the runtime. Every read
// of that block after it is answered by the card alone, with NO record at
// all, and that is the whole point of the cache.
//
// The bytes are checked against LITERALS. A test that recomputed the block
// the way the design packs it would pass on a packing that is wrong in both
// directions.
@Timeout(Duration(minutes: 25))
library;

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_read_bench.dart';

void main() {
  tearDown(Simulator.reset);

  test('a miss posts a record and the same block again is a hit', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    expect(
      await wbRead(b, MimicReg.cacheLines),
      sdCacheDefaultLines,
      reason: 'CACHE_LINES must publish the line count of the build.',
    );
    expect(await cacheCounters(b), (
      hit: 0,
      miss: 0,
      fill: 0,
    ), reason: 'a card that has served nothing must count nothing.');

    // The first read. The cache holds nothing, so the card asks the
    // runtime and the runtime answers.
    final block = sdTestBlockBytes();
    final first = await readMissedBlock(b, sdTestLba, block, reason: 'miss:');
    expect(first.bytes.length, sdBlockBytes);
    // Literals, so a packing that is wrong in both directions cannot pass.
    expect(first.bytes[0], 0x0B);
    expect(first.bytes[1], 0x0E);
    expect(first.bytes[2], 0x11);
    expect(first.bytes[3], 0x14);
    expect(first.bytes[sdBlockBytes - 1], 0x08);
    expect(first.bytes, block, reason: 'the card sent other bytes.');

    expect(
      await cacheCounters(b),
      (hit: 0, miss: 1, fill: 1),
      reason:
          'one read that the cache did not hold is one miss, and the block '
          'that answered it is one line filled.',
    );

    // The second read of the SAME block. The card answers it by itself.
    final second = await readCachedBlock(b, sdTestLba, reason: 'hit:');
    expect(
      await wbRead(b, MimicReg.reqCount),
      0,
      reason: 'a hit must leave the request channel empty.',
    );
    // The same literals as the first read. A cache that gave the right
    // length and the wrong bytes would pass a comparison against the miss
    // alone.
    expect(second.bytes[0], 0x0B);
    expect(second.bytes[1], 0x0E);
    expect(second.bytes[2], 0x11);
    expect(second.bytes[3], 0x14);
    expect(second.bytes[sdBlockBytes - 1], 0x08);
    expect(
      second.bytes,
      first.bytes,
      reason: 'the cache gave other bytes than the runtime did.',
    );

    expect(await cacheCounters(b), (
      hit: 1,
      miss: 1,
      fill: 1,
    ), reason: 'the second read hit and filled nothing.');

    // A THIRD read, so that a cache which serves one hit and then loses
    // the line cannot pass.
    final third = await readCachedBlock(b, sdTestLba, reason: 'hit 2:');
    expect(third.bytes, block);
    expect(await cacheCounters(b), (
      hit: 2,
      miss: 1,
      fill: 1,
    ), reason: 'the third read hit as well.');

    expect(
      b.cardState,
      sdCardStateTran,
      reason: 'the card must return to tran after a hit.',
    );
    expect(
      await wbRead(b, MimicReg.event),
      0,
      reason: 'a read the cache served must raise no event.',
    );
    await Simulator.endSimulation();
  });

  test('no read of the register map has a side effect on the cache', () async {
    // The ruling of this design is that a read of ANY address, at any
    // time, in any order, changes nothing. The cache adds four read-only
    // registers and one write-only one, and a bulk read that walked over
    // them must leave a staged fill address and a filled line alone.
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    final block = sdTestBlockBytes();
    await readMissedBlock(b, sdTestLba, block, reason: 'first:');

    // The whole map, which is what `mimic-cli info` reads.
    for (var addr = MimicReg.id; addr <= MimicReg.reqSnapshotHi; addr += 4) {
      await wbRead(b, addr);
    }
    expect(await cacheCounters(b), (
      hit: 0,
      miss: 1,
      fill: 1,
    ), reason: 'a walk of the map moved a counter, so a read has an effect.');

    final got = await readCachedBlock(b, sdTestLba, reason: 'after walk:');
    expect(
      got.bytes,
      block,
      reason: 'a walk of the map threw the line away, or changed it.',
    );
    await Simulator.endSimulation();
  });
}
