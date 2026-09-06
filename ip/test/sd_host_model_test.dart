import 'package:test/test.dart';

import 'sd_host_model.dart';

void main() {
  test('sdCommandFrame builds the CMD0 frame from the specification', () {
    expect(
      sdCommandFrame(0, 0x00000000),
      equals([0x40, 0x00, 0x00, 0x00, 0x00, 0x95]),
    );
  });

  test('sdCommandFrame builds the CMD8 frame from the specification', () {
    expect(
      sdCommandFrame(8, 0x000001AA),
      equals([0x48, 0x00, 0x00, 0x01, 0xAA, 0x87]),
    );
  });

  test('sdCommandFrame sets the start and transmission bits', () {
    // Bit 7 of the first byte is the start bit and must be 0. Bit 6 is the
    // transmission bit and must be 1 for a host to card command.
    final f = sdCommandFrame(24, 0xDEADBEEF);
    expect(f[0] & 0x80, equals(0x00), reason: 'start bit');
    expect(f[0] & 0x40, equals(0x40), reason: 'transmission bit');
    expect(f[0] & 0x3F, equals(24), reason: 'command index');
    expect(f.last & 0x01, equals(0x01), reason: 'end bit');
  });
}
