// Short CMD18 runs that follow each other, the way a software host reads.
//
// The host takes a fixed number of blocks, stops sampling DAT, sends CMD12
// some time later, waits out busy and starts the next CMD18 where the last
// one stopped. The runtime model pushes the first block of a record under
// its tag and every block after it as a fill, and it goes on pushing from
// its frontier, the way serve.zig does.
//
// The card runs far ahead of USB when it serves blocks from the cache, so a
// block after the last one the host wants can already be on DAT when CMD12
// lands. A frame cannot be cut, so the next CMD18 then finds the read path
// busy. Every block the host receives must equal the image block of its
// address, and no CMD18 may be refused.
@Timeout(Duration(minutes: 90))
library;

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';
import 'sd_read_bench.dart';

const int _chunk = 4;
const int _run = 3;

/// SD clocks after the end bit of CMD12 within which DAT must be let go.
/// The card decodes the command first, which takes a few clocks.
const int _releaseClocks = 8;

/// True while the card drives any data line.
bool _datDriven(SdReadBench b) {
  final oe = b.bridge.output('sd_dat_oe').value;
  return !oe.isValid || oe.toInt() != 0;
}

/// The runtime of serve.zig for stream records, reduced to its rules.
class _Runtime {
  final SdReadBench b;
  int front = 0;
  int chunkEnd = 0;
  int? answer;
  int records = 0;
  int pushed = 0;

  _Runtime(this.b);

  Future<void> service() async {
    while (await wbRead(b, MimicReg.reqCount) != 0) {
      final record = await takeRecord(b);
      records++;
      final n = (record.word0 >> 16) & 0xFFFF;
      if (record.lba != front) front = record.lba;
      chunkEnd = record.lba + n;
      answer = record.seq;
    }
    while (front < chunkEnd &&
        await wbRead(b, MimicReg.dataInCount) >= sdBlockWords) {
      final tag = answer;
      if (tag != null) {
        await pushBlock(
          b,
          sdBlockWordsOf(sdTestBlockBytesFor(front)),
          tag: tag,
        );
        answer = null;
      } else {
        await pushFillNoDrain(b, sdTestBlockBytesFor(front), lba: front);
      }
      front++;
      pushed++;
    }
  }
}

void main() {
  tearDown(Simulator.reset);

  Future<void> reads(List<int> delays, {bool expectCuts = false}) async {
    final b = await setUpSdReadBench(
      readTimeoutClocks: 1 << 20,
      streamBlocks: _chunk,
      cacheLines: 16,
      capacityBlocks: sdTestLba + 4096,
    );
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);
    final runtime = _Runtime(b);

    // The SD clocks that went by, and the clock where DAT was let go.
    var clock = 0;
    int? fallAt;
    var lastDriven = false;
    b.bridge.input('sd_clk').posedge.listen((_) {
      clock++;
      final driven = _datDriven(b);
      if (lastDriven && !driven) fallAt ??= clock;
      lastDriven = driven;
    });
    var cuts = 0;
    var worstRelease = 0;

    var lba = sdTestLba;
    var refused = 0;
    for (var i = 0; i < delays.length; i++) {
      if (i % 4 == 3) lba += 97;
      // CMD18, retried the way a host retries an R1 with ERROR.
      for (var attempt = 0; ; attempt++) {
        expect(
          attempt,
          lessThan(4),
          reason:
              'CMD18 of run $i stayed refused after a delay of '
              '${i == 0 ? 0 : delays[i - 1]} clocks, card state '
              '${b.cardState}.',
        );
        await b.host.idle(sdCommandGapClocks);
        await b.host.sendCommand(sdCmdReadMultipleBlock, lba);
        final r1 = await b.host.receiveResponse(SdResponseKind.r1);
        expect(r1.timedOut, isFalse, reason: 'CMD18 gave no response.');
        if (r1.payload & (1 << 19) == 0) break;
        refused++;
        await b.host.idle(2 * sdBlockWords);
      }
      await runtime.service();
      for (var k = 0; k < _run; k++) {
        // The card needs a few clocks after an end bit to post its record.
        // The first block starts at once, so the host must not wait for it.
        if (k > 0) {
          await b.host.idle(16);
          await runtime.service();
        }
        final got = await b.host.receiveDataBlock(
          timeoutClocks: 12000,
          strict: false,
        );
        expect(got.timedOut, isFalse, reason: 'run $i block $k never came.');
        expect(
          got.crcOk,
          isTrue,
          reason:
              'run $i block $k bad CRC16 after a wait of ${got.gap} clocks.',
        );
        expect(
          got.bytes,
          sdTestBlockBytesFor(lba + k),
          reason: 'run $i block $k is not block ${lba + k} of the image.',
        );
      }
      // The host stops sampling DAT and sends CMD12 after its own delay.
      await b.host.idle(delays[i]);
      final sending = _datDriven(b);
      fallAt = null;
      await b.host.sendCommand(sdCmdStopTransmission, 0);
      final endClock = clock;
      final stop = await b.host.receiveResponse(SdResponseKind.r1);
      expect(stop.timedOut, isFalse, reason: 'CMD12 gave no response.');
      await b.host.waitBusy(timeoutClocks: 12000);
      if (sending) {
        // A card that was sending lets go of DAT right after the command.
        final fall = fallAt;
        expect(fall, isNotNull, reason: 'run $i: DAT was never released.');
        final held = fall! - endClock;
        cuts++;
        if (held > worstRelease) worstRelease = held;
        expect(
          held,
          lessThanOrEqualTo(_releaseClocks),
          reason:
              'run $i: DAT was driven $held clocks after the end bit of '
              'CMD12 with a delay of ${delays[i]} clocks.',
        );
      }
      // The runtime of this test answers nothing here. It runs only while
      // the SD clock stands still, so a block it pushed now would fill the
      // channel and nothing would take it off before the next CMD18.
      lba += _run;
    }
    expect(refused, 0, reason: 'a CMD18 met a card that was still sending.');
    expect(await wbRead(b, MimicReg.event), 0);
    if (expectCuts) {
      expect(cuts, greaterThan(0), reason: 'no run cut a block on DAT.');
    }
    // ignore: avoid_print
    print(
      'CMD12 cut $cuts blocks, DAT was released at most $worstRelease '
      'clocks after the end bit.',
    );
    await Simulator.endSimulation();
  }

  test('CMD12 before the next block starts leaves no block on DAT', () async {
    await reads([20, 60, 20, 60]);
  });

  test('CMD12 inside the next block cuts it and DAT is let go', () async {
    // The block after the last one the host took starts about 96 clocks
    // after the end bit and ends about 4211 clocks after it. The delays
    // are early in the block, in the middle and in the CRC16.
    await reads([200, 2000, 4150, 4165], expectCuts: true);
  });

  test(
    'CMD12 after several more blocks went out leaves the card idle',
    () async {
      await reads([5000, 10000, 9000, 4300]);
    },
  );
}
