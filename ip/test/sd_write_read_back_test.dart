// The full walk: identify, write a block, then read the SAME block back.
//
// The runtime of this test is a small image in a map, which is what the
// real runtime does with a file. The bytes the host reads back must be the
// bytes it wrote, and nothing else in the design proves that both
// directions agree about byte order.
//
// The walk runs TWICE with different bytes. A card that keeps stale state
// passes the first pass and fails the second.
@Timeout(Duration(minutes: 25))
library;

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';
import 'sd_read_bench.dart';

/// The bytes of the block that pass [pass] writes.
///
/// The two passes share no byte at index 0, so a card that gave the second
/// read the block of the first fails on the first byte.
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

  test('a block written comes back byte for byte, twice', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    // The image of the runtime: one block at one address.
    final image = <int, List<int>>{};

    for (var pass = 0; pass < 2; pass++) {
      final block = passBlock(pass);
      final lba = sdTestLba;

      // The write.
      await b.host.idle(sdCommandGapClocks);
      await b.host.sendCommand(sdCmdWriteBlock, lba);
      final r1 = await b.host.receiveResponse(SdResponseKind.r1);
      expect(r1.timedOut, isFalse, reason: 'pass $pass: CMD24 gave nothing.');
      expect(
        r1.payload & (1 << 19),
        0,
        reason: 'pass $pass: the card refused the write.',
      );

      await b.host.idle(4);
      await b.host.sendDataBlock(block);
      final token = await b.host.receiveStatusToken();
      expect(
        token.token,
        SdStatusToken.accepted,
        reason: 'pass $pass: the card did not accept the block.',
      );

      final writeRecord = await takeRecord(b);
      expect(
        sdRecordOp(writeRecord.word0),
        sdRequestOpWriteBlocks,
        reason: 'pass $pass: the record is not a write.',
      );
      expect(writeRecord.lba, lba);
      final words = await pullWriteWords(b, sdBlockWords);
      image[writeRecord.lba] = words;
      await ackWrite(b, writeRecord.seq);
      final busy = await b.host.waitBusy(timeoutClocks: 256);
      expect(
        busy.timedOut,
        isFalse,
        reason: 'pass $pass: the card never released busy.',
      );

      await b.host.idle(8);
      expect(b.cardState, sdCardStateTran);

      // The read of the same block.
      await b.host.idle(sdCommandGapClocks);
      await b.host.sendCommand(sdCmdReadSingleBlock, lba);
      final r1r = await b.host.receiveResponse(SdResponseKind.r1);
      expect(r1r.timedOut, isFalse, reason: 'pass $pass: CMD17 gave nothing.');

      final readRecord = await takeRecord(b);
      expect(readRecord.lba, lba);
      final stored = image[readRecord.lba];
      expect(
        stored,
        isNotNull,
        reason: 'pass $pass: the card asked for a block nothing wrote.',
      );
      await pushBlock(b, stored!, tag: readRecord.seq);

      final got = await b.host.receiveDataBlock(timeoutClocks: 400);
      expect(
        got.timedOut,
        isFalse,
        reason: 'pass $pass: the card sent no block.',
      );
      expect(got.crcOk, isTrue, reason: 'pass $pass: the CRC16 is wrong.');
      // Literals first, so a byte order that is wrong in both directions
      // cannot pass.
      expect(got.bytes[0], 0xA0 + pass);
      expect(got.bytes[1], 0xB0 + pass);
      expect(got.bytes[2], 0xC0 + pass);
      expect(got.bytes[3], 0xD0 + pass);
      expect(got.bytes[sdBlockBytes - 1], 0xE0 + pass);
      expect(
        got.bytes,
        block,
        reason: 'pass $pass: the block that came back is not the one written.',
      );

      await b.host.idle(8);
      expect(b.cardState, sdCardStateTran);
    }

    expect(
      await wbRead(b, MimicReg.event),
      0,
      reason: 'two clean passes must raise no event.',
    );
    await Simulator.endSimulation();
  });
}
