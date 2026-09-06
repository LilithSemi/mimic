/// CRC helpers for the SD command and data lines.
///
/// Both are used by the RTL generation and by the test host model, so the
/// device and the model cannot disagree about a CRC.
library;

/// CRC7 for an SD command or response, polynomial x^7 + x^3 + 1.
///
/// [bytes] is the frame without the CRC byte: for a command that is the
/// start bit, the transmission bit, the 6-bit index and the 32-bit
/// argument, which is 5 bytes. The result is the 7-bit CRC in the low bits.
/// The wire puts it in bits 7 to 1 of the last byte with the end bit at
/// bit 0. Every entry must be 0 to 255, because the CRC reads 8 bits of
/// each entry. An entry outside that range throws.
int sdCrc7(List<int> bytes) {
  var crc = 0;
  for (final b in bytes) {
    _checkByte(b, 'sdCrc7');
    for (var i = 7; i >= 0; i--) {
      final bit = (b >> i) & 1;
      final high = (crc >> 6) & 1;
      crc = (crc << 1) & 0x7F;
      if ((high ^ bit) != 0) crc ^= 0x09;
    }
  }
  return crc & 0x7F;
}

/// CRC16 for an SD data block, polynomial x^16 + x^12 + x^5 + 1.
///
/// This is CRC-16-CCITT with an initial value of zero, sent most
/// significant bit first. In a wide bus each data line carries its own CRC
/// over the bits that line sent. Every entry must be 0 to 255, the same as
/// in [sdCrc7], and an entry outside that range throws.
int sdCrc16(List<int> bytes) {
  var crc = 0;
  for (final b in bytes) {
    _checkByte(b, 'sdCrc16');
    for (var i = 7; i >= 0; i--) {
      final bit = (b >> i) & 1;
      final high = (crc >> 15) & 1;
      crc = (crc << 1) & 0xFFFF;
      if ((high ^ bit) != 0) crc ^= 0x1021;
    }
  }
  return crc & 0xFFFF;
}

/// Throws if [value] is not one byte.
///
/// Both CRCs read 8 bits of each entry. An entry outside 0 to 255 gives a
/// remainder for data that the caller did not give, and the caller then
/// looks for the fault in the device. [caller] names the function for the
/// message.
void _checkByte(int value, String caller) {
  if (value < 0 || value > 0xFF) {
    throw ArgumentError.value(
      value,
      'bytes',
      '$caller reads 8 bits of each entry, so every entry must be 0 to 255.',
    );
  }
}
