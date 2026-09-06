// The commands a Linux host sends between CMD7 and its first read.
//
// `mmc_sd_setup_card` reads the SCR with ACMD51 right after it selects the
// card, and it REJECTS the card when that read fails. CMD16 and ACMD6
// follow. A card that identifies and answers CMD17 but not these is a card
// that a host never asks for a block.
//
// The SCR goes out on DAT0 in the same frame shape a block read uses, with
// 8 bytes in it and not 512. The host model decodes it on its own and
// computes the CRC16 in software, so the card is never asked what it
// thinks its own CRC is.
@Timeout(Duration(minutes: 10))
library;

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';
import 'sd_read_bench.dart';

/// The bit of an R1 card status that reports a state violation.
const int _illegalCommand = 1 << 22;

/// The bit of an R1 card status that reports a general error.
const int _errorBit = 1 << 19;

/// The bit of an R1 card status that reports a block length the card
/// cannot use.
const int _blockLenError = 1 << 29;

/// The 8 bytes of the SCR this card sends, as LITERALS.
///
/// SCR_STRUCTURE 0, SD_SPEC 2, DATA_STAT_AFTER_ERASE 0, SD_SECURITY 3 and
/// SD_BUS_WIDTHS 1, which is the 1-bit bus alone. The value is written out
/// here and not built by the same helper the card uses, so a helper that
/// changes in both places at once cannot pass this test.
const List<int> _scrBytes = [0x02, 0x31, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];

void main() {
  tearDown(Simulator.reset);

  test('ACMD51 sends the 8 SCR bytes on DAT with a good CRC16', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    final scr = await readScr(b);
    expect(scr.timedOut, isFalse, reason: 'ACMD51 sent nothing on DAT.');
    expect(scr.framingOk, isTrue, reason: 'the SCR frame is not framed.');
    expect(scr.crcOk, isTrue, reason: 'the SCR frame carries a bad CRC16.');
    expect(
      scr.bytes.length,
      8,
      reason: 'an SCR is 8 bytes and not a whole block.',
    );
    expect(scr.bytes, _scrBytes);

    // The card is still in tran and can take a read, so the SCR frame did
    // not leave the transmit path or the card state behind.
    await b.host.idle(4);
    expect(b.cardState, sdCardStateTran);
    await Simulator.endSimulation();
  });

  test('the SCR and ACMD6 agree about the bus width', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    final scr = await readScr(b);
    // SD_BUS_WIDTHS is bits 51 to 48 of the SCR, which is the low nibble
    // of byte 1. A 1 is the 1-bit bus and a 4 is the 4-bit bus.
    expect(
      scr.bytes[1] & 0x0F,
      1,
      reason:
          'the SCR must advertise the 1-bit bus alone, because the card '
          'refuses ACMD6 for the 4-bit bus.',
    );

    final ok = await appCommand(b, sdAcmdSetBusWidth, 0);
    expect(ok.payload & _errorBit, 0, reason: 'ACMD6 refused the 1-bit bus.');

    final bad = await appCommand(b, sdAcmdSetBusWidth, 2);
    expect(
      bad.payload & _errorBit,
      _errorBit,
      reason:
          'ACMD6 accepted the 4-bit bus. The card drives DAT0 alone, so a '
          'host that takes that answer reads noise.',
    );
    await Simulator.endSimulation();
  });

  test('CMD16 accepts 512 bytes and refuses every other length', () async {
    final b = await setUpSdReadBench();
    await wbWrite(b, MimicReg.ctrl, MimicCtrl.enable);
    await walkToTran(b);

    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdSetBlocklen, 512);
    final ok = await b.host.receiveResponse(SdResponseKind.r1);
    expect(ok.timedOut, isFalse, reason: 'CMD16 gave no response.');
    expect(ok.field, sdCmdSetBlocklen);
    expect(
      ok.payload & _blockLenError,
      0,
      reason: 'CMD16 refused the one length the card can use.',
    );

    await b.host.idle(sdCommandGapClocks);
    await b.host.sendCommand(sdCmdSetBlocklen, 1024);
    final bad = await b.host.receiveResponse(SdResponseKind.r1);
    expect(bad.timedOut, isFalse, reason: 'CMD16 gave no response.');
    expect(
      bad.payload & _blockLenError,
      _blockLenError,
      reason:
          'CMD16 accepted 1024 bytes. The datapath is 512 bytes only, so a '
          'host that takes that answer reads the wrong number of bytes.',
    );

    // A refused CMD16 changes nothing: the card is still in tran and the
    // next block read still works.
    await b.host.idle(4);
    expect(b.cardState, sdCardStateTran);
    expect(
      bad.payload & _illegalCommand,
      0,
      reason:
          'CMD16 in tran is a legal command. The length is what is wrong '
          'with it, and BLOCK_LEN_ERROR is the bit that says so.',
    );
    await Simulator.endSimulation();
  });
}
