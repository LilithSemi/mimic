// What throws a cache line away: a write to it, a CMD0 and a reset.
//
// A cache that kept a line through a write to the same block would give a
// later read the bytes from BEFORE that write, with a good CRC16 on them,
// and no host could tell. That is the one fault a cache must never have,
// so the card invalidates the line a CMD24 names.
//
// It INVALIDATES and does not update. A write can fail: the runtime may
// refuse the block or never acknowledge it, and a line that had been
// updated would then hold bytes the image does not have. The cost of
// invalidating is one miss, which is one round trip.
@Timeout(Duration(minutes: 30))
library;

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_read_bench.dart';

/// The bytes of the block that pass [pass] writes.
///
/// The two passes share no byte at index 0, so a read that gave the block
/// of the pass before fails on the first byte.
List<int> passBlock(int pass) => [
  0xA0 + pass,
  0xB0 + pass,
  0xC0 + pass,
  0xD0 + pass,
  for (var i = 4; i < sdBlockBytes - 1; i++) (i * 11 + pass * 5) & 0xFF,
  0xE0 + pass,
];

void main() {
  tearDown(Simulator.reset);

  test('a write to a cached block leaves no stale data', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    // The block goes into the cache, and a read proves it is there.
    final before = passBlock(0);
    await pushFill(b, before, lba: sdTestLba);
    final cached = await readCachedBlock(b, sdTestLba, reason: 'before:');
    expect(cached.bytes[0], 0xA0);
    expect(cached.bytes, before);

    // The host writes OTHER bytes to that same block.
    final after = passBlock(1);
    await writeBlockThrough(b, sdTestLba, after, reason: 'write:');

    // The read of it must MISS. A card that answered from the line would
    // give the host the bytes from before the write.
    final back = await readMissedBlock(b, sdTestLba, after, reason: 'after:');
    expect(
      back.bytes[0],
      0xA1,
      reason: 'the card served the block from before the write.',
    );
    expect(back.bytes, after, reason: 'the read gave other bytes.');
    expect(
      back.bytes,
      isNot(before),
      reason: 'the read gave the bytes the write replaced.',
    );
    await Simulator.endSimulation();
  });

  test('a write to a block the cache does not hold keeps the line', () async {
    // The tag is compared, so a write to a block that maps to a line
    // holding ANOTHER block leaves that line alone. Without the compare
    // the host model of what the card holds would drift on every write.
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    const held = sdTestLba;
    const other = sdTestLba + sdCacheDefaultLines;
    final heldBytes = sdTestBlockBytesFor(held);
    await pushFill(b, heldBytes, lba: held);

    // A write to the block that shares the line of the held one.
    await writeBlockThrough(b, other, passBlock(1), reason: 'other:');

    final got = await readCachedBlock(b, held, reason: 'still held:');
    expect(
      got.bytes,
      heldBytes,
      reason: 'a write to another block threw this line away.',
    );
    await Simulator.endSimulation();
  });

  test('CMD0 and a reset each throw the whole cache away', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    final block = sdTestBlockBytes();
    await pushFill(b, block, lba: sdTestLba);
    await readCachedBlock(b, sdTestLba, reason: 'before cmd0:');

    // CMD0 returns the card to idle. A card that a new host re-identifies
    // must not answer out of the store the last host filled.
    await walkToTran(b);
    await readMissedBlock(b, sdTestLba, block, reason: 'after cmd0:');
    await readCachedBlock(b, sdTestLba, reason: 'refilled:');

    // A reset throws the store away as well, through the valid bits.
    await pulseReset(b);
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);
    await readMissedBlock(b, sdTestLba, block, reason: 'after reset:');
    expect(
      await cacheCounters(b),
      (hit: 0, miss: 1, fill: 1),
      reason:
          'the three counters take the reset ASYNCHRONOUSLY and go back to '
          '0, so what they read is the one read after the reset: one miss, '
          'the line it filled, and no hit at all.',
    );
    await Simulator.endSimulation();
  });

  test('the whole walk holds up when it runs twice', () async {
    // Identify, read a block that misses, read it again for a hit, write
    // it, and read it again for the new bytes. TWICE, because a test that
    // runs a sequence once cannot catch stale state.
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);

    var hits = 0;
    var misses = 0;
    var fills = 0;

    for (var pass = 0; pass < 2; pass++) {
      final label = 'pass $pass:';
      await walkToTran(b);

      // Identification sends CMD0, which throws the store away, so the
      // read after it misses in BOTH passes.
      final start = passBlock(pass * 2);
      final missed = await readMissedBlock(b, sdTestLba, start, reason: label);
      expect(missed.bytes[0], 0xA0 + pass * 2, reason: '$label wrong block.');
      expect(missed.bytes, start);
      misses += 1;
      fills += 1;
      expect(await cacheCounters(b), (hit: hits, miss: misses, fill: fills));

      final hit = await readCachedBlock(b, sdTestLba, reason: '$label hit:');
      expect(hit.bytes, start, reason: '$label the cache gave other bytes.');
      hits += 1;
      expect(await cacheCounters(b), (hit: hits, miss: misses, fill: fills));

      // The write throws the line away, so the read after it misses and
      // gives the NEW bytes.
      final written = passBlock(pass * 2 + 1);
      await writeBlockThrough(b, sdTestLba, written, reason: '$label write:');

      final back = await readMissedBlock(
        b,
        sdTestLba,
        written,
        reason: '$label after write:',
      );
      expect(
        back.bytes[0],
        0xA0 + pass * 2 + 1,
        reason: '$label the card served the block from before the write.',
      );
      expect(back.bytes, written);
      misses += 1;
      fills += 1;
      expect(await cacheCounters(b), (hit: hits, miss: misses, fill: fills));

      expect(b.cardState, sdCardStateTran, reason: '$label the card moved.');
      expect(
        await wbRead(b, MimicReg.event),
        0,
        reason: '$label a walk that worked must raise no event.',
      );
    }
    await Simulator.endSimulation();
  });
}
