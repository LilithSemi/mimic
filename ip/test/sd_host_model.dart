// A host-side SD bus model for the link layer Mimic tests.
//
// The host owns the clock, because a real SD host does. The model drives
// [SdHost.clk] by hand rather than with SimpleClockGenerator, so a test can
// stop the clock in the middle of a transfer, which is a real scenario a
// card must survive.
//
// The model also owns the tie between the card and the bus. Every test that
// lets the card answer needs that tie, and a tie that each test writes
// again is a tie that each test can get wrong.

import 'dart:async';

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';

/// Smallest legal Ncr, in clocks.
///
/// Ncr is the gap from the end bit of a command to the start bit of the
/// response. The model measures that gap as `startClock - endClock`, so
/// the smallest value it accepts, 2, puts the start bit on the second
/// clock after the end bit and leaves one idle clock between the two.
///
/// The convention is an open question. Section 4.12 Timings of the SD
/// Physical Layer Simplified Specification is blank, so the numbers come
/// from the MMC specification that SD inherits. Figure 26 of JESD84-A43
/// shows two Z bits between the end bit of the command and the first bit
/// that the card drives. That reading puts the earliest legal start bit at
/// `endClock + 3` and the latest at `endClock + 65`, which is one clock
/// more than [sdNcrMin] and [sdNcrMax] give here.
///
/// The same design counts the other way for Ncc: [sdCommandGapClocks] is 8
/// idle clocks, which is `startClock - endClock == 9`. The two conventions
/// are one clock apart.
///
/// The bounds stay as they are for now. The link today starts a response
/// from the clock that carries `resp_start`, so its Ncr is not the Ncr of
/// a card that decodes a command before it answers. Measure the real Ncr
/// and settle the convention when a card personality lands.
const int sdNcrMin = 2;

/// Largest legal Ncr, in clocks.
///
/// The value uses the same `startClock - endClock` convention as
/// [sdNcrMin]. Read the note there for the open question about the
/// convention and about the MMC reading that gives 65.
const int sdNcrMax = 64;

/// Builds the 48 bits of an SD command as 6 bytes.
///
/// The layout is the start bit 0, the transmission bit 1, the 6-bit index,
/// the 32-bit argument, the 7-bit CRC7 and the end bit 1.
///
/// [index] must fit in 6 bits and [argument] must fit in 32 bits. A value
/// that does not fit throws. The frame of a masked value is a legal frame
/// with a good CRC7 for a command that the caller did not ask for, so the
/// device answers it and the test then looks for the fault in the device.
List<int> sdCommandFrame(int index, int argument) {
  if (index < 0 || index >= (1 << sdCommandIndexBits)) {
    throw ArgumentError.value(
      index,
      'index',
      'must be 0 to ${(1 << sdCommandIndexBits) - 1}. The index field of a '
          'command is $sdCommandIndexBits bits.',
    );
  }
  if (argument < 0 || argument > 0xFFFFFFFF) {
    throw ArgumentError.value(
      argument,
      'argument',
      'must be 0 to 0xFFFFFFFF. The argument field of a command is '
          '$sdCommandArgBits bits.',
    );
  }
  final head = <int>[
    0x40 | index,
    (argument >> 24) & 0xFF,
    (argument >> 16) & 0xFF,
    (argument >> 8) & 0xFF,
    argument & 0xFF,
  ];
  return [...head, ((sdCrc7(head) << 1) | 1) & 0xFF];
}

/// The three shapes of a response on the CMD line.
enum SdResponseKind {
  /// 48 bits: start 0, transmission 0, the 6-bit index, the 32-bit status,
  /// a CRC7 and the end bit 1. R1, R6 and R7 all have this shape.
  r1(sdCommandBits),

  /// 48 bits: the reserved field 111111, the 32-bit OCR, the fixed field
  /// 1111111 in place of a CRC7 and the end bit 1.
  r3(sdCommandBits),

  /// 136 bits: the reserved field 111111 and the 128 bits of the CID or
  /// the CSD register. The register carries its own CRC7 and its own end
  /// bit.
  r2(sdResponseLongBits);

  const SdResponseKind(this.frameBits);

  /// Number of bits in one frame of this shape.
  final int frameBits;
}

/// The result of one [SdHost.receiveDataBlock].
///
/// The result holds the bytes and every verdict a host reads out of the
/// frame, so a test can check the payload and the framing apart from each
/// other.
class SdDataBlock {
  /// The payload bytes, in the order they came off the wire.
  ///
  /// The list is empty after a timeout.
  final List<int> bytes;

  /// The 16 CRC bits the card sent after the payload.
  final int crc;

  /// True if [crc] matches [bytes].
  final bool crcOk;

  /// True if the start bit is 0 and the end bit is 1.
  final bool framingOk;

  /// True if no start bit came before the timeout.
  final bool timedOut;

  /// Clocks the host waited for the start bit.
  final int gap;

  const SdDataBlock._({
    required this.bytes,
    required this.crc,
    required this.crcOk,
    required this.framingOk,
    required this.timedOut,
    required this.gap,
  });
}

/// The result of one [SdHost.receiveResponse].
///
/// The result holds the raw bits and every field a host reads out of them,
/// so a test can check the decode and the wire at the same time.
class SdResponse {
  /// The shape the host asked for.
  final SdResponseKind kind;

  /// The frame bits in the order they came off the wire, most significant
  /// bit first. The list is empty after a timeout.
  final List<int> bits;

  /// True if no start bit came before the timeout.
  final bool timedOut;

  /// Clocks from the end bit of the last command to the start bit of this
  /// response. It is null if no command came before the response.
  final int? ncr;

  /// The 6-bit field after the transmission bit.
  ///
  /// It is the command index in an R1 and the reserved 111111 in an R3 or
  /// an R2.
  final int field;

  /// The 32-bit payload of a short frame: the status of an R1 or the OCR
  /// of an R3. It is 0 for an R2.
  final int payload;

  /// The 128 bits of the register that an R2 carries. It is zero for a
  /// short frame.
  final BigInt register;

  /// The 7 bits in the CRC field of a short frame. It is 0 for an R2.
  final int crc;

  /// True if the CRC7 over the frame matches [crc].
  ///
  /// It is null where no CRC covers the frame, which is an R3 and an R2.
  final bool? crcOk;

  /// True if bits 7 to 1 of an R3 are the fixed 1111111.
  ///
  /// A host reads that field in place of a CRC. It is null for the kinds
  /// that carry no fixed field.
  final bool? fixedFieldOk;

  /// True if the start bit is 0, the transmission bit is 0 and the end bit
  /// is 1.
  final bool framingOk;

  SdResponse._({
    required this.kind,
    required this.bits,
    required this.timedOut,
    required this.ncr,
    required this.field,
    required this.payload,
    required this.register,
    required this.crc,
    required this.crcOk,
    required this.fixedFieldOk,
    required this.framingOk,
  });

  /// Builds the result of a response that never came.
  ///
  /// A response that never came has no start bit, so it has no Ncr to
  /// measure and no bits to decode.
  factory SdResponse.timeout(SdResponseKind kind) => SdResponse._(
    kind: kind,
    bits: const [],
    timedOut: true,
    ncr: null,
    field: 0,
    payload: 0,
    register: BigInt.zero,
    crc: 0,
    crcOk: null,
    fixedFieldOk: null,
    framingOk: false,
  );

  /// Decodes one frame of [kind] out of [bits].
  ///
  /// [bits] holds one 0 or one 1 for each clock of the frame, most
  /// significant bit first, and must be [SdResponseKind.frameBits] long.
  ///
  /// The checks follow what a real host does with each shape. An R1 has a
  /// CRC7 over its 40 leading bits, so [crcOk] holds that verdict. An R3
  /// carries no CRC, so the host reads the fixed 1111111 in bits 7 to 1
  /// instead and [fixedFieldOk] holds that verdict. An R2 carries the CRC7
  /// of the register inside the register, so this method checks no CRC over
  /// the frame and gives the 128 bits back.
  ///
  /// A bad CRC7 or a bad fixed field is data and never throws, because a
  /// test must be able to see a card that gets them wrong. Bad framing is
  /// a fault in the caller or in the card and throws while [strict] is
  /// true.
  factory SdResponse.decode(
    SdResponseKind kind,
    List<int> bits, {
    int? ncr,
    bool strict = true,
  }) {
    if (bits.length != kind.frameBits) {
      throw ArgumentError.value(
        bits.length,
        'bits',
        'must hold ${kind.frameBits} bits for ${kind.name}.',
      );
    }
    for (var i = 0; i < bits.length; i++) {
      if (bits[i] != 0 && bits[i] != 1) {
        throw ArgumentError.value(
          bits[i],
          'bits[$i]',
          'must be 0 or 1. A frame bit that is X or Z means the card left '
              'the line undriven.',
        );
      }
    }

    final framingOk = bits[0] == 0 && bits[1] == 0 && bits.last == 1;
    if (strict && !framingOk) {
      throw StateError(
        'the ${kind.name} frame is not framed: start bit ${bits[0]}, '
        'transmission bit ${bits[1]}, end bit ${bits.last}. A response has '
        'a 0 start bit, a 0 transmission bit and a 1 end bit.',
      );
    }

    var field = 0;
    for (var i = 2; i < sdResponseHeaderBits; i++) {
      field = (field << 1) | bits[i];
    }

    if (kind == SdResponseKind.r2) {
      var register = BigInt.zero;
      for (var i = sdResponseHeaderBits; i < bits.length; i++) {
        register = (register << 1) | BigInt.from(bits[i]);
      }
      return SdResponse._(
        kind: kind,
        bits: List<int>.unmodifiable(bits),
        timedOut: false,
        ncr: ncr,
        field: field,
        payload: 0,
        register: register,
        crc: 0,
        crcOk: null,
        fixedFieldOk: null,
        framingOk: framingOk,
      );
    }

    var payload = 0;
    for (var i = 0; i < sdCommandArgBits; i++) {
      payload = (payload << 1) | bits[sdResponseHeaderBits + i];
    }

    // The CRC field starts where the covered bits stop, because the CRC7
    // covers every bit in front of it. sdCommandCrcBits counts the covered
    // bits and this local gives the position of the first CRC bit. The two
    // are the same number read in two ways, so each use gets its own name.
    const crcFieldStart = sdCommandCrcBits;
    var crc = 0;
    for (var i = crcFieldStart; i < sdCommandBits - 1; i++) {
      crc = (crc << 1) | bits[i];
    }

    // The CRC7 covers the 40 leading bits of the frame, which are the
    // header and the payload. The same helper the device uses builds the
    // verdict, so the model and the device cannot disagree.
    final covered = <int>[];
    for (var i = 0; i < sdCommandCrcBits; i += 8) {
      var b = 0;
      for (var j = 0; j < 8; j++) {
        b = (b << 1) | bits[i + j];
      }
      covered.add(b);
    }

    return SdResponse._(
      kind: kind,
      bits: List<int>.unmodifiable(bits),
      timedOut: false,
      ncr: ncr,
      field: field,
      payload: payload,
      register: BigInt.zero,
      crc: crc,
      crcOk: kind == SdResponseKind.r1 ? crc == sdCrc7(covered) : null,
      fixedFieldOk: kind == SdResponseKind.r3 ? crc == 0x7F : null,
      framingOk: framingOk,
    );
  }

  /// True if [ncr] is inside the window the specification gives.
  ///
  /// It is null if no command came before the response, because then there
  /// is no end bit to measure the gap from.
  bool? get ncrInWindow =>
      ncr == null ? null : ncr! >= sdNcrMin && ncr! <= sdNcrMax;

  @override
  String toString() => timedOut
      ? 'SdResponse(${kind.name}, timed out)'
      : 'SdResponse(${kind.name}, field 0x${field.toRadixString(16)}, '
            'payload 0x${payload.toRadixString(16)}, '
            'register 0x${register.toRadixString(16)}, '
            'crcOk $crcOk, fixedFieldOk $fixedFieldOk, ncr $ncr)';
}

/// The codes of the CRC status token on DAT0.
enum SdStatusToken {
  /// The card took the block.
  accepted(0x2),

  /// The CRC16 of the block was wrong.
  crcError(0x5),

  /// The card could not write the block.
  writeError(0x6),

  /// A code that the specification does not give.
  unknown(-1);

  const SdStatusToken(this.code);

  /// The three bits of the token.
  final int code;

  /// The token that [code] names, or [unknown].
  static SdStatusToken fromCode(int code) =>
      values.firstWhere((t) => t.code == code, orElse: () => unknown);
}

/// The result of one [SdHost.receiveStatusToken].
class SdStatusResult {
  /// The decoded token.
  final SdStatusToken token;

  /// The three status bits as they came off the wire.
  final int code;

  /// The five token bits in wire order. The list is empty after a timeout.
  final List<int> bits;

  /// True if no start bit came before the timeout.
  final bool timedOut;

  /// Clocks the host waited before the start bit of the token.
  final int gap;

  /// True if the start bit is 0 and the stop bit is 1.
  final bool framingOk;

  const SdStatusResult._({
    required this.token,
    required this.code,
    required this.bits,
    required this.timedOut,
    required this.gap,
    required this.framingOk,
  });

  @override
  String toString() => timedOut
      ? 'SdStatusResult(timed out after $gap clocks)'
      : 'SdStatusResult(${token.name}, code 0x${code.toRadixString(16)}, '
            'gap $gap)';
}

/// Drives the SD bus the way a host does.
///
/// The host owns the clock. A real card sees a clock that starts, stops and
/// changes rate, so the model drives [clk] by hand rather than using
/// SimpleClockGenerator. That lets a test park the clock in the middle of a
/// transfer, which is a real scenario.
///
/// Give the model the four card signals as well and it ties the bus itself.
/// CMD carries the card's `cmd_out` while `cmd_oe` is high and the host's
/// own drive at every other time, and DAT works the same way with `dat_out`
/// and `dat_oe`. That is what the tristate in the parent module does. Only
/// a model with the tie can receive, so [receiveResponse],
/// [receiveStatusToken] and [waitBusy] all need it.
///
/// Use [driveCmd] and [driveDat] to put the host's own drive on a line.
/// Never inject into [cmdOut] or [datOut] directly, because the next tick
/// puts the tie back over it.
class SdHost {
  /// The clock the host drives.
  final Logic clk;

  /// The CMD line. This is the device's `cmd_in`.
  ///
  /// The model injects the tie of the host drive and the card drive here.
  final Logic cmdOut;

  /// The DAT lines. This is the device's `dat_in`.
  final Logic datOut;

  /// The card's `cmd_out`, or null if the test wires no card back.
  final Logic? cardCmd;

  /// The card's `cmd_oe`, or null if the test wires no card back.
  final Logic? cardCmdOe;

  /// The card's `dat_out`, or null if the test wires no card back.
  final Logic? cardDat;

  /// The card's `dat_oe`, or null if the test wires no card back.
  final Logic? cardDatOe;

  /// Number of active data lines.
  final int busWidth;

  /// The host's own drive on CMD. The line takes it while the card is
  /// quiet.
  LogicValue _cmdDrive = LogicValue.one;

  /// The host's own drive on DAT. The line takes it while the card is
  /// quiet.
  late LogicValue _datDrive = _datLine(1);

  /// Clocks the host has driven since it was built.
  int _clocks = 0;

  /// The clock that carried the end bit of the last command, or null if
  /// the host has sent no command.
  int? _commandEndClock;

  SdHost({
    required this.clk,
    required this.cmdOut,
    required this.datOut,
    this.cardCmd,
    this.cardCmdOe,
    this.cardDat,
    this.cardDatOe,
    this.busWidth = 1,
  });

  /// The DAT value that drives DAT0 with [bit] and releases every other
  /// line. A released line rests high.
  LogicValue _datLine(int bit) {
    final released = ((1 << busWidth) - 1) & ~1;
    return LogicValue.ofInt(released | (bit & 1), busWidth);
  }

  /// The value on CMD now: the card's drive while the card drives, and the
  /// host's drive at every other time.
  ///
  /// An X or a Z on `cmd_oe` throws. See [_checkOe].
  LogicValue get cmdLine {
    _checkOe(cardCmdOe, 'cmd_oe');
    return (cardCmdOe?.value == LogicValue.one) ? cardCmd!.value : _cmdDrive;
  }

  /// The value on DAT now, in the same shape as [cmdLine].
  ///
  /// An X or a Z on `dat_oe` throws. See [_checkOe].
  LogicValue get datLine {
    _checkOe(cardDatOe, 'dat_oe');
    return (cardDatOe?.value == LogicValue.one) ? cardDat!.value : _datDrive;
  }

  /// Throws if the output enable [oe] holds a value that is not 0 or 1.
  ///
  /// [name] names the signal in the message. The tie reads an output enable
  /// to find out who drives the line, so a card that leaves the enable
  /// undriven gives the line back to the host and hides the fault. The
  /// model makes the fault loud instead.
  ///
  /// The check starts after the first clock, because a register of the card
  /// holds no value before the host drives an edge.
  void _checkOe(Logic? oe, String name) {
    if (oe == null || _clocks == 0 || oe.value.isValid) return;
    throw StateError(
      'the card holds ${oe.value} on $name after $_clocks clocks. An output '
      'enable must be 0 or 1, because the host reads it to find out who '
      'drives the line.',
    );
  }

  /// CMD as a plain bit. It is -1 while the line holds X or Z.
  int get _cmdBit => cmdLine.isValid ? cmdLine.toInt() : -1;

  /// DAT0 as a plain bit. It is -1 while the line holds X or Z.
  int get _dat0Bit {
    final v = datLine[0];
    return v.isValid ? v.toInt() : -1;
  }

  /// Puts the tie on both lines.
  void _tie() {
    cmdOut.inject(cmdLine);
    datOut.inject(datLine);
  }

  /// Puts the host's own drive on CMD.
  void driveCmd(int bit) {
    _cmdDrive = LogicValue.ofInt(bit, 1);
    _tie();
  }

  /// Puts the host's own drive on DAT0 and releases the other data lines.
  void driveDat(int bit) {
    _datDrive = _datLine(bit);
    _tie();
  }

  /// Throws if the test wired no card back to the host.
  void _requireCardTie() {
    if (cardCmd == null ||
        cardCmdOe == null ||
        cardDat == null ||
        cardDatOe == null) {
      throw StateError(
        'the host can only receive with the card tied to it. Give SdHost '
        'cardCmd, cardCmdOe, cardDat and cardDatOe.',
      );
    }
  }

  /// One full clock period, low then high. The device samples on the rising
  /// edge, so the host changes the lines while the clock is low.
  ///
  /// The tie goes on the lines before the falling edge, so the device
  /// samples what the bus holds now. The card puts its next bit out on the
  /// rising edge, so the input of the device holds the bit of the clock
  /// that just ended until the next tick starts. Read [cmdLine] and
  /// [datLine] for the value the bus holds now.
  Future<void> tick() async {
    _tie();
    clk.inject(0);
    await _wait(5);
    clk.inject(1);
    await _wait(5);
    _clocks++;
  }

  /// Waits [amount] simulated time units, using the simulator's action
  /// queue. This is how a hand-driven clock waits without a clock
  /// generator running the schedule for it.
  Future<void> _wait(int amount) {
    final completer = Completer<void>();
    Simulator.registerAction(Simulator.time + amount, completer.complete);
    return completer.future;
  }

  /// Holds the clock still for [amount] simulated time units.
  ///
  /// The clock keeps the level it has now and no edge comes. A real host
  /// can stop the clock at any bit of a transfer, so the card must hold its
  /// state and go on when the clock starts again. This is the public form
  /// of the time-advance helper above.
  Future<void> park(int amount) => _wait(amount);

  /// Holds CMD and DAT released (high) for [cycles] clocks.
  Future<void> idle(int cycles) async {
    driveCmd(1);
    driveDat(1);
    for (var i = 0; i < cycles; i++) {
      await tick();
    }
  }

  /// Sends one data block: the start bit, the payload most significant bit
  /// first, the CRC16 and the end bit. This is the 1-bit form. A wide bus
  /// splits the payload across the lines and gives each line its own CRC.
  ///
  /// Only DAT0 carries the block. The other data lines stay released, the
  /// same way [idle] leaves them.
  /// [crcOverride] replaces the CRC16 the host computes. A test gives it a
  /// wrong value to make the card see a damaged block. The payload still
  /// goes out whole, which is what a real line fault looks like: the bytes
  /// arrive and the check on them fails.
  Future<void> sendDataBlock(List<int> bytes, {int? crcOverride}) async {
    // Build the CRC16 first. The helper reads 8 bits of each entry and
    // throws for an entry outside 0 to 255, and a throw in the middle of
    // the block would leave the card inside a block that has no end bit.
    final crc = crcOverride ?? sdCrc16(bytes);
    driveDat(0); // start bit
    await tick();
    for (final b in bytes) {
      for (var i = 7; i >= 0; i--) {
        driveDat((b >> i) & 1);
        await tick();
      }
    }
    for (var i = 15; i >= 0; i--) {
      driveDat((crc >> i) & 1);
      await tick();
    }
    driveDat(1); // end bit
    await tick();
  }

  /// Sends one command, most significant bit first.
  ///
  /// The host remembers the clock of the end bit, so [receiveResponse] can
  /// measure Ncr from it.
  Future<void> sendCommand(int index, int argument) async {
    for (final b in sdCommandFrame(index, argument)) {
      for (var i = 7; i >= 0; i--) {
        driveCmd((b >> i) & 1);
        await tick();
      }
    }
    _commandEndClock = _clocks - 1;
    driveCmd(1);
  }

  /// Waits for the start bit of a response and reads the whole frame.
  ///
  /// [kind] gives the shape of the frame, which fixes its length and the
  /// checks that go with it. See [SdResponse.decode] for those checks.
  ///
  /// The host waits at most [timeoutClocks] clocks for the start bit,
  /// counted from this call. A response that never comes gives a result
  /// with `timedOut` true and no bits, so a test sees a timeout and a bad
  /// frame as two different outcomes.
  ///
  /// The host looks for the start bit on the tied line, and that line
  /// carries the host drive while the card is quiet. The host cannot tell
  /// its own low drive from a low drive of the card, so leave CMD released
  /// before the call or the host reads its own bit as a start bit.
  ///
  /// While [strict] is true the host demands a card that obeys the rules.
  /// A frame that is not framed throws, a response outside the Ncr window
  /// of [sdNcrMin] to [sdNcrMax] clocks throws, a bad CRC7 throws and an
  /// R3 with a bad fixed field throws. The result carries each verdict as
  /// well, so set [strict] to false to look at a card that breaks the
  /// rules.
  Future<SdResponse> receiveResponse(
    SdResponseKind kind, {
    int timeoutClocks = 128,
    bool strict = true,
  }) async {
    _requireCardTie();

    var waited = 0;
    while (_cmdBit != 0) {
      if (waited >= timeoutClocks) {
        return SdResponse.timeout(kind);
      }
      await tick();
      waited++;
    }

    // The bit on the line now is the start bit, and it belongs to clock
    // [_clocks]. Ncr counts from the clock of the end bit of the command.
    // This response uses the end bit up. A second call with no command in
    // front of it then reports no Ncr, and not a gap that is measured from
    // an old command.
    final ncr = _commandEndClock == null ? null : _clocks - _commandEndClock!;
    _commandEndClock = null;

    final bits = <int>[];
    for (var i = 0; i < kind.frameBits; i++) {
      bits.add(_cmdBit);
      await tick();
    }

    final response = SdResponse.decode(kind, bits, ncr: ncr, strict: strict);
    if (strict && response.ncrInWindow == false) {
      throw StateError(
        'the card answered $ncr clocks after the end bit of the command. '
        'Ncr must be $sdNcrMin to $sdNcrMax clocks.',
      );
    }
    if (strict && response.crcOk == false) {
      throw StateError(
        'the ${kind.name} frame carries the CRC7 '
        '0x${response.crc.toRadixString(16)}, which does not match the '
        'frame. A card that sends a bad CRC7 is a fault. Set strict to '
        'false to read the verdict in crcOk instead.',
      );
    }
    if (strict && response.fixedFieldOk == false) {
      throw StateError(
        'bits 7 to 1 of the ${kind.name} frame are '
        '0x${response.crc.toRadixString(16)} and not the fixed 0x7f. A host '
        'reads that field in place of a CRC. Set strict to false to read '
        'the verdict in fixedFieldOk instead.',
      );
    }
    return response;
  }

  /// Waits for the CRC status token on DAT0 and reads it.
  ///
  /// The card sends the token after a written block. It is a start bit 0,
  /// three status bits and a stop bit 1. The codes are in [SdStatusToken].
  ///
  /// The host waits at most [timeoutClocks] clocks for the start bit,
  /// counted from this call. A token that never comes gives a result with
  /// `timedOut` true. While [strict] is true a token with a bad stop bit
  /// throws, because the length of the token is fixed and a bad stop bit
  /// means the host and the card do not agree on it.
  ///
  /// A token bit that is X or Z throws, and it throws while [strict] is
  /// false as well. The card left DAT0 undriven for that bit, and an
  /// undriven bit that the host reads as a 1 turns a broken card into a
  /// legal code. [SdResponse.decode] refuses such a bit in the same way.
  ///
  /// The host looks for the start bit on the tied line, and that line
  /// carries the host drive while the card is quiet. The host cannot tell
  /// its own low drive from a low drive of the card, so leave DAT0
  /// released before the call.
  Future<SdStatusResult> receiveStatusToken({
    int timeoutClocks = 128,
    bool strict = true,
  }) async {
    _requireCardTie();

    var waited = 0;
    while (_dat0Bit != 0) {
      if (waited >= timeoutClocks) {
        return SdStatusResult._(
          token: SdStatusToken.unknown,
          code: -1,
          bits: const [],
          timedOut: true,
          gap: waited,
          framingOk: false,
        );
      }
      await tick();
      waited++;
    }

    final bits = <int>[];
    for (var i = 0; i < sdStatusTokenBits; i++) {
      bits.add(_dat0Bit);
      await tick();
    }

    for (var i = 0; i < bits.length; i++) {
      if (bits[i] != 0 && bits[i] != 1) {
        throw StateError(
          'bit $i of the status token is X or Z. The card left DAT0 '
          'undriven for that bit, so the token has no code.',
        );
      }
    }

    var code = 0;
    for (var i = 1; i <= sdStatusCodeBits; i++) {
      code = (code << 1) | bits[i];
    }
    final framingOk = bits.first == 0 && bits.last == 1;
    if (strict && !framingOk) {
      throw StateError(
        'the status token is not framed: start bit ${bits.first}, stop bit '
        '${bits.last}. A token has a 0 start bit and a 1 stop bit.',
      );
    }

    return SdStatusResult._(
      token: SdStatusToken.fromCode(code),
      code: code,
      bits: List<int>.unmodifiable(bits),
      timedOut: false,
      gap: waited,
      framingOk: framingOk,
    );
  }

  /// Waits for the start bit of a data block on DAT0 and reads it.
  ///
  /// The block is a start bit 0, [blockBytes] payload bytes most
  /// significant bit first, a 16-bit CRC and an end bit 1. This is the
  /// 1-bit form, which is the shape [SdHost.sendDataBlock] writes.
  ///
  /// The host waits at most [timeoutClocks] clocks for the start bit,
  /// counted from this call. A block that never comes gives a result with
  /// `timedOut` true and no bytes, so a test sees a card that sent nothing
  /// and a card that sent something wrong as two different outcomes.
  ///
  /// While [strict] is true a block with a bad CRC16 throws and a block
  /// with a 0 end bit throws. The result carries each verdict as well, so
  /// set [strict] to false to look at a card that breaks the rules.
  ///
  /// A block bit that is X or Z throws, and it throws while [strict] is
  /// false as well. The card left DAT0 undriven for that bit, and an
  /// undriven bit that the host reads as a 1 turns a broken card into a
  /// block with plausible bytes.
  ///
  /// The host looks for the start bit on the tied line, and that line
  /// carries the host drive while the card is quiet, so leave DAT0
  /// released before the call.
  Future<SdDataBlock> receiveDataBlock({
    int blockBytes = sdBlockBytes,
    int timeoutClocks = 1024,
    bool strict = true,
  }) async {
    _requireCardTie();

    var waited = 0;
    while (_dat0Bit != 0) {
      if (waited >= timeoutClocks) {
        return SdDataBlock._(
          bytes: const [],
          crc: 0,
          crcOk: false,
          framingOk: false,
          timedOut: true,
          gap: waited,
        );
      }
      await tick();
      waited++;
    }

    // The bit on the line now is the start bit. The frame that follows it
    // is the payload, the CRC and the end bit.
    final frameBits = 1 + blockBytes * 8 + sdDataCrcBits + 1;
    final bits = <int>[];
    for (var i = 0; i < frameBits; i++) {
      bits.add(_dat0Bit);
      await tick();
    }
    for (var i = 0; i < bits.length; i++) {
      if (bits[i] != 0 && bits[i] != 1) {
        throw StateError(
          'bit $i of the data block is X or Z. The card left DAT0 undriven '
          'for that bit, so the block has no bytes.',
        );
      }
    }

    final bytes = <int>[];
    for (var i = 0; i < blockBytes; i++) {
      var byte = 0;
      for (var b = 0; b < 8; b++) {
        byte = (byte << 1) | bits[1 + i * 8 + b];
      }
      bytes.add(byte);
    }
    var crc = 0;
    for (var i = 0; i < sdDataCrcBits; i++) {
      crc = (crc << 1) | bits[1 + blockBytes * 8 + i];
    }
    final crcOk = crc == sdCrc16(bytes);
    final framingOk = bits.first == 0 && bits.last == 1;

    if (strict && !framingOk) {
      throw StateError(
        'the data block is not framed: start bit ${bits.first}, end bit '
        '${bits.last}. A block has a 0 start bit and a 1 end bit.',
      );
    }
    if (strict && !crcOk) {
      throw StateError(
        'the data block carries the CRC16 0x${crc.toRadixString(16)}, which '
        'does not match its bytes. A card that sends a bad CRC16 is a '
        'fault. Set strict to false to read the verdict in crcOk instead.',
      );
    }

    return SdDataBlock._(
      bytes: List<int>.unmodifiable(bytes),
      crc: crc,
      crcOk: crcOk,
      framingOk: framingOk,
      timedOut: false,
      gap: waited,
    );
  }

  /// Waits while the card holds DAT0 low as busy.
  ///
  /// A card pulls DAT0 low after the status token while it writes the
  /// block, and releases the line when it is ready again. The result holds
  /// the number of clocks the line stayed low, and `timedOut` if the line
  /// was still low after [timeoutClocks] clocks. A line that is already
  /// high gives 0 clocks and no timeout.
  ///
  /// The host waits while DAT0 is not high, so it reads an X or a Z as
  /// busy. A card that leaves DAT0 undriven makes this method run to the
  /// timeout, and the result then says timed out and not fault. Read
  /// `datLine` after the call to tell the two apart.
  ///
  /// The host looks at the tied line, so it cannot tell its own low drive
  /// from a low drive of the card. Release DAT0 before the call.
  Future<({int clocks, bool timedOut})> waitBusy({
    int timeoutClocks = 4096,
  }) async {
    _requireCardTie();

    var clocks = 0;
    while (_dat0Bit != 1) {
      if (clocks >= timeoutClocks) {
        return (clocks: clocks, timedOut: true);
      }
      await tick();
      clocks++;
    }
    return (clocks: clocks, timedOut: false);
  }
}
