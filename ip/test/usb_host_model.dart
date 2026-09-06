// A host-side USB full-speed line model for the PHY-level Mimic tests.
//
// The device is now the ROHD port of the TinyFPGA protocol engine, which
// decodes REAL USB packets: a token packet carries an 11-bit address and
// endpoint field with a CRC5, and a data packet carries a payload with a
// CRC16. So this model builds the packets byte for byte, applies NRZI and bit
// stuffing in software, and drives the D+/D- pads directly, four clock cycles
// per bit (48 MHz clock, 12 Mbps line rate).
//
// The receive side watches the pads the device drives with a
// [HarborUsbFsRx] instance and reports each completed packet as a PID plus
// the payload bytes.

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';

/// USB 2.0 PID bytes (the 4-bit PID with its complement in the high nibble).
const int usbPidSetup = 0x2D;
const int usbPidIn = 0x69;
const int usbPidOut = 0xE1;
const int usbPidData0 = 0xC3;
const int usbPidData1 = 0x4B;
const int usbPidAck = 0xD2;
const int usbPidNak = 0x5A;
const int usbPidStall = 0x1E;

/// The PID byte that [nibble] encodes.
int usbPidByte(int nibble) => (nibble & 0xF) | ((~nibble & 0xF) << 4);

/// The USB token CRC5 over the low [nbits] bits of [data].
int usbCrc5(int data, int nbits) {
  var crc = 0x1F;
  for (var i = 0; i < nbits; i++) {
    final bit = (data >> i) & 1;
    final xorIn = (crc & 1) ^ bit;
    crc >>= 1;
    if (xorIn != 0) crc ^= 0x14;
  }
  return (~crc) & 0x1F;
}

/// The USB data CRC16 over [bytes].
int usbCrc16(List<int> bytes) {
  var crc = 0xFFFF;
  for (final b in bytes) {
    for (var i = 0; i < 8; i++) {
      final bit = (b >> i) & 1;
      final xorIn = (crc & 1) ^ bit;
      crc >>= 1;
      if (xorIn != 0) crc ^= 0xA001;
    }
  }
  return (~crc) & 0xFFFF;
}

/// The two bytes of a token packet body: the address, the endpoint and the
/// CRC5 over both.
List<int> usbTokenBytes(int addr, int endp) {
  final field = (addr & 0x7F) | ((endp & 0xF) << 7);
  final v = field | (usbCrc5(field, 11) << 11);
  return [v & 0xFF, (v >> 8) & 0xFF];
}

/// Turns [bytes] into the line symbols of one packet: the SYNC byte, the
/// bytes themselves, bit stuffing, NRZI, then two SE0 symbols and one J for
/// the end of packet. Each symbol is `[dp, dm]`.
List<List<int>> usbEncodePacket(List<int> bytes) {
  final raw = <int>[];
  for (final b in [0x80, ...bytes]) {
    for (var i = 0; i < 8; i++) {
      raw.add((b >> i) & 1);
    }
  }
  final stuffed = <int>[];
  var ones = 0;
  for (final bit in raw) {
    stuffed.add(bit);
    if (bit == 1) {
      ones++;
      if (ones == 6) {
        stuffed.add(0);
        ones = 0;
      }
    } else {
      ones = 0;
    }
  }
  final out = <List<int>>[];
  var line = 1;
  for (final bit in stuffed) {
    if (bit == 0) line = 1 - line;
    out.add(line == 1 ? [1, 0] : [0, 1]);
  }
  out.add([0, 0]);
  out.add([0, 0]);
  out.add([1, 0]);
  return out;
}

/// One packet the device transmitted.
class UsbRxPacket {
  /// The PID byte, or -1 when no packet arrived before the timeout.
  final int pid;

  /// The payload bytes, with the CRC16 of a data packet removed.
  final List<int> bytes;

  const UsbRxPacket(this.pid, this.bytes);

  /// True when no packet arrived.
  bool get isEmpty => pid < 0;
}

/// Drives the D+/D- pads of a device and reads back what the device sends.
///
/// Call [idle] before the device leaves reset, then drive packets with
/// [sendToken], [sendData] and [sendHandshake], and read what the device
/// answers with [expectPacket].
class UsbLineHost {
  /// The 48 MHz clock the device and this model share.
  final Logic clk;

  /// The D+ pad of the device, driven by this model.
  final Logic dp;

  /// The D- pad of the device, driven by this model.
  final Logic dm;

  /// The receiver that watches the pads the device drives.
  final HarborUsbFsRx obs;

  /// Called on every clock edge this model waits through. A test uses it to
  /// watch device signals that the line does not show.
  void Function()? onSample;

  /// Clock cycles per line bit. 48 MHz over 12 Mbps is four.
  static const int cyclesPerBit = 4;

  final List<int> _rxBytes = [];
  int _pktFirst = 0;
  int _gotPid = -1;
  List<int> _gotBytes = const [];
  bool _gotPacket = false;

  UsbLineHost({
    required this.clk,
    required this.dp,
    required this.dm,
    required this.obs,
  });

  /// Builds a receiver wired to the device pads through the output enable, so
  /// the line reads idle J while the device is not driving.
  static HarborUsbFsRx observer({
    required Logic clk,
    required Logic reset,
    required Logic oe,
    required Logic dpOut,
    required Logic dmOut,
    String name = 'host_obs_rx',
  }) {
    final rx = HarborUsbFsRx(name: name);
    rx.input('clk').srcConnection! <= clk;
    rx.input('reset').srcConnection! <= reset;
    rx.input('dp').srcConnection! <= mux(oe, dpOut, Const(1));
    rx.input('dn').srcConnection! <= mux(oe, dmOut, Const(0));
    return rx;
  }

  /// Parks the line in the idle J state. Call this before the device leaves
  /// reset: an SE0 line is a bus reset to the device.
  void idle() {
    dp.inject(1);
    dm.inject(0);
  }

  /// Reads the receiver once. Call this on every clock edge the model waits
  /// through, so no transmitted packet is missed.
  void _sample() {
    final start = obs.output('pkt_start').value;
    if (start.isValid && start.toInt() == 1) {
      _pktFirst = _rxBytes.length;
    }
    final put = obs.output('rx_data_put').value;
    if (put.isValid && put.toInt() == 1) {
      final d = obs.output('rx_data').value;
      if (d.isValid) _rxBytes.add(d.toInt());
    }
    onSample?.call();
    final end = obs.output('pkt_end').value;
    if (end.isValid && end.toInt() == 1) {
      final pidVal = obs.output('pid').value;
      if (pidVal.isValid) {
        final pid = usbPidByte(pidVal.toInt());
        var body = _rxBytes.sublist(_pktFirst);
        // A data packet ends with its CRC16. Handshake and token packets
        // carry no payload at all.
        final isData = (pidVal.toInt() & 0x3) == 3;
        if (isData) {
          body = body.length >= 2 ? body.sublist(0, body.length - 2) : <int>[];
        }
        _gotPid = pid;
        _gotBytes = body;
        _gotPacket = true;
      }
    }
  }

  /// Waits [cycles] clock edges while watching the device line.
  Future<void> settle(int cycles) async {
    for (var i = 0; i < cycles; i++) {
      await clk.nextPosedge;
      _sample();
    }
  }

  Future<void> _drive(List<List<int>> symbols) async {
    for (final s in symbols) {
      for (var t = 0; t < cyclesPerBit; t++) {
        dp.inject(s[0]);
        dm.inject(s[1]);
        await clk.nextPosedge;
        _sample();
      }
    }
    idle();
  }

  /// Sends a token packet (SETUP, IN or OUT) for [addr] and [endp].
  Future<void> sendToken(int pid, {int addr = 0, int endp = 0}) =>
      _drive(usbEncodePacket([pid, ...usbTokenBytes(addr, endp)]));

  /// Sends a data packet (DATA0 or DATA1) with [payload] and its CRC16.
  Future<void> sendData(int pid, List<int> payload) {
    final crc = usbCrc16(payload);
    return _drive(
      usbEncodePacket([pid, ...payload, crc & 0xFF, (crc >> 8) & 0xFF]),
    );
  }

  /// Sends a handshake packet (ACK, NAK or STALL).
  Future<void> sendHandshake(int pid) => _drive(usbEncodePacket([pid]));

  /// Waits for the device to transmit one packet, up to [timeout] clock
  /// cycles. Returns a packet with pid -1 when the device stays silent.
  Future<UsbRxPacket> expectPacket({int timeout = 6000}) async {
    _gotPacket = false;
    for (var i = 0; i < timeout; i++) {
      await clk.nextPosedge;
      _sample();
      if (_gotPacket) return UsbRxPacket(_gotPid, _gotBytes);
    }
    return const UsbRxPacket(-1, <int>[]);
  }
}
