// The high speed access mode. CMD6 CHECK reports it, CMD6 SWITCH turns it
// on at the end of the status frame, and CMD0 turns it off.
@Timeout(Duration(minutes: 25))
library;

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';
import 'sd_read_bench.dart';

/// CMD6 arguments: every group no-change except group 1.
const int _checkHighSpeed = 0x00FFFFF1;
const int _switchHighSpeed = 0x80FFFFF1;

/// The group 1 selection nibble of a switch status, bits 379 to 376.
int _group1Selection(List<int> status) => status[16] & 0xF;

bool _highSpeed(SdReadBench b) =>
    b.bridge.card.output('high_speed').value.toInt() == 1;

Future<List<int>> _switch(SdReadBench b, int arg) async {
  await b.host.idle(sdCommandGapClocks);
  await b.host.sendCommand(sdCmdSwitchFunc, arg);
  final r1 = await b.host.receiveResponse(SdResponseKind.r1);
  expect(r1.timedOut, isFalse, reason: 'CMD6 gave no response.');
  final status = await b.host.receiveDataBlock(blockBytes: sdSwitchStatusBytes);
  expect(status.timedOut, isFalse, reason: 'CMD6 sent no status.');
  return status.bytes;
}

void main() {
  tearDown(Simulator.reset);

  test('CHECK reports high speed and changes nothing', () async {
    final b = await setUpSdReadBench(highSpeed: true);
    await walkToTran(b);
    final status = await _switch(b, _checkHighSpeed);
    expect(sdSwitchStatusSupport(status, 1), 0x3);
    expect(_group1Selection(status), sdSwitchFunctionHighSpeed);
    await b.host.idle(8);
    expect(_highSpeed(b), isFalse);
    await Simulator.endSimulation();
  });

  test('SWITCH turns high speed on after the frame, CMD0 off', () async {
    final b = await setUpSdReadBench(highSpeed: true);
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);
    final status = await _switch(b, _switchHighSpeed);
    expect(_group1Selection(status), sdSwitchFunctionHighSpeed);
    await b.host.idle(8);
    expect(_highSpeed(b), isTrue);

    // A no-change CHECK now reports the function in force.
    final again = await _switch(b, 0x00FFFFFF);
    expect(_group1Selection(again), sdSwitchFunctionHighSpeed);

    // A block read still arrives whole with the rising edge launch.
    final block = sdTestBlockBytes();
    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdReadSingleBlock, sdTestLba);
    final r1 = await b.host.receiveResponse(SdResponseKind.r1);
    expect(r1.timedOut, isFalse);
    final record = await takeRecord(b);
    await pushBlock(b, sdBlockWordsOf(block), tag: record.seq);
    final got = await b.host.receiveDataBlock(timeoutClocks: 400);
    expect(got.bytes, block);

    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdGoIdleState, 0);
    await b.host.idle(8);
    expect(_highSpeed(b), isFalse);
    await Simulator.endSimulation();
  });

  test('a default speed build refuses high speed', () async {
    final b = await setUpSdReadBench();
    await walkToTran(b);
    final status = await _switch(b, _switchHighSpeed);
    expect(sdSwitchStatusSupport(status, 1), sdSwitchSupportDefaultOnly);
    expect(_group1Selection(status), sdSwitchSelectNotSupported);
    await b.host.idle(8);
    expect(_highSpeed(b), isFalse);
    await Simulator.endSimulation();
  });
}
