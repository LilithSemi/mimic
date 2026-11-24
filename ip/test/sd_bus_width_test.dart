// The 4-bit bus. ACMD6 sets it, every data frame then uses DAT0 to DAT3
// with a CRC16 per line, and CMD0 takes the card back to the 1-bit bus.
@Timeout(Duration(minutes: 25))
library;

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';
import 'sd_read_bench.dart';

/// ERROR, bit 19 of the card status.
const int _errorBit = 1 << 19;

/// The bytes of a block with a different value in every nibble position,
/// so a swapped line or a swapped nibble changes the result.
List<int> _block(int seed) => [
  for (var i = 0; i < sdBlockBytes; i++) (i * 37 + seed * 13 + (i >> 3)) & 0xFF,
];

Future<void> _setWidth(SdReadBench b, int arg, {required bool wide}) async {
  final r1 = await appCommand(b, sdAcmdSetBusWidth, arg);
  expect(r1.timedOut, isFalse, reason: 'ACMD6 gave no response.');
  expect(r1.payload & _errorBit, 0, reason: 'the card refused ACMD6 $arg.');
  b.host.wide = wide;
}

Future<void> _write(SdReadBench b, int lba, List<int> block) async {
  await b.host.idle(sdCommandGapClocks);
  await b.host.sendCommand(sdCmdWriteBlock, lba);
  final r1 = await b.host.receiveResponse(SdResponseKind.r1);
  expect(r1.timedOut, isFalse, reason: 'CMD24 gave nothing.');
  await b.host.idle(4);
  await b.host.sendDataBlock(block);
  final token = await b.host.receiveStatusToken();
  expect(token.token, SdStatusToken.accepted);
  final record = await takeRecord(b);
  expect(record.lba, lba);
  final words = await pullWriteWords(b, sdBlockWords);
  expect(words, sdBlockWordsOf(block), reason: 'the runtime got other bytes.');
  await ackWrite(b, record.seq);
  final busy = await b.host.waitBusy(timeoutClocks: 256);
  expect(busy.timedOut, isFalse, reason: 'the card never released busy.');
}

Future<List<int>> _read(SdReadBench b, int lba, List<int> block) async {
  await b.host.idle(sdCommandGapClocks);
  await b.host.sendCommand(sdCmdReadSingleBlock, lba);
  final r1 = await b.host.receiveResponse(SdResponseKind.r1);
  expect(r1.timedOut, isFalse, reason: 'CMD17 gave nothing.');
  final record = await takeRecord(b);
  expect(record.lba, lba);
  await pushBlock(b, sdBlockWordsOf(block), tag: record.seq);
  final got = await b.host.receiveDataBlock(timeoutClocks: 400);
  expect(got.timedOut, isFalse, reason: 'the card sent no block.');
  return got.bytes;
}

void main() {
  tearDown(Simulator.reset);

  test('a 4-bit card writes and reads blocks on four lines', () async {
    final b = await setUpSdReadBench(busWidth: 4);
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);
    await _setWidth(b, sdBusWidthArg4Bit, wide: true);

    // ACMD13 reports the 4-bit bus in DAT_BUS_WIDTH, the top two bits.
    final status = await appCommand(b, sdAcmdSdStatus, 0);
    expect(status.timedOut, isFalse);
    final ssr = await b.host.receiveDataBlock(blockBytes: sdSsrBytes);
    expect(ssr.bytes[0] >> 6, 2, reason: 'DAT_BUS_WIDTH must read 10.');

    for (var pass = 0; pass < 2; pass++) {
      final block = _block(pass);
      await _write(b, sdTestLba, block);
      expect(await _read(b, sdTestLba, block), block);
    }
    // The card state crosses into the bus clock domain, so give it time.
    await b.host.idle(8);
    expect(b.cardState, sdCardStateTran);
    await Simulator.endSimulation();
  });

  test('a bad CRC16 on DAT3 alone gets the CRC error token', () async {
    final b = await setUpSdReadBench(busWidth: 4);
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);
    await _setWidth(b, sdBusWidthArg4Bit, wide: true);

    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdWriteBlock, sdTestLba);
    await b.host.receiveResponse(SdResponseKind.r1);
    await b.host.idle(4);
    // Flip one payload bit on DAT3 only. DAT0 to DAT2 stay good.
    final block = _block(3);
    final damaged = [...block]..[10] ^= 0x80;
    await b.host.sendDataBlockWithLineCrcs(damaged, crcsOf: block);
    final token = await b.host.receiveStatusToken();
    expect(token.token, SdStatusToken.crcError);
    await Simulator.endSimulation();
  });

  test('CMD0 takes the card back to the 1-bit bus', () async {
    final b = await setUpSdReadBench(busWidth: 4);
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);
    await _setWidth(b, sdBusWidthArg4Bit, wide: true);

    b.host.wide = false;
    await walkToTran(b);
    final block = _block(5);
    await _write(b, sdTestLba, block);
    expect(await _read(b, sdTestLba, block), block);
    await Simulator.endSimulation();
  });

  test('a 1-bit card refuses the 4-bit bus with ERROR', () async {
    final b = await setUpSdReadBench();
    await walkToTran(b);
    final r1 = await appCommand(b, sdAcmdSetBusWidth, sdBusWidthArg4Bit);
    expect(r1.payload & _errorBit, isNot(0));
    await Simulator.endSimulation();
  });
}
