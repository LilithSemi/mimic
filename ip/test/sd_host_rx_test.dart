// Receive tests for the SD host model.
//
// The model is the golden side of every SD test that comes later, so these
// tests drive the real MimicSdLink and check what the model reads back out
// of it. A response goes out of the link, comes back through the bus tie
// that the model owns, and the decoded fields must match the payload the
// test gave the link.

import 'dart:async';

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';

/// Builds the link with a host that ties the card back onto the bus.
Future<
  ({
    MimicSdLink dut,
    SdHost host,
    Logic reset,
    Logic respStart,
    Logic respData,
    Logic respKind,
    Logic datStatusSend,
    Logic datStatusCode,
  })
>
_setUp() async {
  final dut = MimicSdLink(name: 'sd_link');
  final clk = Logic(name: 'sd_clk');
  final reset = Logic(name: 'sd_reset');
  final cmdIn = Logic(name: 'cmd_in');
  final datIn = Logic(name: 'dat_in');
  final respStart = Logic(name: 'resp_start');
  final respData = Logic(name: 'resp_data', width: sdResponseRegBits);
  final respKind = Logic(name: 'resp_kind', width: sdRespKindBits);
  final datRxEnable = Logic(name: 'dat_rx_enable');
  final datStatusSend = Logic(name: 'dat_status_send');
  final datStatusCode = Logic(name: 'dat_status_code', width: sdStatusCodeBits);

  dut.input('clk').srcConnection! <= clk;
  dut.input('reset').srcConnection! <= reset;
  dut.input('cmd_in').srcConnection! <= cmdIn;
  dut.input('dat_in').srcConnection! <= datIn;
  dut.input('resp_start').srcConnection! <= respStart;
  dut.input('resp_data').srcConnection! <= respData;
  dut.input('resp_kind').srcConnection! <= respKind;
  dut.input('dat_rx_enable').srcConnection! <= datRxEnable;
  dut.input('dat_status_send').srcConnection! <= datStatusSend;
  // The busy level of the card personality. A link input that nothing
  // drives holds X, and the X reaches dat_oe as soon as the host reads the
  // line.
  dut.input('dat_busy').srcConnection! <= Const(0);
  dut.input('dat_status_code').srcConnection! <= datStatusCode;
  // The data transmit path is off in this bench. An input that
  // nothing drives holds X, and the X would reach DAT0.
  dut.input('dat_tx_start').srcConnection! <= Const(0);
  dut.input('dat_tx_byte').srcConnection! <= Const(0, width: 8);
  dut.input('dat_tx_len').srcConnection! <=
      Const(sdBlockBytes, width: sdDataTxLenBits);
  await dut.build();

  // The four card signals give the host its bus tie. CMD carries the
  // card's drive while cmd_oe is high and the host's drive at every other
  // time, which is what the tristate in the parent module does.
  final host = SdHost(
    clk: clk,
    cmdOut: cmdIn,
    datOut: datIn,
    cardCmd: dut.output('cmd_out'),
    cardCmdOe: dut.output('cmd_oe'),
    cardDat: dut.output('dat_out'),
    cardDatOe: dut.output('dat_oe'),
  );
  clk.inject(0);
  reset.inject(1);
  cmdIn.inject(1);
  datIn.inject(1);
  respStart.inject(0);
  respData.inject(0);
  respKind.inject(sdRespKindR1);
  datRxEnable.inject(0);
  datStatusSend.inject(0);
  datStatusCode.inject(0);
  Simulator.setMaxSimTime(2000000);
  unawaited(Simulator.run());
  await host.tick();
  await host.tick();
  reset.inject(0);
  await host.idle(sdCommandGapClocks);
  return (
    dut: dut,
    host: host,
    reset: reset,
    respStart: respStart,
    respData: respData,
    respKind: respKind,
    datStatusSend: datStatusSend,
    datStatusCode: datStatusCode,
  );
}

/// Packs [bytes] into the 128-bit register that an R2 response carries.
///
/// The first byte of the list is the first byte on the wire, so it holds
/// the most significant bits of the register.
BigInt _reg128(List<int> bytes) {
  var value = BigInt.zero;
  for (final b in bytes) {
    value = (value << 8) | BigInt.from(b);
  }
  return value;
}

/// Builds a host with a card that the test drives by hand.
///
/// The link builds every frame it sends, so it cannot send a bad CRC7 and
/// it cannot leave a line undriven. A test that needs a card fault of that
/// shape drives the four card signals itself.
Future<
  ({
    SdHost host,
    Logic cardCmd,
    Logic cardCmdOe,
    Logic cardDat,
    Logic cardDatOe,
  })
>
_handCard({int cmd = 1, int cmdOe = 0, int dat = 1, int datOe = 0}) async {
  final clk = Logic(name: 'clk');
  final cmdIn = Logic(name: 'cmd_in');
  final datIn = Logic(name: 'dat_in');
  final cardCmd = Logic(name: 'card_cmd');
  final cardCmdOe = Logic(name: 'card_cmd_oe');
  final cardDat = Logic(name: 'card_dat');
  final cardDatOe = Logic(name: 'card_dat_oe');
  final host = SdHost(
    clk: clk,
    cmdOut: cmdIn,
    datOut: datIn,
    cardCmd: cardCmd,
    cardCmdOe: cardCmdOe,
    cardDat: cardDat,
    cardDatOe: cardDatOe,
  );
  clk.inject(0);
  cmdIn.inject(1);
  datIn.inject(1);
  cardCmd.inject(cmd);
  cardCmdOe.inject(cmdOe);
  cardDat.inject(dat);
  cardDatOe.inject(datOe);
  Simulator.setMaxSimTime(100000);
  unawaited(Simulator.run());
  // An injected value lands when the simulator next runs, so let it run
  // one time unit. The card holds the first bit from then on, which is
  // what a caller of _driveBits counts from.
  await host.park(1);
  return (
    host: host,
    cardCmd: cardCmd,
    cardCmdOe: cardCmdOe,
    cardDat: cardDat,
    cardDatOe: cardDatOe,
  );
}

/// Puts [bits] on [line], one bit each clock. A bit of -1 leaves the line
/// undriven for that clock.
///
/// The first bit must be on the line already, because the host reads the
/// line as soon as it starts. One clock is 10 simulated time units, so each
/// action lands inside the clock in front of the read that takes the bit.
void _driveBits(Logic line, List<int> bits) {
  final start = Simulator.time;
  for (var i = 1; i < bits.length; i++) {
    final bit = bits[i];
    Simulator.registerAction(
      start + 10 * i - 3,
      () => line.inject(bit < 0 ? LogicValue.x : LogicValue.ofInt(bit, 1)),
    );
  }
}

/// Builds the 48 bits of a short response frame, most significant bit
/// first.
///
/// The bits are the start bit 0, the transmission bit 0, the 6 bits of
/// [field], the 32 bits of [payload], the 7 bits of [crc] and the end bit
/// 1. The caller gives the CRC, so a test can build a frame that carries a
/// CRC7 no card would compute.
List<int> _shortFrame(int field, int payload, int crc) {
  final bits = <int>[0, 0];
  for (var i = sdCommandIndexBits - 1; i >= 0; i--) {
    bits.add((field >> i) & 1);
  }
  for (var i = sdCommandArgBits - 1; i >= 0; i--) {
    bits.add((payload >> i) & 1);
  }
  for (var i = 6; i >= 0; i--) {
    bits.add((crc >> i) & 1);
  }
  return bits..add(1);
}

/// Pulses resp_start for one clock with [data] and [kind] on the ports.
Future<void> _startResponse(
  ({
    MimicSdLink dut,
    SdHost host,
    Logic reset,
    Logic respStart,
    Logic respData,
    Logic respKind,
    Logic datStatusSend,
    Logic datStatusCode,
  })
  s,
  LogicValue data,
  int kind,
) async {
  s.respData.inject(data);
  s.respKind.inject(kind);
  s.respStart.inject(1);
  await s.host.tick();
  s.respStart.inject(0);
}

/// The 32-bit status of a card in the transfer state, as an R1 carries it.
const int _status = 0x00000900;

void main() {
  tearDown(Simulator.reset);

  group('receiveResponse', () {
    test('reads back an R1 with the index, the status and the CRC7', () async {
      final s = await _setUp();

      await s.host.sendCommand(17, 0x00001234);
      await s.host.idle(3);
      await _startResponse(
        s,
        LogicValue.ofInt((17 << sdCommandArgBits) | _status, sdResponseRegBits),
        sdRespKindR1,
      );

      final r = await s.host.receiveResponse(SdResponseKind.r1);

      expect(r.timedOut, isFalse, reason: 'the card answered');
      expect(r.bits, hasLength(sdCommandBits), reason: 'an R1 is 48 bits');
      expect(r.framingOk, isTrue, reason: 'start 0, transmission 0, end 1');
      expect(r.field, equals(17), reason: 'the index field holds CMD17');
      expect(r.payload, equals(_status), reason: 'the 32-bit status');
      // The CRC7 covers the 40 leading bits: the two header bits, the
      // index 17 and the status.
      expect(r.crc, equals(sdCrc7([0x11, 0x00, 0x00, 0x09, 0x00])));
      expect(r.crcOk, isTrue, reason: 'the CRC7 the link built checks out');
      expect(r.register, equals(BigInt.zero), reason: 'a short frame');
      expect(r.fixedFieldOk, isNull, reason: 'only an R3 has a fixed field');
      await Simulator.endSimulation();
    });

    test('reports a bad CRC7 when a payload bit is corrupted', () async {
      final s = await _setUp();

      await s.host.sendCommand(17, 0x00001234);
      await s.host.idle(3);
      await _startResponse(
        s,
        LogicValue.ofInt((17 << sdCommandArgBits) | _status, sdResponseRegBits),
        sdRespKindR1,
      );

      final good = await s.host.receiveResponse(SdResponseKind.r1);
      expect(good.crcOk, isTrue, reason: 'the frame on the wire is good');

      // Corrupt one bit of the status and decode the frame again. The CRC7
      // field still holds the value for the frame the link sent, so the
      // check must now fail. A model that skips the check reports a good
      // CRC for data that no card sent.
      final badPayload = List<int>.of(good.bits);
      badPayload[20] ^= 1;
      final r1 = SdResponse.decode(SdResponseKind.r1, badPayload);
      expect(r1.crcOk, isFalse, reason: 'a flipped status bit breaks the CRC7');
      expect(r1.framingOk, isTrue, reason: 'the framing is still good');

      // A flipped CRC bit must fail in the same way.
      final badCrc = List<int>.of(good.bits);
      badCrc[sdCommandCrcBits + 2] ^= 1;
      expect(
        SdResponse.decode(SdResponseKind.r1, badCrc).crcOk,
        isFalse,
        reason: 'a flipped CRC bit breaks the CRC7',
      );
      await Simulator.endSimulation();
    });

    test('reads back an R3 with the OCR and the fixed field', () async {
      final s = await _setUp();

      // The OCR of a ready high capacity card.
      const ocr = 0xC0FF8000;
      await s.host.sendCommand(41, 0x40FF8000);
      await s.host.idle(3);
      await _startResponse(
        s,
        LogicValue.ofInt(ocr, sdResponseRegBits),
        sdRespKindR3,
      );

      final r = await s.host.receiveResponse(SdResponseKind.r3);

      expect(r.timedOut, isFalse, reason: 'the card answered');
      expect(r.bits, hasLength(sdCommandBits), reason: 'an R3 is 48 bits');
      expect(r.framingOk, isTrue, reason: 'start 0, transmission 0, end 1');
      expect(r.field, equals(0x3F), reason: 'the reserved field is 111111');
      expect(r.payload, equals(ocr), reason: 'the OCR');
      expect(r.crc, equals(0x7F), reason: 'bits 7 to 1 are the fixed 1111111');
      expect(r.fixedFieldOk, isTrue, reason: 'the host reads the fixed field');
      expect(r.crcOk, isNull, reason: 'an R3 carries no CRC to check');
      await Simulator.endSimulation();
    });

    test('sees a bad fixed field in an R3 as data, not as a CRC', () async {
      final s = await _setUp();

      // The fourth value of resp_kind gives a short frame with the
      // reserved field and a CRC7 that the link computes, so its bits 7 to
      // 1 are not the fixed 1111111 that a real R3 carries. A host that
      // reads that frame as an R3 must see the field fail.
      const ocr = 0xC0FF8000;
      await s.host.sendCommand(41, 0x40FF8000);
      await s.host.idle(3);
      await _startResponse(s, LogicValue.ofInt(ocr, sdResponseRegBits), 3);

      // strict is off, because a bad fixed field is a card fault and the
      // host throws on it while strict is on. This test reads the verdict
      // instead, so the escape hatch has to be open.
      final r = await s.host.receiveResponse(SdResponseKind.r3, strict: false);
      expect(r.payload, equals(ocr), reason: 'the payload still decodes');
      expect(r.crc, isNot(equals(0x7F)), reason: 'the link computed a CRC7');
      expect(r.fixedFieldOk, isFalse, reason: 'the fixed field is not ones');
      await Simulator.endSimulation();
    });

    test('reads back the 128-bit register of an R2', () async {
      final s = await _setUp();

      // A CID with its own CRC7 in bits 7 to 1 of the last byte and the
      // end bit in bit 0.
      final cid = <int>[
        0x03, 0x53, 0x44, 0x4D, 0x49, 0x4D, 0x49, 0x43, //
        0x10, 0x12, 0x34, 0x56, 0x78, 0x01, 0x5A, 0xC3,
      ];
      expect(
        (cid.last >> 1) & 0x7F,
        equals(sdCrc7(cid.sublist(0, 15))),
        reason: 'the register carries the CRC7 that the caller built',
      );

      await s.host.sendCommand(2, 0x00000000);
      await s.host.idle(3);
      await _startResponse(
        s,
        LogicValue.ofBigInt(_reg128(cid), sdResponseRegBits),
        sdRespKindR2,
      );

      final r = await s.host.receiveResponse(SdResponseKind.r2);

      expect(r.timedOut, isFalse, reason: 'the card answered');
      expect(r.bits, hasLength(sdResponseLongBits), reason: 'an R2 is 136');
      expect(r.framingOk, isTrue, reason: 'start 0, transmission 0, end 1');
      expect(r.field, equals(0x3F), reason: 'the reserved field is 111111');
      expect(r.register, equals(_reg128(cid)), reason: 'the CID verbatim');
      expect(r.payload, equals(0), reason: 'an R2 has no 32-bit payload');
      expect(r.crcOk, isNull, reason: 'the register holds its own CRC7');
      expect(r.fixedFieldOk, isNull, reason: 'an R2 has no fixed field');

      // The CRC7 inside the register is the one a host checks, and the
      // model gives the bits back so a test can check it.
      final regBytes = <int>[];
      for (var i = 0; i < 16; i++) {
        var b = 0;
        for (var j = 0; j < 8; j++) {
          b = (b << 1) | r.bits[sdResponseHeaderBits + i * 8 + j];
        }
        regBytes.add(b);
      }
      expect(regBytes, equals(cid), reason: 'the register bytes in order');
      await Simulator.endSimulation();
    });

    test('measures Ncr and keeps a response inside the window', () async {
      final s = await _setUp();

      await s.host.sendCommand(17, 0x00001234);
      await s.host.idle(3);
      await _startResponse(
        s,
        LogicValue.ofInt((17 << sdCommandArgBits) | _status, sdResponseRegBits),
        sdRespKindR1,
      );

      final r = await s.host.receiveResponse(SdResponseKind.r1);

      // The gap is the 3 idle clocks, the clock that carried resp_start
      // and the clock that carried the start bit, counted from the end bit
      // of the command.
      expect(r.ncr, equals(5), reason: 'Ncr in clocks from the end bit');
      expect(r.ncrInWindow, isTrue, reason: '5 is inside 2 to 64');
      await Simulator.endSimulation();
    });

    test('reads the shortest legal Ncr as 2 clocks', () async {
      final s = await _setUp();

      // The link raises cmd_oe on the clock edge that samples resp_start,
      // so the start bit comes 2 clocks after the end bit. That is the
      // smallest gap the specification allows, and the model must not read
      // it as smaller.
      await s.host.sendCommand(17, 0x00001234);
      await _startResponse(
        s,
        LogicValue.ofInt((17 << sdCommandArgBits) | _status, sdResponseRegBits),
        sdRespKindR1,
      );

      final r = await s.host.receiveResponse(SdResponseKind.r1);
      expect(r.ncr, equals(sdNcrMin), reason: 'the shortest legal gap');
      expect(r.ncrInWindow, isTrue, reason: '2 is inside the window');
      expect(r.crcOk, isTrue, reason: 'the frame still decodes');
      await Simulator.endSimulation();
    });

    test('refuses a response that comes after the Ncr window', () async {
      final s = await _setUp();

      await s.host.sendCommand(17, 0x00001234);
      await s.host.idle(sdNcrMax + 4);
      await _startResponse(
        s,
        LogicValue.ofInt((17 << sdCommandArgBits) | _status, sdResponseRegBits),
        sdRespKindR1,
      );

      await expectLater(
        s.host.receiveResponse(SdResponseKind.r1),
        throwsA(isA<StateError>()),
        reason: 'a late response is a fault, not a quiet pass',
      );
      await Simulator.endSimulation();
    });

    test('reports a late Ncr as data while strict is off', () async {
      final s = await _setUp();

      await s.host.sendCommand(17, 0x00001234);
      await s.host.idle(sdNcrMax + 4);
      await _startResponse(
        s,
        LogicValue.ofInt((17 << sdCommandArgBits) | _status, sdResponseRegBits),
        sdRespKindR1,
      );

      final r = await s.host.receiveResponse(
        SdResponseKind.r1,
        strict: false,
        timeoutClocks: 8,
      );
      expect(r.ncr, equals(sdNcrMax + 6), reason: 'the measured gap');
      expect(r.ncrInWindow, isFalse, reason: 'the gap is outside the window');
      expect(r.crcOk, isTrue, reason: 'the frame itself is good');
      await Simulator.endSimulation();
    });

    test('reports a timeout when no response comes', () async {
      final s = await _setUp();

      await s.host.sendCommand(17, 0x00001234);
      final r = await s.host.receiveResponse(
        SdResponseKind.r1,
        timeoutClocks: 16,
      );

      expect(r.timedOut, isTrue, reason: 'the card never answered');
      expect(r.bits, isEmpty, reason: 'a timeout carries no frame');
      expect(r.crcOk, isNull, reason: 'there is nothing to check');
      expect(r.framingOk, isFalse, reason: 'no frame is not a framed frame');
      await Simulator.endSimulation();
    });

    test('needs the card tied to the host', () async {
      final host = SdHost(
        clk: Logic(name: 'clk'),
        cmdOut: Logic(name: 'cmd_in'),
        datOut: Logic(name: 'dat_in'),
      );
      await expectLater(
        host.receiveResponse(SdResponseKind.r1),
        throwsA(isA<StateError>()),
        reason: 'a host with no tie can read nothing',
      );
    });

    test('refuses a bad CRC7 while strict is on', () async {
      // The link builds the CRC7 of every frame it sends, so a hand made
      // card drives the bits. A test that calls receiveResponse and forgets
      // to look at crcOk must not pass against a card like this.
      final c = await _handCard(cmd: 0, cmdOe: 1);
      final crc = sdCrc7([0x11, 0x00, 0x00, 0x09, 0x00]);
      _driveBits(c.cardCmd, _shortFrame(17, _status, crc ^ 1));

      await expectLater(
        c.host.receiveResponse(SdResponseKind.r1),
        throwsA(isA<StateError>()),
        reason: 'a bad CRC7 is a card fault, not a quiet pass',
      );
      await Simulator.endSimulation();
    });

    test('gives a bad CRC7 back as data while strict is off', () async {
      final c = await _handCard(cmd: 0, cmdOe: 1);
      final crc = sdCrc7([0x11, 0x00, 0x00, 0x09, 0x00]);
      _driveBits(c.cardCmd, _shortFrame(17, _status, crc ^ 1));

      final r = await c.host.receiveResponse(SdResponseKind.r1, strict: false);
      expect(r.crcOk, isFalse, reason: 'the CRC7 does not match the frame');
      expect(r.framingOk, isTrue, reason: 'the framing is still good');
      expect(r.payload, equals(_status), reason: 'the payload still decodes');
      await Simulator.endSimulation();
    });

    test('refuses a bad R3 fixed field while strict is on', () async {
      // The fourth value of resp_kind gives a short frame with a CRC7 in
      // bits 7 to 1, so a host that reads it as an R3 sees a fixed field
      // that is not 1111111.
      final s = await _setUp();
      await s.host.sendCommand(41, 0x40FF8000);
      await s.host.idle(3);
      await _startResponse(
        s,
        LogicValue.ofInt(0xC0FF8000, sdResponseRegBits),
        3,
      );

      await expectLater(
        s.host.receiveResponse(SdResponseKind.r3),
        throwsA(isA<StateError>()),
        reason: 'a bad fixed field is a card fault, not a quiet pass',
      );
      await Simulator.endSimulation();
    });

    test('reports no Ncr for a response with no command in front', () async {
      final s = await _setUp();

      await s.host.sendCommand(17, 0x00001234);
      await s.host.idle(3);
      await _startResponse(
        s,
        LogicValue.ofInt((17 << sdCommandArgBits) | _status, sdResponseRegBits),
        sdRespKindR1,
      );
      final first = await s.host.receiveResponse(SdResponseKind.r1);
      expect(first.ncr, equals(5), reason: 'the gap of the first response');

      // The first response used the end bit of the command up. A second
      // response with no command in front of it has no gap to measure, so
      // the host must report no Ncr and not a gap from the old command.
      await s.host.idle(sdCommandGapClocks);
      await _startResponse(
        s,
        LogicValue.ofInt((17 << sdCommandArgBits) | _status, sdResponseRegBits),
        sdRespKindR1,
      );
      final second = await s.host.receiveResponse(SdResponseKind.r1);
      expect(second.ncr, isNull, reason: 'no command came in front of it');
      expect(second.ncrInWindow, isNull, reason: 'no gap gives no verdict');
      expect(second.crcOk, isTrue, reason: 'the frame itself is good');
      await Simulator.endSimulation();
    });
  });

  group('the Ncr window', () {
    // The model measures Ncr as startClock - endClock and takes
    // sdNcrMin to sdNcrMax. These tests pin both edges, so a change of
    // either bound shows up as a test change and not as a quiet change of
    // behaviour. The note on sdNcrMin holds the open question about the
    // convention: the MMC reading of two Z bits after the end bit gives 3
    // and 65 instead of 2 and 64.
    List<int> framed() {
      final bits = List<int>.filled(sdCommandBits, 0);
      bits[bits.length - 1] = 1;
      return bits;
    }

    bool? windowAt(int? ncr) =>
        SdResponse.decode(SdResponseKind.r1, framed(), ncr: ncr).ncrInWindow;

    test('refuses a gap of 1 clock', () {
      expect(windowAt(1), isFalse, reason: '1 clock is shorter than sdNcrMin');
    });

    test('takes the shortest gap of 2 clocks', () {
      expect(sdNcrMin, equals(2), reason: 'the bound this model uses');
      expect(windowAt(2), isTrue, reason: '2 clocks is sdNcrMin');
    });

    test('takes a gap of 64 clocks and refuses 65', () {
      expect(sdNcrMax, equals(64), reason: 'the bound this model uses');
      expect(windowAt(64), isTrue, reason: '64 clocks is sdNcrMax');
      expect(windowAt(65), isFalse, reason: '65 is one clock past sdNcrMax');
    });

    test('gives no verdict without a command', () {
      expect(windowAt(null), isNull, reason: 'no end bit to measure from');
    });
  });

  group('bus tie', () {
    test('puts the card drive on CMD while the host stays released', () async {
      final s = await _setUp();

      await _startResponse(
        s,
        LogicValue.ofInt((17 << sdCommandArgBits) | _status, sdResponseRegBits),
        sdRespKindR1,
      );

      // The host holds its own drive high for the whole frame. The line
      // must still carry every bit the card sends, because the tie gives
      // the line to the card while cmd_oe is high. The device samples
      // cmd_in on the rising edge of each clock, so the check reads
      // cmd_in after the clock that carried the bit.
      var sawLow = false;
      for (var i = 0; i < sdCommandBits; i++) {
        final cardBit = s.dut.output('cmd_out').value;
        expect(
          s.host.cmdLine,
          equals(cardBit),
          reason: 'the CMD line is the card drive for bit $i',
        );
        if (cardBit == LogicValue.zero) sawLow = true;
        await s.host.tick();
        expect(
          s.dut.input('cmd_in').value,
          equals(cardBit),
          reason: 'the device saw its own bit $i on cmd_in',
        );
      }
      expect(sawLow, isTrue, reason: 'the frame holds low bits');

      // The card released the bus, so the line goes back to the host.
      expect(s.dut.output('cmd_oe').value.toInt(), equals(0));
      s.host.driveCmd(0);
      expect(
        s.host.cmdLine,
        equals(LogicValue.zero),
        reason: 'the host owns CMD again',
      );
      await s.host.tick();
      expect(
        s.dut.input('cmd_in').value,
        equals(LogicValue.zero),
        reason: 'the device sees the host drive',
      );
      await Simulator.endSimulation();
    });

    test('puts the card drive on DAT while the host stays released', () async {
      final s = await _setUp();

      s.datStatusCode.inject(SdStatusToken.accepted.code);
      s.datStatusSend.inject(1);
      await s.host.tick();
      s.datStatusSend.inject(0);

      for (var i = 0; i < sdStatusTokenBits; i++) {
        final cardBit = s.dut.output('dat_out').value;
        expect(
          s.host.datLine,
          equals(cardBit),
          reason: 'the DAT line is the card drive for token bit $i',
        );
        await s.host.tick();
        expect(
          s.dut.input('dat_in').value,
          equals(cardBit),
          reason: 'the device saw its own token bit $i on dat_in',
        );
      }
      expect(s.dut.output('dat_oe').value.toInt(), equals(0));
      s.host.driveDat(0);
      expect(
        s.host.datLine,
        equals(LogicValue.zero),
        reason: 'the host owns DAT again',
      );
      await s.host.tick();
      expect(
        s.dut.input('dat_in').value,
        equals(LogicValue.zero),
        reason: 'the device sees the host drive',
      );
      await Simulator.endSimulation();
    });

    test('refuses an X on a card output enable', () async {
      // The tie reads the output enable to find out who drives the line.
      // An X there is a card fault, and a tie that reads it as low gives
      // the line back to the host and hides the fault.
      final c = await _handCard();
      await c.host.tick();

      c.cardCmdOe.inject(LogicValue.x);
      await c.host.park(1);
      expect(
        () => c.host.cmdLine,
        throwsA(isA<StateError>()),
        reason: 'an X on cmd_oe must be loud',
      );

      c.cardCmdOe.inject(0);
      c.cardDatOe.inject(LogicValue.x);
      await c.host.park(1);
      expect(
        () => c.host.datLine,
        throwsA(isA<StateError>()),
        reason: 'an X on dat_oe must be loud',
      );

      c.cardDatOe.inject(0);
      await c.host.park(1);
      expect(
        c.host.cmdLine,
        equals(LogicValue.one),
        reason: 'a valid enable gives the line back to the host',
      );
      await Simulator.endSimulation();
    });
  });

  group('sendDataBlock', () {
    test('leaves the upper data lines released at a wide bus', () async {
      // The link takes bus width 1 only today, so no card can show this.
      // The host model must still put the block on DAT0 and leave DAT3 to
      // DAT1 released, because a host that pulls them low for a whole
      // block breaks a card that reads all four lines.
      final clk = Logic(name: 'clk');
      final cmdIn = Logic(name: 'cmd_in');
      final datIn = Logic(name: 'dat_in', width: 4);
      final host = SdHost(clk: clk, cmdOut: cmdIn, datOut: datIn, busWidth: 4);
      final seen = <LogicValue>[];
      final sub = datIn.changed.listen((e) => seen.add(e.newValue));

      clk.inject(0);
      cmdIn.inject(1);
      datIn.inject(LogicValue.filled(4, LogicValue.one));
      Simulator.setMaxSimTime(100000);
      unawaited(Simulator.run());
      await host.idle(2);
      await host.sendDataBlock(<int>[0x00, 0xFF, 0x5A]);
      await host.idle(2);
      await sub.cancel();

      expect(seen, isNotEmpty, reason: 'the block moved the lines');
      for (final v in seen) {
        expect(
          v.slice(3, 1),
          equals(LogicValue.filled(3, LogicValue.one)),
          reason: 'DAT3 to DAT1 stay released for the value $v',
        );
      }
      expect(
        seen.any((v) => v[0] == LogicValue.zero),
        isTrue,
        reason: 'the block drove DAT0 low',
      );
      await Simulator.endSimulation();
    });

    test('refuses a byte that is not 8 bits before it drives', () async {
      // The CRC16 reads 8 bits of each entry, so an entry outside 0 to 255
      // is a fault. The host must find it before the start bit goes out,
      // because a throw in the middle of a block leaves the card inside a
      // block that never ends.
      final clk = Logic(name: 'clk');
      final cmdIn = Logic(name: 'cmd_in');
      final datIn = Logic(name: 'dat_in');
      final host = SdHost(clk: clk, cmdOut: cmdIn, datOut: datIn);
      final seen = <LogicValue>[];
      final sub = datIn.changed.listen((e) => seen.add(e.newValue));

      clk.inject(0);
      cmdIn.inject(1);
      datIn.inject(1);
      Simulator.setMaxSimTime(100000);
      unawaited(Simulator.run());
      await host.idle(2);

      await expectLater(
        host.sendDataBlock(<int>[0x00, 0x1FF, 0x5A]),
        throwsA(isA<ArgumentError>()),
        reason: '0x1FF does not fit one byte',
      );

      await host.idle(2);
      await sub.cancel();
      expect(
        seen.any((v) => v[0] == LogicValue.zero),
        isFalse,
        reason: 'no bit of the block went on the wire',
      );
      await Simulator.endSimulation();
    });
  });

  group('receiveStatusToken', () {
    test('reads the accepted token off DAT0', () async {
      final s = await _setUp();

      s.datStatusCode.inject(SdStatusToken.accepted.code);
      s.datStatusSend.inject(1);
      await s.host.tick();
      s.datStatusSend.inject(0);

      final r = await s.host.receiveStatusToken();

      expect(r.timedOut, isFalse, reason: 'the card sent a token');
      expect(r.bits, equals([0, 0, 1, 0, 1]), reason: 'start, 010, stop');
      expect(r.code, equals(0x2), reason: 'the three status bits');
      expect(r.token, equals(SdStatusToken.accepted), reason: '010 accepted');
      expect(r.framingOk, isTrue, reason: 'start 0 and stop 1');
      expect(r.gap, equals(0), reason: 'the token was on the line already');
      await Simulator.endSimulation();
    });

    test('reads the CRC error and the write error tokens', () async {
      final s = await _setUp();

      Future<SdStatusResult> send(int code) async {
        s.datStatusCode.inject(code);
        s.datStatusSend.inject(1);
        await s.host.tick();
        s.datStatusSend.inject(0);
        final r = await s.host.receiveStatusToken();
        await s.host.idle(4);
        return r;
      }

      final crc = await send(SdStatusToken.crcError.code);
      expect(crc.bits, equals([0, 1, 0, 1, 1]), reason: 'start, 101, stop');
      expect(crc.token, equals(SdStatusToken.crcError), reason: '101');

      final write = await send(SdStatusToken.writeError.code);
      expect(write.bits, equals([0, 1, 1, 0, 1]), reason: 'start, 110, stop');
      expect(write.token, equals(SdStatusToken.writeError), reason: '110');

      // A code the specification does not give must not read as one of the
      // three. 000 is the one the line gives when a card holds DAT0 low.
      final none = await send(0);
      expect(none.code, equals(0), reason: 'the three bits came back');
      expect(none.token, equals(SdStatusToken.unknown), reason: '000');
      await Simulator.endSimulation();
    });

    test('reports a timeout when no token comes', () async {
      final s = await _setUp();
      final r = await s.host.receiveStatusToken(timeoutClocks: 12);
      expect(r.timedOut, isTrue, reason: 'the card sent no token');
      expect(r.bits, isEmpty, reason: 'a timeout carries no token');
      expect(r.token, equals(SdStatusToken.unknown), reason: 'nothing to read');
      expect(r.gap, equals(12), reason: 'the host waited the whole timeout');
      await Simulator.endSimulation();
    });

    test('refuses an X on a status bit', () async {
      // The card drives the start bit 0, then leaves DAT0 undriven for the
      // first status bit, then sends 1, 0 and the stop bit 1. A host that
      // reads the undriven bit as a 1 sees the code 110, which is a clean
      // write error from a card that is broken.
      final c = await _handCard(dat: 0, datOe: 1);
      _driveBits(c.cardDat, <int>[0, -1, 1, 0, 1]);

      await expectLater(
        c.host.receiveStatusToken(),
        throwsA(isA<StateError>()),
        reason: 'an undriven bit has no code',
      );
      await Simulator.endSimulation();
    });

    test('refuses an X on a status bit while strict is off', () async {
      // strict is about a card that breaks a rule the host can still read.
      // An undriven bit is not readable at all, so it throws either way.
      final c = await _handCard(dat: 0, datOe: 1);
      _driveBits(c.cardDat, <int>[0, -1, 1, 0, 1]);

      await expectLater(
        c.host.receiveStatusToken(strict: false),
        throwsA(isA<StateError>()),
        reason: 'strict off does not make an undriven bit readable',
      );
      await Simulator.endSimulation();
    });
  });

  group('waitBusy', () {
    test('returns as soon as DAT0 is high', () async {
      final s = await _setUp();
      final r = await s.host.waitBusy();
      expect(r.timedOut, isFalse, reason: 'the line is free');
      expect(r.clocks, equals(0), reason: 'the host waited no clock');
      await Simulator.endSimulation();
    });

    test('counts the clocks that DAT0 stays low', () async {
      final s = await _setUp();

      // The link holds DAT0 low for no clock of its own, because the busy
      // state belongs to a card personality and not to the link. The host
      // therefore holds the line low itself and releases it inside the
      // last busy clock, after the rising edge of that clock. One clock is
      // 10 simulated time units and the rising edge is 5 units into it.
      const busyClocks = 6;
      s.host.driveDat(0);
      Simulator.registerAction(
        Simulator.time + 10 * busyClocks - 3,
        () => s.host.driveDat(1),
      );

      final r = await s.host.waitBusy();
      expect(r.timedOut, isFalse, reason: 'the card released the line');
      expect(r.clocks, equals(busyClocks), reason: 'the busy clocks');
      await Simulator.endSimulation();
    });

    test('reports a timeout when DAT0 stays low', () async {
      final s = await _setUp();
      s.host.driveDat(0);
      final r = await s.host.waitBusy(timeoutClocks: 20);
      expect(r.timedOut, isTrue, reason: 'the line never went high');
      expect(r.clocks, equals(20), reason: 'the host waited the whole timeout');
      await Simulator.endSimulation();
    });
  });

  group('the golden model refuses a value it cannot send', () {
    test('sdCommandFrame refuses an index that is not 6 bits', () {
      for (final index in [-1, 64, 0x40, 1000]) {
        expect(
          () => sdCommandFrame(index, 0),
          throwsA(isA<ArgumentError>()),
          reason: 'the index $index does not fit the field',
        );
      }
      expect(sdCommandFrame(63, 0).first, equals(0x7F), reason: '63 fits');
    });

    test('sdCommandFrame refuses an argument that is not 32 bits', () {
      for (final arg in [-1, 0x100000000, 0x1FFFFFFFF]) {
        expect(
          () => sdCommandFrame(0, arg),
          throwsA(isA<ArgumentError>()),
          reason: 'the argument $arg does not fit the field',
        );
      }
      expect(
        sdCommandFrame(0, 0xFFFFFFFF).sublist(1, 5),
        equals([0xFF, 0xFF, 0xFF, 0xFF]),
        reason: '0xFFFFFFFF fits',
      );
    });

    test('the CRC helpers refuse an entry that is not a byte', () {
      for (final bad in [-1, 256, 0x1FF]) {
        expect(
          () => sdCrc7([0x40, bad, 0x00, 0x00, 0x00]),
          throwsA(isA<ArgumentError>()),
          reason: 'sdCrc7 reads 8 bits of the entry $bad',
        );
        expect(
          () => sdCrc16([0x00, bad]),
          throwsA(isA<ArgumentError>()),
          reason: 'sdCrc16 reads 8 bits of the entry $bad',
        );
      }
    });

    test('decode refuses a frame of the wrong length', () {
      expect(
        () => SdResponse.decode(SdResponseKind.r1, List<int>.filled(47, 1)),
        throwsA(isA<ArgumentError>()),
        reason: 'an R1 is 48 bits',
      );
      expect(
        () => SdResponse.decode(SdResponseKind.r2, List<int>.filled(48, 1)),
        throwsA(isA<ArgumentError>()),
        reason: 'an R2 is 136 bits',
      );
    });

    test('decode refuses a frame that is not framed', () {
      final bits = List<int>.filled(sdCommandBits, 0);
      bits[bits.length - 1] = 1;
      expect(
        () => SdResponse.decode(SdResponseKind.r1, bits),
        returnsNormally,
        reason: 'start 0, transmission 0 and end 1 is framed',
      );

      final noEnd = List<int>.of(bits)..[bits.length - 1] = 0;
      expect(
        () => SdResponse.decode(SdResponseKind.r1, noEnd),
        throwsA(isA<StateError>()),
        reason: 'a frame with no end bit is a fault',
      );
      expect(
        SdResponse.decode(SdResponseKind.r1, noEnd, strict: false).framingOk,
        isFalse,
        reason: 'strict off gives the verdict back instead',
      );

      final host = List<int>.of(bits)..[1] = 1;
      expect(
        () => SdResponse.decode(SdResponseKind.r1, host),
        throwsA(isA<StateError>()),
        reason: 'a 1 transmission bit is a command, not a response',
      );
    });
  });
}
