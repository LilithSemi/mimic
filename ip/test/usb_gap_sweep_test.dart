// Gap sweep and error recovery on the real USB path.
//
// The sweep drives a WRITE then a READ of SCRATCH at every inter-command gap,
// hunting an engine wedge. The other tests drive a kernel-like enumeration
// and the two lost-ACK cases a host controller produces.
//
// LOST ACK BEHAVIOUR
// The device now uses the ported TinyFPGA protocol engine, which follows the
// USB rule for a bulk IN whose handshake is lost: it keeps the packet and
// retransmits it, with the SAME data toggle, on the next IN token. The host
// side of that rule is to accept the duplicate, ACK it, and poll again. So
// the recovery tests below drop the ACK of a response and then let the host
// clear the duplicate, instead of expecting the device to throw the response
// away when a new command arrives.

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'mimic_usb_tb.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('kernel-like enumeration then EP1 read', () async {
    final tb = await buildMimicUsbTb('mimic_gap_enum_tb');

    // A kernel-like enumeration: GET_DESCRIPTOR(device), SET_ADDRESS,
    // GET_DESCRIPTOR(config), the string reads, SET_CONFIGURATION, each with
    // its full status stage. Then the very first EP1 bulk exchange must
    // behave.
    final dev = await tb.controlRead(0, [
      0x80,
      0x06,
      0x00,
      0x01,
      0x00,
      0x00,
      0x12,
      0x00,
    ], 'GET_DESCRIPTOR(device)');
    expect(dev.length, equals(18), reason: 'device descriptor is 18 bytes');
    expect(dev[0], equals(18), reason: 'bLength');
    expect(dev[1], equals(0x01), reason: 'bDescriptorType DEVICE');
    expect(
      dev[7],
      equals(mimicTbMaxPacket),
      reason: 'bMaxPacketSize0 is the endpoint buffer size',
    );
    expect(dev[8] | (dev[9] << 8), equals(0x1209), reason: 'idVendor');
    expect(dev[10] | (dev[11] << 8), equals(0x10C1), reason: 'idProduct');

    await tb.controlNoData(0, [
      0x00,
      0x05,
      mimicTbDevAddr,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
    ], 'SET_ADDRESS');

    final cfg = await tb.controlRead(mimicTbDevAddr, [
      0x80,
      0x06,
      0x00,
      0x02,
      0x00,
      0x00,
      0x20,
      0x00,
    ], 'GET_DESCRIPTOR(config)');
    expect(cfg.length, equals(32), reason: 'config tree is 32 bytes');
    expect(cfg[1], equals(0x02), reason: 'bDescriptorType CONFIGURATION');
    // The two bulk endpoint descriptors must declare the same 32-byte
    // maximum packet size the endpoint buffer holds.
    expect(
      cfg[22] | (cfg[23] << 8),
      equals(mimicTbMaxPacket),
      reason: 'EP1 OUT wMaxPacketSize',
    );
    expect(
      cfg[29] | (cfg[30] << 8),
      equals(mimicTbMaxPacket),
      reason: 'EP1 IN wMaxPacketSize',
    );

    for (final index in [0, 1, 2, 3]) {
      final s = await tb.controlRead(mimicTbDevAddr, [
        0x80,
        0x06,
        index,
        0x03,
        0x09,
        0x04,
        0xFF,
        0x00,
      ], 'GET_DESCRIPTOR(string $index)');
      expect(s, isNotEmpty, reason: 'string $index is served');
      expect(s[0], equals(s.length), reason: 'string $index bLength');
      expect(s[1], equals(0x03), reason: 'string $index type');
    }

    await tb.controlNoData(mimicTbDevAddr, [
      0x00,
      0x09,
      0x01,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
    ], 'SET_CONFIGURATION');
    await tb.settle(50);

    // The first EP1 bulk exchange after the full enumeration.
    expect(
      await tb.bulkOut(mimicReadFrame(0x00, 4)),
      isTrue,
      reason: 'read ACK',
    );
    final rbytes = await tb.bulkInBytes(4);
    expect(
      rbytes.length,
      equals(4),
      reason: 'first EP1 response is 4 bytes, got ${rbytes.length}',
    );
    expect(mimicWord(rbytes), equals(0x4D494D43), reason: 'the ID word');
  });

  test('write-then-read gap sweep finds no wedge', () async {
    final tb = await buildMimicUsbTb('mimic_gap_tb', maxSimTime: 2000000000);
    await tb.enumerate();

    // Sweep the gap between the WRITE command and the READ command.
    final failures = <int>[];
    for (var gap = 0; gap <= 64; gap++) {
      final value = 0xDEAD0000 | gap;
      final ok = await tb.bulkOut(
        mimicWriteFrame(0x14, [
          value & 0xFF,
          (value >> 8) & 0xFF,
          (value >> 16) & 0xFF,
          (value >> 24) & 0xFF,
        ]),
      );
      if (!ok) {
        failures.add(gap);
        continue;
      }

      await tb.settle(gap);

      if (!await tb.bulkOut(mimicReadFrame(0x14, 4))) {
        failures.add(gap);
        continue;
      }

      await tb.settle(20);
      final resp = await tb.bulkIn();
      final rbytes = resp.bytes;
      if (rbytes.length != 4 || mimicWord(rbytes) != value) {
        failures.add(gap);
      }
    }
    expect(failures, isEmpty, reason: 'wedges at gaps: $failures');
  });

  test('a lost IN handshake recovers on the duplicate', () async {
    final tb = await buildMimicUsbTb('mimic_gap_miss_tb');
    await tb.enumerate();

    // WRITE, read back, but DO NOT ACK the response. The device never sees
    // the handshake, so it keeps the packet.
    expect(
      await tb.bulkOut(mimicWriteFrame(0x14, [0xBE, 0xBA, 0xFE, 0xCA])),
      isTrue,
      reason: 'write ACK',
    );
    expect(
      await tb.bulkOut(mimicReadFrame(0x14, 4)),
      isTrue,
      reason: 'read ACK',
    );
    final first = await tb.bulkIn(ack: false);
    expect(
      mimicWord(first.bytes),
      equals(0xCAFEBABE),
      reason: 'first response',
    );

    // The host's NEXT command still gets through: the OUT endpoint does not
    // depend on the IN endpoint.
    expect(
      await tb.bulkOut(mimicReadFrame(0x14, 4)),
      isTrue,
      reason: 'OUT after the lost handshake completes',
    );

    // The device retransmits the packet it never saw acknowledged, with the
    // same data toggle. The host ACKs the duplicate and polls again.
    final dup = await tb.bulkIn();
    expect(
      dup.pid,
      equals(first.pid),
      reason: 'the retransmission keeps the data toggle',
    );
    expect(
      mimicWord(dup.bytes),
      equals(0xCAFEBABE),
      reason: 'the retransmission carries the same bytes',
    );

    // The response to the new command follows, with the toggle flipped.
    final fresh = await tb.bulkIn();
    expect(
      fresh.pid,
      isNot(equals(first.pid)),
      reason: 'the fresh packet flips the data toggle',
    );
    expect(
      mimicWord(fresh.bytes),
      equals(0xCAFEBABE),
      reason: 'response after the recovery',
    );
  });

  test('repeated lost IN handshakes stay stable', () async {
    final tb = await buildMimicUsbTb(
      'mimic_gap_miss_loop_tb',
      maxSimTime: 2000000000,
    );
    await tb.enumerate();

    // Every round writes a new value, reads it back, and drops the handshake
    // of the response. The next round must clear the retransmission and then
    // read the fresh value. Twenty rounds must all deliver.
    var failures = 0;
    var previous = 0;
    for (var i = 0; i < 20; i++) {
      final value = 0xBEEF0000 | i;
      if (!await tb.bulkOut(
        mimicWriteFrame(0x14, [
          value & 0xFF,
          (value >> 8) & 0xFF,
          (value >> 16) & 0xFF,
          (value >> 24) & 0xFF,
        ]),
      )) {
        failures++;
        continue;
      }
      if (!await tb.bulkOut(mimicReadFrame(0x14, 4))) {
        failures++;
        continue;
      }

      if (i > 0) {
        // Clear the packet whose handshake the device never saw.
        final dup = await tb.bulkIn();
        if (dup.bytes.length != 4 || mimicWord(dup.bytes) != previous) {
          failures++;
          continue;
        }
      }

      // The fresh response, whose handshake is dropped again.
      final resp = await tb.bulkIn(ack: false);
      if (resp.bytes.length != 4 || mimicWord(resp.bytes) != value) {
        failures++;
        continue;
      }
      previous = value;
    }
    expect(failures, equals(0), reason: '$failures of 20 rounds failed');
  });
}
