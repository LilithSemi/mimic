// CMD6, SWITCH_FUNC. The last setup command a host sends before it mounts.
//
// The card answers R1 and then puts 64 bytes on DAT0 with a CRC16, in the
// same frame shape a block read uses and through the same sender the SCR
// of ACMD51 uses. The 64 bytes are the status data structure of the SD
// Physical Layer specification.
//
// This card is default speed, 1-bit, and holds no optional function at
// all, so the status names function 0 of every group and nothing else. Bit
// 31 of the argument picks CHECK or SWITCH, and both give the same answer
// here: a switch to the function that is already in force changes nothing.
//
// The bytes below are LITERALS. The card builds the same value from named
// constants, and a test that built it the same way would pass on a layout
// that is wrong in both places.
@Timeout(Duration(minutes: 30))
library;

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';
import 'sd_read_bench.dart';

/// The bit of an R1 card status that reports a general error.
const int _errorBit = 1 << 19;

/// The bit of an R1 card status that reports a block length the card
/// cannot use.
const int _blockLenError = 1 << 29;

/// The CMD6 argument that asks what the card supports and leaves every
/// group as it is: mode CHECK, and 0xF in all six group nibbles.
const int _checkNoChange = 0x00FFFFFF;

/// The same argument with mode SWITCH.
const int _switchNoChange = 0x80FFFFFF;

/// The CMD6 argument a Linux host sends to ask for the high speed access
/// mode: mode CHECK, group 1 function 1, every other group unchanged.
const int _checkHighSpeed = 0x00FFFFF1;

/// The same request with mode SWITCH.
const int _switchHighSpeed = 0x80FFFFF1;

/// The 64 bytes of the switch status this card sends for a request that
/// asks for no change, as LITERALS.
///
/// Bytes 0 and 1 are the maximum current, 100 mA. Bytes 2 to 13 are the
/// support map of group 6 down to group 1, each 0x0001, which is function
/// 0 alone. Bytes 14 to 16 are the selection nibbles of group 6 down to
/// group 1, all 0, which is the default function. Byte 17 is the version
/// of the structure. Bytes 18 to 29 are the busy map of group 6 down to
/// group 1, all 0. Bytes 30 to 63 are reserved.
const List<int> _statusNoChange = [
  0x00, 0x64, //
  0x00, 0x01, 0x00, 0x01, 0x00, 0x01, //
  0x00, 0x01, 0x00, 0x01, 0x00, 0x01, //
  0x00, 0x00, 0x00, //
  0x01, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, //
];

/// The same 64 bytes for a request that asks group 1 for function 1.
///
/// The card refuses that function, so the group 1 selection nibble, which
/// is the low nibble of byte 16, reads 0xF. Every other byte is the same.
const List<int> _statusHighSpeed = [
  0x00, 0x64, //
  0x00, 0x01, 0x00, 0x01, 0x00, 0x01, //
  0x00, 0x01, 0x00, 0x01, 0x00, 0x01, //
  0x00, 0x00, 0x0F, //
  0x01, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, //
];

/// Sends CMD6 with [argument] and reads the 64 bytes that follow the R1.
///
/// The frame has the shape of a block read with 64 bytes in it, so the
/// host model decodes it with the same method and computes the CRC16 on
/// its own.
Future<SdDataBlock> readSwitchStatus(SdReadBench b, int argument) async {
  await b.host.idle(sdCommandGapClocks);
  await b.host.sendCommand(sdCmdSwitchFunc, argument);
  final answer = await b.host.receiveResponse(SdResponseKind.r1);
  expect(answer.timedOut, isFalse, reason: 'CMD6 gave no response.');
  expect(answer.field, sdCmdSwitchFunc, reason: 'CMD6 echoed another index.');
  expect(
    answer.payload & _errorBit,
    0,
    reason: 'CMD6 answered R1 with ERROR, so no status follows.',
  );
  return b.host.receiveDataBlock(
    blockBytes: sdSwitchStatusBytes,
    timeoutClocks: 200,
  );
}

/// Reads one block with CMD17 and checks the bytes.
Future<void> readOneBlock(SdReadBench b, {required int lba}) async {
  await b.host.idle(sdCommandGapClocks);
  await b.host.sendCommand(sdCmdReadSingleBlock, lba);
  final answer = await b.host.receiveResponse(SdResponseKind.r1);
  expect(answer.timedOut, isFalse, reason: 'CMD17 gave no response.');
  expect(answer.payload & _errorBit, 0, reason: 'CMD17 refused the read.');

  final block = sdTestBlockBytesFor(lba);
  await answerRecord(b, block, expectLba: lba);

  final got = await b.host.receiveDataBlock(timeoutClocks: 200);
  expect(got.timedOut, isFalse, reason: 'the card sent no block.');
  expect(got.crcOk, isTrue, reason: 'the block carries a bad CRC16.');
  expect(got.bytes, block, reason: 'the card sent other bytes.');
}

void main() {
  tearDown(Simulator.reset);

  test(
    'CMD6 in CHECK mode sends the 64 status bytes with a good CRC16',
    () async {
      final b = await setUpSdReadBench();
      await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
      await walkToTran(b);

      final status = await readSwitchStatus(b, _checkNoChange);
      expect(status.timedOut, isFalse, reason: 'CMD6 sent nothing on DAT.');
      expect(
        status.framingOk,
        isTrue,
        reason: 'the status frame is not framed.',
      );
      expect(status.crcOk, isTrue, reason: 'the status carries a bad CRC16.');
      expect(
        status.bytes.length,
        64,
        reason: 'a switch status is 64 bytes and not a whole block.',
      );
      expect(status.bytes, _statusNoChange);

      // The card is still in tran and the sender is free, so the frame left
      // neither the transmit path nor the card state behind.
      await b.host.idle(4);
      expect(b.cardState, sdCardStateTran);
      await Simulator.endSimulation();
    },
  );

  test(
    'CMD6 reports the high speed access mode as one it does not have',
    () async {
      final b = await setUpSdReadBench();
      await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
      await walkToTran(b);

      final status = await readSwitchStatus(b, _checkHighSpeed);
      expect(status.crcOk, isTrue, reason: 'the status carries a bad CRC16.');

      // Byte 13 is the low byte of the group 1 support map, and bit 1 of it
      // is the high speed access mode. Linux reads that one bit and only
      // sends the switch when it is high. The card answers at the default
      // speed alone, so the bit must be 0.
      expect(
        status.bytes[13] & 0x02,
        0,
        reason:
            'the card advertised the high speed access mode. A host that '
            'takes it clocks the card at 50 MHz, which this card cannot '
            'answer.',
      );
      expect(
        status.bytes[13] & 0x01,
        0x01,
        reason: 'the card must support the default function of group 1.',
      );

      // The low nibble of byte 16 is the group 1 selection. The host asked
      // for function 1 and the card does not have it, so the field reads
      // 0xF.
      expect(
        status.bytes[16] & 0x0F,
        0x0F,
        reason:
            'the card must report 0xF for a function it does not have, and '
            'not the default function as though it granted the request.',
      );
      expect(status.bytes, _statusHighSpeed);
      await Simulator.endSimulation();
    },
  );

  test('CMD6 in SWITCH mode answers the same and changes nothing', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    final check = await readSwitchStatus(b, _checkNoChange);
    expect(check.crcOk, isTrue, reason: 'the CHECK status has a bad CRC16.');

    final switched = await readSwitchStatus(b, _switchNoChange);
    expect(
      switched.crcOk,
      isTrue,
      reason: 'the SWITCH status has a bad CRC16.',
    );
    expect(
      switched.bytes,
      check.bytes,
      reason:
          'a SWITCH that can only grant the function already in force must '
          'answer what the CHECK answered.',
    );
    expect(switched.bytes, _statusNoChange);

    // A SWITCH for a function the card does not have gives the same 0xF
    // that the CHECK gave, and still changes nothing.
    final refused = await readSwitchStatus(b, _switchHighSpeed);
    expect(refused.crcOk, isTrue, reason: 'the refused status has a bad CRC.');
    expect(refused.bytes, _statusHighSpeed);

    // Nothing the card does has moved. It is in tran, it still refuses the
    // 4-bit bus, it still takes only 512-byte blocks, and it still reads a
    // block.
    await b.host.idle(4);
    expect(b.cardState, sdCardStateTran);

    final wide = await appCommand(b, sdAcmdSetBusWidth, 2);
    expect(
      wide.payload & _errorBit,
      _errorBit,
      reason: 'CMD6 left the card taking the 4-bit bus.',
    );

    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdSetBlocklen, 1024);
    final blockLen = await b.host.receiveResponse(SdResponseKind.r1);
    expect(
      blockLen.payload & _blockLenError,
      _blockLenError,
      reason: 'CMD6 left the card taking another block length.',
    );

    await readOneBlock(b, lba: sdTestLba);
    expect(
      await wbRead(b, MimicReg.event),
      0,
      reason: 'the CMD6 frames raised an event.',
    );
    await Simulator.endSimulation();
  });

  test('the switch status agrees with the SCR and with ACMD6', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    final scr = await readScr(b);
    expect(scr.crcOk, isTrue, reason: 'the SCR carries a bad CRC16.');
    // SD_BUS_WIDTHS is the low nibble of byte 1 of the SCR. A 1 is the
    // required 1-bit and 4-bit widths.
    expect(scr.bytes[1] & 0x0F, 5);

    final status = await readSwitchStatus(b, _checkNoChange);
    expect(status.crcOk, isTrue, reason: 'the status carries a bad CRC16.');

    // Every group of the status names function 0 and nothing else. Bytes
    // 2 to 13 hold the support map of group 6 down to group 1.
    for (var group = 1; group <= 6; group++) {
      final index = 2 + (6 - group) * 2;
      final support = (status.bytes[index] << 8) | status.bytes[index + 1];
      expect(
        support,
        0x0001,
        reason:
            'group $group advertises 0x${support.toRadixString(16)}. The '
            'card grants the default function alone, so a host that asks '
            'for another one reads the default back and cannot tell that '
            'from a broken card.',
      );
    }

    // ACMD6 and CMD6 are the same index and must stay two commands. ACMD6
    // still refuses the 4-bit bus until that datapath exists, and it sends
    // no data frame at all. The board limits the host to one line.
    final ok = await appCommand(b, sdAcmdSetBusWidth, 0);
    expect(ok.payload & _errorBit, 0, reason: 'ACMD6 refused the 1-bit bus.');
    final quiet = await b.host.receiveDataBlock(
      blockBytes: sdSwitchStatusBytes,
      timeoutClocks: 64,
      strict: false,
    );
    expect(
      quiet.timedOut,
      isTrue,
      reason:
          'ACMD6 sent a data frame. Index 6 with the CMD55 bit high is '
          'SET_BUS_WIDTH and it answers on CMD alone.',
    );

    final bad = await appCommand(b, sdAcmdSetBusWidth, 2);
    expect(
      bad.payload & _errorBit,
      _errorBit,
      reason: 'ACMD6 accepted the 4-bit bus that the SCR does not name.',
    );
    await Simulator.endSimulation();
  });

  test('CMD6 outside tran is refused and sends nothing', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);

    // The card is in idle, which is where a card sits before it
    // identifies. CMD6 belongs to tran, so it gives no answer at all, the
    // way every other addressed command of this card does out of its
    // state.
    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdSwitchFunc, _checkNoChange);
    final idle = await b.host.receiveResponse(SdResponseKind.r1);
    expect(
      idle.timedOut,
      isTrue,
      reason: 'CMD6 answered in idle, where the card holds no such command.',
    );
    final quiet = await b.host.receiveDataBlock(
      blockBytes: sdSwitchStatusBytes,
      timeoutClocks: 128,
      strict: false,
    );
    expect(
      quiet.timedOut,
      isTrue,
      reason: 'CMD6 in idle put a frame on DAT with no command to carry it.',
    );

    // The card still identifies after it, so the refused command changed
    // nothing.
    await walkToTran(b);
    expect(b.cardState, sdCardStateTran);
    await Simulator.endSimulation();
  });

  test('the whole setup walk with CMD6 and a read, run TWICE', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);

    for (var run = 0; run < 2; run++) {
      // CMD0 is the first command of the walk, so the second run starts
      // from idle the way the first one did.
      await walkToTran(b);

      final scr = await readScr(b);
      expect(scr.timedOut, isFalse, reason: 'run $run: ACMD51 sent nothing.');
      expect(scr.crcOk, isTrue, reason: 'run $run: the SCR CRC16 is bad.');

      await b.host.idle(sdCommandGapClocks);
      await b.host.sendCommand(sdCmdSetBlocklen, 512);
      final blockLen = await b.host.receiveResponse(SdResponseKind.r1);
      expect(
        blockLen.payload & _blockLenError,
        0,
        reason: 'run $run: CMD16 refused 512 bytes.',
      );

      final busWidth = await appCommand(b, sdAcmdSetBusWidth, 0);
      expect(
        busWidth.payload & _errorBit,
        0,
        reason: 'run $run: ACMD6 refused the 1-bit bus.',
      );

      final status = await readSwitchStatus(b, _checkHighSpeed);
      expect(status.timedOut, isFalse, reason: 'run $run: CMD6 sent nothing.');
      expect(
        status.crcOk,
        isTrue,
        reason: 'run $run: the status CRC16 is bad.',
      );
      expect(
        status.bytes,
        _statusHighSpeed,
        reason: 'run $run: the status is not the status.',
      );

      await readOneBlock(b, lba: sdTestLba + run * 16);

      expect(
        await wbRead(b, MimicReg.event),
        0,
        reason: 'run $run: the walk raised an event.',
      );
    }
    await Simulator.endSimulation();
  });
}
