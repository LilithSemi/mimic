// Tests for the Mimic CSR map and USB command constants (regs.dart).
//
// These values are the wire contract shared with the host runtime (Zig).
// The test pins them to the exact agreed values, so an accidental change
// fails loudly here instead of corrupting a host-device conversation.

@TestOn('vm')
library;

import 'package:mimic/mimic.dart';
import 'package:test/test.dart';

void main() {
  group('MimicReg byte offsets', () {
    test('registers sit at the agreed byte addresses', () {
      expect(MimicReg.id, equals(0x00));
      expect(MimicReg.version, equals(0x04));
      expect(MimicReg.ctrl, equals(0x08));
      expect(MimicReg.status, equals(0x0C));
      expect(MimicReg.numBlocks, equals(0x10));
      expect(MimicReg.scratch, equals(0x14));
      expect(MimicReg.req, equals(0x18));
      expect(MimicReg.reqCount, equals(0x1C));
      expect(MimicReg.dataIn, equals(0x20));
      expect(MimicReg.dataInCount, equals(0x24));
      expect(MimicReg.dataOut, equals(0x28));
      expect(MimicReg.dataOutCount, equals(0x2C));
      expect(MimicReg.event, equals(0x30));
      expect(MimicReg.irqEnable, equals(0x34));
      expect(MimicReg.cardState, equals(0x44));
      expect(MimicReg.csd0, equals(0x48));
      expect(MimicReg.csd1, equals(0x4C));
      expect(MimicReg.csd2, equals(0x50));
      expect(MimicReg.csd3, equals(0x54));
      expect(MimicReg.dbgSdClk, equals(0x58));
      expect(MimicReg.dbgSdCmd, equals(0x5C));
      expect(MimicReg.dbgSdCrcErr, equals(0x60));
      expect(MimicReg.dbgSdResp, equals(0x64));
      expect(MimicReg.reqHi, equals(0x68));
      expect(MimicReg.dataTag, equals(0x6C));
      expect(MimicReg.reqPop, equals(0x70));
      expect(MimicReg.dataOutPop, equals(0x74));
      expect(MimicReg.writeAck, equals(0x78));
      expect(MimicReg.dataFillLba, equals(0x7C));
      expect(MimicReg.dbgCacheHit, equals(0x80));
      expect(MimicReg.dbgCacheMiss, equals(0x84));
      expect(MimicReg.dbgCacheFill, equals(0x88));
      expect(MimicReg.cacheLines, equals(0x8C));
    });

    test('the block cache registers sit above the write path', () {
      // The five registers of the block cache were added ABOVE the map
      // that was already there, so no address of it moved and no runtime
      // built against the older map reads a different register.
      expect(
        MimicReg.dataFillLba - MimicReg.writeAck,
        equals(4),
        reason: 'DATA_FILL_LBA follows WRITE_ACK',
      );
      expect(
        MimicReg.dbgCache,
        equals([0x80, 0x84, 0x88]),
        reason: 'the three counters are one block, in address order',
      );
      expect(
        MimicReg.cacheLines - MimicReg.dbgCacheFill,
        equals(4),
        reason: 'CACHE_LINES follows the counters',
      );
      // The tag that marks a FILL must be the tag that names no record,
      // or a fill would be served as the answer to a read.
      expect(MimicDataTag.fill, equals(0));
    });

    test('the block read path registers follow the bring-up counters', () {
      expect(MimicReg.reqHi, greaterThan(MimicReg.dbgSdResp));
      expect(
        MimicReg.reqHi - MimicReg.dbgSdResp,
        equals(4),
        reason: 'REQ_HI follows the last counter',
      );
      expect(
        MimicReg.dataTag - MimicReg.reqHi,
        equals(4),
        reason: 'DATA_TAG follows REQ_HI',
      );
      expect(
        MimicReg.reqPop - MimicReg.dataTag,
        equals(4),
        reason: 'REQ_POP follows DATA_TAG',
      );
      expect(
        MimicReg.dataOutPop - MimicReg.reqPop,
        equals(4),
        reason: 'DATA_OUT_POP follows REQ_POP',
      );
      expect(
        MimicReg.writeAck - MimicReg.dataOutPop,
        equals(4),
        reason: 'WRITE_ACK follows DATA_OUT_POP',
      );
    });

    test('the write path takes no word and no answer on a read', () {
      // The mirror of the REQ_POP rule. NO ADDRESS OF THE MAP HAS A SIDE
      // EFFECT ON READ, so the pop of a word and the acknowledgement of a
      // write are both WRITES, at addresses of their own above the
      // bring-up counters.
      expect(MimicDataOutPop.pop, equals(1 << 0));
      expect(
        MimicDataOutPop.pop.bitLength,
        equals(1),
        reason: 'the pop bit is one bit',
      );
      expect(MimicReg.dataOutPop, isNot(equals(MimicReg.dataOut)));
      expect(MimicReg.dataOutPop, isNot(equals(MimicReg.dataOutCount)));
      expect(MimicReg.dataOutPop, greaterThan(MimicReg.dbgSdResp));
      expect(MimicReg.writeAck, greaterThan(MimicReg.dbgSdResp));

      // The WRITE_ACK fields: an 8-bit tag with the fail bit above it.
      expect(MimicWriteAck.tagMask, equals(0xFF));
      expect(MimicWriteAck.fail, equals(1 << 8));
      expect(
        MimicWriteAck.tagMask & MimicWriteAck.fail,
        equals(0),
        reason: 'the tag and the fail bit must not overlap',
      );
    });

    test('the pop of a record is a WRITE and not a read', () {
      // The whole point of REQ_POP: no address of the map has a side
      // effect on read, so a bulk read of the map, a debug tool or
      // `mimic-cli info` cannot take a record by accident. REQ_POP is the
      // one address that moves the request channel and it is write-only.
      expect(MimicReqPop.pop, equals(1 << 0));
      expect(
        MimicReqPop.pop.bitLength,
        equals(1),
        reason: 'the pop bit is one bit',
      );
      // REQ_POP is not one of the addresses a record read touches.
      expect(MimicReg.reqPop, isNot(equals(MimicReg.req)));
      expect(MimicReg.reqPop, isNot(equals(MimicReg.reqHi)));
    });

    test('the SD bring-up counters follow the CSD block', () {
      // The runtime reads the four in one burst, so they are four words in
      // a row and the list is in that order.
      expect(
        MimicReg.dbgSd,
        equals([
          MimicReg.dbgSdClk,
          MimicReg.dbgSdCmd,
          MimicReg.dbgSdCrcErr,
          MimicReg.dbgSdResp,
        ]),
      );
      expect(MimicReg.dbgSd, hasLength(4));
      for (var i = 1; i < MimicReg.dbgSd.length; i++) {
        expect(MimicReg.dbgSd[i] - MimicReg.dbgSd[i - 1], equals(4));
      }
      expect(
        MimicReg.dbgSd.first - MimicReg.csd.last,
        equals(4),
        reason: 'the counter block follows CSD_3',
      );
    });

    test('the CSD block is four words, lowest first', () {
      // The runtime writes the block in this order, so the list and the
      // four offsets must agree. CSD_0 holds csd[31:0].
      expect(
        MimicReg.csd,
        equals([MimicReg.csd0, MimicReg.csd1, MimicReg.csd2, MimicReg.csd3]),
      );
      expect(MimicReg.csd, hasLength(4));
      for (var i = 1; i < MimicReg.csd.length; i++) {
        expect(
          MimicReg.csd[i] - MimicReg.csd[i - 1],
          equals(4),
          reason: 'the CSD registers are one word apart',
        );
      }
      expect(
        MimicReg.csd.first - MimicReg.cardState,
        equals(4),
        reason: 'the CSD block follows CARD_STATE',
      );
    });

    test('registers are 4-byte aligned and strictly increasing', () {
      final offsets = [
        MimicReg.id,
        MimicReg.version,
        MimicReg.ctrl,
        MimicReg.status,
        MimicReg.numBlocks,
        MimicReg.scratch,
        MimicReg.req,
        MimicReg.reqCount,
        MimicReg.dataIn,
        MimicReg.dataInCount,
        MimicReg.dataOut,
        MimicReg.dataOutCount,
        MimicReg.event,
        MimicReg.irqEnable,
        MimicReg.dbgCmdCount,
        MimicReg.dbgInCount,
        MimicReg.dbgResetCount,
        MimicReg.cardState,
        ...MimicReg.csd,
        ...MimicReg.dbgSd,
        MimicReg.reqHi,
        MimicReg.dataTag,
        MimicReg.reqPop,
        MimicReg.dataOutPop,
        MimicReg.writeAck,
      ];
      var prev = -4;
      for (final o in offsets) {
        expect(o % 4, equals(0), reason: '0x${o.toRadixString(16)} aligned');
        expect(o, greaterThan(prev), reason: 'strictly increasing');
        prev = o;
      }
    });
  });

  group('MimicRegValue fixed values', () {
    test('ID reads the MIMC magic', () {
      // 'MIMC' packed little-endian: 'M'=0x4D, 'I'=0x49, 'M'=0x4D, 'C'=0x43.
      expect(MimicRegValue.id, equals(0x4D494D43));
    });

    test('VERSION packs interface version 1.0.0', () {
      // major << 16 | minor << 8 | patch = 1 << 16 = 65536.
      expect(MimicRegValue.version, equals(0x00010000));
      expect(MimicRegValue.version, equals(65536));
      expect(MimicRegValue.versionString, equals('1.0.0'));
    });
  });

  group('MimicCtrl bits', () {
    test('the four control bits sit at 0..3', () {
      expect(MimicCtrl.enable, equals(1 << 0));
      expect(MimicCtrl.testPattern, equals(1 << 1));
      expect(MimicCtrl.readOnly, equals(1 << 2));
      expect(MimicCtrl.cacheBypass, equals(1 << 3));
    });

    test('write-back is bit 4, above the four that were there', () {
      expect(MimicCtrl.writeBack, equals(1 << 4));
      expect(
        MimicCtrl.writeBack & MimicCtrl.cacheBypass,
        equals(0),
        reason: 'write-back must not share a bit with the four below it',
      );
    });
  });

  group('MimicEvent bits', () {
    test('the two timeout bits sit at 0 and 1', () {
      expect(MimicEvent.readTimeout, equals(1 << 0));
      expect(MimicEvent.writeTimeout, equals(1 << 1));
    });

    test('the data channel overflow bit sits above them', () {
      expect(MimicEvent.dataInOverflow, equals(1 << 2));
      expect(
        MimicEvent.dataInOverflow &
            (MimicEvent.readTimeout | MimicEvent.writeTimeout),
        equals(0),
        reason: 'the three event bits must not share one bit number.',
      );
    });
  });

  group('CSR base', () {
    test('the CSR space starts at the fabric base 0', () {
      expect(mimicCsrBase, equals(0x00000000));
    });
  });

  group('MimicUsbOpcode', () {
    test('opcodes match the framed protocol', () {
      expect(MimicUsbOpcode.write, equals(0x01));
      expect(MimicUsbOpcode.read, equals(0x02));
      expect(MimicUsbOpcode.writeStream, equals(0x03));
    });
  });
}
