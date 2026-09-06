import 'dart:async';

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';

/// Builds the link with a host driving it, with the data ports wired.
Future<
  ({
    MimicSdLink dut,
    SdHost host,
    Logic reset,
    Logic datRxEnable,
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
  // The busy level of the card personality. These tests drive the link
  // alone, and a link input that nothing drives holds X, which reaches
  // dat_oe as soon as the host reads the line.
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
  Simulator.setMaxSimTime(20000000);
  unawaited(Simulator.run());
  await host.tick();
  await host.tick();
  reset.inject(0);
  await host.idle(4);
  return (
    dut: dut,
    host: host,
    reset: reset,
    datRxEnable: datRxEnable,
    datStatusSend: datStatusSend,
    datStatusCode: datStatusCode,
  );
}

/// The code that tells the host the card accepted the block.
const int sdStatusAccepted = 0x2;

/// The code that tells the host the CRC of the block was wrong.
const int sdStatusCrcError = 0x5;

/// Reads DAT0 as a plain integer.
int _dat0(MimicSdLink dut) => dut.output('dat_out').value[0].toInt();

/// Collects every byte the link reports, plus the end-of-block result.
class _BlockSink {
  final received = <int>[];
  var sawEnd = false;
  var crcOk = false;

  /// The CRC verdict of every block that ended, in order.
  final endResults = <bool>[];
  late final StreamSubscription<LogicValueChanged> _byteSub;
  late final StreamSubscription<LogicValueChanged> _endSub;

  _BlockSink(MimicSdLink dut) {
    _byteSub = dut.output('dat_byte_valid').changed.listen((_) {
      if (dut.output('dat_byte_valid').value.toInt() == 1) {
        received.add(dut.output('dat_byte').value.toInt());
      }
    });
    _endSub = dut.output('dat_block_end').changed.listen((_) {
      if (dut.output('dat_block_end').value.toInt() == 1) {
        sawEnd = true;
        crcOk = dut.output('dat_crc_ok').value.toInt() == 1;
        endResults.add(crcOk);
      }
    });
  }

  Future<void> cancel() async {
    await _byteSub.cancel();
    await _endSub.cancel();
  }
}

void main() {
  tearDown(Simulator.reset);

  test('receives a 512-byte block and accepts the CRC', () async {
    final s = await _setUp();
    final payload = List<int>.generate(
      512,
      (i) => (i * 7 + 3) & 0xFF,
      growable: false,
    );
    final sink = _BlockSink(s.dut);

    s.datRxEnable.inject(1);
    await s.host.sendDataBlock(payload);
    await s.host.idle(4);
    await sink.cancel();

    expect(sink.received.length, equals(512), reason: 'every byte arrived');
    expect(sink.received, equals(payload), reason: 'bytes in order');
    expect(sink.sawEnd, isTrue, reason: 'dat_block_end pulsed');
    expect(sink.crcOk, isTrue, reason: 'CRC16 accepted');
    await Simulator.endSimulation();
  });

  test('rejects a block whose payload does not match its CRC', () async {
    final s = await _setUp();
    final payload = List<int>.generate(
      512,
      (i) => (i * 7 + 3) & 0xFF,
      growable: false,
    );
    final sink = _BlockSink(s.dut);

    // Compute the CRC over the good payload, then corrupt one byte, so the
    // CRC on the wire no longer matches the bytes on the wire.
    final crc = sdCrc16(payload);
    final corrupt = List<int>.of(payload);
    corrupt[100] ^= 0xFF;

    s.datRxEnable.inject(1);
    s.host.driveDat(0); // start bit
    await s.host.tick();
    for (final b in corrupt) {
      for (var i = 7; i >= 0; i--) {
        s.host.driveDat((b >> i) & 1);
        await s.host.tick();
      }
    }
    for (var i = 15; i >= 0; i--) {
      s.host.driveDat((crc >> i) & 1);
      await s.host.tick();
    }
    s.host.driveDat(1); // end bit
    await s.host.tick();
    await s.host.idle(4);
    await sink.cancel();

    expect(sink.received.length, equals(512), reason: 'bytes still framed');
    expect(sink.sawEnd, isTrue, reason: 'dat_block_end still pulsed');
    expect(sink.crcOk, isFalse, reason: 'CRC16 rejected');
    await Simulator.endSimulation();
  });

  // Regression test. A single block cannot show state that carries from one
  // block to the next. Two blocks with different payloads can: a remainder
  // or a counter that stays from the first block makes the second block
  // fail its CRC or lose its framing.
  test('receives two blocks in a row and accepts both CRCs', () async {
    final s = await _setUp();
    final first = List<int>.generate(
      512,
      (i) => (i * 7 + 3) & 0xFF,
      growable: false,
    );
    final second = List<int>.generate(
      512,
      (i) => (i * 31 + 17) & 0xFF,
      growable: false,
    );
    final sink = _BlockSink(s.dut);

    s.datRxEnable.inject(1);
    await s.host.sendDataBlock(first);
    await s.host.idle(4);
    await s.host.sendDataBlock(second);
    await s.host.idle(4);
    await sink.cancel();

    expect(sink.received.length, equals(1024), reason: 'both blocks arrived');
    expect(
      sink.received,
      equals([...first, ...second]),
      reason: 'bytes of both blocks in order',
    );
    expect(
      sink.endResults,
      equals([true, true]),
      reason: 'both blocks ended with a good CRC',
    );
    await Simulator.endSimulation();
  });

  // dat_rx_enable is the contract between the personality and the framer.
  // The personality raises it only in the window where it expects a block.
  // A framer that ignores it frames any block the host sends, at any time.
  test('frames nothing while dat_rx_enable is low', () async {
    final s = await _setUp();
    final payload = List<int>.generate(
      512,
      (i) => (i * 7 + 3) & 0xFF,
      growable: false,
    );
    final sink = _BlockSink(s.dut);

    // The personality expects no block, so the enable stays low.
    await s.host.sendDataBlock(payload);
    await s.host.idle(8);

    expect(
      sink.received,
      isEmpty,
      reason: 'the framer takes no byte while the enable is low',
    );
    expect(sink.sawEnd, isFalse, reason: 'no block ended');

    // The receiver is not stuck. It takes the block once the personality
    // opens the window.
    s.datRxEnable.inject(1);
    await s.host.sendDataBlock(payload);
    await s.host.idle(4);
    await sink.cancel();

    expect(sink.received, equals(payload), reason: 'the enabled block frames');
    expect(sink.endResults, equals([true]), reason: 'one block, good CRC');
    await Simulator.endSimulation();
  });

  test('sends the CRC status token on DAT0', () async {
    final s = await _setUp();

    s.datStatusCode.inject(sdStatusAccepted);
    s.datStatusSend.inject(1);
    await s.host.tick();
    s.datStatusSend.inject(0);

    // The token is a start bit 0, the three status bits and a stop bit 1.
    // The code 010 therefore gives 0, 0, 1, 0, 1 on DAT0.
    final bits = <int>[];
    for (var i = 0; i < sdStatusTokenBits; i++) {
      expect(
        s.dut.output('dat_oe').value.toInt(),
        equals(1),
        reason: 'the card drives DAT for the whole token',
      );
      bits.add(_dat0(s.dut));
      await s.host.tick();
    }

    expect(bits, equals([0, 0, 1, 0, 1]), reason: 'start, 010, stop');
    expect(
      s.dut.output('dat_oe').value.toInt(),
      equals(0),
      reason: 'the card releases DAT after the stop bit',
    );
    await Simulator.endSimulation();
  });

  // Regression test. A single token cannot show state that carries from one
  // token to the next. A counter or a shift register that stays from the
  // first token makes the second token the wrong length or the wrong code.
  test('sends two status tokens in a row', () async {
    final s = await _setUp();

    Future<List<int>> sendToken(int code) async {
      s.datStatusCode.inject(code);
      s.datStatusSend.inject(1);
      await s.host.tick();
      s.datStatusSend.inject(0);
      final bits = <int>[];
      for (var i = 0; i < sdStatusTokenBits; i++) {
        bits.add(_dat0(s.dut));
        await s.host.tick();
      }
      return bits;
    }

    final first = await sendToken(sdStatusAccepted);
    await s.host.idle(4);
    final second = await sendToken(sdStatusCrcError);

    expect(first, equals([0, 0, 1, 0, 1]), reason: 'start, 010, stop');
    expect(second, equals([0, 1, 0, 1, 1]), reason: 'start, 101, stop');
    await Simulator.endSimulation();
  });

  // The end bit closes a block. A framer that can rearm on the very next
  // clock starts a phantom block of 4114 clocks when that end bit is a 0.
  test('starts no phantom block when the end bit is a 0', () async {
    final s = await _setUp();
    final payload = List<int>.generate(
      512,
      (i) => (i * 7 + 3) & 0xFF,
      growable: false,
    );
    final sink = _BlockSink(s.dut);
    final crc = sdCrc16(payload);

    s.datRxEnable.inject(1);
    s.host.driveDat(0); // start bit
    await s.host.tick();
    for (final b in payload) {
      for (var i = 7; i >= 0; i--) {
        s.host.driveDat((b >> i) & 1);
        await s.host.tick();
      }
    }
    for (var i = 15; i >= 0; i--) {
      s.host.driveDat((crc >> i) & 1);
      await s.host.tick();
    }
    s.host.driveDat(0); // a malformed end bit
    await s.host.tick();
    await s.host.idle(24);
    await sink.cancel();

    expect(
      sink.received.length,
      equals(512),
      reason: 'the bad end bit frames no byte of a new block',
    );
    expect(
      sink.endResults,
      equals([true]),
      reason: 'only the real block ended',
    );
    await Simulator.endSimulation();
  });

  // The card drives DAT for the first time here. A token starts with a 0,
  // and the parent ties dat_out and dat_in together, so with no guard the
  // framer takes the token as the start of a block.
  test('does not frame its own status token as a block', () async {
    final s = await _setUp();
    final sink = _BlockSink(s.dut);
    final payload = List<int>.generate(
      512,
      (i) => (i * 13 + 5) & 0xFF,
      growable: false,
    );

    // The personality holds dat_rx_enable high until dat_block_end, so the
    // window of the token and the window of the framer overlap.
    s.datRxEnable.inject(1);
    s.datStatusCode.inject(sdStatusAccepted);
    s.datStatusSend.inject(1);
    await s.host.tick();
    s.datStatusSend.inject(0);

    // The host model ties dat_out back to dat_in, the way the parent
    // tristate does, so the card sees every bit that it sends. The host
    // holds DAT high while the card drives it.
    for (var i = 0; i < 24; i++) {
      await s.host.tick();
    }
    await s.host.idle(8);

    expect(
      sink.received,
      isEmpty,
      reason: 'the receiver frames no byte out of the token the card sent',
    );
    expect(sink.sawEnd, isFalse, reason: 'no block ended');

    // The receiver still works after the card releases the bus.
    await s.host.sendDataBlock(payload);
    await s.host.idle(4);
    await sink.cancel();

    expect(sink.received, equals(payload), reason: 'the real block frames');
    expect(sink.endResults, equals([true]), reason: 'one block, good CRC');
    await Simulator.endSimulation();
  });

  // The host owns the clock and can stop it at any bit. The card holds its
  // state and goes on when the clock starts again. Only hardware shows this
  // otherwise, so the host model drives the clock by hand.
  test(
    'finishes a block after the host parks the clock in the middle',
    () async {
      final s = await _setUp();
      final payload = List<int>.generate(
        512,
        (i) => (i * 11 + 29) & 0xFF,
        growable: false,
      );
      final sink = _BlockSink(s.dut);

      // The bits of one block: the start bit, the payload most significant
      // bit first, the CRC16 and the end bit.
      final bits = <int>[0];
      for (final b in payload) {
        for (var i = 7; i >= 0; i--) {
          bits.add((b >> i) & 1);
        }
      }
      final crc = sdCrc16(payload);
      for (var i = 15; i >= 0; i--) {
        bits.add((crc >> i) & 1);
      }
      bits.add(1);

      // Park the clock in the middle of the payload, at a bit that is not a
      // byte boundary, so the byte counter and the bit counter both hold a
      // value that is not zero.
      const parkAt = 2003;
      s.datRxEnable.inject(1);
      for (var i = 0; i < bits.length; i++) {
        if (i == parkAt) {
          // No tick here. Simulated time moves on and no clock edge comes.
          await s.host.park(50000);
        }
        s.host.driveDat(bits[i]);
        await s.host.tick();
      }
      await s.host.idle(4);
      await sink.cancel();

      expect(sink.received.length, equals(512), reason: 'every byte arrived');
      expect(sink.received, equals(payload), reason: 'bytes in order');
      expect(sink.sawEnd, isTrue, reason: 'dat_block_end pulsed');
      expect(sink.crcOk, isTrue, reason: 'CRC16 accepted across the stop');
      await Simulator.endSimulation();
    },
  );
}
