@TestOn('vm')
library;

import 'package:mimic/mimic.dart';
import 'package:test/test.dart';

void main() {
  test('library version constant is exported', () {
    expect(mimicVersion, isNotEmpty);
  });
}
