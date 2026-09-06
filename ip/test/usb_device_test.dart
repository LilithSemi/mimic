// Tests for MimicUsbDevice + MimicUsbCmdEngine + the CSR round trip.
//
// MimicUsbDevice is a custom vendor-class full-speed USB device
// (bDeviceClass 0xFF) that exposes TWO bulk endpoints (EP1 OUT
// host->device, EP1 IN device->host) and a command protocol on top of them
// that performs Wishbone READS and WRITES: the command engine is a
// Wishbone MASTER, so a host can write the SD card's CSRs and read them
// back over USB.
//
// Command framing (host -> device, on the bulk OUT stream):
//   header = { opcode:u8, addr:u32 (LE), len:u16 (LE) }  (7 bytes)
//   WRITE (opcode 0x01): header then `len` data bytes. Bytes accumulate into
//                        32-bit words. Each full word is written to
//                        Wishbone at the word-aligned address, and the
//                        address advances one word per write.
//   READ  (opcode 0x02): header only. The device fetches `len` bytes from
//                        Wishbone starting at addr and emits them on the
//                        bulk IN stream (resp_data / resp_valid, paced by
//                        resp_ready).
//   WRITE_STREAM (opcode 0x03): like WRITE, but the address stays fixed
//                        (a FIFO push).
//
// The tests run at the COMMAND/byte-stream level through the REAL SoC
// fabric: buildMimicSoc(tbCmdPorts: true) wires the command engine through
// harbor's Wishbone decoder into the real MimicSdCard slave, and the
// testbench drives the exposed cmd_*/resp_* ports. The raw dp/dm
// enumeration path is harbor's own engine territory and is not re-tested
// here; a separate SV-emission test proves the PHY/packet submodules are
// present in a full build.

import 'package:harbor/harbor.dart';
import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Golden helpers (host-side, independent of the RTL).

List<int> _le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
List<int> _le32(int v) => [
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
];

List<int> _writeCmd(int addr, List<int> data) => [
  MimicUsbOpcode.write,
  ..._le32(addr),
  ..._le16(data.length),
  ...data,
];

List<int> _readCmd(int addr, int len) => [
  MimicUsbOpcode.read,
  ..._le32(addr),
  ..._le16(len),
];

List<int> _writeStreamCmd(int addr, List<int> data) => [
  MimicUsbOpcode.writeStream,
  ..._le32(addr),
  ..._le16(data.length),
  ...data,
];

int _word(List<int> b) => b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);

// The simulator lifecycle of this file.
//
// A test that starts the simulator must also stop it, and it must stop it
// when the body THROWS as well as when the body passes. `Simulator.reset()`
// CLOSES the event streams of the simulator, so a run that is still ticking
// when `tearDown` resets throws "Bad state: Cannot add new events after
// calling close" and that error hides the failure that really happened.
//
// `_startSim` keeps the future of the run, and `_stopSim` asks the run to
// end and then WAITS for it, so `tearDown` only ever resets a simulator
// that has stopped. A test that never started one leaves the future null
// and `_stopSim` does nothing.
Future<void>? _simRun;

void _startSim(int maxSimTime) {
  Simulator.setMaxSimTime(maxSimTime);
  _simRun = Simulator.run();
}

Future<void> _stopSim() async {
  final run = _simRun;
  _simRun = null;
  if (run == null) {
    return;
  }
  await Simulator.endSimulation();
  await run;
}

// Drives every input of a `tbCmdPorts` SoC to a real value and takes the
// SoC out of reset.
//
// The SD pins get a value even though this bench drives the command ports
// only. The SoC holds an SD card and the card pins are ports of the top
// module, so an input with no driver holds X. The SD clock stays LOW, which
// is what a card sees before a host arrives, and CMD and DAT stay HIGH,
// which is what the pull-up of an idle line gives.
//
// The ORDER matters twice over:
//   - The SD pins take their value BEFORE the reset edge. ROHD builds the
//     asynchronous reset of [MimicResetSync] as a flop whose triggers are
//     the SD clock AND the reset, and it drives the whole flop to X while
//     ANY trigger of it is X.
//   - The reset goes to 1 ONE CLOCK after it goes to 0, so the SD domain
//     sees a true 0 to 1 edge. Two injects in one timestamp make the edge
//     an X to 1 edge, which ROHD does not treat as an edge at all, and the
//     SD domain then keeps the X it powered up with for the whole test.
Future<void> _resetSoc(HarborSoC soc, Logic clk) async {
  soc.input(mimicSdClkPinName).inject(0);
  soc.input('sd_cmd_in').inject(1);
  soc.input('sd_dat_in').inject(1);
  // Idle J state on the line (dp=1, dm=0): no bus reset, no packets.
  soc.input('usb_dp').inject(1);
  soc.input('usb_dm').inject(0);
  soc.input('cmd_data').inject(0);
  soc.input('cmd_valid').inject(0);
  soc.input('resp_ready').inject(0);
  soc.input('reset').inject(0);
  await clk.nextPosedge;
  soc.input('reset').inject(1);
  for (var i = 0; i < 5; i++) {
    await clk.nextPosedge;
  }
  soc.input('reset').inject(0);
  await clk.nextPosedge;
}

// Feed one command's bytes into the bulk-OUT stream, honoring cmd_ready.
Future<void> _feedCmd(
  HarborSoC soc,
  Logic clk,
  Logic cmdData,
  Logic cmdValid,
  List<int> bytes,
) async {
  for (final b in bytes) {
    var guard = 0;
    while (soc.output('cmd_ready').value.toInt() == 0 && guard < 200000) {
      guard++;
      await clk.nextPosedge;
    }
    cmdData.put(b);
    cmdValid.put(1);
    await clk.nextPosedge;
    cmdValid.put(0);
    cmdData.put(0);
    // One idle cycle between bytes (the engine can NAK / process).
    await clk.nextPosedge;
  }
}

// Collect `n` response bytes from the bulk-IN stream with a per-byte
// valid/ready handshake. The command engine drives resp_data
// COMBINATIONALLY (byte[count]) and holds each byte until it sees
// resp_ready, advancing the next cycle. So we must consume ONE byte per
// resp_ready pulse: on a cycle where resp_valid is high, latch resp_data and
// assert resp_ready for that cycle (the engine accepts and advances), then
// drop resp_ready and wait for the next byte. Holding resp_ready
// continuously would let the engine race ahead of our async sampling and we
// would miss/duplicate bytes. Pulsing per byte is the correct contract (the
// same one the harbor EP1-IN assembler uses).
Future<List<int>> _collectResp(
  HarborSoC soc,
  Logic clk,
  Logic respReady,
  int n,
) async {
  final out = <int>[];
  var guard = 0;
  respReady.put(0);
  while (out.length < n && guard < 2000000) {
    guard++;
    final validNow =
        soc.output('resp_valid').value.isValid &&
        soc.output('resp_valid').value.toInt() == 1;
    if (validNow) {
      // Latch the currently-held byte and accept it this cycle (pulse ready
      // so the engine advances to the next byte on the coming edge).
      out.add(soc.output('resp_data').value.toInt());
      respReady.put(1);
      await clk.nextPosedge;
      respReady.put(0);
      // Let the combinational resp_data settle to the next byte before
      // sampling.
      await clk.nextPosedge;
    } else {
      await clk.nextPosedge;
    }
  }
  respReady.put(0);
  return out;
}

// Wait for the command engine to go idle (busy low).
Future<void> _waitIdle(HarborSoC soc, Logic clk) async {
  var guard = 0;
  while (soc.output('busy').value.toInt() == 1 && guard < 200000) {
    guard++;
    await clk.nextPosedge;
  }
}

void main() {
  tearDown(() async {
    await _stopSim();
    await Simulator.reset();
  });

  // Config validation.
  group('MimicUsbDeviceConfig validation', () {
    test('rejects a non-[8,16,32,64] data width', () {
      expect(
        () => MimicUsbDeviceConfig(busDataWidth: 12).validate(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects an out-of-range address width', () {
      expect(
        () => MimicUsbDeviceConfig(busAddressWidth: 0).validate(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects an out-of-range idProduct', () {
      expect(
        () => const MimicUsbDeviceConfig(idProduct: 0x10000).validate(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects an empty or oversized serialNumber', () {
      expect(
        () => const MimicUsbDeviceConfig(serialNumber: '').validate(),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => MimicUsbDeviceConfig(serialNumber: 'x' * 127).validate(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('accepts a sane default', () {
      expect(() => const MimicUsbDeviceConfig().validate(), returnsNormally);
    });

    test('accepts a serial number', () {
      expect(
        () => const MimicUsbDeviceConfig(serialNumber: 'mimic-42').validate(),
        returnsNormally,
      );
    });

    test('the default product id is the Mimic one', () {
      expect(const MimicUsbDeviceConfig().idProduct, equals(0x10C1));
    });
  });

  // Descriptor ROM: vendor-class device descriptor + bulk-endpoint config.
  group('MimicUsbDescriptorRom', () {
    test(
      'device descriptor is vendor-class (0xFF) with the configured VID/PID',
      () {
        final dev = MimicUsbDescriptorRom.deviceDescriptor;
        expect(dev.length, equals(18));
        expect(dev[0], equals(18)); // bLength
        expect(dev[1], equals(0x01)); // DEVICE
        expect(dev[4], equals(0xFF)); // bDeviceClass = vendor-specific
        // 32 is the ceiling of the ported TinyFPGA endpoint buffer.
        expect(dev[7], equals(mimicUsbMaxPacketSize)); // bMaxPacketSize0
        expect(mimicUsbMaxPacketSize, equals(32));
        // Default VID/PID template bytes.
        expect(dev[8] | (dev[9] << 8), equals(0x1209));
        expect(dev[10] | (dev[11] << 8), equals(0x10C1));
        // No serial by default.
        expect(dev[16], equals(0));
      },
    );

    test('descriptorEntries patches VID/PID into the device descriptor', () {
      final ents = MimicUsbDescriptorRom.descriptorEntries(
        idVendor: 0x1234,
        idProduct: 0x5678,
      );
      final dev = ents.firstWhere((e) => e.type == 0x01).bytes;
      expect(dev[8] | (dev[9] << 8), equals(0x1234));
      expect(dev[10] | (dev[11] << 8), equals(0x5678));
    });

    test('config has one interface with two bulk endpoints (EP1 OUT + EP1 IN), '
        'maxPacketSize 32', () {
      final cfg = MimicUsbDescriptorRom.configDescriptorBulk;
      // wTotalLength == real byte count.
      final wTotal = cfg[2] | (cfg[3] << 8);
      expect(wTotal, equals(cfg.length));
      // config(9) + interface(9) + ep(7) + ep(7) = 32.
      expect(cfg.length, equals(32));
      // Interface descriptor at offset 9.
      expect(cfg[9 + 1], equals(0x04)); // INTERFACE
      expect(cfg[9 + 4], equals(2)); // bNumEndpoints = 2
      expect(cfg[9 + 5], equals(0xFF)); // bInterfaceClass = vendor
      // EP1 OUT descriptor at offset 18.
      final epOut = cfg.sublist(18, 25);
      expect(epOut[1], equals(0x05)); // ENDPOINT
      expect(epOut[2], equals(0x01)); // EP1 OUT (dir bit 7 = 0)
      expect(epOut[3], equals(0x02)); // bmAttributes = bulk
      expect(
        epOut[4] | (epOut[5] << 8),
        equals(mimicUsbMaxPacketSize),
      ); // wMaxPacketSize
      // EP1 IN descriptor at offset 25.
      final epIn = cfg.sublist(25, 32);
      expect(epIn[1], equals(0x05));
      expect(epIn[2], equals(0x81)); // EP1 IN (dir bit 7 = 1)
      expect(epIn[3], equals(0x02));
      expect(epIn[4] | (epIn[5] << 8), equals(mimicUsbMaxPacketSize));
    });

    // The descriptor set MimicUsbDevice hands to the ported TinyFPGA core.
    // Its endpoint buffer holds 32 bytes and no more, so every packet-size
    // field of every served descriptor must declare exactly that. This walks
    // the CONFIGURATION tree by bLength, so a new endpoint descriptor cannot
    // slip in with a size the buffer cannot hold.
    test('every descriptorEntries packet size is the endpoint buffer size', () {
      for (final bulk in [true, false]) {
        final ents = MimicUsbDescriptorRom.descriptorEntries(
          bulkEndpoints: bulk,
        );
        final dev = ents.firstWhere((e) => e.type == 0x01).bytes;
        expect(
          dev[7],
          equals(mimicUsbMaxPacketSize),
          reason: 'bMaxPacketSize0 (bulkEndpoints: $bulk)',
        );
        final cfg = ents.firstWhere((e) => e.type == 0x02).bytes;
        var endpoints = 0;
        for (var offset = 0; offset < cfg.length;) {
          final subLength = cfg[offset];
          expect(subLength, greaterThan(0), reason: 'bLength at $offset');
          if (cfg[offset + 1] == 0x05) {
            endpoints++;
            expect(
              cfg[offset + 4] | (cfg[offset + 5] << 8),
              equals(mimicUsbMaxPacketSize),
              reason: 'wMaxPacketSize at $offset (bulkEndpoints: $bulk)',
            );
          }
          offset += subLength;
        }
        expect(endpoints, equals(bulk ? 2 : 0), reason: 'endpoint count');
      }
    });

    test('control-only (bulkEndpoints:false) config advertises 0 endpoints, '
        'wTotalLength 18, and carries no endpoint descriptors', () {
      final cfg = MimicUsbDescriptorRom.configDescriptorNoBulk;
      // wTotalLength == real byte count == config(9) + interface(9) = 18.
      final wTotal = cfg[2] | (cfg[3] << 8);
      expect(wTotal, equals(cfg.length));
      expect(cfg.length, equals(18));
      expect(cfg[1], equals(0x02)); // CONFIGURATION
      // Interface descriptor at offset 9.
      expect(cfg[9 + 0], equals(9)); // bLength
      expect(cfg[9 + 1], equals(0x04)); // INTERFACE
      expect(cfg[9 + 4], equals(0)); // bNumEndpoints = 0
      expect(cfg[9 + 5], equals(0xFF)); // bInterfaceClass = vendor
      // No ENDPOINT descriptor and no endpoint addresses anywhere.
      expect(cfg.contains(0x05), isFalse, reason: 'no ENDPOINT type');
      expect(cfg.contains(0x81), isFalse, reason: 'no EP1 IN address');
      // 0x01 appears only as bNumInterfaces/bConfigurationValue header
      // fields, never as an endpoint address; the ENDPOINT-absence check
      // above already proves no endpoint descriptor exists.
    });

    test('ROM presents device descriptor bytes at offset, present=1', () async {
      final rom = MimicUsbDescriptorRom(name: 'rom_t');
      await rom.build();
      rom.input('desc_type').put(0x01);
      rom.input('desc_index').put(0x00);
      final dev = MimicUsbDescriptorRom.deviceDescriptor;
      expect(rom.output('present').value.toInt(), equals(1));
      expect(rom.output('length').value.toInt(), equals(dev.length));
      for (var i = 0; i < dev.length; i++) {
        rom.input('offset').put(i);
        expect(
          rom.output('data').value.toInt(),
          equals(dev[i]),
          reason: 'device descriptor byte $i',
        );
      }
      // An absent descriptor reports present=0.
      rom.input('desc_type').put(0x09);
      expect(rom.output('present').value.toInt(), equals(0));
    });

    test('string indexes: 1 manufacturer, 2 product, 3 interface', () {
      final ents = MimicUsbDescriptorRom.descriptorEntries();
      final strings = {
        for (final e in ents.where((e) => e.type == 0x03)) e.index: e.bytes,
      };
      expect(strings.containsKey(1), isTrue);
      expect(strings.containsKey(2), isTrue);
      expect(strings.containsKey(3), isTrue);
      // No serial string without a serial.
      expect(strings.containsKey(4), isFalse);
      // The device descriptor points at the same indexes.
      final dev = ents.firstWhere((e) => e.type == 0x01).bytes;
      expect(dev[14], equals(1)); // iManufacturer
      expect(dev[15], equals(2)); // iProduct
      expect(dev[16], equals(0)); // iSerialNumber (none)
      // Interface descriptor iInterface.
      final cfg = ents.firstWhere((e) => e.type == 0x02).bytes;
      expect(cfg[9 + 8], equals(3)); // iInterface
    });

    test('a serial number lands at string index 4 and iSerialNumber=4', () {
      final ents = MimicUsbDescriptorRom.descriptorEntries(
        serialNumber: 'mimic-0001',
      );
      final strings = {
        for (final e in ents.where((e) => e.type == 0x03)) e.index: e.bytes,
      };
      expect(strings.containsKey(4), isTrue);
      final dev = ents.firstWhere((e) => e.type == 0x01).bytes;
      expect(dev[16], equals(4)); // iSerialNumber
      // The serial string is a well-formed STRING descriptor of the text.
      final serial = strings[4]!;
      expect(serial[0], equals(2 + 2 * 'mimic-0001'.length)); // bLength
      expect(serial[1], equals(0x03)); // STRING
      expect(serial[2], equals('m'.codeUnitAt(0))); // first character
    });

    test(
      'control-only ROM serves the 0-endpoint config byte-for-byte',
      () async {
        final rom = MimicUsbDescriptorRom(
          name: 'rom_nobulk',
          bulkEndpoints: false,
        );
        await rom.build();
        rom.input('desc_type').put(0x02);
        rom.input('desc_index').put(0x00);
        final cfg = MimicUsbDescriptorRom.configDescriptorNoBulk;
        expect(rom.output('present').value.toInt(), equals(1));
        expect(rom.output('length').value.toInt(), equals(cfg.length));
        for (var i = 0; i < cfg.length; i++) {
          rom.input('offset').put(i);
          expect(
            rom.output('data').value.toInt(),
            equals(cfg[i]),
            reason: 'nobulk config byte $i',
          );
        }
      },
    );

    test(
      'descriptorEntries(bulkEndpoints:false) injects the 0-endpoint config',
      () {
        final ents = MimicUsbDescriptorRom.descriptorEntries(
          bulkEndpoints: false,
        );
        final cfg = ents.firstWhere((e) => e.type == 0x02).bytes;
        expect(cfg.length, equals(18));
        expect(cfg[9 + 4], equals(0)); // bNumEndpoints = 0
        // device + 4 strings (langid + 3) still present.
        expect(ents.where((e) => e.type == 0x03).length, equals(4));
      },
    );
  });

  // Command-level round trip through the REAL SoC fabric: the command
  // engine drives harbor's Wishbone decoder into the real MimicSdCard
  // slave, and the testbench drives the exposed cmd_*/resp_* ports of the
  // tbCmdPorts build.
  group('CSR round trip through the fabric', () {
    test(
      'WRITE to SCRATCH lands; READ reads it back; ID/VERSION read fixed',
      () async {
        final soc = buildMimicSoc(name: 'mimic_cmd_tb', tbCmdPorts: true);

        final clk = SimpleClockGenerator(10).clk;
        soc.port('clk').getsLogic(clk);
        await soc.build();

        final cmdData = soc.input('cmd_data');
        final cmdValid = soc.input('cmd_valid');
        final respReady = soc.input('resp_ready');

        _startSim(20000000);
        await _resetSoc(soc, clk);

        // WRITE 0xDEADBEEF to SCRATCH (0x14, 4 bytes).
        await _feedCmd(
          soc,
          clk,
          cmdData,
          cmdValid,
          _writeCmd(MimicReg.scratch, _le32(0xDEADBEEF)),
        );
        await _waitIdle(soc, clk);

        // READ SCRATCH back (4 bytes): the round trip through the bridge RTL
        // and the fabric must return the written word byte-exact.
        await _feedCmd(
          soc,
          clk,
          cmdData,
          cmdValid,
          _readCmd(MimicReg.scratch, 4),
        );
        final scratch = await _collectResp(soc, clk, respReady, 4);
        expect(
          _word(scratch),
          equals(0xDEADBEEF),
          reason: 'SCRATCH round trip',
        );

        // READ ID (0x00): the MIMC magic.
        await _feedCmd(soc, clk, cmdData, cmdValid, _readCmd(MimicReg.id, 4));
        final id = await _collectResp(soc, clk, respReady, 4);
        expect(_word(id), equals(0x4D494D43), reason: 'ID magic');

        // READ VERSION (0x04): interface version 1.0.0.
        await _feedCmd(
          soc,
          clk,
          cmdData,
          cmdValid,
          _readCmd(MimicReg.version, 4),
        );
        final ver = await _collectResp(soc, clk, respReady, 4);
        expect(_word(ver), equals(0x00010000), reason: 'VERSION 1.0.0');

        // WRITE a second SCRATCH value, then read it back: two words.
        await _feedCmd(
          soc,
          clk,
          cmdData,
          cmdValid,
          _writeCmd(MimicReg.scratch, _le32(0x13572468)),
        );
        await _waitIdle(soc, clk);
        await _feedCmd(
          soc,
          clk,
          cmdData,
          cmdValid,
          _readCmd(MimicReg.scratch, 4),
        );
        final scratch2 = await _collectResp(soc, clk, respReady, 4);
        expect(_word(scratch2), equals(0x13572468), reason: 'SCRATCH second');
      },
    );

    test('WRITE_STREAM to DATA_IN lands in the block FIFO and the free space '
        'falls by what it wrote', () async {
      final soc = buildMimicSoc(name: 'mimic_stream_tb', tbCmdPorts: true);

      final clk = SimpleClockGenerator(10).clk;
      soc.port('clk').getsLogic(clk);
      await soc.build();

      final cmdData = soc.input('cmd_data');
      final cmdValid = soc.input('cmd_valid');
      final respReady = soc.input('resp_ready');

      _startSim(20000000);
      await _resetSoc(soc, clk);

      // Reserve a block with DATA_TAG, then WRITE_STREAM 8 bytes to
      // DATA_IN (0x20). The two words land in the block FIFO, and
      // DATA_IN_COUNT reports the free space that is left.
      await _feedCmd(
        soc,
        clk,
        cmdData,
        cmdValid,
        _writeCmd(MimicReg.dataTag, _le32(1)),
      );
      await _waitIdle(soc, clk);

      await _feedCmd(
        soc,
        clk,
        cmdData,
        cmdValid,
        _writeStreamCmd(MimicReg.dataIn, _le32(0x11223344) + _le32(0x55667788)),
      );
      await _waitIdle(soc, clk);

      await _feedCmd(
        soc,
        clk,
        cmdData,
        cmdValid,
        _readCmd(MimicReg.dataInCount, 4),
      );
      final cnt = await _collectResp(soc, clk, respReady, 4);
      expect(
        _word(cnt),
        equals(sdDataInFifoWords - 2),
        reason:
            'DATA_IN_COUNT is free space in words, so 2 pushes into a '
            '$sdDataInFifoWords word FIFO leave ${sdDataInFifoWords - 2}',
      );
    });
  });

  // SV emission: full MimicUsbDevice names itself + the ported TinyFPGA
  // line/packet/protocol submodules (proving the real USB transport is
  // wired, not stubbed).
  group('MimicUsbDevice SV emission', () {
    test('emits non-empty SV naming MimicUsbDevice + the harbor PHY/packet '
        'submodules + the command engine', () async {
      final dev = MimicUsbDevice(
        config: const MimicUsbDeviceConfig(
          busAddressWidth: 12,
          busDataWidth: 32,
        ),
        name: 'mimic_usb_device',
      );
      await dev.build();
      final sv = dev.generateSynth();
      expect(sv, isNotEmpty);
      expect(sv, contains('MimicUsbDevice'));
      // The ported TinyFPGA line layer.
      expect(sv, contains('HarborUsbFsRx'));
      expect(sv, contains('HarborUsbFsTx'));
      // The packet layer and the per-endpoint protocol engines.
      expect(sv, contains('HarborUsbFsPe'));
      expect(sv, contains('HarborUsbFsInPe'));
      expect(sv, contains('HarborUsbFsOutPe'));
      // SE0 bus-reset detection.
      expect(sv, contains('HarborUsbFsResetDet'));
      expect(sv, contains('MimicUsbCmdEngine'));
      // HarborUsbFsDevice is the EP0+bulk front-end.
      expect(sv, contains('HarborUsbFsDevice'));
    });
  });
}
