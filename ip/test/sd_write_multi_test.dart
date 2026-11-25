// CMD25, WRITE_MULTIPLE_BLOCK.
//
// The card takes one block after another at consecutive addresses and posts
// one write record for each, until CMD12 stops it. A CMD12 in rcv ends the
// write at once. A CMD12 in prg lets the card finish the block it holds.
@Timeout(Duration(minutes: 30))
library;

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';
import 'sd_read_bench.dart';

/// A block that no other block of these tests matches.
List<int> _block(int n) => [
  for (var i = 0; i < sdBlockBytes; i++) (i * 13 + n * 31 + 5) & 0xFF,
];

Future<SdReadBench> _bench() async {
  final b = await setUpSdReadBench();
  await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
  await walkToTran(b);
  return b;
}

Future<void> _command(SdReadBench b, int index, int arg) async {
  await b.host.idle(sdCommandGapClocks);
  await b.host.sendCommand(index, arg);
  final r1 = await b.host.receiveResponse(SdResponseKind.r1);
  expect(r1.timedOut, isFalse, reason: 'CMD$index gave no response.');
  expect(r1.payload & (1 << 19), 0, reason: 'CMD$index set ERROR.');
}

/// Sends block [n] of a CMD25 at [lba] and checks the token and the
/// record. The runtime does not acknowledge it yet.
Future<int> _sendBlock(SdReadBench b, int lba, int n) async {
  await b.host.idle(4);
  await b.host.sendDataBlock(_block(n));
  final token = await b.host.receiveStatusToken();
  expect(token.token, SdStatusToken.accepted, reason: 'block $n refused.');
  await b.host.park(8);
  expect(
    b.cardState,
    sdCardStatePrg,
    reason: 'block $n must put the card in prg.',
  );

  final record = await takeRecord(b);
  expect(record.lba, lba + n, reason: 'block $n has the wrong address.');
  expect(sdRecordOp(record.word0), sdRequestOpWriteBlocks);
  final words = await pullWriteWords(b, sdBlockWords);
  expect(sdBytesOfWords(words), _block(n), reason: 'block $n has wrong bytes.');
  return record.seq;
}

Future<void> _ack(SdReadBench b, int seq) async {
  await ackWrite(b, seq);
  final busy = await b.host.waitBusy(timeoutClocks: 256);
  expect(busy.timedOut, isFalse, reason: 'the card never released busy.');
}

void main() {
  tearDown(Simulator.reset);

  test(
    'CMD25 takes blocks at consecutive addresses until CMD12 in rcv',
    () async {
      final b = await _bench();
      const lba = sdTestLba;

      await _command(b, sdCmdWriteMultipleBlock, lba);
      final seqs = <int>[];
      for (var n = 0; n < 3; n++) {
        final seq = await _sendBlock(b, lba, n);
        seqs.add(seq);
        await _ack(b, seq);
        await b.host.idle(4);
        expect(
          b.cardState,
          sdCardStateRcv,
          reason: 'after block $n the card must wait for the next one.',
        );
      }
      expect(seqs.toSet().length, 3, reason: 'each block needs its own tag.');

      await _command(b, sdCmdStopTransmission, 0);
      await b.host.idle(8);
      expect(b.cardState, sdCardStateTran);
      expect(
        await wbRead(b, MimicReg.reqCount),
        0,
        reason: 'no fourth record.',
      );
      expect(await wbRead(b, MimicReg.event), 0);
      await Simulator.endSimulation();
    },
  );

  test('CMD12 in prg finishes the block and then ends the write', () async {
    final b = await _bench();
    const lba = sdTestLba + 8;

    await _command(b, sdCmdWriteMultipleBlock, lba);
    final first = await _sendBlock(b, lba, 0);
    await _ack(b, first);
    final second = await _sendBlock(b, lba, 1);

    // The host stops the write while the card still programs block 1.
    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdStopTransmission, 0);
    final r1 = await b.host.receiveResponse(SdResponseKind.r1);
    expect(r1.timedOut, isFalse, reason: 'CMD12 in prg gave no response.');
    await b.host.park(8);
    expect(b.cardState, sdCardStatePrg, reason: 'the block is not done yet.');
    expect(
      b.host.datLine[0],
      LogicValue.zero,
      reason: 'busy must hold until the runtime takes the block.',
    );

    await _ack(b, second);
    await b.host.idle(8);
    expect(b.cardState, sdCardStateTran);
    expect(await wbRead(b, MimicReg.reqCount), 0);
    expect(await wbRead(b, MimicReg.event), 0);
    await Simulator.endSimulation();
  });
}
