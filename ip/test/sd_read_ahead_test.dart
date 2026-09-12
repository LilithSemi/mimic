// READ AHEAD: blocks the runtime pushes before the card asks for them.
//
// The arithmetic is what makes this necessary and not merely nice. One
// 512-byte block on a 1-bit bus is 4114 SD clocks, which is 165 us at 25
// MHz. One USB full-speed round trip is about 1 ms. A block that the
// runtime fetches when the card ASKS for it therefore arrives about six
// times too late, every time. The runtime has to be pushing blocks before
// the card asks, and the card has to be able to take them.
//
// Three things have to hold for that, and each has a test here.
//
//   The card must TAKE a read while a block it did not ask for is still on
//   the channel. Read ahead leaves blocks waiting by design and the host
//   stops the SD clock between commands, so a block left by one command is
//   still there when the next arrives. A card that refused a read there
//   would refuse one CMD18 after another for as long as read ahead kept
//   pushing.
//
//   A fill must reach the cache DURING a stream. A CMD18 never leaves the
//   card idle: it looks the next block up on the clock the link reports
//   the end bit of this one. The card takes one waiting block off the
//   channel in that gap.
//
//   A block nobody asked for must NEVER be sent as the answer to a
//   request. The tag is what keeps them apart, and the last two tests here
//   are the negative controls of that rule.
@Timeout(Duration(minutes: 30))
library;

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';
import 'sd_read_bench.dart';

/// SD clocks that a lookup after a gap block needs before the block comes.
///
/// The card takes the gap block off the channel one word per clock, which
/// is [sdBlockWords] clocks, and it looks the next block up after that.
/// The wait for a start bit has to cover both with room to spare.
const int _gapTimeoutClocks = sdBlockWords + 400;

/// SD clocks that let the count of pushed blocks cross into the card.
///
/// The count crosses through a two-flop synchroniser, so a few clocks are
/// enough, and they are far fewer than the [sdBlockWords] clocks the card
/// needs to take a whole block off the channel. A test that wants the card
/// to be in the middle of taking a block gives exactly this many.
const int _crossingClocks = 8;

void main() {
  tearDown(Simulator.reset);

  test('data waits when its tag FIFO pointer crosses later', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    const fillLba = sdTestLba + 63;
    final bytes = sdTestBlockBytesFor(fillLba);

    // Model the independent CDC ordering seen in hardware: data and the
    // completed-block count are visible in the SD domain, but the tag FIFO
    // read pointer has not crossed yet.
    b.tagVisible.inject(0);
    await pushFillNoDrain(b, bytes, lba: fillLba);
    await b.host.idle(_crossingClocks + 8);

    expect(
      await wbRead(b, MimicReg.dataInCount),
      sdDataInFifoWords - sdBlockWords,
      reason: 'the card consumed data before its matching tag was visible.',
    );

    b.tagVisible.inject(1);
    await b.host.idle(sdBlockWords + 64);
    expect(
      await wbRead(b, MimicReg.dataInCount),
      sdDataInFifoWords,
      reason:
          'the card did not consume the block after its tag became visible.',
    );

    final got = await readCachedBlock(b, fillLba, reason: 'delayed tag:');
    expect(got.bytes, bytes);
    await Simulator.endSimulation();
  });

  test(
    'a read is taken while a fill is still coming off the channel',
    () async {
      // The regression of the failure that read ahead caused on hardware.
      // With a fill left on the channel the card refused CMD18 again and
      // again, and the host read a file that was part right and part
      // missing.
      final b = await setUpSdReadBench();
      await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
      await walkToTran(b);

      const fillLba = sdTestLba + 64;
      const readLba = sdTestLba;
      await pushFillNoDrain(b, sdTestBlockBytesFor(fillLba), lba: fillLba);

      // Enough clocks for the card to LEARN that a block is there, and far
      // too few for it to take the block off. The card is therefore in the
      // middle of taking it when the command below is decoded, which is
      // exactly where the host leaves it on a real board.
      await b.host.idle(_crossingClocks);

      // The card must accept this. `startRead` fails the test on an R1 with
      // the ERROR bit, which is what a refused read answers.
      await startRead(b, readLba, reason: 'with a fill on the channel:');

      // The card finishes taking the fill off the channel and looks the
      // read up after it, so the record comes a block of clocks later than
      // it would on an empty channel. That is 128 SD clocks against the 4114
      // that one block takes on DAT.
      await b.host.idle(sdBlockWords + 32);

      final want = sdTestBlockBytesFor(readLba);
      expect(
        await wbRead(b, MimicReg.reqCount),
        1,
        reason: 'the read is a miss, so the card must post one record.',
      );
      await answerRecord(b, want, expectLba: readLba);

      final got = await b.host.receiveDataBlock(
        timeoutClocks: _gapTimeoutClocks,
      );
      expect(got.timedOut, isFalse, reason: 'the card sent no block.');
      expect(got.crcOk, isTrue, reason: 'the block carries a bad CRC16.');
      expect(
        got.bytes,
        want,
        reason: 'the card sent the FILL and not the block that was asked for.',
      );

      // The fill went into the cache while all that ran, so the block it
      // carries is now a hit and costs no record at all.
      final cached = await readCachedBlock(b, fillLba, reason: 'the fill:');
      expect(cached.bytes, sdTestBlockBytesFor(fillLba));
      expect(
        await wbRead(b, MimicReg.event),
        0,
        reason: 'nothing here may raise an event.',
      );
      await Simulator.endSimulation();
    },
  );

  test('three fills behind an answer stream as four ordered blocks', () async {
    // Read ahead during CMD18, which is where boot spends nearly all of
    // its time. The runtime answers the record for block N and pushes the
    // fill for block N+1 behind it, which is the order it really uses. The
    // card sends N, takes the fill off the channel in the gap at the end
    // bit, and the lookup of N+1 then HITS: no record, no round trip.
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdReadMultipleBlock, sdTestLba);
    final r1 = await b.host.receiveResponse(SdResponseKind.r1);
    expect(r1.timedOut, isFalse, reason: 'CMD18 gave no response.');
    expect(
      r1.payload & (1 << 19),
      0,
      reason: 'CMD18 answered R1 with ERROR, so no block follows.',
    );

    final first = sdTestBlockBytesFor(sdTestLba);
    final second = sdTestBlockBytesFor(sdTestLba + 1);
    final third = sdTestBlockBytesFor(sdTestLba + 2);
    final fourth = sdTestBlockBytesFor(sdTestLba + 3);
    expect(
      first[0],
      isNot(second[0]),
      reason: 'the two blocks must differ, or this test proves nothing.',
    );

    await answerRecord(b, first, expectLba: sdTestLba);
    // The read ahead of the runtime, pushed behind the answer and while
    // the card is still sending the block before it.
    await pushFillNoDrain(b, second, lba: sdTestLba + 1);
    await pushFillNoDrain(b, third, lba: sdTestLba + 2);
    await pushFillNoDrain(b, fourth, lba: sdTestLba + 3);

    final gotFirst = await b.host.receiveDataBlock(timeoutClocks: 400);
    expect(gotFirst.timedOut, isFalse, reason: 'block 0 never came.');
    expect(gotFirst.crcOk, isTrue, reason: 'block 0 carries a bad CRC16.');
    expect(gotFirst.bytes, first, reason: 'block 0 holds other bytes.');

    // Each fill is already the next address of the stream. The card sends all
    // three directly from the FIFO without a request between blocks.
    final gotSecond = await b.host.receiveDataBlock(
      timeoutClocks: _gapTimeoutClocks,
    );
    expect(
      gotSecond.timedOut,
      isFalse,
      reason:
          'block 1 never came. The card did not take the fill in the gap of '
          'the stream, so the lookup missed and nothing answered it.',
    );
    expect(gotSecond.crcOk, isTrue, reason: 'block 1 carries a bad CRC16.');
    expect(
      gotSecond.bytes,
      second,
      reason: 'block 1 holds other bytes than the fill carried.',
    );
    final gotThird = await b.host.receiveDataBlock(
      timeoutClocks: _gapTimeoutClocks,
    );
    expect(gotThird.timedOut, isFalse, reason: 'block 2 never came.');
    expect(gotThird.crcOk, isTrue, reason: 'block 2 carries a bad CRC16.');
    expect(gotThird.bytes, third, reason: 'block 2 holds other bytes.');

    final gotFourth = await b.host.receiveDataBlock(
      timeoutClocks: _gapTimeoutClocks,
    );
    expect(gotFourth.timedOut, isFalse, reason: 'block 3 never came.');
    expect(gotFourth.crcOk, isTrue, reason: 'block 3 carries a bad CRC16.');
    expect(gotFourth.bytes, fourth, reason: 'block 3 holds other bytes.');

    // The stream asks for block 4 at the end of the queued window. Nothing
    // has answered it, so exactly one record stands.
    await b.host.idle(8);
    expect(
      await wbRead(b, MimicReg.reqCount),
      1,
      reason:
          'a queued fill posted a record of its own or the stream did not '
          'advance through all four blocks.',
    );

    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdStopTransmission, 0);
    final stop = await b.host.receiveResponse(SdResponseKind.r1);
    expect(stop.timedOut, isFalse, reason: 'CMD12 gave no response.');
    await Simulator.endSimulation();
  });

  test('a fill is never sent as the answer to a request', () async {
    // The rule that read ahead must not break. A block that answers no
    // record carries the tag that names none, and the card takes it off
    // the channel and puts it in the CACHE. It must never leave on DAT as
    // the answer to the record the card is waiting for.
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    const fillLba = sdTestLba + 64;
    const readLba = sdTestLba;
    final fillBytes = sdTestBlockBytesFor(fillLba);
    final wantBytes = sdTestBlockBytesFor(readLba);
    expect(
      fillBytes[0],
      isNot(wantBytes[0]),
      reason: 'the two blocks must differ, or this test proves nothing.',
    );

    await startRead(b, readLba, reason: 'before the fill:');
    expect(await wbRead(b, MimicReg.reqCount), 1);
    final record = await takeRecord(b);
    expect(record.lba, readLba);

    // The fill goes in FIRST, in front of the answer. That is the race a
    // runtime really runs into: it pushes the fills of one record while
    // the card is already asking for the next block.
    await pushFillNoDrain(b, fillBytes, lba: fillLba);
    await pushBlock(b, sdBlockWordsOf(wantBytes), tag: record.seq);

    final got = await b.host.receiveDataBlock(timeoutClocks: _gapTimeoutClocks);
    expect(got.timedOut, isFalse, reason: 'the card sent no block.');
    expect(got.crcOk, isTrue, reason: 'the block carries a bad CRC16.');
    expect(
      got.bytes,
      isNot(fillBytes),
      reason: 'the card sent the FILL as the answer to the record.',
    );
    expect(got.bytes, wantBytes, reason: 'the card sent other bytes.');

    // The fill was not thrown away either: it went into its own line.
    final cached = await readCachedBlock(b, fillLba, reason: 'the fill:');
    expect(cached.bytes, fillBytes);
    await Simulator.endSimulation();
  });

  test(
    'two blocks on the deeper channel keep their own tags and bytes',
    () async {
      // The channel holds four blocks now, so the runtime can be several
      // blocks ahead of the card. Each block must still leave with the bytes
      // the tag beside it named: a tag that named the block after it, or a
      // fill address that belonged to another block, would give the host the
      // right address with the wrong bytes, a good CRC16 on them, and
      // nothing reporting a fault anywhere.
      final b = await setUpSdReadBench();
      await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
      await walkToTran(b);

      const firstFill = sdTestLba + 64;
      const secondFill = sdTestLba + 65;
      final firstBytes = sdTestBlockBytesFor(firstFill);
      final secondBytes = sdTestBlockBytesFor(secondFill);
      expect(firstBytes[0], isNot(secondBytes[0]));

      // Both go in with NO SD clock between them, which is what a host that
      // stopped its clock leaves the runtime free to do.
      await pushFillNoDrain(b, firstBytes, lba: firstFill);
      await pushFillNoDrain(b, secondBytes, lba: secondFill);
      expect(
        await wbRead(b, MimicReg.dataInCount),
        sdDataInFifoWords - 2 * sdBlockWords,
        reason: 'two blocks must take two blocks of the free space.',
      );

      // The card takes them one at a time, and each one lands in the line
      // its OWN address names.
      await b.host.idle(2 * sdBlockWords + 64);
      expect(
        await wbRead(b, MimicReg.dataInCount),
        sdDataInFifoWords,
        reason: 'the card must take BOTH blocks off the channel.',
      );

      final gotFirst = await readCachedBlock(b, firstFill, reason: 'fill 0:');
      expect(
        gotFirst.bytes,
        firstBytes,
        reason: 'the first line holds the bytes of the other block.',
      );
      final gotSecond = await readCachedBlock(b, secondFill, reason: 'fill 1:');
      expect(
        gotSecond.bytes,
        secondBytes,
        reason: 'the second line holds the bytes of the other block.',
      );
      expect(
        await wbRead(b, MimicReg.event),
        0,
        reason:
            'no push may have been thrown away. EVENT bit 2 says the channel '
            'was full and a word went nowhere.',
      );
      await Simulator.endSimulation();
    },
  );

  test('two blocks on the deeper channel cannot be observed torn', () async {
    // The negative control of the test above. The data words bypass the
    // FIFO and cross through ONE register instead, which is the crossing a
    // stream must not have. The card still hears that two blocks arrived,
    // so it takes two and fills two lines, and the bytes in them are not
    // the bytes the runtime pushed.
    final b = await setUpSdReadBench(breakDataCrossing: true);
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    const firstFill = sdTestLba + 64;
    const secondFill = sdTestLba + 65;
    final firstBytes = sdTestBlockBytesFor(firstFill);
    final secondBytes = sdTestBlockBytesFor(secondFill);

    await pushFillNoDrain(b, firstBytes, lba: firstFill);
    await pushFillNoDrain(b, secondBytes, lba: secondFill);
    await b.host.idle(2 * sdBlockWords + 64);

    final gotFirst = await b.host.receiveDataBlock(
      timeoutClocks: 400,
      strict: false,
    );
    // The bench with the broken crossing must still get a block out, or
    // the control proves nothing about the words.
    await startRead(b, firstFill, reason: 'torn fill 0:');
    final torn = await b.host.receiveDataBlock(
      timeoutClocks: _gapTimeoutClocks,
      strict: false,
    );
    expect(
      gotFirst.timedOut,
      isTrue,
      reason: 'a fill sends nothing on DAT, so nothing may arrive here.',
    );
    expect(
      torn.timedOut,
      isFalse,
      reason:
          'the broken bench sent no block at all, so this control has no '
          'teeth.',
    );
    expect(
      torn.bytes,
      isNot(firstBytes),
      reason:
          'the broken crossing gave the card the right block. The FIFO is '
          'then not what carries it and this control has no teeth.',
    );
    await Simulator.endSimulation();
  });
}
