import 'package:mimic/mimic.dart';
import 'package:test/test.dart';

/// The ULPI signals of the USB3320C on Mimic V1, and the ball of each.
const Map<String, String> _ulpi = {
  'ulpi_clk': 'J16',
  'ulpi_dir': 'N16',
  'ulpi_nxt': 'K14',
  'ulpi_stp': 'P16',
  'ulpi_data[0]': 'K15',
  'ulpi_data[1]': 'J15',
  'ulpi_data[2]': 'J14',
  'ulpi_data[3]': 'H14',
  'ulpi_data[4]': 'H15',
  'ulpi_data[5]': 'G16',
  'ulpi_data[6]': 'F16',
  'ulpi_data[7]': 'G15',
  'ulpi_rst_n': 'R15',
};

void main() {
  test(
    'mimic v1 has a 24 MHz oscillator and the ULPI PHY on banks 2 and 3',
    () {
      expect(mimicV1Board.oscillatorHz, 24000000);
      _ulpi.forEach((name, ball) {
        expect(
          mimicV1Board.pins[name]?.split(' ').first,
          ball,
          reason: '$name must be on $ball',
        );
      });
      for (final name in ['usb_dp', 'usb_dm', 'usb_pullup']) {
        expect(mimicV1Board.pins.containsKey(name), isFalse, reason: name);
      }
      expect(mimicV1Board.clockCapableSites, containsAll(['K16', 'J16', 'K1']));
    },
  );

  test('genip refuses a ULPI board until the ULPI link exists', () {
    expect(
      () => MimicGenIpConfig(boardName: 'mimic-v1').buildSoC(),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('ULPI'),
        ),
      ),
    );
  });

  test('a board without ULPI still builds', () {
    expect(
      () => MimicGenIpConfig(boardName: 'orangecrab-25f').buildSoC(),
      returnsNormally,
    );
  });
}
