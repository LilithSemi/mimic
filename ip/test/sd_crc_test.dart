import 'package:mimic/mimic.dart';
import 'package:test/test.dart';

void main() {
  group('sdCrc7', () {
    // CMD0 GO_IDLE_STATE, argument 0. The complete frame on the wire is
    // 40 00 00 00 00 95. The last byte is (crc7 << 1) | 1, so crc7 is 0x4A.
    test('CMD0 with a zero argument gives 0x4A', () {
      expect(sdCrc7([0x40, 0x00, 0x00, 0x00, 0x00]), equals(0x4A));
    });

    // CMD8 SEND_IF_COND, argument 0x000001AA. Frame 48 00 00 01 AA 87,
    // so crc7 is 0x43.
    test('CMD8 with argument 0x1AA gives 0x43', () {
      expect(sdCrc7([0x48, 0x00, 0x00, 0x01, 0xAA]), equals(0x43));
    });
  });

  group('sdCrc16', () {
    // CRC-16-CCITT, polynomial 0x1021, initial value 0, MSB first. The
    // standard check value for the ASCII string "123456789" is 0x31C3.
    test('the standard check string gives 0x31C3', () {
      expect(sdCrc16('123456789'.codeUnits), equals(0x31C3));
    });

    test('an empty input gives the initial value', () {
      expect(sdCrc16(const []), equals(0x0000));
    });
  });
}
