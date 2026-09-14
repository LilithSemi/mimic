// Full-USB-path round trip: the host model drives real D+/D- packets through
// the ported TinyFPGA protocol engine, the EP1 bulk endpoints, the command
// engine, the Wishbone fabric, and the MimicSdCard slave. The command-level
// tb ports are NOT used: this test exercises the synthesizable data path end
// to end.
//
// The sequence mirrors what the host runtime does on real hardware:
//   1. Enumerate: SET_ADDRESS(7), SET_CONFIGURATION(1), with full status
//      stages (the IN ZLP of each included).
//   2. Bulk OUT to EP1: a WRITE command frame to SCRATCH.
//   3. Bulk OUT to EP1: a READ command frame for SCRATCH.
//   4. Bulk IN from EP1: the response must carry the written word.
//
// The host is [MimicUsbTb]: it builds real USB packets (token packets with a
// CRC5, data packets with a CRC16), applies NRZI and bit stuffing, and drives
// the pads four clock cycles per bit.
//
// PACKET SIZE
// Every endpoint of this device declares a 32-byte maximum packet size,
// because the ported endpoint buffer holds 32 bytes. A response longer than
// 32 bytes therefore arrives as several packets, and the tests below count
// them.

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'mimic_usb_tb.dart';
import 'usb_host_model.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test(
    'enumerate, WRITE to SCRATCH, READ it back over the real USB path',
    () async {
      final tb = await buildMimicUsbTb('mimic_usb_tb');
      await tb.enumerate();

      // WRITE 0xCAFEBABE to SCRATCH (0x14) on EP1 OUT.
      expect(
        await tb.bulkOut(mimicWriteFrame(0x14, [0xBE, 0xBA, 0xFE, 0xCA])),
        isTrue,
        reason: 'device ACKs the WRITE',
      );
      await tb.settle(50);

      // READ SCRATCH (0x14, 4 bytes) on EP1 OUT.
      expect(
        await tb.bulkOut(mimicReadFrame(0x14, 4)),
        isTrue,
        reason: 'device ACKs the READ',
      );

      final rbytes = await tb.bulkInBytes(4);
      expect(
        rbytes.length,
        equals(4),
        reason: 'READ response is 4 bytes, got ${rbytes.length}',
      );
      expect(
        mimicWord(rbytes),
        equals(0xCAFEBABE),
        reason: 'SCRATCH round trip over the real USB path',
      );
    },
  );

  test('multi-word READ (8 bytes) over the real USB path', () async {
    final tb = await buildMimicUsbTb('mimic_usb_mw_tb');
    await tb.enumerate();

    // READ 8 bytes from 0x00: ID + VERSION.
    expect(
      await tb.bulkOut(mimicReadFrame(0x00, 8)),
      isTrue,
      reason: 'device ACKs the READ',
    );

    final rbytes = await tb.bulkInBytes(8);
    expect(
      rbytes.length,
      equals(8),
      reason: 'multi-word READ returns 8 bytes, got ${rbytes.length}',
    );
    expect(
      mimicWord(rbytes.sublist(0, 4)),
      equals(0x4D494D43),
      reason: 'ID word',
    );
    expect(
      mimicWord(rbytes.sublist(4, 8)),
      equals(0x00010100),
      reason: 'VERSION word',
    );
  });

  test('multi-packet READ (128 bytes) over the real USB path', () async {
    final tb = await buildMimicUsbTb('mimic_usb_mp_tb');
    await tb.enumerate();

    // READ 128 bytes from 0x00. With a 32-byte endpoint that is four full
    // packets.
    expect(
      await tb.bulkOut(mimicReadFrame(0x00, 128)),
      isTrue,
      reason: 'device ACKs the READ(128)',
    );

    final packets = <UsbRxPacket>[];
    final all = <int>[];
    for (var i = 0; i < 4; i++) {
      final p = await tb.bulkIn();
      expect(
        p.isEmpty,
        isFalse,
        reason: 'packet $i of the 128-byte response arrives',
      );
      expect(
        p.bytes.length,
        equals(mimicTbMaxPacket),
        reason: 'packet $i fills wMaxPacketSize, got ${p.bytes.length}',
      );
      packets.add(p);
      all.addAll(p.bytes);
    }
    expect(all.length, equals(128), reason: 'four packets carry 128 bytes');
    expect(
      mimicWord(all.sublist(0, 4)),
      equals(0x4D494D43),
      reason: 'word 0 is ID',
    );
    expect(
      mimicWord(all.sublist(4, 8)),
      equals(0x00010100),
      reason: 'word 1 is VERSION',
    );
    // The bulk IN data toggle must alternate across the four packets.
    for (var i = 1; i < packets.length; i++) {
      expect(
        packets[i].pid,
        isNot(equals(packets[i - 1].pid)),
        reason: 'packet $i flips the data toggle',
      );
    }
  });

  test(
    '36-byte READ crosses the packet boundary and the device recovers',
    () async {
      final tb = await buildMimicUsbTb('mimic_usb_36_tb');
      await tb.enumerate();

      // READ 36 bytes from 0x00: nine words, crossing DATA_IN at 0x20 and the
      // 32-byte packet boundary.
      expect(
        await tb.bulkOut(mimicReadFrame(0x00, 36)),
        isTrue,
        reason: 'device ACKs the READ(36)',
      );

      final first = await tb.bulkIn();
      expect(
        first.bytes.length,
        equals(mimicTbMaxPacket),
        reason: 'first packet fills the endpoint, got ${first.bytes.length}',
      );
      final second = await tb.bulkIn();
      expect(
        second.bytes.length,
        equals(4),
        reason:
            'second packet carries the remainder, got '
            '${second.bytes.length}',
      );
      final all = [...first.bytes, ...second.bytes];
      expect(all.length, equals(36), reason: '36-byte READ returns 36 bytes');
      expect(
        mimicWord(all.sublist(0, 4)),
        equals(0x4D494D43),
        reason: 'ID word',
      );

      // The device must still answer a follow-up read.
      expect(
        await tb.bulkOut(mimicReadFrame(0x00, 4)),
        isTrue,
        reason: 'device ACKs the follow-up',
      );
      final again = await tb.bulkInBytes(4);
      expect(again.length, equals(4), reason: 'follow-up read still works');
      expect(
        mimicWord(again),
        equals(0x4D494D43),
        reason: 'follow-up reads ID',
      );
    },
  );

  // A command frame longer than the 32-byte packet size arrives as several
  // OUT packets. The command engine must parse the whole frame as ONE
  // command: a per-packet restart drops every byte after the first packet.
  test('a WRITE frame split across three packets writes every word', () async {
    final tb = await buildMimicUsbTb('mimic_usb_mpo_tb');
    await tb.enumerate();

    // 15 words (60 bytes) from 0x00. With the 7-byte header the frame is 67
    // bytes: three OUT packets of 32, 32 and 3 bytes.
    final words = List.generate(15, (i) => 0xC0DE0000 | (i + 1));
    final frame = mimicWriteFrame(0x00, mimicWordBytes(words));
    expect(frame.length, equals(67), reason: 'the frame needs three packets');

    expect(
      await tb.bulkOutFrame(frame),
      isTrue,
      reason: 'the device ACKs all three OUT packets',
    );
    await tb.settle(50);

    // Read the whole CSR block back. The read-only registers keep their
    // fixed values, and every read-write register holds the word the frame
    // carried for it.
    expect(
      await tb.bulkOut(mimicReadFrame(0x00, 60)),
      isTrue,
      reason: 'the device ACKs the read back',
    );
    final rbytes = await tb.bulkInBytes(60);
    expect(rbytes.length, equals(60), reason: 'the read back returns 60 bytes');

    int word(int index) => mimicWord(rbytes.sublist(index * 4, index * 4 + 4));

    expect(word(0), equals(MimicRegValue.id), reason: 'ID stays read-only');
    expect(
      word(1),
      equals(MimicRegValue.version),
      reason: 'VERSION stays read-only',
    );
    // CTRL and NUM_BLOCKS come from the first OUT packet, SCRATCH straddles
    // no boundary but sits late in it, and IRQ_ENABLE comes from the second
    // OUT packet.
    expect(word(2), equals(words[2]), reason: 'CTRL from packet 1');
    expect(word(4), equals(words[4]), reason: 'NUM_BLOCKS from packet 1');
    expect(word(5), equals(words[5]), reason: 'SCRATCH from packet 1');
    expect(word(13), equals(words[13]), reason: 'IRQ_ENABLE from packet 2');
  });

  // The last word of this frame straddles the boundary between the second
  // and the third OUT packet, so it proves the byte order holds across a
  // packet boundary.
  test(
    'a WRITE_STREAM frame split across three packets keeps byte order',
    () async {
      final tb = await buildMimicUsbTb('mimic_usb_mps_tb');
      await tb.enumerate();

      // 15 words to the fixed SCRATCH address: a 67-byte frame again. Every
      // word writes SCRATCH, so SCRATCH must hold the last word of the frame.
      // Byte 63 of the frame is the low byte of that word and sits in the
      // second packet. Bytes 64 to 66 are the other three and sit in the
      // third.
      final words = List.generate(15, (i) => 0x5A5A0000 | (i + 1));
      final frame = mimicWriteStreamFrame(
        MimicReg.scratch,
        mimicWordBytes(words),
      );
      expect(frame.length, equals(67), reason: 'the frame needs three packets');

      expect(
        await tb.bulkOutFrame(frame),
        isTrue,
        reason: 'the device ACKs all three OUT packets',
      );
      await tb.settle(50);

      expect(
        await tb.bulkOut(mimicReadFrame(MimicReg.scratch, 4)),
        isTrue,
        reason: 'the device ACKs the read back',
      );
      final rbytes = await tb.bulkInBytes(4);
      expect(rbytes.length, equals(4), reason: 'the read back returns 4 bytes');
      expect(
        mimicWord(rbytes),
        equals(words.last),
        reason: 'SCRATCH holds the last word of the stream',
      );
    },
  );

  // The preempt keeps its job: a host that walks away from a response and
  // sends a NEW command must not wedge the engine. The new command starts a
  // new transfer, because the frame before it ended with a short packet.
  test('a new command after an abandoned response still preempts', () async {
    final tb = await buildMimicUsbTb('mimic_usb_preempt_tb');
    await tb.enumerate();

    // READ 128 bytes: four IN packets. Take the first packet only and walk
    // away from the rest.
    expect(
      await tb.bulkOut(mimicReadFrame(0x00, 128)),
      isTrue,
      reason: 'the device ACKs the READ(128)',
    );
    final first = await tb.bulkIn();
    expect(first.isEmpty, isFalse, reason: 'the first response packet arrives');
    expect(
      first.bytes.length,
      equals(mimicTbMaxPacket),
      reason: 'the first response packet is full',
    );

    // A new command, while the rest of the response is still in flight.
    expect(
      await tb.bulkOutFrame(
        mimicWriteFrame(MimicReg.scratch, mimicWordBytes([0xDECAFBAD])),
      ),
      isTrue,
      reason: 'the device ACKs the new WRITE',
    );
    await tb.settle(50);
    expect(
      await tb.bulkOut(mimicReadFrame(MimicReg.scratch, 4)),
      isTrue,
      reason: 'the device ACKs the new READ',
    );

    // The endpoint may still hold a packet of the abandoned response, so
    // read until the 4-byte answer of the new READ arrives.
    var got = -1;
    for (var i = 0; i < 6 && got < 0; i++) {
      final p = await tb.bulkIn();
      if (p.isEmpty) break;
      if (p.bytes.length == 4) got = mimicWord(p.bytes);
    }
    expect(
      got,
      equals(0xDECAFBAD),
      reason: 'the new command wins and the device stays alive',
    );
  });
}
