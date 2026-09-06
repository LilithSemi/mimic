// The write that no answer comes for.
//
// A runtime that takes the block and never acknowledges it must not hold
// the SD host on busy for ever. The card gives up after its own timeout,
// releases DAT0, returns to the transfer state and reports the event in
// EVENT bit 1.
//
// The block STAYS on the write channel after that, because only the
// runtime can take it off, so the card refuses every new write with the
// ERROR bit until the runtime answers. This file proves both halves.
@Timeout(Duration(minutes: 10))
library;

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';
import 'sd_read_bench.dart';

/// SD clocks this file gives the card to wait for an acknowledgement.
///
/// It is long enough to cover the R1 of CMD24, which is 48 clocks, and
/// short enough to be reachable in a simulation.
const int writeTimeoutTestClocks = 400;

/// The bytes of the block this file writes.
List<int> timeoutTestBlock() => [
  for (var i = 0; i < sdBlockBytes; i++) (i * 3 + 1) & 0xFF,
];

void main() {
  tearDown(Simulator.reset);

  test(
    'a write the runtime never answers releases the host and reports',
    () async {
      final b = await setUpSdReadBench(
        writeTimeoutClocks: writeTimeoutTestClocks,
      );
      await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
      await walkToTran(b);

      await b.host.idle(sdCommandGapClocks);
      await b.host.sendCommand(sdCmdWriteBlock, sdTestLba);
      final r1 = await b.host.receiveResponse(SdResponseKind.r1);
      expect(r1.timedOut, isFalse, reason: 'CMD24 gave no response.');

      await b.host.idle(4);
      await b.host.sendDataBlock(timeoutTestBlock());

      final token = await b.host.receiveStatusToken();
      expect(token.token, SdStatusToken.accepted);

      // Nothing answers. The card must let go by itself.
      final busy = await b.host.waitBusy(
        timeoutClocks: writeTimeoutTestClocks * 2,
      );
      expect(
        busy.timedOut,
        isFalse,
        reason: 'the card held the host on busy past its own timeout.',
      );
      expect(
        busy.clocks,
        greaterThan(8),
        reason:
            'the card released busy at once, so nothing proves it waited for '
            'the runtime at all.',
      );

      await b.host.idle(8);
      expect(
        b.cardState,
        sdCardStateTran,
        reason: 'a write that timed out must return the card to tran.',
      );
      expect(
        await wbRead(b, MimicReg.event) & MimicEvent.writeTimeout,
        MimicEvent.writeTimeout,
        reason: 'EVENT bit 1 must report a write the runtime never answered.',
      );

      // The block is still on the channel, so the card takes no new write.
      expect(await wbRead(b, MimicReg.dataOutCount), sdBlockWords);
      await b.host.idle(sdCommandGapClocks);
      await b.host.sendCommand(sdCmdWriteBlock, sdTestLba + 1);
      final refused = await b.host.receiveResponse(SdResponseKind.r1);
      expect(refused.timedOut, isFalse);
      expect(
        refused.payload & (1 << 19),
        isNot(0),
        reason:
            'the card must refuse a write while a block the runtime has not '
            'taken is still on the channel.',
      );

      // The runtime answers late. The POP is what takes the block off the
      // channel and opens the card to a new write. The acknowledgement that
      // follows carries the tag of the record the card gave up on, and it
      // releases nobody, because the card is holding nobody.
      final record = await takeRecord(b);
      expect(record.seq, 1);
      await pullWriteWords(b, sdBlockWords);
      await ackWrite(b, record.seq);
      await b.host.idle(8);

      await b.host.idle(sdCommandGapClocks);
      await b.host.sendCommand(sdCmdWriteBlock, sdTestLba + 1);
      final again = await b.host.receiveResponse(SdResponseKind.r1);
      expect(
        again.payload & (1 << 19),
        0,
        reason: 'the card must take a write once the channel is clear again.',
      );
      await Simulator.endSimulation();
    },
  );
}
