/// The identification registers of an SD card.
///
/// Pure Dart. No ROHD imports. A host reads these registers to decide if it
/// accepts the card, how large the card is, and how wide the bus can be. A
/// wrong bit gives the host no useful error: the host rejects the card, or
/// it reads the wrong capacity. So every field below follows the layout of
/// the SD Physical Layer specification.
///
/// The bit numbers in the comments are the numbers of the specification.
/// Bit 0 is the last bit of the last byte and the highest bit number is the
/// first bit of the first byte. The card sends the first byte first.
///
/// The CID and the CSD hold their own CRC7, because the link sends these
/// two registers on the wire without a change. [sdCrc7] computes it. This
/// file does not have a second CRC.
library;

import 'sd_crc.dart';

/// OCR bit 31: the card has completed its power-up sequence.
///
/// A 0 tells the host to send ACMD41 again and wait. A 1 tells the host
/// that the other OCR bits are now correct.
const int sdOcrPowerUpDone = 1 << 31;

/// OCR bit 30, CCS: the card is an SDHC or SDXC card.
///
/// A 1 means the card takes a block number in a read or a write command. A
/// 0 means the card takes a byte address.
const int sdOcrCardCapacityStatus = 1 << 30;

/// OCR bits 23 to 15: the supply voltages that the card accepts.
///
/// Bit 15 is 2.7 to 2.8 V and each bit above it is 0.1 V more, up to bit
/// 23 for 3.5 to 3.6 V. All nine bits together are the full 2.7 to 3.6 V
/// range that a standard card supports.
const int sdOcrVoltage27To36 = 0x00FF8000;

/// SD_BUS_WIDTHS bit 0: the card supports the 1-bit bus.
const int sdBusWidth1Bit = 1 << 0;

/// SD_BUS_WIDTHS bit 2: the card supports the 4-bit bus.
///
/// Do not put this bit in the SCR until the receive datapath can read four
/// data lines. See [sdScr].
const int sdBusWidth4Bit = 1 << 2;

/// Number of bytes in the CID and in the CSD register.
const int sdRegisterBytes = 16;

/// First year the MDT field of the CID can express.
///
/// MDT holds the year as an offset from 2000 in 8 bits, so the field cannot
/// name a year before 2000 at all.
const int sdCidMdtFirstYear = 2000;

/// Last year the MDT field of the CID can express.
///
/// The 8-bit offset stops at 255, so [sdCidMdtFirstYear] plus 255 is the
/// last year the field holds.
const int sdCidMdtLastYear = sdCidMdtFirstYear + 0xFF;

/// The MDT year [sdCid] uses when the caller names none.
///
/// A generator resolves the real date of the build and gives it to [sdCid].
/// This value is what a caller that names no date gets, so a CID always
/// carries a date that the field can hold.
const int sdCidDefaultManufactureYear = 2025;

/// The MDT month [sdCid] uses when the caller names none. See
/// [sdCidDefaultManufactureYear].
const int sdCidDefaultManufactureMonth = 1;

/// Number of bytes in the SCR register.
const int sdScrBytes = 8;

/// Number of 512-byte blocks in one C_SIZE step of a version 2.0 CSD.
const int sdCsdCapacityUnitBlocks = 1024;

/// Largest value that the 22-bit C_SIZE field can hold.
const int sdCsdMaxCSize = 0x3FFFFF;

/// The 32-bit OCR register, which the card returns in an R3 response.
///
/// [ready] sets bit 31. Give false while the card still initialises, so
/// that the host sends ACMD41 again. [sdhc] sets bit 30 (CCS), which tells
/// the host to address the card in blocks and not in bytes. A ready SDHC
/// card reads 0xC0FF8000.
int sdOcr({bool ready = true, bool sdhc = true}) {
  var ocr = sdOcrVoltage27To36;
  if (ready) ocr |= sdOcrPowerUpDone;
  if (sdhc) ocr |= sdOcrCardCapacityStatus;
  return ocr;
}

/// The 128-bit CID register as 16 bytes, most significant byte first.
///
/// The layout from the first bit is MID 8, OID 16, PNM 40, PRV 8, PSN 32,
/// 4 reserved bits, MDT 12, CRC7 7 and one fixed 1 bit.
///
/// [manufacturerId] is MID, the 8-bit code of the card maker. The default
/// 0x00 is not a code that the SD Association gives to a maker, so the
/// card does not claim to come from another company. [oemId] is OID, two
/// ASCII characters. [productName] is PNM, five ASCII characters.
/// [productRevision] is PRV, two binary-coded decimal digits, so 0x10 is
/// revision 1.0. [serialNumber] is PSN, a 32-bit number. [manufactureYear]
/// and [manufactureMonth] are MDT: the field holds the year after 2000 in
/// 8 bits and the month, 1 to 12, in 4 bits.
///
/// Every argument outside its field throws, because a value that does not
/// fit would change a different field.
List<int> sdCid({
  int manufacturerId = 0x00,
  String oemId = 'MI',
  String productName = 'MIMIC',
  int productRevision = 0x10,
  int serialNumber = 0x00000001,
  int manufactureYear = sdCidDefaultManufactureYear,
  int manufactureMonth = sdCidDefaultManufactureMonth,
}) {
  _checkRange(manufacturerId, 0, 0xFF, 'manufacturerId', 'MID is 8 bits');
  _checkAscii(oemId, 2, 'oemId', 'OID');
  _checkAscii(productName, 5, 'productName', 'PNM');
  _checkRange(productRevision, 0, 0xFF, 'productRevision', 'PRV is 8 bits');
  _checkRange(serialNumber, 0, 0xFFFFFFFF, 'serialNumber', 'PSN is 32 bits');
  _checkRange(
    manufactureYear,
    sdCidMdtFirstYear,
    sdCidMdtLastYear,
    'manufactureYear',
    'MDT holds the year after $sdCidMdtFirstYear in 8 bits, so '
        '$sdCidMdtFirstYear to $sdCidMdtLastYear',
  );
  _checkRange(
    manufactureMonth,
    1,
    12,
    'manufactureMonth',
    'MDT holds the month as 1 to 12',
  );

  final year = manufactureYear - sdCidMdtFirstYear;
  final bytes = <int>[
    manufacturerId,
    oemId.codeUnitAt(0),
    oemId.codeUnitAt(1),
    for (var i = 0; i < 5; i++) productName.codeUnitAt(i),
    productRevision,
    (serialNumber >> 24) & 0xFF,
    (serialNumber >> 16) & 0xFF,
    (serialNumber >> 8) & 0xFF,
    serialNumber & 0xFF,
    // Bits 23 to 20 are reserved and stay 0. Bits 19 to 16 are the top
    // four bits of MDT, which are the top four bits of the year.
    (year >> 4) & 0x0F,
    // Bits 15 to 12 are the last four bits of the year, bits 11 to 8 the
    // month.
    ((year & 0x0F) << 4) | manufactureMonth,
  ];
  return _withCrc7(bytes);
}

/// The 128-bit CSD register of version 2.0 as 16 bytes.
///
/// Version 2.0 is the CSD that an SDHC or SDXC card reports.
/// `CSD_STRUCTURE` is 01 and almost every other field has a fixed value,
/// because the card always reads and writes 512-byte blocks. Only C_SIZE
/// changes with the card.
///
/// [capacityBlocks] is the number of 512-byte blocks on the card. The
/// field holds `capacityBlocks / 1024 - 1`, so the count must be a
/// multiple of 1024 and must fit in the 22 bits of C_SIZE. A count that
/// does not fit throws, because a truncated count would show the host a
/// card of a different size.
///
/// [temporaryWriteProtect] sets TMP_WRITE_PROTECT, which tells the host
/// that the card refuses a write until somebody clears the bit.
/// [permanentWriteProtect] sets PERM_WRITE_PROTECT, which tells the host
/// that the card never accepts a write again.
List<int> sdCsdV2({
  required int capacityBlocks,
  bool temporaryWriteProtect = false,
  bool permanentWriteProtect = false,
}) {
  if (capacityBlocks <= 0 || capacityBlocks % sdCsdCapacityUnitBlocks != 0) {
    throw ArgumentError.value(
      capacityBlocks,
      'capacityBlocks',
      'C_SIZE counts steps of $sdCsdCapacityUnitBlocks blocks, so the '
          'block count must be a positive multiple of '
          '$sdCsdCapacityUnitBlocks.',
    );
  }
  final cSize = capacityBlocks ~/ sdCsdCapacityUnitBlocks - 1;
  if (cSize > sdCsdMaxCSize) {
    throw ArgumentError.value(
      capacityBlocks,
      'capacityBlocks',
      'C_SIZE is 22 bits, so the largest block count is '
          '${(sdCsdMaxCSize + 1) * sdCsdCapacityUnitBlocks}.',
    );
  }

  final bytes = <int>[
    // CSD_STRUCTURE 01, then six reserved bits.
    0x40,
    // TAAC 0x0E: the read access time is fixed at 1 ms.
    0x0E,
    // NSAC 0x00: the read access time has no clock cycle part.
    0x00,
    // TRAN_SPEED 0x32: 25 Mbit/s, the default speed.
    0x32,
    // CCC 0x5B5 in bits 95 to 84: command classes 0, 2, 4, 5, 7, 8 and 10.
    0x5B,
    // The last four bits of CCC, then READ_BL_LEN 9, which is 512 bytes.
    0x59,
    // READ_BL_PARTIAL 0, WRITE_BLK_MISALIGN 0, READ_BLK_MISALIGN 0,
    // DSR_IMP 0 and four reserved bits. A version 2.0 card reads and
    // writes whole blocks only.
    0x00,
    // Two more reserved bits, then the top six bits of C_SIZE.
    (cSize >> 16) & 0x3F,
    (cSize >> 8) & 0xFF,
    cSize & 0xFF,
    // One reserved bit, ERASE_BLK_EN 1, then the top six bits of
    // SECTOR_SIZE, which is fixed at 0x7F.
    0x7F,
    // The last bit of SECTOR_SIZE, then WP_GRP_SIZE 0.
    0x80,
    // WP_GRP_ENABLE 0, two reserved bits, R2W_FACTOR 010 which is a factor
    // of 4, then the top two bits of WRITE_BL_LEN.
    0x0A,
    // The last two bits of WRITE_BL_LEN, which is 9 for 512 bytes,
    // WRITE_BL_PARTIAL 0 and five reserved bits.
    0x40,
    // FILE_FORMAT_GRP 0, COPY 1, the two write protect bits, FILE_FORMAT
    // 00 and two reserved bits. COPY 1 says that the content is a copy and
    // not the original content of the maker, which is true of this card.
    0x40 |
        (permanentWriteProtect ? 0x20 : 0x00) |
        (temporaryWriteProtect ? 0x10 : 0x00),
  ];
  return _withCrc7(bytes);
}

/// The C_SIZE field of a version 2.0 CSD.
///
/// [csd] is the 16 bytes that [sdCsdV2] gives. A register of a different
/// length, or one that does not have `CSD_STRUCTURE` 01, throws: the same
/// bits mean a different field in version 1.0.
int sdCsdCSize(List<int> csd) {
  if (csd.length != sdRegisterBytes) {
    throw ArgumentError.value(
      csd.length,
      'csd',
      'A CSD register is $sdRegisterBytes bytes.',
    );
  }
  final structure = (csd[0] >> 6) & 0x3;
  if (structure != 1) {
    throw ArgumentError.value(
      structure,
      'csd',
      'C_SIZE sits at other bits in a CSD that is not version 2.0. '
          'CSD_STRUCTURE must be 01.',
    );
  }
  return ((csd[7] & 0x3F) << 16) | (csd[8] << 8) | csd[9];
}

/// The capacity of a version 2.0 CSD in 512-byte blocks.
///
/// The capacity is `(C_SIZE + 1) * 1024`, which is the reverse of what
/// [sdCsdV2] does with `capacityBlocks`.
int sdCsdCapacityBlocks(List<int> csd) =>
    (sdCsdCSize(csd) + 1) * sdCsdCapacityUnitBlocks;

/// The 64-bit SCR register, which the card sends on the data lines.
///
/// [busWidths] is SD_BUS_WIDTHS, four bits: [sdBusWidth1Bit] and
/// [sdBusWidth4Bit].
///
/// The default advertises the 1-bit bus alone, because the receive
/// datapath reads one data line. Do not add [sdBusWidth4Bit] before the
/// datapath can read four lines: the host would send ACMD6, change the
/// bus, and then read only noise.
///
/// The other fields are the fields of a version 2.00 SDHC card:
/// SCR_STRUCTURE 0 for SCR version 1.0, SD_SPEC 2 for specification
/// version 2.00, DATA_STAT_AFTER_ERASE 0 because an erased block reads as
/// zero, and SD_SECURITY 3 for the security of an SDHC card. Bits 47 to 0
/// are reserved or belong to the maker, and stay 0.
int sdScr({int busWidths = sdBusWidth1Bit}) {
  if (busWidths < 1 || busWidths > 0xF) {
    throw ArgumentError.value(
      busWidths,
      'busWidths',
      'SD_BUS_WIDTHS is 4 bits and a card must support one width or more.',
    );
  }
  return (0 << 60) | (2 << 56) | (0 << 55) | (3 << 52) | (busWidths << 48);
}

/// The SCR register as 8 bytes, most significant byte first.
///
/// The card sends the SCR on the data lines in this order.
List<int> sdScrToBytes(int scr) => [
  for (var shift = 56; shift >= 0; shift -= 8) (scr >> shift) & 0xFF,
];

/// The value of a register, for a port that is as wide as the register.
///
/// [bytes] is the register with the most significant byte first, which is
/// the order that the card sends. The result drives a 128-bit port, which
/// is wider than an int, so it is a [BigInt]. Every entry must be 0 to
/// 255, and an entry outside that range throws.
BigInt sdRegisterToBigInt(List<int> bytes) {
  var value = BigInt.zero;
  for (final b in bytes) {
    _checkRange(b, 0, 0xFF, 'bytes', 'A register byte is 0 to 255');
    value = (value << 8) | BigInt.from(b);
  }
  return value;
}

/// The register as 32-bit words, most significant word first.
///
/// The host writes a register to the device one word at a time, so a
/// register goes to the hardware in this shape. [bytes] must hold a whole
/// number of words, else the last word would hold bits that the caller did
/// not give, and a byte count that is not a multiple of 4 throws.
List<int> sdRegisterToWords(List<int> bytes) {
  if (bytes.length % 4 != 0) {
    throw ArgumentError.value(
      bytes.length,
      'bytes',
      'A 32-bit word is 4 bytes, so the byte count must be a multiple of 4.',
    );
  }
  final words = <int>[];
  for (var i = 0; i < bytes.length; i += 4) {
    for (var j = i; j < i + 4; j++) {
      _checkRange(bytes[j], 0, 0xFF, 'bytes', 'A register byte is 0 to 255');
    }
    words.add(
      (bytes[i] << 24) |
          (bytes[i + 1] << 16) |
          (bytes[i + 2] << 8) |
          bytes[i + 3],
    );
  }
  return words;
}

/// Adds the last byte of a CID or a CSD to the first 15 bytes.
///
/// The last byte is the 7-bit CRC over the first 120 bits and then a 1,
/// which is also the end bit of the response frame.
List<int> _withCrc7(List<int> bytes) {
  assert(bytes.length == sdRegisterBytes - 1, 'the CRC needs 15 bytes');
  return [...bytes, (sdCrc7(bytes) << 1) | 1];
}

/// Throws if [value] is not in [low] to [high].
///
/// A value outside its field would change the bits of a different field,
/// and the host would then read a card that nobody made. [name] is the
/// argument and [why] says what the field holds.
void _checkRange(int value, int low, int high, String name, String why) {
  if (value < low || value > high) {
    throw ArgumentError.value(value, name, '$why, so give $low to $high.');
  }
}

/// Throws if [text] is not [length] ASCII characters.
///
/// The CID holds these fields as fixed-length ASCII. A shorter or a longer
/// string would move every field after it. [name] is the argument and
/// [field] is the name in the specification.
void _checkAscii(String text, int length, String name, String field) {
  if (text.length != length) {
    throw ArgumentError.value(
      text,
      name,
      '$field is exactly $length ASCII characters.',
    );
  }
  for (var i = 0; i < length; i++) {
    final code = text.codeUnitAt(i);
    if (code < 0x20 || code > 0x7E) {
      throw ArgumentError.value(
        text,
        name,
        '$field holds printable ASCII only.',
      );
    }
  }
}

/// Number of bytes in the switch status that CMD6 sends on the data lines.
///
/// The SD Physical Layer specification calls this the status data
/// structure of SWITCH_FUNC. It is 512 bits and the card sends it in the
/// same frame shape a block read uses.
const int sdSwitchStatusBytes = 64;

/// Number of bits in the switch status. See [sdSwitchStatusBytes].
const int sdSwitchStatusBits = sdSwitchStatusBytes * 8;

/// Number of function groups that the switch status reports.
///
/// The groups are 1 access mode, 2 command system, 3 driver strength, 4
/// power limit, 5 reserved and 6 reserved.
const int sdSwitchGroups = 6;

/// Number of bits that one function group takes in the CMD6 argument and
/// in the selection field of the status.
const int sdSwitchGroupBits = 4;

/// Number of bits that one function group takes in the support map and in
/// the busy map of the status.
///
/// The map holds one bit for each of the 16 functions a group can name.
const int sdSwitchGroupMapBits = 16;

/// Number of bits in the maximum current field of the switch status.
const int sdSwitchMaxCurrentBits = 16;

/// The function number that every group holds as its default.
///
/// Function 0 of group 1 is the default speed access mode. Function 0 of
/// every other group is the behaviour of a card that names no option. A
/// card supports function 0 of every group and cannot refuse it.
const int sdSwitchFunctionDefault = 0;

/// The support map of a group that offers the default function alone.
///
/// Bit `n` of a support map is high while the card supports function `n`,
/// so bit 0 alone is a group with no option beyond the default.
const int sdSwitchSupportDefaultOnly = 1 << sdSwitchFunctionDefault;

/// The group 1 function number of the high speed access mode.
///
/// A card that sets this bit in the group 1 support map tells the host it
/// can take a 50 MHz clock. Do NOT set it while the datapath answers at
/// the default speed. See [sdCardSwitchStatus].
const int sdSwitchFunctionHighSpeed = 1;

/// The value of a selection field that reports a function the card does
/// not have.
///
/// The specification uses 0xF both for a check that the card cannot grant
/// and for a switch that failed.
const int sdSwitchSelectNotSupported = 0xF;

/// The argument nibble that asks a group to stay as it is.
///
/// A host puts 0xF in a group it does not want to move. The card reads it
/// the same way it reads a request for the function that is already
/// selected.
const int sdSwitchArgNoChange = 0xF;

/// The version number of the status data structure, in bits 375 to 368.
///
/// Version 1 defines the busy fields down to bit 272, which version 0 does
/// not have. A card that reports SD_SPEC 2 in its SCR uses version 1.
const int sdSwitchStatusVersion = 1;

/// Bit number of the lowest bit of the selection field of the status.
///
/// The selection field holds one nibble for each group, group 1 lowest.
/// Bits 379 to 376 are group 1 and bits 399 to 396 are group 6.
const int sdSwitchSelectionLsb = 376;

/// Number of bits in the whole selection field. See [sdSwitchSelectionLsb].
const int sdSwitchSelectionBits = sdSwitchGroups * sdSwitchGroupBits;

/// Bit number of the CMD6 argument that selects the mode.
///
/// A 0 is CHECK, which asks what the card supports and changes nothing. A
/// 1 is SWITCH, which asks the card to change function.
const int sdSwitchModeBit = 31;

/// The maximum current the card consumes, in mA, for bits 511 to 496.
///
/// The value is the current budget of the SD bus at the default speed. The
/// host reads it to learn if its supply can feed the card while a function
/// is active. This card adds no optional function, so the number is the
/// budget of a card that only does what the specification asks of every
/// card.
const int sdSwitchMaxCurrentMa = 100;

/// The switch status of a card that offers no function beyond the default.
///
/// [maxCurrentMa] goes in bits 511 to 496. [selections] holds the value of
/// the selection nibble of each group, group 1 first. The default reports
/// the default function of every group.
///
/// The layout from the first bit is: 16 bits of maximum current, then the
/// support map of group 6 down to group 1 at 16 bits each, then the
/// selection nibble of group 6 down to group 1 at 4 bits each, then 8 bits
/// of structure version, then the busy map of group 6 down to group 1 at
/// 16 bits each, and then 272 reserved bits that stay 0.
///
/// The support map of every group is [sdSwitchSupportDefaultOnly], because
/// this card has no optional function at all. The busy map of every group
/// is 0, because a function that the card does not have is never busy.
///
/// Every argument outside its field throws, because a value that does not
/// fit would change a different field.
List<int> sdSwitchStatus({
  int maxCurrentMa = sdSwitchMaxCurrentMa,
  List<int> selections = const [0, 0, 0, 0, 0, 0],
}) {
  _checkRange(
    maxCurrentMa,
    0,
    (1 << sdSwitchMaxCurrentBits) - 1,
    'maxCurrentMa',
    'The maximum current field is $sdSwitchMaxCurrentBits bits',
  );
  if (selections.length != sdSwitchGroups) {
    throw ArgumentError.value(
      selections.length,
      'selections',
      'The status holds one selection nibble for each of the '
          '$sdSwitchGroups groups.',
    );
  }
  for (final selection in selections) {
    _checkRange(
      selection,
      0,
      (1 << sdSwitchGroupBits) - 1,
      'selections',
      'A selection field is $sdSwitchGroupBits bits',
    );
  }

  final bytes = <int>[
    // Bits 511 to 496: the maximum current.
    (maxCurrentMa >> 8) & 0xFF,
    maxCurrentMa & 0xFF,
    // Bits 495 to 400: the support map of group 6 down to group 1.
    for (var group = sdSwitchGroups; group >= 1; group--) ...[
      (sdSwitchSupportDefaultOnly >> 8) & 0xFF,
      sdSwitchSupportDefaultOnly & 0xFF,
    ],
    // Bits 399 to 376: the selection nibble of group 6 down to group 1.
    // Two groups share one byte, so the loop steps down in pairs.
    for (var group = sdSwitchGroups; group >= 2; group -= 2)
      ((selections[group - 1] & 0xF) << 4) | (selections[group - 2] & 0xF),
    // Bits 375 to 368: the version of the structure.
    sdSwitchStatusVersion,
    // Bits 367 to 272: the busy map of group 6 down to group 1. Nothing is
    // busy, because the card holds no optional function to make busy.
    for (var group = sdSwitchGroups; group >= 1; group--) ...[0x00, 0x00],
    // Bits 271 to 0: reserved.
  ];
  return [
    ...bytes,
    for (var i = bytes.length; i < sdSwitchStatusBytes; i++) 0x00,
  ];
}

/// The support map of one group, read back out of a switch status.
///
/// [status] is the [sdSwitchStatusBytes] bytes that [sdSwitchStatus]
/// gives. [group] is 1 to [sdSwitchGroups]. The result is the 16-bit map
/// in which bit `n` is high while the card supports function `n`.
int sdSwitchStatusSupport(List<int> status, int group) {
  if (status.length != sdSwitchStatusBytes) {
    throw ArgumentError.value(
      status.length,
      'status',
      'A switch status is $sdSwitchStatusBytes bytes.',
    );
  }
  _checkRange(group, 1, sdSwitchGroups, 'group', 'A group is 1 to 6');
  // The map of group 6 starts at byte 2 and each group below it is two
  // bytes later.
  final index = 2 + (sdSwitchGroups - group) * 2;
  return (status[index] << 8) | status[index + 1];
}
