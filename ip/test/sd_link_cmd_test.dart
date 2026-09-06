// Command tests for MimicSdLink.
//
// The host model drives the clock and the CMD line. The tests watch the
// link for the cmd_valid pulse and read the framed index, argument and CRC
// result in that cycle. They also drive the response path and check the
// bits the card puts back on CMD.

import 'dart:async';

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';

/// Collects one record for each cmd_valid pulse.
///
/// cmd_valid and cmd_crc_ok are both registers and change on the same clock
/// edge. Reading them from a listener on one of the two makes the result
/// depend on the order of the events. This monitor reads every output at
/// the postTick event instead, which the simulator raises after all values
/// of the clock settle, so the four outputs always belong to the same
/// clock.
class _FrameMonitor {
  /// The link under test.
  final MimicSdLink dut;

  /// One record for each cmd_valid pulse, in order.
  final List<({int index, int arg, bool crcOk})> frames = [];

  /// True if cmd_crc_ok was ever high while cmd_valid was low.
  bool crcOkOutsidePulse = false;

  bool _wasValid = false;
  late final StreamSubscription<void> _sub;

  _FrameMonitor(this.dut) {
    _sub = Simulator.postTick.listen((_) {
      final valid = dut.output('cmd_valid').value == LogicValue.one;
      final crcOk = dut.output('cmd_crc_ok').value == LogicValue.one;
      if (valid && !_wasValid) {
        frames.add((
          index: dut.output('cmd_index').value.toInt(),
          arg: dut.output('cmd_arg').value.toInt(),
          crcOk: crcOk,
        ));
      }
      if (!valid && crcOk) {
        crcOkOutsidePulse = true;
      }
      _wasValid = valid;
    });
  }

  /// Stops the monitor.
  Future<void> stop() => _sub.cancel();
}

/// Builds the link with a host driving it. Returns the parts a test needs.
///
/// The setup releases reset and then holds CMD high for
/// [sdCommandGapClocks] clocks, which is the gap that arms the framer. Set
/// [holdReset] to keep reset high instead, so a test can release it at a
/// point of its own choice.
Future<
  ({
    MimicSdLink dut,
    SdHost host,
    Logic reset,
    Logic respStart,
    Logic respData,
    Logic respKind,
  })
>
_setUp({bool holdReset = false}) async {
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
  final datStatusCode = Logic(name: 'dat_status_code', width: 3);

  dut.input('clk').srcConnection! <= clk;
  dut.input('reset').srcConnection! <= reset;
  dut.input('cmd_in').srcConnection! <= cmdIn;
  dut.input('dat_in').srcConnection! <= datIn;
  dut.input('resp_start').srcConnection! <= respStart;
  dut.input('resp_data').srcConnection! <= respData;
  dut.input('resp_kind').srcConnection! <= respKind;
  // The data ports take part in no command test, but an input that nothing
  // drives holds X. X on dat_rx_enable or dat_status_send goes straight
  // into the data receive registers as soon as a test pulls dat_in low.
  // Hold all three low instead.
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
  if (!holdReset) {
    reset.inject(0);
    await host.idle(sdCommandGapClocks);
  }
  return (
    dut: dut,
    host: host,
    reset: reset,
    respStart: respStart,
    respData: respData,
    respKind: respKind,
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

/// Reads [count] frame bits off CMD while the card drives the bus.
///
/// It checks that cmd_oe and resp_busy stay high for every bit and that
/// both fall in the clock after the last bit, which proves the frame has
/// the length that the kind asks for.
Future<List<int>> _readFrame(MimicSdLink dut, SdHost host, int count) async {
  final bits = <int>[];
  for (var i = 0; i < count; i++) {
    expect(
      dut.output('cmd_oe').value.toInt(),
      equals(1),
      reason: 'the card drives CMD for bit $i of $count',
    );
    expect(
      dut.output('resp_busy').value.toInt(),
      equals(1),
      reason: 'resp_busy is high for bit $i of $count',
    );
    bits.add(dut.output('cmd_out').value.toInt());
    await host.tick();
  }
  expect(
    dut.output('cmd_oe').value.toInt(),
    equals(0),
    reason: 'the card releases CMD after $count bits',
  );
  expect(
    dut.output('resp_busy').value.toInt(),
    equals(0),
    reason: 'resp_busy falls with cmd_oe after $count bits',
  );
  return bits;
}

/// Packs [bits] into bytes, most significant bit first.
List<int> _packBytes(List<int> bits) {
  final bytes = <int>[];
  for (var i = 0; i < bits.length; i += 8) {
    var b = 0;
    for (var j = 0; j < 8; j++) {
      b = (b << 1) | bits[i + j];
    }
    bytes.add(b);
  }
  return bytes;
}

/// Sends the 48 raw bits of [frame] on CMD, most significant bit first.
Future<void> _sendBytes(SdHost host, List<int> frame) async {
  for (final b in frame) {
    for (var i = 7; i >= 0; i--) {
      host.driveCmd((b >> i) & 1);
      await host.tick();
    }
  }
  host.driveCmd(1);
}

/// Sends the raw [bits] on CMD, one bit for each clock, in list order.
///
/// This sends a run of bits that is not a whole byte, which lets a test
/// build a bit stream that no host would send.
Future<void> _sendBits(SdHost host, List<int> bits) async {
  for (final bit in bits) {
    host.driveCmd(bit);
    await host.tick();
  }
  host.driveCmd(1);
}

void main() {
  tearDown(Simulator.reset);

  test('receives CMD0 and reports a good CRC', () async {
    final s = await _setUp();
    final mon = _FrameMonitor(s.dut);

    await s.host.sendCommand(0, 0x00000000);
    await s.host.idle(8);
    await mon.stop();

    expect(mon.frames, hasLength(1), reason: 'cmd_valid pulsed');
    expect(mon.frames.single.index, equals(0), reason: 'command index');
    expect(mon.frames.single.arg, equals(0), reason: 'argument');
    expect(mon.frames.single.crcOk, isTrue, reason: 'CRC7 accepted');
    expect(
      mon.crcOkOutsidePulse,
      isFalse,
      reason: 'cmd_crc_ok is only high while cmd_valid is high',
    );
    await Simulator.endSimulation();
  });

  test('receives CMD24 with its argument intact', () async {
    final s = await _setUp();
    final mon = _FrameMonitor(s.dut);
    await s.host.sendCommand(24, 0x0000002A);
    await s.host.idle(8);
    await mon.stop();
    expect(mon.frames, hasLength(1));
    expect(mon.frames.single.index, equals(24));
    expect(mon.frames.single.arg, equals(0x2A));
    await Simulator.endSimulation();
  });

  test(
    'receives three frames back to back with the CRC reseeded each time',
    () async {
      final s = await _setUp();
      final mon = _FrameMonitor(s.dut);

      await s.host.sendCommand(0, 0x00000000);
      await s.host.idle(8);
      await s.host.sendCommand(8, 0x000001AA);
      await s.host.idle(8);
      await s.host.sendCommand(55, 0xDEADBEEF);
      await s.host.idle(8);
      await mon.stop();

      expect(
        mon.frames.map((f) => f.index).toList(),
        equals([0, 8, 55]),
        reason: 'command index for each of the three frames',
      );
      expect(
        mon.frames.map((f) => f.arg).toList(),
        equals([0x00000000, 0x000001AA, 0xDEADBEEF]),
        reason: 'argument for each of the three frames',
      );
      expect(
        mon.frames.map((f) => f.crcOk).toList(),
        equals([true, true, true]),
        reason: 'CRC7 accepted for each frame, with no carryover from the last',
      );
      await Simulator.endSimulation();
    },
  );

  test('reports a bad CRC when a bit is corrupted', () async {
    final s = await _setUp();
    final mon = _FrameMonitor(s.dut);

    // Send CMD0 but flip one argument bit so the CRC no longer matches.
    final bad = sdCommandFrame(0, 0x00000000);
    bad[3] ^= 0x01;
    await _sendBytes(s.host, bad);
    await s.host.idle(8);
    await mon.stop();

    expect(mon.frames, hasLength(1), reason: 'the frame still framed');
    expect(mon.frames.single.crcOk, isFalse, reason: 'CRC7 rejected');
    expect(
      mon.crcOkOutsidePulse,
      isFalse,
      reason: 'cmd_crc_ok stays low outside the pulse',
    );
    await Simulator.endSimulation();
  });

  test('transmits an R1 response with a correct CRC7', () async {
    final s = await _setUp();

    // R1 for CMD0. The link puts in the start bit and the transmission
    // bit, so the caller gives the 6-bit index and the 32-bit status only.
    // The index is 0 and the status is 0x00000900, so the 40 bits that the
    // CRC7 covers are 0x0000000900.
    const content = 0x00000900;
    const payload = 0x0000000900;
    s.dut.input('resp_data').srcConnection!.inject(content);
    s.dut.input('resp_kind').srcConnection!.inject(sdRespKindR1);
    s.dut.input('resp_start').srcConnection!.inject(1);
    await s.host.tick();
    s.dut.input('resp_start').srcConnection!.inject(0);

    // Sample cmd_out on each clock while the module drives the bus. The
    // helper also proves the frame is exactly sdCommandBits clocks long.
    final bits = await _readFrame(s.dut, s.host, sdCommandBits);

    // Rebuild the bytes and check the CRC the way a host would.
    final bytes = _packBytes(bits);
    expect(bytes.last & 0x01, equals(1), reason: 'end bit');
    expect(
      (bytes.last >> 1) & 0x7F,
      equals(sdCrc7(bytes.sublist(0, 5))),
      reason: 'CRC7 over the 40-bit payload',
    );

    // The first 40 bits are the payload and the bus is released after.
    var payloadBack = 0;
    for (var i = 0; i < sdCommandCrcBits; i++) {
      payloadBack = (payloadBack << 1) | bits[i];
    }
    expect(
      payloadBack,
      equals(payload),
      reason:
          'payload, most significant '
          'bit first',
    );
    expect(
      s.dut.output('cmd_oe').value.toInt(),
      equals(0),
      reason: 'the card releases CMD after the end bit',
    );
    expect(
      s.dut.output('resp_busy').value.toInt(),
      equals(0),
      reason: 'resp_busy falls with cmd_oe',
    );
    await Simulator.endSimulation();
  });

  test('transmits an R3 response with the fixed CRC field', () async {
    final s = await _setUp();

    // The OCR of a ready high capacity card. R3 has no CRC and no index,
    // so the link puts ones in both fields and the caller gives the OCR
    // only. resp_data bits 37 to 32 stay 0 here, which proves the link
    // forces the reserved field and does not copy the caller.
    const ocr = 0x40FF8000;
    const header = 0x3F;
    final computed = sdCrc7([header, 0x40, 0xFF, 0x80, 0x00]);
    expect(
      computed,
      isNot(equals(0x7F)),
      reason:
          'the OCR is one whose real CRC7 is not the fixed field, so the '
          'test can tell a computed CRC from the fixed one',
    );

    s.respData.inject(ocr);
    s.respKind.inject(sdRespKindR3);
    s.respStart.inject(1);
    await s.host.tick();
    s.respStart.inject(0);

    final bits = await _readFrame(s.dut, s.host, sdCommandBits);
    expect(
      bits,
      hasLength(sdCommandBits),
      reason: 'an R3 is 48 bits, the same length as an R1',
    );

    final bytes = _packBytes(bits);
    expect(
      bytes.first,
      equals(header),
      reason: 'start bit 0, transmission bit 0, then the reserved 111111',
    );
    var ocrBack = 0;
    for (var i = 0; i < sdCommandArgBits; i++) {
      ocrBack = (ocrBack << 1) | bits[sdResponseHeaderBits + i];
    }
    expect(ocrBack, equals(ocr), reason: 'the OCR, most significant bit first');
    expect(
      (bytes.last >> 1) & 0x7F,
      equals(0x7F),
      reason: 'bits 7 to 1 are the fixed 1111111 of an R3',
    );
    expect(
      (bytes.last >> 1) & 0x7F,
      isNot(equals(computed)),
      reason: 'the link computes no CRC7 for an R3',
    );
    expect(bytes.last & 0x01, equals(1), reason: 'end bit');
    await Simulator.endSimulation();
  });

  test('transmits a 136-bit R2 with the register verbatim', () async {
    final s = await _setUp();

    // A CID with its own CRC7 in bits 7 to 1 of the last byte and the end
    // bit in bit 0. The caller builds that byte, so the link must send all
    // 128 bits as they are.
    final cid = <int>[
      0x03, 0x53, 0x44, 0x4D, 0x49, 0x4D, 0x49, 0x43, //
      0x10, 0x12, 0x34, 0x56, 0x78, 0x01, 0x5A, 0xC3,
    ];
    expect(
      (cid.last >> 1) & 0x7F,
      equals(sdCrc7(cid.sublist(0, 15))),
      reason: 'the register carries the CRC7 that the caller built',
    );
    expect(cid.last & 0x01, equals(1), reason: 'the register ends in a 1');

    s.respData.inject(LogicValue.ofBigInt(_reg128(cid), sdResponseRegBits));
    s.respKind.inject(sdRespKindR2);
    s.respStart.inject(1);
    await s.host.tick();
    s.respStart.inject(0);

    final bits = await _readFrame(s.dut, s.host, sdResponseLongBits);
    expect(bits, hasLength(136), reason: 'an R2 is 136 bits');

    final bytes = _packBytes(bits);
    expect(
      bytes.first,
      equals(0x3F),
      reason: 'the header is 00111111, which the link owns',
    );
    expect(
      bytes.sublist(1),
      equals(cid),
      reason:
          'the 128 bits of the register come out in order, with the CRC7 '
          'and the end bit that the caller gave',
    );
    await Simulator.endSimulation();
  });

  test('does not frame its own response as a command', () async {
    final s = await _setUp();
    final mon = _FrameMonitor(s.dut);

    // A response has a 0 start bit and a good CRC7, so a framer with no
    // guard accepts it as a command. The index is 0 and the status is
    // 0x00000900, so the 40 bits that the CRC7 covers are 0x0000000900.
    const content = 0x00000900;
    s.respData.inject(content);
    s.respKind.inject(sdRespKindR1);
    s.respStart.inject(1);
    await s.host.tick();
    s.respStart.inject(0);

    // The host model ties cmd_out back to cmd_in, the way the parent
    // tristate does, so the card sees every bit that it sends.
    for (var i = 0; i < 56; i++) {
      await s.host.tick();
    }
    await s.host.idle(8);

    expect(
      mon.frames,
      isEmpty,
      reason: 'the receiver ignores the response the card sent',
    );

    // The receiver still works after the card releases the bus.
    await s.host.sendCommand(17, 0x00001234);
    await s.host.idle(8);

    expect(mon.frames, hasLength(1), reason: 'the next real command frames');
    expect(mon.frames.single.index, equals(17));
    expect(mon.frames.single.arg, equals(0x00001234));
    expect(mon.frames.single.crcOk, isTrue);

    // The same 48 bits from outside the card carry a good CRC7 too. Only
    // the transmission bit tells them apart from a command, so the second
    // guard must drop them. Without it the link reports index 0 with the
    // response status as the argument.
    //
    // The idle gate also holds the framer off the 0 bits later in this
    // stream, which is the subject of the next test.
    final head = <int>[0x00, 0x00, 0x00, 0x09, 0x00];
    await _sendBytes(s.host, [...head, ((sdCrc7(head) << 1) | 1) & 0xFF]);
    await s.host.idle(64);
    await mon.stop();

    expect(
      mon.frames.any((f) => f.crcOk && f.index == 0 && f.arg == 0x00000900),
      isFalse,
      reason: 'a frame with a 0 transmission bit is never accepted',
    );
    await Simulator.endSimulation();
  });

  test('stays deaf for the whole response and then enforces Nrc', () async {
    final s = await _setUp();
    final mon = _FrameMonitor(s.dut);

    // A real R3 response ends in eight ones: the reserved 1111111 field
    // and the end bit. Phase 2 polls ACMD41, which is answered with R3
    // every time, so this is the shape the card sends most often. The
    // content below carries the R3 bit pattern in an R1 kind, and its
    // computed CRC7 is 0x7F, so the frame the card sends here also ends in
    // eight ones. A gap counter that counts those ones reaches the goal on
    // the end bit and arms the framer for the very next clock, which drops
    // Nrc to zero.
    const head = <int>[0x3F, 0xC0, 0xD0, 0x00, 0x00];
    expect(sdCrc7(head), equals(0x7F), reason: 'the frame ends in ones');
    const content = 0x3FC0D00000;

    s.respData.inject(content);
    s.respKind.inject(sdRespKindR1);
    s.respStart.inject(1);
    await s.host.tick();
    s.respStart.inject(0);

    // The host model ties cmd_out back to cmd_in while the card drives the
    // bus, the way the parent tristate does, so the card sees every bit
    // that it sends.
    for (var i = 0; i < sdCommandBits; i++) {
      expect(
        s.dut.output('cmd_oe').value.toInt(),
        equals(1),
        reason: 'the card drives CMD for the whole frame',
      );
      await s.host.tick();
    }
    s.host.driveCmd(1);

    expect(
      mon.frames,
      isEmpty,
      reason: 'no frame comes out of the response the card sent',
    );

    // A command that starts in the clock right after the end bit of the
    // response breaks Nrc. The framer must drop it.
    await s.host.sendCommand(17, 0x00001234);
    await s.host.idle(sdCommandGapClocks);

    expect(
      mon.frames,
      isEmpty,
      reason: 'Nrc runs from the end bit of the response',
    );

    // The receiver is not stuck. A command after a legal gap still frames.
    await s.host.sendCommand(8, 0x000001AA);
    await s.host.idle(sdCommandGapClocks);
    await mon.stop();

    expect(mon.frames, hasLength(1), reason: 'the legal command frames');
    expect(mon.frames.single.index, equals(8), reason: 'CMD8 index');
    expect(mon.frames.single.arg, equals(0x000001AA), reason: 'CMD8 argument');
    expect(mon.frames.single.crcOk, isTrue, reason: 'CRC7 accepted');
    await Simulator.endSimulation();
  });

  test('stays deaf for a whole R2 and then enforces Nrc', () async {
    final s = await _setUp();
    final mon = _FrameMonitor(s.dut);

    // The twin of the R1 test above, for the long frame. This CID ends in
    // 0xFF, because its own CRC7 is 0x7F, so the last eight bits of the
    // 136-bit frame are ones. A gap counter that counts those ones reaches
    // the goal on the end bit and drops Nrc to zero. The counter must
    // count from the true end bit of the frame, which is bit 135 and not
    // bit 47, so a long frame must not desynchronise the gate.
    final cid = <int>[
      0x03, 0x53, 0x44, 0x4D, 0x49, 0x4D, 0x49, 0x43, //
      0x10, 0x12, 0x34, 0x56, 0x78, 0x01, 0x32, 0xFF,
    ];
    expect(
      sdCrc7(cid.sublist(0, 15)),
      equals(0x7F),
      reason: 'the frame ends in ones',
    );

    s.respData.inject(LogicValue.ofBigInt(_reg128(cid), sdResponseRegBits));
    s.respKind.inject(sdRespKindR2);
    s.respStart.inject(1);
    await s.host.tick();
    s.respStart.inject(0);

    // The host model ties cmd_out back to cmd_in while the card drives the
    // bus, the way the parent tristate does, so the card sees every bit
    // that it sends.
    for (var i = 0; i < sdResponseLongBits; i++) {
      expect(
        s.dut.output('cmd_oe').value.toInt(),
        equals(1),
        reason: 'the card drives CMD for all 136 bits',
      );
      expect(
        s.dut.output('resp_busy').value.toInt(),
        equals(1),
        reason: 'resp_busy is high for all 136 bits',
      );
      await s.host.tick();
    }
    s.host.driveCmd(1);
    expect(
      s.dut.output('cmd_oe').value.toInt(),
      equals(0),
      reason: 'the card releases CMD after 136 bits',
    );
    expect(
      s.dut.output('resp_busy').value.toInt(),
      equals(0),
      reason: 'resp_busy falls with cmd_oe after 136 bits',
    );

    expect(
      mon.frames,
      isEmpty,
      reason: 'no frame comes out of the long response the card sent',
    );

    // A command that starts in the clock right after the end bit of the
    // response breaks Nrc. The framer must drop it.
    await s.host.sendCommand(17, 0x00001234);
    await s.host.idle(sdCommandGapClocks);

    expect(
      mon.frames,
      isEmpty,
      reason: 'Nrc runs from the end bit of the 136-bit response',
    );

    // The receiver is not stuck. A command after a legal gap still frames.
    await s.host.sendCommand(8, 0x000001AA);
    await s.host.idle(sdCommandGapClocks);
    await mon.stop();

    expect(mon.frames, hasLength(1), reason: 'the legal command frames');
    expect(mon.frames.single.index, equals(8), reason: 'CMD8 index');
    expect(mon.frames.single.arg, equals(0x000001AA), reason: 'CMD8 argument');
    expect(mon.frames.single.crcOk, isTrue, reason: 'CRC7 accepted');
    await Simulator.endSimulation();
  });

  test('closes a frame that was open when the response started', () async {
    final s = await _setUp();
    final mon = _FrameMonitor(s.dut);

    // One low clock on an armed framer opens a frame. Frame bit 1 is high
    // here, so the transmission bit guard does not drop it, and the frame
    // stays open while the line rests.
    await _sendBits(s.host, [0]);
    await s.host.tick();

    // The personality answers now. The frame from the glitch is still
    // open, so a receiver that only blocks new starts shifts the card's
    // own response into rxShift and rxCrcIn. The CRC7 of this content is
    // 0x7F, so frame bit 47 of the open frame lands on a 1 and the
    // receiver raises cmd_valid on a frame that no host sent.
    const content = 0x3FC0D00000;
    s.respData.inject(content);
    s.respKind.inject(sdRespKindR1);
    s.respStart.inject(1);
    await s.host.tick();
    s.respStart.inject(0);

    for (var i = 0; i < sdCommandBits; i++) {
      await s.host.tick();
    }
    s.host.driveCmd(1);
    await s.host.idle(sdCommandGapClocks);
    await mon.stop();

    expect(
      mon.frames,
      isEmpty,
      reason: 'the open frame closes when the card starts to drive CMD',
    );
    await Simulator.endSimulation();
  });

  test('refuses a bus width the receive path cannot serve', () {
    // The receive datapath reads DAT0 only, so a card built at width 4 or
    // 8 takes a quarter or an eighth of each block and then reports a CRC
    // failure. The constructor must refuse the width instead.
    for (final width in [0, 2, 4, 8]) {
      expect(
        () => MimicSdLink(busWidth: width),
        throwsA(isA<ArgumentError>()),
        reason: 'busWidth $width is not built yet',
      );
    }
  });

  test('builds no frame from a stream tail plus the idle line', () async {
    final s = await _setUp();
    final mon = _FrameMonitor(s.dut);

    // These 6 bytes are a card response that something replays onto CMD.
    // With no idle gate the framer starts on the 0 at bit 41 of the
    // stream, takes the last bits of the stream and then the idle line,
    // and builds a 48-bit frame. That frame reads as index 15 with the
    // argument 0xFFFFFFFF. Its CRC7 field and its computed CRC7 are both
    // 0x7F, so it reports a good CRC. Index 15 is GO_INACTIVE_STATE, and
    // a card personality that acts on it goes quiet.
    await _sendBytes(s.host, [0x00, 0x00, 0x00, 0x09, 0x00, 0xA7]);
    await s.host.idle(64);
    await mon.stop();

    expect(
      mon.frames.where((f) => f.index == 15).toList(),
      isEmpty,
      reason: 'no GO_INACTIVE_STATE frame comes out of the stream tail',
    );
    expect(mon.frames, isEmpty, reason: 'the stream holds no command');
    await Simulator.endSimulation();
  });

  test('starts no frame right after a frame that ends in ones', () async {
    final s = await _setUp();
    final mon = _FrameMonitor(s.dut);

    // The CRC7 of CMD0 with the argument 0x58 is 0x7F, so the last 8 bits
    // of the frame are ones. A gap counter that also counts the bits
    // inside a frame reaches the goal on the end bit. A low bit in the
    // clock right after the end bit then starts a frame with a gap of 0
    // clocks. The 7 bits below are the head of that frame, and the idle
    // line gives the rest, which builds the index 15 frame with the
    // argument 0xFFFFFFFF and a good CRC7 that the stream tail test
    // describes. Ncc runs from the end bit, so the framer must stay off
    // for 8 clocks after it.
    await _sendBytes(s.host, sdCommandFrame(0, 0x00000058));
    await _sendBits(s.host, [0, 1, 0, 0, 1, 1, 1]);
    await s.host.idle(64);
    await mon.stop();

    expect(
      mon.frames.where((f) => f.index == 15).toList(),
      isEmpty,
      reason: 'no frame starts in the clock after the end bit',
    );
    expect(mon.frames, hasLength(1), reason: 'only CMD0 frames');
    expect(mon.frames.single.index, equals(0), reason: 'CMD0 index');
    expect(mon.frames.single.arg, equals(0x58), reason: 'CMD0 argument');
    expect(mon.frames.single.crcOk, isTrue, reason: 'CRC7 accepted');
    await Simulator.endSimulation();
  });

  test('leaves reset unarmed and keeps the next command', () async {
    final s = await _setUp(holdReset: true);
    final mon = _FrameMonitor(s.dut);

    // Reset falls while the host is in the middle of CMD17. With no idle
    // gate the framer starts on a 0 later in that command. It then gives
    // spurious cmd_valid pulses out of the rest of the stream, two of them
    // with no end bit check, and holds a frame open across the CMD8 that
    // comes next, so it loses CMD8.
    //
    // This test also covers the reset value of rxIdle, not only the gate.
    // A framer that leaves reset armed starts on the same 0 and loses
    // CMD8 in the same way, so this test gives zero frames. Keep the
    // reset value at 0.
    const releaseAt = 10;
    var bit = 0;
    for (final b in sdCommandFrame(17, 0xAAAAAAAA)) {
      for (var i = 7; i >= 0; i--) {
        s.host.driveCmd((b >> i) & 1);
        if (bit == releaseAt) {
          s.reset.inject(0);
        }
        await s.host.tick();
        bit++;
      }
    }
    s.host.driveCmd(1);
    await s.host.idle(sdCommandGapClocks);
    await s.host.sendCommand(8, 0x000001AA);
    await s.host.idle(sdCommandGapClocks);
    await mon.stop();

    expect(mon.frames, hasLength(1), reason: 'only the real command frames');
    expect(mon.frames.single.index, equals(8), reason: 'CMD8 index');
    expect(mon.frames.single.arg, equals(0x000001AA), reason: 'CMD8 argument');
    expect(mon.frames.single.crcOk, isTrue, reason: 'CRC7 accepted');
    await Simulator.endSimulation();
  });

  test(
    'receives commands that a gap of exactly Ncc clocks separates',
    () async {
      final s = await _setUp();
      final mon = _FrameMonitor(s.dut);

      // Ncc and Nrc are both 8 clocks, so 8 is the shortest gap that a host
      // which obeys the specification makes. The idle gate must keep every
      // one of these frames.
      await s.host.sendCommand(0, 0x00000000);
      await s.host.idle(sdCommandGapClocks);
      await s.host.sendCommand(8, 0x000001AA);
      await s.host.idle(sdCommandGapClocks);
      await s.host.sendCommand(55, 0xDEADBEEF);
      await s.host.idle(sdCommandGapClocks);
      await mon.stop();

      expect(
        mon.frames.map((f) => f.index).toList(),
        equals([0, 8, 55]),
        reason: 'every command with the shortest legal gap still frames',
      );
      expect(
        mon.frames.map((f) => f.arg).toList(),
        equals([0x00000000, 0x000001AA, 0xDEADBEEF]),
        reason: 'argument for each of the three frames',
      );
      expect(
        mon.frames.map((f) => f.crcOk).toList(),
        equals([true, true, true]),
        reason: 'CRC7 accepted for each frame',
      );
      await Simulator.endSimulation();
    },
  );
}
