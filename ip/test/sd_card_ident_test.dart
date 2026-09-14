// The card identification walk against MimicSdCardDevice.
//
// This file is the acceptance test of the SD card personality. The host
// model drives the clock and the CMD line of the device, and the device
// answers with the link and the state machine that it holds. The walk is
// the sequence that a host sends before it reads one block: CMD0, CMD8,
// CMD55 and ACMD41 until the card reports its power-up done, then CMD2,
// CMD3, CMD9 and CMD7. The card must end in the transfer state.
//
// Every check here reads the wire. The expected values are literals with
// the field layout in the comment beside them, or values that
// `sd_regs.dart` builds. A test that computes an expected value the way
// the device computes it proves nothing.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';

/// The argument of CMD8: VHS 1 for 2.7 to 3.6 V and the check pattern 0xAA.
///
/// The card echoes the low 12 bits of this argument in its R7, so the
/// value is also the payload the host looks for.
const int _ifCondArg = 0x000001AA;

/// The card status that CMD55 answers while the card is in idle.
///
/// CURRENT_STATE is bits 12 to 9 and holds 0 for idle. READY_FOR_DATA is
/// bit 8 and reads 1, because the card is not writing. APP_CMD is bit 5
/// and CMD55 raises it. Every other bit is 0.
const int _statusIdleAppCmd = 0x00000120;

/// The card status that CMD7 answers while the card is in stby.
///
/// CURRENT_STATE holds 3 for stby, which is bits 12 to 9, and
/// READY_FOR_DATA is bit 8. CMD7 is not an application command, so APP_CMD
/// stays 0. The card status reports the state that the card was in when
/// the command arrived, so the move to tran does not show here.
const int _statusStby = 0x00000700;

/// The payload of the R6 that CMD3 answers.
///
/// The high 16 bits are the address that the card publishes, which is
/// [sdCardRca]. The low 16 bits are the R6 status: three error bits that
/// are 0, then bits 12 to 0 of the card status, which hold CURRENT_STATE 2
/// for ident and READY_FOR_DATA 1.
const int _publishedRcaR6 = 0x00010500;

/// The OCR that ACMD41 answers before the power-up is done.
///
/// Bit 31 is 0, which tells the host to poll again. Bit 30 is CCS and bits
/// 23 to 15 are the 2.7 to 3.6 V window. See `sdOcr` in sd_regs.dart.
const int _ocrBusy = 0x40FF8000;

/// The OCR that ACMD41 answers once the power-up is done.
///
/// It is [_ocrBusy] with bit 31 raised.
const int _ocrReady = 0xC0FF8000;

/// Largest number of ACMD41 polls the walk sends before it gives up.
///
/// The card reports busy for a fixed number of polls and then reports
/// ready. The walk does not assume that number, so this bound only has to
/// be large enough that a working card always passes it.
const int _opCondPollBound = 32;

/// The device under test with a host driving its pins.
///
/// The host owns the clock and the tie between the card and the bus, so
/// the test drives the four split pins through the model and never
/// injects into them.
Future<({MimicSdCardDevice dut, SdHost host})> _setUp({BigInt? cid}) async {
  final dut = MimicSdCardDevice(name: 'sd_card_device', cid: cid);
  final clk = Logic(name: 'sd_clk');
  final reset = Logic(name: 'sd_reset');
  final cmdIn = Logic(name: 'sd_cmd_in');
  final datIn = Logic(name: 'sd_dat_in');
  // The CSD crossing, as the card sees it. The SoC drives these two from a
  // handshake. A test that writes no CSD holds `csd_valid` low, and the card
  // then answers CMD9 with the default that its register resets to.
  final csd = Logic(name: 'csd', width: sdResponseRegBits);
  final csdValid = Logic(name: 'csd_valid');

  dut.input('clk').srcConnection! <= clk;
  dut.input('reset').srcConnection! <= reset;
  dut.input('sd_cmd_in').srcConnection! <= cmdIn;
  dut.input('sd_dat_in').srcConnection! <= datIn;
  dut.input('csd').srcConnection! <= csd;
  dut.input('csd_valid').srcConnection! <= csdValid;
  dut.input('num_blocks').srcConnection! <=
      Const(sdCardCapacityBlocks, width: sdCommandArgBits);
  dut.input('num_blocks_valid').srcConnection! <= Const(1);
  // The block read path is off in the identification walk. Every input
  // needs a driver, because an input that nothing drives holds X.
  dut.input('card_enable').srcConnection! <= Const(0);
  dut.input('data_word').srcConnection! <= Const(0, width: 32);
  dut.input('data_empty').srcConnection! <= Const(1);
  dut.input('data_blocks_pushed_gray').srcConnection! <=
      Const(0, width: sdBlockCountBits);
  dut.input('data_tag').srcConnection! <= Const(0, width: sdRequestSeqBits);
  dut.input('data_tag_empty').srcConnection! <= Const(1);
  await dut.build();

  final host = SdHost(
    clk: clk,
    cmdOut: cmdIn,
    datOut: datIn,
    cardCmd: dut.output('sd_cmd_out'),
    cardCmdOe: dut.output('sd_cmd_oe'),
    cardDat: dut.output('sd_dat_out'),
    cardDatOe: dut.output('sd_dat_oe'),
  );

  clk.inject(0);
  reset.inject(1);
  cmdIn.inject(1);
  datIn.inject(1);
  // A value that no test writes, so an answer that carries it can only come
  // from a card that took the port with no valid behind it.
  csd.inject(BigInt.zero);
  csdValid.inject(0);
  Simulator.setMaxSimTime(2000000);
  unawaited(Simulator.run());
  await host.tick();
  await host.tick();
  reset.inject(0);
  // The framer arms only after CMD stays high for this gap, so the first
  // command of the walk needs it.
  await host.idle(sdCommandGapClocks);
  return (dut: dut, host: host);
}

/// The path from the CSD CSR block to the card, in the small.
///
/// It holds the three modules that the SoC holds on that path, wired the
/// same way: the CSR slave in the bus clock domain, one
/// [HarborCdcHandshake], and the card in the SD clock domain. The two
/// clocks are separate ports, so a test drives the bus clock with a
/// generator and the SD clock by hand through the host model.
///
/// The card state takes the same road back that the SoC gives it, one
/// [HarborCdcSync] per bit, because the CSR slave needs that input driven.
class _CsdBridge extends BridgeModule {
  /// The CSR slave that the runtime writes.
  late final MimicSdCard csr;

  /// The card personality on the SD bus.
  late final MimicSdCardDevice card;

  _CsdBridge({String name = 'csd_bridge'}) : super('CsdBridge', name: name) {
    createPort('sys_clk', PortDirection.input);
    createPort('sd_clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('wb_cyc', PortDirection.input);
    createPort('wb_stb', PortDirection.input);
    createPort('wb_we', PortDirection.input);
    createPort('wb_adr', PortDirection.input, width: 12);
    createPort('wb_dat', PortDirection.input, width: 32);
    createPort('wb_sel', PortDirection.input, width: 4);
    createPort('sd_cmd_in', PortDirection.input);
    createPort('sd_dat_in', PortDirection.input);
    addOutput('wb_ack');
    addOutput('wb_miso', width: 32);
    addOutput('sd_cmd_out');
    addOutput('sd_cmd_oe');
    addOutput('sd_dat_out');
    addOutput('sd_dat_oe');
    addOutput('card_state', width: sdCardStateBits);

    final sysClk = input('sys_clk');
    final sdClk = input('sd_clk');
    final reset = input('reset');

    csr = MimicSdCard(baseAddress: 0, name: 'mimic_sd_card');
    addSubModule(csr);
    card = MimicSdCardDevice(name: 'sd_card_device');
    addSubModule(card);

    csr.input('clk').srcConnection! <= sysClk;
    csr.input('reset').srcConnection! <= reset;
    csr.input('bus_CYC').srcConnection! <= input('wb_cyc');
    csr.input('bus_STB').srcConnection! <= input('wb_stb');
    csr.input('bus_WE').srcConnection! <= input('wb_we');
    csr.input('bus_ADR').srcConnection! <= input('wb_adr');
    csr.input('bus_DAT_MOSI').srcConnection! <= input('wb_dat');
    csr.input('bus_SEL').srcConnection! <= input('wb_sel');
    output('wb_ack') <= csr.output('bus_ACK');
    output('wb_miso') <= csr.output('bus_DAT_MISO');

    card.input('clk').srcConnection! <= sdClk;
    card.input('reset').srcConnection! <= reset;
    card.input('sd_cmd_in').srcConnection! <= input('sd_cmd_in');
    card.input('sd_dat_in').srcConnection! <= input('sd_dat_in');
    output('sd_cmd_out') <= card.output('sd_cmd_out');
    output('sd_cmd_oe') <= card.output('sd_cmd_oe');
    output('sd_dat_out') <= card.output('sd_dat_out');
    output('sd_dat_oe') <= card.output('sd_dat_oe');
    output('card_state') <= card.output('card_state');

    final stateBits = <Logic>[];
    for (var i = 0; i < sdCardStateBits; i++) {
      final sync = HarborCdcSync(name: 'card_state_sync_$i');
      addSubModule(sync);
      sync.input('async_in').srcConnection! <= card.output('card_state')[i];
      sync.input('dst_clk').srcConnection! <= sysClk;
      sync.input('dst_reset').srcConnection! <= reset;
      stateBits.add(sync.output('sync_out'));
    }
    csr.input('card_state').srcConnection! <= stateBits.rswizzle();

    // The four SD bring-up counters take the same road the SoC gives them:
    // a gray code out of the SD clock domain, one synchroniser per bit, and
    // the conversion back to binary on this side. The CSR slave needs these
    // inputs driven, and the walk below reads the registers back over the
    // bus the way a runtime does.
    final dbg = <String, ({String cardPort, int width})>{
      'dbg_sd_clk': (cardPort: 'dbg_sd_clk_gray', width: sdDbgClkBits),
      'dbg_sd_cmd': (cardPort: 'dbg_sd_cmd_gray', width: sdDbgEventBits),
      'dbg_sd_crc_err': (
        cardPort: 'dbg_sd_crc_err_gray',
        width: sdDbgEventBits,
      ),
      'dbg_sd_resp': (cardPort: 'dbg_sd_resp_gray', width: sdDbgEventBits),
    };
    dbg.forEach((csrPort, spec) {
      final sync = MimicSdGraySync(width: spec.width, name: '${csrPort}_sync');
      addSubModule(sync);
      sync.input('gray_in').srcConnection! <= card.output(spec.cardPort);
      sync.input('clk').srcConnection! <= sysClk;
      sync.input('reset').srcConnection! <= reset;
      csr.input(csrPort).srcConnection! <= sync.output('count');
    });

    final cdc = HarborCdcHandshake(
      dataWidth: sdResponseRegBits,
      name: 'csd_cdc',
    );
    addSubModule(cdc);
    cdc.input('src_clk').srcConnection! <= sysClk;
    cdc.input('src_reset').srcConnection! <= reset;
    cdc.input('src_data').srcConnection! <= csr.output('csd');
    cdc.input('src_valid').srcConnection! <= Const(1);
    cdc.input('dst_clk').srcConnection! <= sdClk;
    cdc.input('dst_reset').srcConnection! <= reset;
    cdc.input('dst_ready').srcConnection! <= ~cdc.output('dst_valid');
    card.input('csd').srcConnection! <= cdc.output('dst_data');
    card.input('csd_valid').srcConnection! <= cdc.output('dst_valid');
    card.input('num_blocks').srcConnection! <=
        Const(sdCardCapacityBlocks, width: sdCommandArgBits);
    card.input('num_blocks_valid').srcConnection! <= Const(1);

    // The block read path is off in this bench. Every input needs a
    // driver, because an input that nothing drives holds X and the X
    // reaches the registers of the read path.
    card.input('card_enable').srcConnection! <= Const(0);
    card.input('data_word').srcConnection! <= Const(0, width: 32);
    card.input('data_empty').srcConnection! <= Const(1);
    card.input('data_blocks_pushed_gray').srcConnection! <=
        Const(0, width: sdBlockCountBits);
    // The tag channel of the block read path. No test here reads a block,
    // so the channel is empty and its tag names no request.
    card.input('data_tag').srcConnection! <= Const(0, width: sdRequestSeqBits);
    card.input('data_tag_empty').srcConnection! <= Const(1);

    // The runtime end of the block read channels. This bench holds no
    // FIFO, so the request channel reads empty and the data channel never
    // fills.
    csr.input('req_data').srcConnection! <= Const(0, width: sdRequestBits);
    csr.input('req_empty').srcConnection! <= Const(1);
    csr.input('data_full').srcConnection! <= Const(0);
    csr.input('data_blocked').srcConnection! <= Const(0);
    csr.input('tag_full').srcConnection! <= Const(0);
    csr.input('words_consumed').srcConnection! <=
        Const(0, width: sdDataWordCountBits);
    csr.input('sd_read_timeout_toggle').srcConnection! <= Const(0);
  }
}

/// The CSD that the card would answer CMD9 with at this moment.
///
/// It reads the register at the far end of the crossing, which is the port
/// the state machine builds its R2 from. A test reads it on every simulator
/// tick, which is how it can tell a value that is part old and part new
/// from one that moved in a single clock.
///
/// This is an INTERNAL net. A card that holds the right CSD and sends
/// another one passes every check that reads it, so a test that uses this
/// must also send a real CMD9 and read the answer off the CMD wire.
LogicValue _settledCsd(MimicSdCardDevice card) =>
    card.subModules.whereType<MimicSdCardFsm>().single.input('csd').value;

/// The card state that the device reports now.
int _cardState(MimicSdCardDevice dut) => dut.output('card_state').value.toInt();

/// The 16 bytes of a register that an R2 carried, most significant first.
List<int> _registerBytes(BigInt value) => [
  for (var shift = (sdRegisterBytes - 1) * 8; shift >= 0; shift -= 8)
    ((value >> shift) & BigInt.from(0xFF)).toInt(),
];

/// Checks the shape of a short response and the Ncr window it kept.
///
/// [what] names the command in the failure message. [index] is the value
/// the host expects in the 6-bit field after the transmission bit, and
/// [payload] is the 32-bit word after that field.
void _checkShort(
  SdResponse response,
  String what, {
  required int index,
  required int payload,
}) {
  expect(response.timedOut, isFalse, reason: '$what gave no response.');
  expect(response.framingOk, isTrue, reason: '$what is not framed.');
  expect(
    response.field,
    index,
    reason: '$what answered with the index field ${response.field}.',
  );
  expect(
    response.payload,
    payload,
    reason:
        '$what answered the payload '
        '0x${response.payload.toRadixString(16)}.',
  );
  expect(response.crcOk, isTrue, reason: '$what carries a bad CRC7.');
  _checkNcr(response, what);
}

/// Checks that the response came inside the Ncr window.
///
/// The host model measures Ncr from the end bit of the command it sent, so
/// the test reads what the model reports and never counts clocks itself.
void _checkNcr(SdResponse response, String what) {
  expect(
    response.ncr,
    isNotNull,
    reason: '$what has no Ncr, so no command came before the response.',
  );
  expect(
    response.ncrInWindow,
    isTrue,
    reason:
        '$what answered ${response.ncr} clocks after the end bit of the '
        'command. Ncr must be $sdNcrMin to $sdNcrMax clocks.',
  );
}

/// Checks the CRC7 that a CID or a CSD register carries in its last byte.
///
/// The link sends these 128 bits with nothing added, so a wrong last byte
/// is a register that a host rejects. [bytes] is the whole register.
void _checkRegisterCrc(List<int> bytes, String what) {
  expect(
    bytes.length,
    sdRegisterBytes,
    reason: '$what is not $sdRegisterBytes bytes long.',
  );
  final expected = ((sdCrc7(bytes.sublist(0, sdRegisterBytes - 1)) << 1) | 1);
  expect(
    bytes.last,
    expected,
    reason:
        '$what ends with the byte 0x${bytes.last.toRadixString(16)}, which '
        'is not the CRC7 of the first ${sdRegisterBytes - 1} bytes with the '
        'end bit.',
  );
}

/// Drives the whole identification sequence and checks every answer.
///
/// The walk leaves the card in the transfer state. It can run again on the
/// same card, because it starts with CMD0. The return value is the number
/// of ACMD41 polls the walk sent before it saw the power-up done, so a
/// caller can check that the card reported busy at least once.
///
/// [expectedCsd] is the CSD register that CMD9 must answer with. It is the
/// default CSD unless a caller wrote another one over the CSR block.
///
/// [expectedBlocks] is the capacity the host must read out of that CSD, as
/// an INDEPENDENT number. A caller that gives [expectedCsd] must give it,
/// because the number is what the check is for: an expected value that this
/// file decodes out of the expected CSD would only prove that the decoder
/// agrees with itself. See the file header.
///
/// [expectedCid] is the CID register that CMD2 must answer with. It is the
/// default CID unless the caller built the card with a manufacture date of
/// its own.
///
/// [expectedYear] and [expectedMonth] are the date the host must read out
/// of the MDT field of that CID, as INDEPENDENT numbers, for the same
/// reason [expectedBlocks] is independent of [expectedCsd].
Future<int> _identify(
  SdHost host,
  MimicSdCardDevice dut, {
  List<int>? expectedCsd,
  int? expectedBlocks,
  BigInt? expectedCid,
  int? expectedYear,
  int? expectedMonth,
}) async {
  if (expectedCsd != null && expectedBlocks == null) {
    throw ArgumentError(
      'A test that gives its own CSD must also give the block count that '
      'the host reads out of it.',
    );
  }
  final wantCsd = expectedCsd ?? sdCsdV2(capacityBlocks: sdCardCapacityBlocks);
  final wantBlocks = expectedBlocks ?? sdCardCapacityBlocks;
  // CMD0, GO_IDLE_STATE. It is a broadcast command and gives no response,
  // so the host waits out a short window and reads a timeout.
  await host.idle(sdCommandGapClocks);
  await host.sendCommand(sdCmdGoIdleState, 0);
  final afterReset = await host.receiveResponse(
    SdResponseKind.r1,
    timeoutClocks: 16,
  );
  expect(
    afterReset.timedOut,
    isTrue,
    reason: 'CMD0 is a broadcast command and must give no response.',
  );
  expect(
    _cardState(dut),
    sdCardStateIdle,
    reason: 'CMD0 must take the card back to idle.',
  );

  // CMD8, SEND_IF_COND. The R7 echoes the voltage and the check pattern,
  // which is how a host tells a version 2.0 card from an older one.
  await host.idle(sdCommandGapClocks);
  await host.sendCommand(sdCmdSendIfCond, _ifCondArg);
  final ifCond = await host.receiveResponse(SdResponseKind.r1);
  _checkShort(ifCond, 'CMD8', index: sdCmdSendIfCond, payload: _ifCondArg);

  // CMD55 and ACMD41, until the card reports its power-up done. The number
  // of polls is the card's business, so the walk reads bit 31 of the OCR
  // and does not count.
  var polls = 0;
  SdResponse? opCond;
  while (true) {
    polls++;
    if (polls > _opCondPollBound) {
      fail(
        'the card never raised bit 31 of the OCR in $_opCondPollBound '
        'ACMD41 polls. The last OCR was '
        '0x${opCond?.payload.toRadixString(16)}.',
      );
    }

    await host.idle(sdCommandGapClocks);
    await host.sendCommand(sdCmdAppCmd, 0);
    final appCmd = await host.receiveResponse(SdResponseKind.r1);
    _checkShort(
      appCmd,
      'CMD55 (poll $polls)',
      index: sdCmdAppCmd,
      payload: _statusIdleAppCmd,
    );

    await host.idle(sdCommandGapClocks);
    await host.sendCommand(sdAcmdSendOpCond, sdOcr(ready: false));
    opCond = await host.receiveResponse(SdResponseKind.r3);
    expect(
      opCond.timedOut,
      isFalse,
      reason: 'ACMD41 (poll $polls) gave no response.',
    );
    expect(
      opCond.framingOk,
      isTrue,
      reason: 'ACMD41 (poll $polls) is not framed.',
    );
    // An R3 has no index and no CRC. The reserved field is six ones and
    // bits 7 to 1 are seven ones, and a host reads both in their place.
    expect(
      opCond.field,
      0x3F,
      reason: 'the reserved field of an R3 must be 111111.',
    );
    expect(
      opCond.fixedFieldOk,
      isTrue,
      reason: 'bits 7 to 1 of an R3 must be the fixed 1111111.',
    );
    _checkNcr(opCond, 'ACMD41 (poll $polls)');

    if (opCond.payload & sdOcrPowerUpDone != 0) break;
    expect(
      opCond.payload,
      _ocrBusy,
      reason:
          'the busy OCR of poll $polls is not the card OCR with bit 31 '
          'clear.',
    );
    expect(
      _cardState(dut),
      sdCardStateIdle,
      reason: 'the card must stay in idle while it reports busy.',
    );
  }
  expect(
    opCond.payload,
    _ocrReady,
    reason: 'the ready OCR is not the card OCR with bit 31 set.',
  );
  expect(
    _cardState(dut),
    sdCardStateReady,
    reason:
        'the ACMD41 that reports the power-up done must move the card '
        'to ready.',
  );

  // CMD2, ALL_SEND_CID. The R2 carries the 128 bits of the CID.
  await host.idle(sdCommandGapClocks);
  await host.sendCommand(sdCmdAllSendCid, 0);
  final cid = await host.receiveResponse(SdResponseKind.r2);
  expect(cid.timedOut, isFalse, reason: 'CMD2 gave no response.');
  expect(cid.framingOk, isTrue, reason: 'the R2 of CMD2 is not framed.');
  expect(
    cid.field,
    0x3F,
    reason: 'the reserved field of an R2 must be 111111.',
  );
  _checkNcr(cid, 'CMD2');
  final cidBytes = _registerBytes(cid.register);
  _checkRegisterCrc(cidBytes, 'the CID');
  // The fields a host reads out of the CID, taken off the wire and not
  // from the value the device sends.
  expect(cidBytes[0], 0x00, reason: 'MID is the first byte of the CID.');
  expect(
    String.fromCharCodes(cidBytes.sublist(1, 3)),
    'MI',
    reason: 'OID is two ASCII characters after MID.',
  );
  expect(
    String.fromCharCodes(cidBytes.sublist(3, 8)),
    'MIMIC',
    reason: 'PNM is five ASCII characters after OID.',
  );
  expect(cidBytes[8], 0x10, reason: 'PRV 0x10 is revision 1.0.');
  expect(
    cid.register,
    expectedCid ?? sdRegisterToBigInt(sdCid()),
    reason: 'the CID on the wire is not the CID that sd_regs.dart builds.',
  );
  if (expectedYear != null || expectedMonth != null) {
    // MDT, taken off the wire byte by byte. The field is the low 12 bits
    // of the two bytes after PSN: 4 reserved bits, the 8-bit year after
    // 2000, and the 4-bit month. Nothing here calls the builder that made
    // the register, so this reads the bits the way a host reads them.
    final mdtYear =
        sdCidMdtFirstYear + ((cidBytes[13] << 4) | (cidBytes[14] >> 4));
    final mdtMonth = cidBytes[14] & 0x0F;
    expect(
      mdtYear,
      expectedYear,
      reason: 'the MDT year on the wire is not the year the card was built.',
    );
    expect(
      mdtMonth,
      expectedMonth,
      reason:
          'the MDT month on the wire is not the month the card was '
          'built.',
    );
  }
  expect(
    _cardState(dut),
    sdCardStateIdent,
    reason: 'CMD2 must move the card to ident.',
  );

  // CMD3, SEND_RELATIVE_ADDR. The R6 publishes the address of the card.
  await host.idle(sdCommandGapClocks);
  await host.sendCommand(sdCmdSendRelativeAddr, 0);
  final rca = await host.receiveResponse(SdResponseKind.r1);
  _checkShort(
    rca,
    'CMD3',
    index: sdCmdSendRelativeAddr,
    payload: _publishedRcaR6,
  );
  expect(
    rca.payload >> sdRcaBits,
    sdCardRca,
    reason: 'the high 16 bits of an R6 are the address of the card.',
  );
  expect(
    _cardState(dut),
    sdCardStateStby,
    reason: 'CMD3 must move the card to stby.',
  );

  // Every command below names the card by the address it published.
  final cardArg = sdCardRca << sdRcaBits;

  // CMD9, SEND_CSD. The R2 carries the 128 bits of the CSD, and the host
  // reads the capacity of the card out of it.
  await host.idle(sdCommandGapClocks);
  await host.sendCommand(sdCmdSendCsd, cardArg);
  final csd = await host.receiveResponse(SdResponseKind.r2);
  expect(csd.timedOut, isFalse, reason: 'CMD9 gave no response.');
  expect(csd.framingOk, isTrue, reason: 'the R2 of CMD9 is not framed.');
  expect(
    csd.field,
    0x3F,
    reason: 'the reserved field of an R2 must be 111111.',
  );
  _checkNcr(csd, 'CMD9');
  final csdBytes = _registerBytes(csd.register);
  _checkRegisterCrc(csdBytes, 'the CSD');
  expect(
    (csdBytes[0] >> 6) & 0x3,
    1,
    reason: 'CSD_STRUCTURE must be 01, which is a version 2.0 CSD.',
  );
  expect(
    sdCsdCapacityBlocks(csdBytes),
    wantBlocks,
    reason: 'the capacity the host reads out of the CSD is wrong.',
  );
  expect(
    csd.register,
    sdRegisterToBigInt(wantCsd),
    reason: 'the CSD on the wire is not the CSD that sd_regs.dart builds.',
  );
  expect(
    _cardState(dut),
    sdCardStateStby,
    reason: 'CMD9 must leave the card in stby.',
  );

  // CMD7, SELECT_CARD. The R1 carries the card status of the stby state,
  // because the status reports the state the command arrived in.
  await host.idle(sdCommandGapClocks);
  await host.sendCommand(sdCmdSelectCard, cardArg);
  final select = await host.receiveResponse(SdResponseKind.r1);
  _checkShort(select, 'CMD7', index: sdCmdSelectCard, payload: _statusStby);
  expect(
    _cardState(dut),
    sdCardStateTran,
    reason: 'CMD7 must move the card to tran, which ends the walk.',
  );

  return polls;
}

/// Number of 512-byte blocks in the disk image that Mimic must serve.
///
/// A version 2.0 CSD cannot report this count: C_SIZE counts steps of
/// [sdCsdCapacityUnitBlocks] blocks and this count is not a whole number of
/// steps. [_imageBlocksAligned] is the count that a CSD can report.
const int _imageBlocksRaw = 3309569;

/// The capacity that the CSD reports for that image, rounded DOWN.
///
/// The last block of the image is then out of reach of the host, which is
/// the safe direction: reporting more blocks than the image holds lets a
/// host read past its end.
const int _imageBlocksAligned = 3309568;

/// SD clocks between two CSR writes of the runtime, as the card sees them.
///
/// The runtime sends each write as its own USB frame, so two writes land
/// microseconds apart. At any SD clock a host uses, that is hundreds of SD
/// clocks, which is far more than the crossing needs to move a value. A
/// small gap here would only prove that the crossing is too slow to tear,
/// and the hardware gives it all the time it needs.
const int _runtimeWriteGapClocks = 200;

/// The bench of the [_CsdBridge]: the modules, the two clocks and the bus.
class _CsdBench {
  /// The design under test.
  final _CsdBridge bridge;

  /// The host that drives the SD bus and the SD clock.
  final SdHost host;

  /// The free-running bus clock. It is asynchronous to the SD clock.
  final Logic sysClk;

  /// The Wishbone master signals that a test drives.
  final Logic cyc;
  final Logic stb;
  final Logic we;
  final Logic adr;
  final Logic dat;

  _CsdBench({
    required this.bridge,
    required this.host,
    required this.sysClk,
    required this.cyc,
    required this.stb,
    required this.we,
    required this.adr,
    required this.dat,
  });
}

/// Builds the [_CsdBridge] with both clocks running and reset released.
///
/// The bus clock comes from a generator with a period that is not a whole
/// part of the SD clock period, so the two domains drift against each other
/// the way two real clocks do.
Future<_CsdBench> _setUpBridge() async {
  final bridge = _CsdBridge();
  final sdClk = Logic(name: 'sd_clk');
  final reset = Logic(name: 'reset');
  final cmdIn = Logic(name: 'sd_cmd_in');
  final datIn = Logic(name: 'sd_dat_in');
  final cyc = Logic(name: 'wb_cyc');
  final stb = Logic(name: 'wb_stb');
  final we = Logic(name: 'wb_we');
  final adr = Logic(name: 'wb_adr', width: 12);
  final dat = Logic(name: 'wb_dat', width: 32);
  final sel = Logic(name: 'wb_sel', width: 4);

  // One SD clock period is 10 time units, which is what the host model
  // drives. 6 is not a whole part of it.
  final sysClk = SimpleClockGenerator(6).clk;

  bridge.input('sys_clk').srcConnection! <= sysClk;
  bridge.input('sd_clk').srcConnection! <= sdClk;
  bridge.input('reset').srcConnection! <= reset;
  bridge.input('sd_cmd_in').srcConnection! <= cmdIn;
  bridge.input('sd_dat_in').srcConnection! <= datIn;
  bridge.input('wb_cyc').srcConnection! <= cyc;
  bridge.input('wb_stb').srcConnection! <= stb;
  bridge.input('wb_we').srcConnection! <= we;
  bridge.input('wb_adr').srcConnection! <= adr;
  bridge.input('wb_dat').srcConnection! <= dat;
  bridge.input('wb_sel').srcConnection! <= sel;
  await bridge.build();

  final host = SdHost(
    clk: sdClk,
    cmdOut: cmdIn,
    datOut: datIn,
    cardCmd: bridge.output('sd_cmd_out'),
    cardCmdOe: bridge.output('sd_cmd_oe'),
    cardDat: bridge.output('sd_dat_out'),
    cardDatOe: bridge.output('sd_dat_oe'),
  );

  sdClk.inject(0);
  reset.inject(1);
  cmdIn.inject(1);
  datIn.inject(1);
  cyc.inject(0);
  stb.inject(0);
  we.inject(0);
  adr.inject(0);
  dat.inject(0);
  sel.inject(0xF);
  Simulator.setMaxSimTime(4000000);
  unawaited(Simulator.run());
  // Both domains need edges under reset, because each holds its own
  // registers.
  await host.idle(4);
  reset.inject(0);
  await host.idle(sdCommandGapClocks);
  return _CsdBench(
    bridge: bridge,
    host: host,
    sysClk: sysClk,
    cyc: cyc,
    stb: stb,
    we: we,
    adr: adr,
    dat: dat,
  );
}

/// Runs one Wishbone write cycle on the bus clock.
Future<void> _wbWrite(_CsdBench b, int addr, int data) async {
  await b.sysClk.nextPosedge;
  b.adr.inject(addr);
  b.dat.inject(data);
  b.we.inject(1);
  b.cyc.inject(1);
  b.stb.inject(1);
  await _wbFinish(b);
}

/// Runs one Wishbone read cycle on the bus clock and returns the word.
Future<int> _wbRead(_CsdBench b, int addr) async {
  await b.sysClk.nextPosedge;
  b.adr.inject(addr);
  b.we.inject(0);
  b.cyc.inject(1);
  b.stb.inject(1);
  await _wbFinish(b);
  return b.bridge.output('wb_miso').value.toInt();
}

/// Waits for ACK and drops the cycle.
///
/// The slave answers in the clock after it sees the strobe, and it holds
/// the read word with the acknowledge, so the caller reads both here.
Future<void> _wbFinish(_CsdBench b) async {
  for (var i = 0; i < 16; i++) {
    await b.sysClk.nextPosedge;
    if (b.bridge.output('wb_ack').value == LogicValue.one) {
      b.cyc.inject(0);
      b.stb.inject(0);
      b.we.inject(0);
      return;
    }
  }
  fail('the CSR slave gave no ACK in 16 bus clocks');
}

void main() {
  tearDown(Simulator.reset);

  test('the card walks the identification sequence into tran', () async {
    final s = await _setUp();
    final polls = await _identify(s.host, s.dut);
    expect(
      polls,
      greaterThan(1),
      reason:
          'a card fresh from reset must report a busy OCR before it '
          'reports ready',
    );
  });

  test('a second walk on the same card reaches tran again', () async {
    // The card keeps its registers over the second walk, so this run finds
    // state that the first walk left behind. Only CMD0 and the commands of
    // the walk itself clear it. opCondPoll deliberately survives CMD0, so
    // this second walk correctly gets a ready OCR on its first poll and
    // must not be held to the busy check of the first walk.
    final s = await _setUp();
    await _identify(s.host, s.dut);
    await _identify(s.host, s.dut);
  });

  test('a card built with a date reports that date in its CID', () async {
    // The MDT field carries the date of the BUILD and not a constant. This
    // date is in no default of this repository, so a host that reads it off
    // the wire can only have got it from the build.
    const year = 2031;
    const month = 7;
    final cid = sdCardCidValueFor(
      manufactureYear: year,
      manufactureMonth: month,
    );
    expect(
      cid,
      isNot(equals(sdCardCidValue)),
      reason:
          'the test date must differ from the default, or it proves '
          'nothing',
    );
    final s = await _setUp(cid: cid);
    await _identify(
      s.host,
      s.dut,
      expectedCid: cid,
      expectedYear: year,
      expectedMonth: month,
    );
  });

  test('the default CSD constants agree with the CSR word order', () {
    // The reset value of the register is the default CSD, and the walk
    // above already reads it off the wire. This check pins the number that
    // the default reports, so a change to the default cannot pass unseen.
    expect(
      sdCsdCapacityBlocks(sdCsdV2(capacityBlocks: sdCardCapacityBlocks)),
      equals(sdCardCapacityBlocks),
    );
    expect(sdCardCapacityBlocks, equals(1024 * 1024));
    expect(sdCardCsdWords, hasLength(MimicReg.csd.length));
    // The CSR words run the other way from the wire bytes: CSD_0 holds the
    // LAST four bytes of the register.
    expect(
      sdCardCsdWords[0],
      equals(
        sdRegisterToWords(sdCsdV2(capacityBlocks: sdCardCapacityBlocks)).last,
      ),
    );
  });

  group('the CSD crosses from the CSR block into the SD clock domain', () {
    test('the card holds the default CSD until a transfer lands', () async {
      final b = await _setUpBridge();

      // No write, and the SD clock has run. The card must still answer with
      // the default, because the CSR block resets to it.
      await b.host.idle(64);
      expect(
        _settledCsd(b.bridge.card).toBigInt(),
        equals(sdCardCsdValue),
        reason: 'a card that nothing configured reports the default CSD',
      );

      // The four CSR registers read back the default as well, so a runtime
      // that reads before it writes sees the same register the card holds.
      for (var i = 0; i < MimicReg.csd.length; i++) {
        expect(
          await _wbRead(b, MimicReg.csd[i]),
          equals(sdCardCsdWords[i]),
          reason: 'CSD_$i resets to word $i of the default CSD',
        );
      }
      await Simulator.endSimulation();
    });

    test('a runtime write reaches the card whole and never torn', () async {
      final b = await _setUpBridge();
      final runtimeCsd = sdCsdV2(capacityBlocks: _imageBlocksAligned);
      final runtimeWords = sdRegisterToWords(runtimeCsd).reversed.toList();
      final runtimeValue = sdRegisterToBigInt(runtimeCsd);

      // Every CSD the card is allowed to hold while the write is in flight.
      // The write moves the CSR block one word at a time, so the source of
      // the crossing goes through three values that are part old and part
      // new. None of them may reach the card.
      final allowed = <BigInt>{sdCardCsdValue, runtimeValue};
      final seen = <BigInt>{};
      final torn = <BigInt>[];
      final watch = Simulator.postTick.listen((_) {
        final v = _settledCsd(b.bridge.card);
        if (!v.isValid) {
          torn.add(BigInt.from(-1));
          return;
        }
        final value = v.toBigInt();
        seen.add(value);
        if (!allowed.contains(value)) {
          torn.add(value);
        }
      });

      // The runtime writes the four words, lowest first, while the host
      // keeps clocking the card. The SD clock runs the whole time, so the
      // crossing is free to move a value across between any two writes.
      for (var i = 0; i < runtimeWords.length; i++) {
        await _wbWrite(b, MimicReg.csd[i], runtimeWords[i]);
        await b.host.idle(_runtimeWriteGapClocks);
      }
      await b.host.idle(_runtimeWriteGapClocks);
      await watch.cancel();

      expect(torn, isEmpty, reason: 'the card saw a CSD that no one wrote');
      expect(
        seen,
        equals(allowed),
        reason: 'the card must hold the default first and the new CSD after',
      );
      expect(
        _settledCsd(b.bridge.card).toBigInt(),
        equals(runtimeValue),
        reason: 'the crossing must finish while the SD clock runs',
      );

      // The capacity that a host decodes back is the one that was written,
      // and it is not the default.
      expect(sdCsdCapacityBlocks(runtimeCsd), equals(_imageBlocksAligned));
      expect(_imageBlocksAligned, isNot(equals(sdCardCapacityBlocks)));

      // Read the register the way a real host does. Every check above
      // watches an internal net, so a card that holds the right CSD but
      // sends another one would pass them all. The walk ends with a CMD9
      // and reads the 128 bits off the CMD wire.
      await _identify(
        b.host,
        b.bridge.card,
        expectedCsd: runtimeCsd,
        expectedBlocks: _imageBlocksAligned,
      );
      await Simulator.endSimulation();
    });

    test('the walk ends in tran with the CSD of a 3309569 block image, rounded '
        'down to 3309568 blocks', () async {
      // The raw image count is not a whole number of C_SIZE steps, so the
      // runtime has to round it before it can build a CSD at all.
      expect(
        () => sdCsdV2(capacityBlocks: _imageBlocksRaw),
        throwsArgumentError,
      );
      expect(
        _imageBlocksAligned,
        equals(
          (_imageBlocksRaw ~/ sdCsdCapacityUnitBlocks) *
              sdCsdCapacityUnitBlocks,
        ),
      );

      final b = await _setUpBridge();
      final runtimeCsd = sdCsdV2(capacityBlocks: _imageBlocksAligned);
      final runtimeWords = sdRegisterToWords(runtimeCsd).reversed.toList();

      for (var i = 0; i < runtimeWords.length; i++) {
        await _wbWrite(b, MimicReg.csd[i], runtimeWords[i]);
      }
      // Let the crossing finish before the walk asks for the CSD.
      await b.host.idle(64);

      await _identify(
        b.host,
        b.bridge.card,
        expectedCsd: runtimeCsd,
        expectedBlocks: _imageBlocksAligned,
      );
      expect(
        _cardState(b.bridge.card),
        equals(sdCardStateTran),
        reason: 'the walk must still end in tran with a written CSD',
      );

      // Twice, so that no answer of the first walk can carry the second.
      await _identify(
        b.host,
        b.bridge.card,
        expectedCsd: runtimeCsd,
        expectedBlocks: _imageBlocksAligned,
      );
      expect(_cardState(b.bridge.card), equals(sdCardStateTran));
      await Simulator.endSimulation();
    });
  });

  group('the SD bring-up counters', () {
    test('a walk ends in tran and the counters report it', () async {
      // The counters must not change what the card does, and they must
      // report the walk that really happened. The walk itself carries
      // every check of the card. This test adds what the counters say
      // about it, read back over the bus the way a runtime reads them.
      final b = await _setUpBridge();

      // Before the walk. The SD clock has already run under reset and
      // after it, so the clock counter is moving and no command has been
      // sent yet.
      final clockBefore = await _wbRead(b, MimicReg.dbgSdClk);
      expect(
        clockBefore,
        greaterThan(0),
        reason: 'the bench clocks the card, so the tick counter must move',
      );
      expect(await _wbRead(b, MimicReg.dbgSdCmd), equals(0));
      expect(await _wbRead(b, MimicReg.dbgSdCrcErr), equals(0));
      expect(await _wbRead(b, MimicReg.dbgSdResp), equals(0));

      await _identify(b.host, b.bridge.card);
      expect(_cardState(b.bridge.card), equals(sdCardStateTran));

      // Let the crossing carry the last counts across.
      await b.host.idle(8);

      final commands = await _wbRead(b, MimicReg.dbgSdCmd);
      final responses = await _wbRead(b, MimicReg.dbgSdResp);
      final crcErrors = await _wbRead(b, MimicReg.dbgSdCrcErr);
      final clockAfter = await _wbRead(b, MimicReg.dbgSdClk);

      // The walk sends CMD0, CMD8, one CMD55 and one ACMD41 per poll, then
      // CMD2, CMD3, CMD9 and CMD7. Every one of them is framed.
      //
      // Only CMD0 gives no response, so the card answers one fewer frame
      // than it hears. The count of polls is the card's business, so the
      // check reads the two counters against each other and does not
      // count the walk itself.
      expect(
        commands,
        greaterThanOrEqualTo(8),
        reason: 'the walk sends at least eight commands',
      );
      expect(
        responses,
        equals(commands - 1),
        reason: 'every command of the walk but CMD0 gets one response',
      );
      expect(
        crcErrors,
        equals(0),
        reason: 'the host model sends a correct CRC7 on every command',
      );
      expect(
        clockAfter,
        greaterThan(clockBefore),
        reason: 'the clock counter runs through the whole walk',
      );
      await Simulator.endSimulation();
    });
  });
}
