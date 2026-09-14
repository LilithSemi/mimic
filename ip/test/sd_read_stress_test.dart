// A LONG CMD18 stream with read ahead running beside it.
//
// Every other read test answers one record, waits for the block and then
// answers the next. The runtime does not work that way. A CMD18 record
// asks for a whole CHUNK of blocks, and the runtime pushes block after
// block against it, so the channel holds several blocks at once while the
// card is in the middle of a stream.
//
// Hardware showed that a stream stops asking for blocks after a long run,
// and that read ahead makes it worse at every setting. A test that answers
// one record at a time cannot see either fault, because it never puts a
// fill and a demand block on the channel together.
//
// The runtime here is a task of its own on the bus clock, the way the
// real one is a process of its own. It polls REQ_COUNT, answers the
// record it finds, and appends the next blocks as fills.
@Timeout(Duration(minutes: 90))
library;

import 'dart:async';

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';
import 'sd_read_bench.dart';

/// SD clocks the card waits for the answer to one record in this test.
///
/// One block takes 4114 SD clocks on DAT, and the runtime task here runs
/// on a bus clock that is not much faster, so a record can wait several
/// block times. The value is far above that and still reachable inside
/// the simulation if the card waits for a block that never comes.
const int _stressTimeoutClocks = 200000;

/// A runtime that answers records and pushes read ahead beside them.
class _Runtime {
  final SdReadBench b;

  /// Blocks the runtime pushes after the record it answers.
  final int readAhead;

  /// Records answered.
  int records = 0;

  /// Fill blocks pushed.
  int fills = 0;

  /// Set by the test to stop the loop.
  bool stop = false;

  /// The next block the read ahead window owes.
  int aheadFrom = 0;

  /// One past the last block the read ahead window owes.
  int aheadEnd = 0;

  _Runtime(this.b, {required this.readAhead});

  /// Free words on the read data channel.
  Future<int> _free() => wbRead(b, MimicReg.dataInCount);

  Future<void> run() async {
    while (!stop) {
      final pending = await wbRead(b, MimicReg.reqCount);
      if (pending == 0) {
        // Nothing is owed. This is where the runtime spends its spare
        // transfers on the read ahead window.
        if (aheadFrom < aheadEnd && await _free() >= sdBlockWords) {
          await pushFillNoDrain(
            b,
            sdTestBlockBytesFor(aheadFrom),
            lba: aheadFrom,
          );
          aheadFrom++;
          fills++;
        } else {
          await wbRead(b, MimicReg.status);
        }
        continue;
      }

      final record = await takeRecord(b);
      records++;
      final blocks = (record.word0 >> 16) & 0xFFFF;
      // A record must be answered, so it waits for room. The wait ends
      // when the test stops the loop, so a card that consumes nothing
      // cannot hold this task for ever.
      //
      // A record that asks for a CHUNK is answered block after block
      // against the ONE tag of that record. The loop stops early when a
      // new record lands, because the card posts one only when it is no
      // longer serving this chunk, which means the host stopped it.
      var served = 0;
      while (!stop && served < blocks) {
        if (await _free() < sdBlockWords) {
          await wbRead(b, MimicReg.status);
          continue;
        }
        await pushBlock(
          b,
          sdBlockWordsOf(sdTestBlockBytesFor(record.lba + served)),
          tag: record.seq,
        );
        served++;
        if (blocks > 1 && await wbRead(b, MimicReg.reqCount) != 0) break;
      }
      if (stop) return;

      // A chunk IS the read ahead, so no fill goes behind one. The window
      // below belongs to the single block path.
      if (blocks > 1) continue;

      // The window opens on the block after the record and runs for
      // [readAhead] blocks. A later record that lands inside the window
      // moves the window on, the way the runtime moves `ahead_from`.
      final from = record.lba + 1;
      if (from > aheadFrom) aheadFrom = from;
      aheadEnd = from + readAhead;
      if (await wbRead(b, MimicReg.reqCount) != 0) continue;
      while (aheadFrom < aheadEnd) {
        if (await _free() < sdBlockWords) break;
        await pushFillNoDrain(
          b,
          sdTestBlockBytesFor(aheadFrom),
          lba: aheadFrom,
        );
        aheadFrom++;
        fills++;
      }
    }
  }
}

/// Reads [count] blocks with CMD18 while the runtime task answers the
/// records beside it.
Future<void> _streamBlocks(
  SdReadBench b, {
  required int lba,
  required int count,
}) async {
  await b.host.idle(sdCommandGapClocks);
  await b.host.sendCommand(sdCmdReadMultipleBlock, lba);
  final answer = await b.host.receiveResponse(SdResponseKind.r1);
  expect(answer.timedOut, isFalse, reason: 'CMD18 gave no response.');
  expect(
    answer.payload & (1 << 19),
    0,
    reason: 'CMD18 answered R1 with ERROR, so no block follows.',
  );

  for (var i = 0; i < count; i++) {
    final want = sdTestBlockBytesFor(lba + i);
    final got = await b.host.receiveDataBlock(timeoutClocks: 40000);
    expect(
      got.timedOut,
      isFalse,
      reason: 'block $i of the stream, LBA ${lba + i}, never came.',
    );
    expect(got.framingOk, isTrue, reason: 'block $i is not framed.');
    expect(got.crcOk, isTrue, reason: 'block $i carries a bad CRC16.');
    expect(
      got.bytes,
      want,
      reason: 'block $i is not block ${lba + i} of the image.',
    );
    await b.host.idle(8);
    expect(
      b.cardState,
      sdCardStateData,
      reason: 'the card left the data state at block $i of the stream.',
    );
  }

  await b.host.idle(sdCommandGapClocks);
  await b.host.sendCommand(sdCmdStopTransmission, 0);
  final stop = await b.host.receiveResponse(SdResponseKind.r1);
  expect(stop.timedOut, isFalse, reason: 'CMD12 gave no response.');
  await b.host.idle(16);
  expect(
    b.cardState,
    sdCardStateTran,
    reason: 'CMD12 must return the card to tran.',
  );
}

void main() {
  tearDown(Simulator.reset);

  for (final readAhead in [0, 3]) {
    test('a CMD18 stream survives read ahead of $readAhead', () async {
      final b = await setUpSdReadBench(readTimeoutClocks: _stressTimeoutClocks);
      await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
      await walkToTran(b);

      final rt = _Runtime(b, readAhead: readAhead);
      final task = rt.run();

      await _streamBlocks(b, lba: sdTestLba, count: 8);

      rt.stop = true;
      await task;

      // The measurement. Eight blocks are inside ONE chunk, so the card
      // posts ONE record for the whole stream. It posted one for each
      // block before.
      expect(
        rt.records,
        1,
        reason:
            'a stream of 8 blocks must cost one record, not one for each '
            'block.',
      );
      expect(
        await wbRead(b, MimicReg.event),
        0,
        reason: 'a stream that worked must raise no event.',
      );
      await Simulator.endSimulation();
    });
  }
}
