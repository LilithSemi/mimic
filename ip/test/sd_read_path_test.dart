// The request half of the block read path.
//
// A host sends CMD17. The card posts a request record over the CSR bus,
// and a runtime reads it back out of the REQ register. These tests check
// what the card asks for and when it refuses to ask at all. The block that
// comes back is in sd_read_block_test.dart.
//
// Every check here reads the wire or the register map, and the expected
// values are literals.
//
// A test here drives hundreds of SD clocks and the bus clock runs beside
// it, so it takes longer than the 30 seconds a Dart test gets by default.
@Timeout(Duration(minutes: 5))
library;

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';
import 'sd_read_bench.dart';

void main() {
  tearDown(Simulator.reset);

  test('CMD17 in tran posts a record whose address is the argument', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdReadSingleBlock, sdTestLba);
    final response = await b.host.receiveResponse(SdResponseKind.r1);
    expect(response.timedOut, isFalse, reason: 'CMD17 gave no response.');
    expect(
      response.field,
      sdCmdReadSingleBlock,
      reason: 'the R1 of CMD17 must echo the command index.',
    );
    expect(
      b.cardState,
      sdCardStateData,
      reason: 'CMD17 must move the card into the data state.',
    );

    // The record needs bus clocks to cross, and the card is waiting, so
    // the SD clock can stand still while the runtime reads it.
    expect(
      await wbRead(b, MimicReg.reqCount),
      1,
      reason: 'the request channel must hold one record.',
    );
    final record = await takeRecord(b);
    expect(
      record.word0,
      sdRecordWord0(1),
      reason:
          'word 0 must hold the read_blocks opcode, a block count of 1 and '
          'the sequence tag of the first read the card took.',
    );
    expect(
      record.lba,
      sdTestLba,
      reason: 'word 1 must hold the block address of the command.',
    );
    expect(
      await wbRead(b, MimicReg.reqCount),
      0,
      reason: 'the record must be gone once both its words are read.',
    );
    await Simulator.endSimulation();
  });

  test('a burst that reads across REQ leaves the record where it is', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);
    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdReadSingleBlock, sdTestLba);
    await b.host.receiveResponse(SdResponseKind.r1);

    // A burst that walks the whole register map, which is what
    // `mimic-cli info` does. It crosses REQ and must not eat the record.
    for (var addr = MimicReg.id; addr <= MimicReg.dbgSdResp; addr += 4) {
      await wbRead(b, addr);
    }

    expect(
      await wbRead(b, MimicReg.reqCount),
      1,
      reason: 'a burst across REQ must leave the record on the channel.',
    );
    final record = await takeRecord(b);
    expect(record.word0, sdRecordWord0(1));
    expect(record.lba, sdTestLba);
    await Simulator.endSimulation();
  });

  test('CMD17 out of tran is refused and posts no record', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    // CMD0 takes the card back to idle, where CMD17 has no meaning.
    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdGoIdleState, 0);
    await b.host.receiveResponse(SdResponseKind.r1, timeoutClocks: 16);
    expect(b.cardState, sdCardStateIdle);

    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdReadSingleBlock, sdTestLba);
    final response = await b.host.receiveResponse(
      SdResponseKind.r1,
      timeoutClocks: 64,
    );
    expect(
      response.timedOut,
      isTrue,
      reason: 'CMD17 out of tran must give no response at all.',
    );
    expect(
      b.cardState,
      sdCardStateIdle,
      reason: 'a refused CMD17 must not move the card.',
    );
    expect(
      await wbRead(b, MimicReg.reqCount),
      0,
      reason: 'CMD17 out of tran must post no record.',
    );
    await Simulator.endSimulation();
  });

  test(
    'a card the runtime never enabled refuses CMD17 with an error',
    () async {
      // CTRL bit 0 is never written here, so the card is not enabled.
      final b = await setUpSdReadBench();
      await walkToTran(b);

      await b.host.idle(sdCommandGapClocks);
      await b.host.sendCommand(sdCmdReadSingleBlock, sdTestLba);
      final response = await b.host.receiveResponse(SdResponseKind.r1);
      expect(response.timedOut, isFalse, reason: 'CMD17 gave no response.');
      // Bit 19 of the card status is ERROR.
      expect(
        response.payload & (1 << 19),
        isNot(0),
        reason: 'a card that cannot read must say so in the card status.',
      );
      expect(
        b.cardState,
        sdCardStateTran,
        reason: 'a refused CMD17 must leave the card in tran.',
      );
      expect(
        await wbRead(b, MimicReg.reqCount),
        0,
        reason: 'a refused CMD17 must post no record.',
      );
      await Simulator.endSimulation();
    },
  );

  // The regression test of Critical 1 of the read path review: the record
  // carried no tag, so the runtime could not say which read a block
  // answered and the card could not either.
  test('the record carries a sequence tag that counts the reads', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    for (var read = 1; read <= 3; read++) {
      await b.host.idle(sdCommandGapClocks);
      await b.host.sendCommand(sdCmdReadSingleBlock, sdTestLba + read);
      final response = await b.host.receiveResponse(SdResponseKind.r1);
      expect(response.timedOut, isFalse, reason: 'read $read: no response.');

      final record = await takeRecord(b);
      expect(
        record.seq,
        read,
        reason: 'read $read: the tag must name this read and no other.',
      );
      expect(record.word0, sdRecordWord0(read));
      expect(record.lba, sdTestLba + read);

      // Answer it, so the card comes back to tran for the next read.
      await pushBlock(b, sdBlockWordsOf(sdTestBlockBytes()), tag: record.seq);
      final got = await b.host.receiveDataBlock(timeoutClocks: 400);
      expect(got.timedOut, isFalse, reason: 'read $read: the card sent none.');
      expect(got.crcOk, isTrue);
      await b.host.idle(4);
      expect(b.cardState, sdCardStateTran);
    }
    await Simulator.endSimulation();
  });

  // The regression test of Critical 2 of the read path review. One foreign
  // read between the two reads of a record made the runtime read word 0
  // twice, so it served the block address 0x00010001 for every read that
  // followed and the record never popped.
  //
  // No read of the map has a side effect now, so this holds by
  // CONSTRUCTION and not by an order that a reader must keep. The test
  // therefore reads every address that the old map made dangerous,
  // REQ_HI itself among them, in the middle of the record.
  test(
    'a foreign access between the two record reads changes nothing',
    () async {
      final b = await setUpSdReadBench();
      await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
      await walkToTran(b);

      await b.host.idle(sdCommandGapClocks);
      await b.host.sendCommand(sdCmdReadSingleBlock, 0xABCD);
      await b.host.receiveResponse(SdResponseKind.r1);

      final word0 = await wbRead(b, MimicReg.req);
      // `mimic-cli info` beside `serve` is exactly this: reads of other
      // registers, in the middle of a record. REQ_HI is in the list because
      // a bulk read of the map crosses it, and a read of it must take
      // nothing.
      expect(await wbRead(b, MimicReg.id), MimicRegValue.id);
      expect(await wbRead(b, MimicReg.cardState), sdCardStateData);
      expect(
        await wbRead(b, MimicReg.reqHi),
        0xABCD,
        reason: 'a bare read of REQ_HI gives the block address.',
      );
      expect(await wbRead(b, MimicReg.reqHi), 0xABCD);
      expect(await wbRead(b, MimicReg.req), sdRecordWord0(1));
      await wbRead(b, MimicReg.dbgSdResp);
      expect(
        await wbRead(b, MimicReg.reqCount),
        1,
        reason: 'no read of any address may take the record.',
      );

      // A write of REQ_POP with the pop bit CLEAR is also a no-op.
      await wbWrite(b, MimicReg.reqPop, 0);
      expect(
        await wbRead(b, MimicReg.reqCount),
        1,
        reason: 'a write of REQ_POP without bit 0 takes nothing.',
      );

      final lba = await wbRead(b, MimicReg.reqHi);
      await wbWrite(b, MimicReg.reqPop, MimicReqPop.pop);

      expect(word0, sdRecordWord0(1), reason: 'REQ must give word 0.');
      expect(
        lba,
        0xABCD,
        reason:
            'REQ_HI must give the block address of the command, whatever was '
            'read between the two.',
      );
      expect(
        await wbRead(b, MimicReg.reqCount),
        0,
        reason: 'the write of REQ_POP must take the record.',
      );

      // The record popped EXACTLY once: the channel holds one record and
      // the many reads above took none of the others.
      expect(await wbRead(b, MimicReg.req), 0);
      expect(await wbRead(b, MimicReg.reqHi), 0);
      await Simulator.endSimulation();
    },
  );

  test('a read of REQ has no side effect at all', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdReadSingleBlock, sdTestLba);
    await b.host.receiveResponse(SdResponseKind.r1);

    // Ten reads of REQ give the same word ten times and pop nothing.
    for (var i = 0; i < 10; i++) {
      expect(await wbRead(b, MimicReg.req), sdRecordWord0(1));
    }
    expect(await wbRead(b, MimicReg.reqCount), 1);

    // The record is still whole.
    final record = await takeRecord(b);
    expect(record.lba, sdTestLba);
    expect(await wbRead(b, MimicReg.reqCount), 0);

    // An empty channel reads 0 at both addresses and pops nothing.
    expect(await wbRead(b, MimicReg.req), 0);
    expect(await wbRead(b, MimicReg.reqHi), 0);
    expect(await wbRead(b, MimicReg.reqCount), 0);
    await Simulator.endSimulation();
  });
}
