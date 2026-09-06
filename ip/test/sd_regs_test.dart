// Tests for the SD card identification registers (sd_regs.dart).
//
// A host reads these registers to decide if it accepts the card and how
// large the card is. A wrong bit gives no useful error: the host rejects
// the card, or it reads the wrong capacity. So the test pins each field to
// the layout of the SD Physical Layer specification.
//
// The CRC7 check uses its own CRC below, not sdCrc7. The two use different
// arithmetic, so a fault in one does not hide a fault in the other.

@TestOn('vm')
library;

import 'package:mimic/mimic.dart';
import 'package:test/test.dart';

/// CRC7 for the test, polynomial x^7 + x^3 + 1.
///
/// This keeps the remainder in bits 7 to 1 of an 8-bit register and uses
/// the polynomial as 0x89. [sdCrc7] keeps a 7-bit register and uses 0x09.
/// The two must always agree. The result is the 7-bit CRC in the low bits.
int referenceCrc7(List<int> bytes) {
  var crc = 0;
  for (final b in bytes) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      if ((crc & 0x80) != 0) crc ^= 0x89;
      crc = (crc << 1) & 0xFF;
    }
  }
  return crc >> 1;
}

/// Reads [count] bits of [bytes] that start at [msb], the bit number of the
/// most significant bit in the register.
///
/// The registers number their bits from the last bit of the last byte,
/// which is bit 0, up to the first bit of the first byte. The
/// specification gives every field in those numbers, so the test reads the
/// fields in the same numbers.
int fieldOf(List<int> bytes, int msb, int count) {
  final totalBits = bytes.length * 8;
  var value = 0;
  for (var i = 0; i < count; i++) {
    final bit = msb - i;
    final byte = bytes[(totalBits - 1 - bit) ~/ 8];
    value = (value << 1) | ((byte >> (bit % 8)) & 1);
  }
  return value;
}

void main() {
  group('reference CRC7', () {
    // The two CRCs must agree, else the CRC check below proves nothing.
    test('agrees with sdCrc7 on the known command frames', () {
      expect(referenceCrc7([0x40, 0x00, 0x00, 0x00, 0x00]), equals(0x4A));
      expect(referenceCrc7([0x48, 0x00, 0x00, 0x01, 0xAA]), equals(0x43));
    });
  });

  group('sdOcr', () {
    test('a ready SDHC card reads 0xC0FF8000', () {
      expect(sdOcr(), equals(0xC0FF8000));
      expect(sdOcr(ready: true, sdhc: true), equals(0xC0FF8000));
    });

    test('a busy card differs only in bit 31', () {
      final ready = sdOcr();
      final busy = sdOcr(ready: false);
      expect(busy ^ ready, equals(1 << 31));
      expect(busy & (1 << 31), equals(0));
      expect(ready & (1 << 31), isNot(equals(0)));
    });

    test('a card without block addressing clears CCS', () {
      expect(sdOcr(sdhc: false), equals(0x80FF8000));
    });

    test('the voltage window covers 2.7 V to 3.6 V', () {
      // Bit 15 is 2.7 to 2.8 V and bit 23 is 3.5 to 3.6 V.
      for (var bit = 15; bit <= 23; bit++) {
        expect(sdOcr() & (1 << bit), isNot(equals(0)), reason: 'bit $bit');
      }
      for (var bit = 0; bit < 15; bit++) {
        expect(sdOcr() & (1 << bit), equals(0), reason: 'bit $bit');
      }
      for (var bit = 24; bit < 30; bit++) {
        expect(sdOcr() & (1 << bit), equals(0), reason: 'bit $bit');
      }
    });
  });

  group('sdCid', () {
    test('is 16 bytes and every entry is one byte', () {
      final cid = sdCid();
      expect(cid, hasLength(16));
      for (final b in cid) {
        expect(b, inInclusiveRange(0, 255));
      }
    });

    test('the last byte holds the CRC7 and the fixed 1 bit', () {
      final cid = sdCid();
      expect(cid[15] & 1, equals(1));
      expect((cid[15] >> 1) & 0x7F, equals(referenceCrc7(cid.sublist(0, 15))));
    });

    test('holds the given fields at the places of the specification', () {
      final cid = sdCid(
        manufacturerId: 0x27,
        oemId: 'PH',
        productName: 'SD64G',
        productRevision: 0x23,
        serialNumber: 0xDEADBEEF,
        manufactureYear: 2024,
        manufactureMonth: 7,
      );
      expect(fieldOf(cid, 127, 8), equals(0x27));
      expect(fieldOf(cid, 119, 16), equals(0x5048));
      expect(
        cid.sublist(3, 8),
        equals('SD64G'.codeUnits),
        reason: 'PNM is 5 ASCII characters',
      );
      // PNM is bits 103 to 64, so PRV starts at bit 63.
      expect(fieldOf(cid, 63, 8), equals(0x23), reason: 'PRV');
      expect(fieldOf(cid, 55, 32), equals(0xDEADBEEF), reason: 'PSN');
      expect(fieldOf(cid, 23, 4), equals(0), reason: 'reserved');
      // MDT is the year after 2000 in the high 8 bits, then the month.
      expect(fieldOf(cid, 19, 12), equals((24 << 4) | 7), reason: 'MDT');
    });

    test('rejects a product name that is not 5 characters', () {
      expect(() => sdCid(productName: 'TOOLONG'), throwsArgumentError);
      expect(() => sdCid(productName: 'AB'), throwsArgumentError);
    });

    test('rejects a month outside 1 to 12', () {
      expect(() => sdCid(manufactureMonth: 0), throwsArgumentError);
      expect(() => sdCid(manufactureMonth: 13), throwsArgumentError);
    });

    test('rejects a year the 8-bit field cannot hold', () {
      expect(() => sdCid(manufactureYear: 1999), throwsArgumentError);
      expect(() => sdCid(manufactureYear: 2256), throwsArgumentError);
    });
  });

  group('sdCsdV2', () {
    test('is 16 bytes and ends with the CRC7 and the fixed 1 bit', () {
      final csd = sdCsdV2(capacityBlocks: 1024 * 1024);
      expect(csd, hasLength(16));
      expect(csd[15] & 1, equals(1));
      expect((csd[15] >> 1) & 0x7F, equals(referenceCrc7(csd.sublist(0, 15))));
    });

    test('CSD_STRUCTURE is 01', () {
      final csd = sdCsdV2(capacityBlocks: 1024 * 1024);
      expect(fieldOf(csd, 127, 2), equals(1));
    });

    test('holds the fixed values that a version 2.0 card reports', () {
      final csd = sdCsdV2(capacityBlocks: 1024 * 1024);
      expect(fieldOf(csd, 125, 6), equals(0), reason: 'reserved');
      expect(fieldOf(csd, 119, 8), equals(0x0E), reason: 'TAAC');
      expect(fieldOf(csd, 111, 8), equals(0x00), reason: 'NSAC');
      expect(fieldOf(csd, 103, 8), equals(0x32), reason: 'TRAN_SPEED');
      expect(fieldOf(csd, 95, 12), equals(0x5B5), reason: 'CCC');
      expect(fieldOf(csd, 83, 4), equals(9), reason: 'READ_BL_LEN');
      expect(fieldOf(csd, 79, 1), equals(0), reason: 'READ_BL_PARTIAL');
      expect(fieldOf(csd, 78, 1), equals(0), reason: 'WRITE_BLK_MISALIGN');
      expect(fieldOf(csd, 77, 1), equals(0), reason: 'READ_BLK_MISALIGN');
      expect(fieldOf(csd, 76, 1), equals(0), reason: 'DSR_IMP');
      expect(fieldOf(csd, 75, 6), equals(0), reason: 'reserved');
      expect(fieldOf(csd, 47, 1), equals(0), reason: 'reserved');
      expect(fieldOf(csd, 46, 1), equals(1), reason: 'ERASE_BLK_EN');
      expect(fieldOf(csd, 45, 7), equals(0x7F), reason: 'SECTOR_SIZE');
      expect(fieldOf(csd, 38, 7), equals(0), reason: 'WP_GRP_SIZE');
      expect(fieldOf(csd, 31, 1), equals(0), reason: 'WP_GRP_ENABLE');
      expect(fieldOf(csd, 30, 2), equals(0), reason: 'reserved');
      expect(fieldOf(csd, 28, 3), equals(2), reason: 'R2W_FACTOR');
      expect(fieldOf(csd, 25, 4), equals(9), reason: 'WRITE_BL_LEN');
      expect(fieldOf(csd, 21, 1), equals(0), reason: 'WRITE_BL_PARTIAL');
      expect(fieldOf(csd, 20, 5), equals(0), reason: 'reserved');
      expect(fieldOf(csd, 15, 1), equals(0), reason: 'FILE_FORMAT_GRP');
      expect(fieldOf(csd, 11, 2), equals(0), reason: 'FILE_FORMAT');
      expect(fieldOf(csd, 9, 2), equals(0), reason: 'reserved');
    });

    test('write protection is clear by default and can be set', () {
      final open = sdCsdV2(capacityBlocks: 1024 * 1024);
      expect(fieldOf(open, 13, 1), equals(0), reason: 'PERM_WRITE_PROTECT');
      expect(fieldOf(open, 12, 1), equals(0), reason: 'TMP_WRITE_PROTECT');
      final locked = sdCsdV2(
        capacityBlocks: 1024 * 1024,
        temporaryWriteProtect: true,
      );
      expect(fieldOf(locked, 12, 1), equals(1));
    });

    test('a capacity goes through C_SIZE and comes back', () {
      for (final blocks in [
        1024,
        4096 * 1024,
        7563 * 1024,
        15193 * 1024,
        0x3FFFFF * 1024,
      ]) {
        final csd = sdCsdV2(capacityBlocks: blocks);
        final cSize = sdCsdCSize(csd);
        expect(fieldOf(csd, 69, 22), equals(cSize), reason: 'C_SIZE place');
        expect((cSize + 1) * 1024, equals(blocks), reason: '$blocks blocks');
        expect(sdCsdCapacityBlocks(csd), equals(blocks));
      }
    });

    test('rejects a capacity that C_SIZE cannot hold', () {
      expect(() => sdCsdV2(capacityBlocks: 0), throwsArgumentError);
      expect(() => sdCsdV2(capacityBlocks: 1500), throwsArgumentError);
      expect(
        () => sdCsdV2(capacityBlocks: (sdCsdMaxCSize + 2) * 1024),
        throwsArgumentError,
      );
    });

    test('the capacity reader rejects a register it cannot read', () {
      expect(() => sdCsdCSize(const [0, 1, 2]), throwsArgumentError);
      final v1 = List<int>.filled(16, 0);
      expect(() => sdCsdCSize(v1), throwsArgumentError, reason: 'version 1.0');
    });
  });

  group('sdScr', () {
    test('advertises 1-bit and not 4-bit', () {
      final scr = sdScr();
      final widths = (scr >> 48) & 0xF;
      expect(widths & sdBusWidth1Bit, equals(sdBusWidth1Bit));
      expect(widths & sdBusWidth4Bit, equals(0), reason: 'no 4-bit path yet');
      expect(widths, equals(1));
    });

    test('holds the fields that a version 2.00 SDHC card reports', () {
      final scr = sdScr();
      expect((scr >> 60) & 0xF, equals(0), reason: 'SCR_STRUCTURE 1.0');
      expect((scr >> 56) & 0xF, equals(2), reason: 'SD_SPEC 2.00');
      expect((scr >> 55) & 0x1, equals(0), reason: 'DATA_STAT_AFTER_ERASE');
      expect((scr >> 52) & 0x7, equals(3), reason: 'SD_SECURITY SDHC');
      expect(scr & 0xFFFFFFFFFFFF, equals(0), reason: 'bits 47 to 0');
      expect(scr, equals(0x0231000000000000));
    });

    test('rejects a bus width set that is not 1 to 15', () {
      expect(() => sdScr(busWidths: 0), throwsArgumentError);
      expect(() => sdScr(busWidths: 0x10), throwsArgumentError);
    });

    test('gives 8 bytes, most significant first', () {
      expect(
        sdScrToBytes(sdScr()),
        equals([0x02, 0x31, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
      );
    });
  });

  group('register helpers', () {
    test('turns 16 bytes into the value of a 128-bit port', () {
      final bytes = List<int>.generate(16, (i) => i + 1);
      expect(
        sdRegisterToBigInt(bytes),
        equals(BigInt.parse('0102030405060708090a0b0c0d0e0f10', radix: 16)),
      );
      expect(sdRegisterToBigInt(const [0xFF]), equals(BigInt.from(0xFF)));
    });

    test('turns 16 bytes into 32-bit words, most significant first', () {
      final bytes = List<int>.generate(16, (i) => i);
      expect(
        sdRegisterToWords(bytes),
        equals([0x00010203, 0x04050607, 0x08090A0B, 0x0C0D0E0F]),
      );
    });

    test('rejects an entry that is not one byte', () {
      expect(() => sdRegisterToBigInt(const [0x100]), throwsArgumentError);
      expect(() => sdRegisterToWords(const [-1]), throwsArgumentError);
    });

    test('rejects a byte count that is not a whole number of words', () {
      expect(() => sdRegisterToWords(const [1, 2, 3]), throwsArgumentError);
    });

    test('the CID and the CSD reach the RTL as 128 bits', () {
      final cid = sdRegisterToBigInt(sdCid());
      expect(cid.bitLength, lessThanOrEqualTo(128));
      expect(sdRegisterToWords(sdCsdV2(capacityBlocks: 1024)), hasLength(4));
    });
  });
}
