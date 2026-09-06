// MimicSdLink: the SD bus link layer, framing and CRC only.
//
// This module runs in the SD clock domain, which the host drives and can
// stop. It frames the 48-bit command on CMD and checks its CRC7. It also
// sends a response back on CMD, in each of the three shapes that the SD
// specification gives: 48 bits with a CRC7 that the link computes, 48 bits
// with the fixed CRC field of an R3, and the 136 bits of an R2. It knows
// nothing about card state, addresses or USB. A card personality sits on
// top of it and decides what the commands mean.
//
// Ports stay split (`cmd_in`, `cmd_out`, `cmd_oe`). The parent module owns
// the tristate, in the same shape as MimicUsbDevice. A split port is also
// much easier to drive from a ROHD test than a shared bidirectional net.

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Number of bits in one SD command frame on the CMD line.
///
/// The layout is the start bit, the transmission bit, the 6-bit index, the
/// 32-bit argument, the 7-bit CRC7 and the end bit.
const int sdCommandBits = 48;

/// Number of leading frame bits that the CRC7 covers.
///
/// The CRC7 covers the start bit, the transmission bit, the index and the
/// argument. It does not cover itself or the end bit.
const int sdCommandCrcBits = 40;

/// Number of bits in the index field of a command or a response.
const int sdCommandIndexBits = 6;

/// Number of bits in the argument field of a command.
///
/// A response of the same length holds its status or its OCR here.
const int sdCommandArgBits = 32;

/// Number of frame bits before the payload of a response.
///
/// The header is the start bit, the transmission bit and the 6-bit index
/// or reserved field. The link owns all of them.
const int sdResponseHeaderBits = 2 + sdCommandIndexBits;

/// Number of bits in one long response frame on the CMD line.
///
/// The R2 response holds the header and then the 128 bits of the CID or
/// the CSD register.
const int sdResponseLongBits = 136;

/// Number of bits in the register that an R2 response carries.
const int sdResponseRegBits = sdResponseLongBits - sdResponseHeaderBits;

/// Number of bits in the `resp_kind` port.
///
/// Three of the four values have a meaning. The fourth gives a short frame
/// with the reserved field 111111 and a computed CRC7, because a
/// transmitter must always send a frame that a host can parse. It is not
/// the frame of [sdRespKindR1], which takes its index field from the
/// caller.
const int sdRespKindBits = 2;

/// Response kind: 48 bits with a CRC7 that the link computes.
///
/// The caller gives the 6-bit index in `resp_data` bits 37 to 32 and the
/// 32-bit status in bits 31 to 0. R1, R6 and R7 all have this shape.
const int sdRespKindR1 = 0;

/// Response kind: 48 bits with the fixed CRC field 1111111.
///
/// R3 carries the OCR and has no CRC. Bits 7 to 1 of the frame are seven
/// ones and a host must not check them. The index field is also all ones.
/// The link puts the ones in both fields itself, so the caller gives the
/// OCR in `resp_data` bits 31 to 0 and nothing else.
const int sdRespKindR3 = 1;

/// Response kind: 136 bits with no CRC that the link computes.
///
/// R2 carries the CID or the CSD register in `resp_data` bits 127 to 0.
/// The register holds its own CRC7 in bits 7 to 1 and a 1 in bit 0, which
/// is the end bit of the frame, so the link sends the 128 bits as they
/// are.
const int sdRespKindR2 = 2;

/// Number of clocks that CMD must stay high before the framer can start.
///
/// The SD Physical Layer specification gives 8 clocks for Ncc, from the end
/// bit of one command to the start bit of the next command, and 8 clocks
/// for Nrc, from the end bit of a response to the start bit of the next
/// command. A host that obeys the specification always makes a gap of this
/// length, so the gate keeps all legal traffic.
const int sdCommandGapClocks = 8;

/// One CRC7 step, polynomial x^7 + x^3 + 1.
///
/// [state] is the current 7-bit remainder and [bit] is the bit now on the
/// wire. The result is the remainder after that bit. The feedback taps are
/// bit 6 out and bit 3 in, which agrees with `sdCrc7` in software.
Logic _crc7Step(Logic state, Logic bit, String name) {
  final feedback = (state[6] ^ bit).named('${name}_feedback');
  return [
    state.slice(5, 3),
    (state[2] ^ feedback).named('${name}_bit3'),
    state.slice(1, 0),
    feedback,
  ].swizzle().named(name);
}

/// Number of payload bytes in one SD data block.
///
/// The SD Physical Layer specification fixes the block length at 512 bytes
/// for standard capacity and high capacity cards.
const int sdBlockBytes = 512;

/// Number of CRC bits that follow the payload of a data block.
const int sdDataCrcBits = 16;

/// Number of status bits in the CRC status token.
const int sdStatusCodeBits = 3;

/// Number of bits in one CRC status token on DAT0.
///
/// The token is a start bit, [sdStatusCodeBits] status bits and a stop bit.
const int sdStatusTokenBits = sdStatusCodeBits + 2;

/// Number of clocks in one data block on DAT0.
///
/// The block is a start bit, [sdBlockBytes] bytes most significant bit
/// first, a [sdDataCrcBits] bit CRC and an end bit. The transmit path and
/// the receive path frame the same shape, so the two cannot drift apart.
const int sdDataBlockClocks = 1 + sdBlockBytes * 8 + sdDataCrcBits + 1;

/// Number of bits in the transmit LENGTH of one data frame.
///
/// A frame on DAT is not always a block. The card answers ACMD51 with the
/// 8 bytes of the SCR and CMD6 with the 64 bytes of the switch status, and
/// each of those is the same frame shape with fewer bytes in it. The
/// length is therefore a value the caller gives with the transfer, and the
/// width holds the longest frame the card sends, which is one block.
final int sdDataTxLenBits = sdBlockBytes.bitLength;

/// Number of clocks in a data frame of [bytes] payload bytes.
///
/// The frame is a start bit, [bytes] bytes most significant bit first, a
/// [sdDataCrcBits] bit CRC and an end bit. [sdDataBlockClocks] is this
/// count for a whole block.
int sdDataFrameClocks(int bytes) => 1 + bytes * 8 + sdDataCrcBits + 1;

/// Transmit phase 0: the data transmitter is idle.
const int sdDataTxPhaseIdle = 0;

/// Transmit phase 1: the start bit of the block is on the line.
const int sdDataTxPhaseStart = 1;

/// Transmit phase 2: the payload bytes are on the line.
const int sdDataTxPhasePayload = 2;

/// Transmit phase 3: the CRC16 is on the line.
const int sdDataTxPhaseCrc = 3;

/// Transmit phase 4: the end bit of the block is on the line.
const int sdDataTxPhaseEnd = 4;

/// Number of bits in the transmit phase register.
///
/// The width comes from the largest phase number, so a phase that this
/// file adds later cannot lose its top bit without notice.
final int sdDataTxPhaseBits = sdDataTxPhaseEnd.bitLength;

/// One CRC16 step, polynomial x^16 + x^12 + x^5 + 1.
///
/// [state] is the current 16-bit remainder and [bit] is the bit now on the
/// line. The result is the remainder after that bit. The feedback taps are
/// bit 15 out and bits 12, 5 and 0 in, which agrees with `sdCrc16` in
/// software. Each data line of a wide bus needs its own copy of this step,
/// so it takes the line as a parameter.
Logic _crc16Step(Logic state, Logic bit, String name) {
  final feedback = (state[15] ^ bit).named('${name}_feedback');
  return [
    state.slice(14, 12),
    (state[11] ^ feedback).named('${name}_bit12'),
    state.slice(10, 5),
    (state[4] ^ feedback).named('${name}_bit5'),
    state.slice(3, 0),
    feedback,
  ].swizzle().named(name);
}

/// SD link layer: command framing and CRC7 checking, plus response send.
///
/// `cmd_valid` is a pulse of one cycle, in the clock cycle after the last
/// bit of a frame is sampled. `cmd_index`, `cmd_arg` and `cmd_crc_ok` all
/// hold the result of that frame while the pulse is high. `cmd_crc_ok` is
/// a register and reads 0 in every other cycle, so a stale verdict cannot
/// leak between frames.
///
/// The framer starts a command only after CMD stays high for
/// [sdCommandGapClocks] clocks. The specification gives that gap after
/// every command and every response, so a legal host always makes it.
///
/// A pulse on `resp_start` sends a response back to the host, most
/// significant bit first. `resp_kind` picks the shape of the frame and the
/// link samples it with the pulse. The three kinds are [sdRespKindR1],
/// [sdRespKindR3] and [sdRespKindR2], and each one says which bits of
/// `resp_data` it reads.
///
/// The link owns the start bit and the transmission bit. Both are 0 in
/// every response, so the caller cannot set them. The link also owns the
/// six ones of the reserved field of an R3 and of an R2.
///
/// `resp_busy` and `cmd_oe` stay high for every bit of the frame, which is
/// [sdCommandBits] bits for a short kind and [sdResponseLongBits] bits for
/// an R2. The link drops a pulse on `resp_start` that comes while
/// `resp_busy` is high, so the caller must wait for `resp_busy` to fall
/// before it starts the next response.
///
/// The data receive path frames one block on DAT while `dat_rx_enable` is
/// high. A block is a start bit, [sdBlockBytes] bytes most significant bit
/// first, a [sdDataCrcBits] bit CRC and an end bit. `dat_byte_valid`
/// pulses for one cycle for each byte, with the byte on `dat_byte`.
/// `dat_block_end` pulses for one cycle after the last CRC bit, and
/// `dat_crc_ok` holds the verdict for that block while the pulse is high.
/// `dat_crc_ok` is a register and reads 0 in every other cycle, so a stale
/// verdict cannot leak between blocks.
///
/// The card personality must obey this contract for `dat_rx_enable`. It
/// must raise `dat_rx_enable` only in the window where it expects a block,
/// and it must hold `dat_rx_enable` high until `dat_block_end`.
/// `dat_rx_enable` gates the start of a block only. A block that is
/// already open runs to its end bit even if `dat_rx_enable` falls in the
/// middle of it.
///
/// The framer also ignores the bits that the card itself sends, and it
/// needs DAT0 high for one clock after a block before it can start a new
/// block. That clock is the end bit of a good block.
///
/// A pulse on `dat_status_send` sends the CRC status token on DAT0. The
/// token is a start bit 0, the [sdStatusCodeBits] bits of
/// `dat_status_code`, then a stop bit 1. `dat_oe` stays high for all
/// [sdStatusTokenBits] bits. The codes are 010 accepted, 101 CRC error and
/// 110 write error.
///
/// The data transmit path sends one data frame on DAT0. A pulse on
/// `dat_tx_start` opens the frame, and the link then drives
/// `sdDataFrameClocks(dat_tx_len)` clocks with no gap: the start bit, the
/// payload bytes most significant bit first, the CRC16 that the link
/// computes over those bytes, and the end bit. `dat_tx_busy` is high for
/// every one of those clocks and `dat_tx_done` pulses for one clock after
/// the end bit.
///
/// `dat_tx_len` is the PAYLOAD LENGTH IN BYTES of the frame the pulse
/// opens. The link samples it in the clock where it takes `dat_tx_start`
/// and holds it for the whole frame, so the caller may change the port
/// afterwards. A block read gives [sdBlockBytes], ACMD51 gives 8 for the
/// SCR and CMD6 gives 64 for the switch status. A length of 0 is not a
/// frame and the caller must never ask for one.
///
/// The caller feeds the payload one byte at a time. `dat_tx_byte` holds
/// the byte the link takes next, and `dat_tx_next` is high in the clock
/// where the link TAKES it. A caller therefore holds byte 0 on
/// `dat_tx_byte` before it pulses `dat_tx_start`, and moves to the next
/// byte on each clock where `dat_tx_next` is high. The link raises
/// `dat_tx_next` exactly `dat_tx_len` times, so the last pulse takes the
/// last byte and no pulse asks for a byte that does not exist.
///
/// The link cannot pause in the middle of a frame, because the SD bus has
/// no way to say wait inside one. The caller must therefore hold the whole
/// payload before it starts.
///
/// The transmitter and the status token share DAT0. The link drops a pulse
/// on `dat_tx_start` that comes while the token is going out, and a pulse
/// on `dat_status_send` that comes while a block is going out, so the two
/// cannot drive the line at once.
///
/// `dat_busy` holds DAT0 LOW while it is high and neither of those two
/// drives the line. A card that took a block pulls DAT0 low until it has
/// written the block, and the host waits on that level. The line is the
/// same line the two senders use, so the sender wins whenever one runs:
/// the busy level cannot cut a frame or a token in half. `dat_busy` also
/// holds the receive framer off, because a low line is not a line that a
/// new block can start on.
class MimicSdLink extends BridgeModule {
  /// Number of data lines. Only 1 is legal today.
  ///
  /// The port widths follow this value and the transmit side is already
  /// width correct, but the receive datapath reads DAT0 only. The
  /// constructor therefore refuses every other value. See the check below.
  final int busWidth;

  MimicSdLink({this.busWidth = 1, String? name})
    : super('MimicSdLink', name: name ?? 'sd_link') {
    if (busWidth != 1) {
      // The receive datapath is 1-bit only. It reads dat_in[0], it keeps
      // one 8-bit byte register and one CRC16 remainder, and it counts one
      // block as 4114 clocks. A card built at width 4 or 8 would therefore
      // take a quarter or an eighth of each block and then report a CRC
      // failure, which looks like bad data and not like a build error.
      // Bus widths 4 and 8 are planned. They need a per-line receive
      // datapath first.
      throw ArgumentError.value(
        busWidth,
        'busWidth',
        'must be 1. The receive path is 1-bit only. Widths 4 and 8 are '
            'planned and need a per-line receive datapath first.',
      );
    }
    if (sdDataTxLenBits != sdBlockBytes.bitLength) {
      throw StateError(
        'The transmit length port is $sdDataTxLenBits bits and one block is '
        '$sdBlockBytes bytes. The port must hold the longest frame the card '
        'sends, because Const truncates a wider value with no message and a '
        'truncated length is a frame that ends in the middle.',
      );
    }
    if (sdCommandGapClocks < 1) {
      throw StateError(
        'sdCommandGapClocks is $sdCommandGapClocks. It must be 1 or more, '
        'because a gate of 0 clocks arms the framer on every bit.',
      );
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('cmd_in', PortDirection.input);
    createPort('dat_in', PortDirection.input, width: busWidth);
    createPort('resp_start', PortDirection.input);
    createPort('resp_data', PortDirection.input, width: sdResponseRegBits);
    createPort('resp_kind', PortDirection.input, width: sdRespKindBits);
    createPort('dat_rx_enable', PortDirection.input);
    createPort('dat_busy', PortDirection.input);
    createPort('dat_status_send', PortDirection.input);
    createPort('dat_status_code', PortDirection.input, width: sdStatusCodeBits);
    createPort('dat_tx_start', PortDirection.input);
    createPort('dat_tx_byte', PortDirection.input, width: 8);
    createPort('dat_tx_len', PortDirection.input, width: sdDataTxLenBits);

    addOutput('cmd_out');
    addOutput('cmd_oe');
    addOutput('dat_out', width: busWidth);
    addOutput('dat_oe');
    addOutput('cmd_index', width: sdCommandIndexBits);
    addOutput('cmd_arg', width: sdCommandArgBits);
    addOutput('cmd_valid');
    addOutput('cmd_crc_ok');
    addOutput('resp_busy');
    addOutput('dat_byte', width: 8);
    addOutput('dat_byte_valid');
    addOutput('dat_block_end');
    addOutput('dat_crc_ok');
    addOutput('dat_tx_next');
    addOutput('dat_tx_busy');
    addOutput('dat_tx_done');

    final clk = input('clk');
    final reset = input('reset');
    final cmdIn = input('cmd_in');

    final crcStart = Const(sdCommandCrcBits, width: 6);
    final endBitIndex = Const(sdCommandBits - 1, width: 6);
    final one6 = Const(1, width: 6);

    // Transmit state. txActive is high for every bit of a response, which
    // is 48 bits or 136 bits. txCount holds the index of the frame bit that
    // cmd_out shows now, and txKind holds the kind that resp_start sampled.
    //
    // The width of the counter and of the shift register comes from the
    // longest frame, so a counter cannot truncate and miss the last bit and
    // a register cannot truncate and lose the payload.
    final txCountWidth = sdResponseLongBits.bitLength;
    final txActive = Logic(name: 'tx_active');
    final txCount = Logic(name: 'tx_count', width: txCountWidth);
    final txShift = Logic(name: 'tx_shift', width: sdResponseLongBits);
    final txCrc = Logic(name: 'tx_crc', width: 7);
    final txKind = Logic(name: 'tx_kind', width: sdRespKindBits);

    // Receive state. rxActive is high while a frame is shifted in. rxCount
    // holds the index of the frame bit that the next clock edge samples.
    final rxActive = Logic(name: 'rx_active');
    final rxCount = Logic(name: 'rx_count', width: 6);
    final rxShift = Logic(name: 'rx_shift', width: sdCommandCrcBits);
    final rxCrc = Logic(name: 'rx_crc', width: 7);
    final rxCrcIn = Logic(name: 'rx_crc_in', width: 7);
    final validPulse = Logic(name: 'rx_valid_pulse');
    final crcOk = Logic(name: 'rx_crc_ok');

    // Idle gate. rxIdle counts the clocks that CMD stays high while no
    // frame is open, and holds at sdCommandGapClocks. The framer is armed
    // only at that count.
    //
    // The width comes from the constant, so a larger gap cannot truncate
    // the goal to a smaller number and turn the gate off without notice.
    final idleWidth = sdCommandGapClocks.bitLength;
    final rxIdle = Logic(name: 'rx_idle', width: idleWidth);
    final oneIdle = Const(1, width: idleWidth);
    final zeroIdle = Const(0, width: idleWidth);
    final idleGoal = Const(sdCommandGapClocks, width: idleWidth);
    final armed = rxIdle.gte(idleGoal).named('rx_armed');

    // A frame starts on a low bit while the receiver is idle and armed.
    //
    // Three guards keep the framer off bits that are not a command.
    //
    // Guard 1 and guard 2 keep the card from framing its own response. The
    // parent ties cmd_out and cmd_in together, so the card sees what it
    // sends. A response also starts with a 0 bit and carries a good CRC7,
    // so the framer would accept it as a command.
    //
    // Guard 1 is txActive. The card is deaf to CMD while it drives CMD, so
    // txActive appears in three places. It keeps a frame from opening, in
    // the startBit term here. It clears the idle counter, so the ones the
    // card sends do not arm the framer and Nrc is counted from the clock
    // after the response. And it closes a frame that was already open, so
    // the bits the card sends cannot enter rxShift or rxCrcIn. The DAT
    // path holds the same rule with stActive.
    //
    // Guard 2 is in rxAbort below and reads the transmission bit.
    //
    // Guard 3 is the idle gate. Without it the framer starts on any low
    // bit, so it can start in the middle of a bit stream and build a frame
    // out of the tail of one frame plus the idle line. Some of those
    // frames carry a good CRC7 and a command index that a card acts on. A
    // start in the middle of a frame can also hold a frame open across the
    // command that comes next and lose that command.
    //
    // rxIdle resets to 0, so the framer leaves reset unarmed and must see
    // sdCommandGapClocks high clocks before its first start bit.
    //
    // The gate lowers the number of such frames. It does not remove them.
    // A command whose argument holds a run of 8 or more ones, and then a
    // 0, still arms the framer in the middle of that command.
    //
    // A sweep of the shipped configuration measured the frames that stay.
    // The stimulus was 400 random commands, each sent with reset released
    // at one of 47 points in the middle of the frame and with one more
    // command after it, which gives 18800 points. No garbage frame with a
    // good CRC7 came out. 244 of the 18800 points started the framer
    // inside the command in progress and lost the command that came
    // after. These counts belong to that stimulus and change with the
    // traffic.
    final startBit = (armed & ~rxActive & ~cmdIn & ~txActive).named('rx_start');

    // Frame bits 1 to 39 feed the shift register and the CRC. Bit 0, the
    // start bit, takes the startBit path below and does the same.
    final dataPhase = (rxActive & rxCount.lt(crcStart)).named('rx_data_phase');

    // Frame bits 40 to 46 are the CRC7 that the host sent.
    final crcPhase =
        (rxActive & ~rxCount.lt(crcStart) & rxCount.lt(endBitIndex)).named(
          'rx_crc_phase',
        );

    // Frame bit 47 is the end bit and closes the frame.
    final lastBit = (rxActive & rxCount.eq(endBitIndex)).named('rx_last');

    // Frame bit 1 is the transmission bit. A host to card command sets it
    // to 1 and a card to host response clears it. A frame with a 0 there
    // is not a command, so the receiver drops it and waits for a new start
    // bit. This is the second guard against framing the card's own send.
    final rxAbort = (rxActive & rxCount.eq(one6) & ~cmdIn).named('rx_abort');

    // The CRC7 restarts at zero for each frame, so the start bit runs
    // through a step that reads a zero remainder. This keeps the remainder
    // of the last frame out of the new one.
    final crcFirst = _crc7Step(Const(0, width: 7), cmdIn, 'rx_crc_first');
    final crcNext = _crc7Step(rxCrc, cmdIn, 'rx_crc_step');

    final shiftNext = [
      rxShift.slice(sdCommandCrcBits - 2, 0),
      cmdIn,
    ].swizzle().named('rx_shift_next');

    // startBit and rxActive are mutually exclusive, so these conditions can
    // sit side by side. The later ones win, which is what the end bit needs.
    Sequential(clk, reset: reset, [
      validPulse < Const(0),
      crcOk < Const(0),
      // The idle gate counter. A low bit on CMD clears the count, so only
      // a continuous run of high bits arms the framer. An open frame also
      // clears it, because the high bits inside a frame are frame bits and
      // not idle time. A response clears it too, because the parent loops
      // cmd_out back to cmd_in and the high bits of a response are frame
      // bits of the card's own send. The count therefore starts from the
      // clock after the end bit of a command or of a response, which is
      // where the specification starts Ncc and Nrc. The count holds at the
      // goal and does not wrap. The reset value is 0.
      If(
        cmdIn & ~rxActive & ~txActive,
        then: [
          If(~armed, then: [rxIdle < rxIdle + oneIdle]),
        ],
        orElse: [rxIdle < zeroIdle],
      ),
      If(
        startBit,
        then: [
          // The start bit is bit 0 of the frame and joins the CRC.
          rxActive < Const(1),
          rxCount < one6,
          rxShift < shiftNext,
          rxCrc < crcFirst,
        ],
      ),
      If(rxActive, then: [rxCount < rxCount + one6]),
      If(dataPhase, then: [rxShift < shiftNext, rxCrc < crcNext]),
      If(
        crcPhase,
        then: [
          rxCrcIn < [rxCrcIn.slice(5, 0), cmdIn].swizzle(),
        ],
      ),
      If(
        lastBit,
        then: [
          rxActive < Const(0),
          rxCount < Const(0, width: 6),
          // Framing hygiene, apart from the idle gate. Frame bit 47 is the
          // end bit and a command sets it to 1. A frame that ends with a 0
          // is not a command, so the receiver drops it with no pulse.
          If(
            cmdIn,
            then: [
              validPulse < Const(1),
              // Both remainders hold still by now: rxCrc last moved on
              // frame bit 39 and rxCrcIn on frame bit 46. The verdict is
              // caught on the same edge that raises the pulse, so the two
              // agree.
              crcOk < rxCrc.eq(rxCrcIn),
            ],
          ),
        ],
      ),
      If(rxAbort, then: [rxActive < Const(0), rxCount < Const(0, width: 6)]),
      // Guard 1 again, and the last branch, so it beats every branch above
      // it. A frame that was already open when the card started to answer
      // is closed here. Without it the card shifts its own response into
      // rxShift and rxCrcIn and can raise cmd_valid on a frame that no
      // host sent. rxAbort cannot do this work, because it fires only at
      // rxCount 1 and a frame can be at any count when the answer starts.
      //
      // The pulse and the verdict go down here too. A frame that was open
      // at frame bit 47 when the answer started would otherwise reach the
      // end bit branch above and report a command out of the card's own
      // first response bit.
      If(
        txActive,
        then: [
          rxActive < Const(0),
          rxCount < Const(0, width: 6),
          validPulse < Const(0),
          crcOk < Const(0),
        ],
      ),
    ]);

    output('cmd_valid') <= validPulse;
    output('cmd_index') <= rxShift.slice(37, 32);
    output('cmd_arg') <= rxShift.slice(31, 0);
    output('cmd_crc_ok') <= crcOk;

    // Transmit constants. They belong to the transmit counter, which is
    // wider than the receive counter, because a response can be longer than
    // a command but a command is always 48 bits.
    final oneTx = Const(1, width: txCountWidth);
    final txZero = Const(0, width: txCountWidth);
    final txCrcStart = Const(sdCommandCrcBits, width: txCountWidth);
    final txShortEnd = Const(sdCommandBits - 1, width: txCountWidth);
    final txLongEnd = Const(sdResponseLongBits - 1, width: txCountWidth);
    final kindR1 = Const(sdRespKindR1, width: sdRespKindBits);
    final kindR2 = Const(sdRespKindR2, width: sdRespKindBits);
    final kindR3 = Const(sdRespKindR3, width: sdRespKindBits);

    // The kind that the frame in progress uses. txKind resets to
    // sdRespKindR1, and the transmitter reads these two only while it is
    // active, which is after resp_start loaded the kind.
    final txLong = txKind.eq(kindR2).named('tx_long');
    final txFixedCrc = txKind.eq(kindR3).named('tx_fixed_crc');

    // The index of the end bit, and the phase the transmitter is in.
    //
    // A short frame takes bits 0 to 39 from the shift register, bits 40 to
    // 46 from the CRC7 and puts a 1 in bit 47. A long frame takes all 136
    // bits from the shift register, because the register that the caller
    // gave holds its own CRC7 and its own end bit already.
    final txEndIndex = mux(txLong, txLongEnd, txShortEnd).named('tx_end');
    final txPayload = mux(
      txLong,
      Const(1),
      txCount.lt(txCrcStart),
    ).named('tx_payload_phase');
    final txCrcPhase = (~txPayload & txCount.lt(txEndIndex)).named(
      'tx_crc_phase',
    );

    // The CRC field of a short frame. An R3 has no CRC, so the field is
    // seven ones and a host must not check it.
    final txCrcBit = mux(txFixedCrc, Const(1), txCrc[6]).named('tx_crc_bit');

    // The bit on the wire now.
    final txBit = mux(
      txPayload,
      txShift[sdResponseLongBits - 1],
      mux(txCount.lt(txEndIndex), txCrcBit, Const(1)),
    ).named('tx_bit');

    // The CRC7 reads the bit that goes out, so it uses the same step as the
    // receiver. It runs through the payload phase and then shifts out. A
    // long frame never reads it.
    final txCrcNext = _crc7Step(
      txCrc,
      txShift[sdResponseLongBits - 1],
      'tx_crc_step',
    );
    final txShiftNext = [
      txShift.slice(sdResponseLongBits - 2, 0),
      Const(0),
    ].swizzle().named('tx_shift_next');
    final txCrcShift = [
      txCrc.slice(5, 0),
      Const(0),
    ].swizzle().named('tx_crc_shift');

    // The frame that resp_start loads.
    //
    // The link owns the start bit and the transmission bit, which are 0 in
    // every response. It owns the six ones of the reserved field of an R3
    // and of an R2 too. Only an R1 takes the index field from the caller.
    //
    // A short frame sits at the top of the register, so its bit 0 is the
    // bit that goes out first and the CRC7 reads the same bit.
    //
    // Only sdRespKindR2 takes the long shape and only sdRespKindR1 takes
    // the index from the caller, so the fourth value of resp_kind gives a
    // short frame with the reserved field and a computed CRC7.
    final respData = input('resp_data');
    final respKind = input('resp_kind');
    final txField = mux(
      respKind.eq(kindR1),
      respData.slice(
        sdCommandArgBits + sdCommandIndexBits - 1,
        sdCommandArgBits,
      ),
      Const(1, width: sdCommandIndexBits, fill: true),
    ).named('tx_field');
    final txHeader = [
      Const(0, width: sdResponseHeaderBits - sdCommandIndexBits),
      txField,
    ].swizzle().named('tx_header');
    final txLoadShort = [
      txHeader,
      respData.slice(sdCommandArgBits - 1, 0),
      Const(0, width: sdResponseLongBits - sdCommandCrcBits),
    ].swizzle().named('tx_load_short');
    final txLoadLong = [txHeader, respData].swizzle().named('tx_load_long');
    final txLoad = mux(
      respKind.eq(kindR2),
      txLoadLong,
      txLoadShort,
    ).named('tx_load');

    final txStart = (input('resp_start') & ~txActive).named('tx_start');

    Sequential(clk, reset: reset, [
      If(
        txStart,
        then: [
          txActive < Const(1),
          txCount < txZero,
          txKind < respKind,
          txShift < txLoad,
          txCrc < Const(0, width: 7),
        ],
      ),
      If(
        txActive,
        then: [
          txCount < txCount + oneTx,
          If(
            txPayload,
            then: [txShift < txShiftNext, txCrc < txCrcNext],
            orElse: [
              If(txCrcPhase, then: [txCrc < txCrcShift]),
            ],
          ),
          If(
            txCount.eq(txEndIndex),
            then: [txActive < Const(0), txCount < txZero],
          ),
        ],
      ),
    ]);

    // The bus rests high when the card does not drive it.
    output('cmd_out') <= mux(txActive, txBit, Const(1));
    output('cmd_oe') <= txActive;
    output('resp_busy') <= txActive;

    // CRC status token. The card answers a written block with a start bit,
    // three status bits and a stop bit, on DAT0. The codes are 010
    // accepted, 101 CRC error and 110 write error.
    //
    // The width of the counter comes from the constant, so a longer token
    // cannot truncate the goal and stop the counter from reaching it.
    // The phase of the data transmitter. It is declared here, above the
    // status token, because the two share DAT0 and each one has to see the
    // other. The transmit datapath itself is at the end of this
    // constructor.
    final dtPhase = Logic(name: 'dt_phase', width: sdDataTxPhaseBits);
    final dtIdlePhase = Const(sdDataTxPhaseIdle, width: sdDataTxPhaseBits);
    final dtActive = dtPhase.neq(dtIdlePhase).named('dt_active');

    final stCountWidth = sdStatusTokenBits.bitLength;
    final stActive = Logic(name: 'st_active');
    final stShift = Logic(name: 'st_shift', width: sdStatusTokenBits);
    final stCount = Logic(name: 'st_count', width: stCountWidth);
    final oneSt = Const(1, width: stCountWidth);
    final stLast = Const(sdStatusTokenBits - 1, width: stCountWidth);

    // A pulse starts the token only while the card is not already sending
    // one, so the two branches below are mutually exclusive. A block on
    // DAT0 also blocks the token, because the two share the line.
    final stStart = (input('dat_status_send') & ~stActive & ~dtActive).named(
      'st_start',
    );

    Sequential(clk, reset: reset, [
      If(
        stStart,
        then: [
          stActive < Const(1),
          stCount < Const(0, width: stCountWidth),
          // Start bit 0, the three status bits, then the stop bit 1.
          stShift < [Const(0), input('dat_status_code'), Const(1)].swizzle(),
        ],
      ),
      If(
        stActive,
        then: [
          // The line rests high, so the shift register fills with ones.
          stShift <
              [stShift.slice(sdStatusTokenBits - 2, 0), Const(1)].swizzle(),
          stCount < stCount + oneSt,
          If(
            stCount.eq(stLast),
            then: [
              stActive < Const(0),
              stCount < Const(0, width: stCountWidth),
            ],
          ),
        ],
      ),
    ]);

    // DAT0 carries the token, most significant bit of the shift register
    // first. The line itself is driven at the end of this constructor,
    // where the block transmitter has been built as well.
    final stBit = stShift[sdStatusTokenBits - 1].named('st_bit');

    // Data receive. The block is a start bit, sdBlockBytes bytes most
    // significant bit first, a 16-bit CRC and an end bit. Only DAT0 is used
    // at busWidth 1. A wide bus splits the payload across the lines and
    // gives each line its own shift register and its own CRC, so this
    // block is the one-line form of the same structure.
    final dat0 = input('dat_in')[0].named('dat0');

    // The widths come from the constants, so a larger block or a longer CRC
    // cannot truncate a goal and stop a counter from reaching it.
    final byteWidth = sdBlockBytes.bitLength;
    final crcCountWidth = sdDataCrcBits.bitLength;
    final oneBit3 = Const(1, width: 3);
    final oneByte = Const(1, width: byteWidth);
    final oneCrcCount = Const(1, width: crcCountWidth);

    // drActive is high from the start bit to the last CRC bit. drInCrc is
    // high while the CRC bits arrive. drBit is the bit index inside the
    // byte, drByte the byte index inside the block and drCrcCount the bit
    // index inside the CRC.
    final drActive = Logic(name: 'dr_active');
    final drInCrc = Logic(name: 'dr_in_crc');
    final drBit = Logic(name: 'dr_bit', width: 3);
    final drByte = Logic(name: 'dr_byte', width: byteWidth);
    final drCrcCount = Logic(name: 'dr_crc_count', width: crcCountWidth);
    final drShift = Logic(name: 'dr_shift', width: 8);
    final drCrc = Logic(name: 'dr_crc', width: 16);
    final drCrcIn = Logic(name: 'dr_crc_in', width: 16);
    final drBytePulse = Logic(name: 'dr_byte_pulse');
    final drEndPulse = Logic(name: 'dr_end_pulse');
    final drCrcOk = Logic(name: 'dr_crc_ok');
    final drIdle = Logic(name: 'dr_idle');

    // A block starts on a low bit while the receiver is idle, the card
    // personality expects a block, and the card does not drive DAT itself.
    //
    // Guard 1 is dat_rx_enable. The class doc gives the contract that the
    // personality must obey for it.
    //
    // Guard 2 is stActive and dtActive, which together are dat_oe. A
    // status token and a data block both start with a 0 bit. The parent
    // ties dat_out and dat_in together, so the card sees what it sends,
    // and with no guard the framer takes the card's own send as the start
    // of a block. This is the twin of the txActive guard on the command
    // path.
    //
    // Guard 3 is drIdle, which asks for DAT0 high for one clock while no
    // block is open and the card does not drive DAT. The end bit of a good
    // block gives that clock, so a block that ends well can be followed at
    // once by the next block. A block that ends with a 0 in place of its
    // end bit does not give that clock, so the framer cannot rearm on the
    // bad end bit and start a phantom block.
    final drStart =
        (input('dat_rx_enable') &
                drIdle &
                ~drActive &
                ~stActive &
                ~dtActive &
                ~input('dat_busy') &
                ~dat0)
            .named('dr_start');

    // The two phases of an open block. They cannot both be high.
    final drPayload = (drActive & ~drInCrc).named('dr_payload_phase');
    final drCrcPhase = (drActive & drInCrc).named('dr_crc_phase');

    final drShiftNext = [
      drShift.slice(6, 0),
      dat0,
    ].swizzle().named('dr_shift_next');
    final drCrcNext = _crc16Step(drCrc, dat0, 'dr_crc_step');
    final drCrcInNext = [
      drCrcIn.slice(14, 0),
      dat0,
    ].swizzle().named('dr_crc_in_next');

    final drLastBit = drBit.eq(Const(7, width: 3)).named('dr_last_bit');
    final drLastByte = drByte
        .eq(Const(sdBlockBytes - 1, width: byteWidth))
        .named('dr_last_byte');
    final drLastCrcBit = drCrcCount
        .eq(Const(sdDataCrcBits - 1, width: crcCountWidth))
        .named('dr_last_crc_bit');

    // drStart needs drActive low, so the start branch and the two phase
    // branches are mutually exclusive and can sit side by side. Inside a
    // branch the later assignment wins, which is what the last bit of a
    // byte and the last bit of the CRC need.
    Sequential(clk, reset: reset, [
      drBytePulse < Const(0),
      drEndPulse < Const(0),
      drCrcOk < Const(0),
      // The rearm gate. It reads the state of this clock and arms the
      // framer for the clock that follows. The reset value is 0, so the
      // framer leaves reset unarmed.
      drIdle < (dat0 & ~drActive & ~stActive & ~dtActive & ~input('dat_busy')),
      If(
        drStart,
        then: [
          // The start bit is not part of the CRC, so every counter and
          // both remainders start from zero here. This keeps the state of
          // the block before out of the new block.
          drActive < Const(1),
          drInCrc < Const(0),
          drBit < Const(0, width: 3),
          drByte < Const(0, width: byteWidth),
          drCrcCount < Const(0, width: crcCountWidth),
          drCrc < Const(0, width: 16),
          drCrcIn < Const(0, width: 16),
        ],
      ),
      If(
        drPayload,
        then: [
          // Shift the bit into the byte and run the CRC over it.
          drShift < drShiftNext,
          drCrc < drCrcNext,
          drBit < drBit + oneBit3,
          If(
            drLastBit,
            then: [
              // drShift holds the whole byte on this same edge, so the
              // byte on dat_byte and the pulse belong to each other.
              drBytePulse < Const(1),
              drBit < Const(0, width: 3),
              drByte < drByte + oneByte,
              If(
                drLastByte,
                then: [
                  // The CRC follows the last byte of the payload.
                  drInCrc < Const(1),
                  drByte < Const(0, width: byteWidth),
                ],
              ),
            ],
          ),
        ],
      ),
      If(
        drCrcPhase,
        then: [
          // The CRC bits the host sent go into a compare register.
          drCrcIn < drCrcInNext,
          drCrcCount < drCrcCount + oneCrcCount,
          If(
            drLastCrcBit,
            then: [
              drActive < Const(0),
              drInCrc < Const(0),
              drCrcCount < Const(0, width: crcCountWidth),
              drEndPulse < Const(1),
              // drCrc stopped on the last bit of the payload. The last CRC
              // bit is on the line now, so the verdict reads drCrcInNext
              // and not the register, and is caught on the same edge that
              // raises the pulse. The two therefore agree.
              drCrcOk < drCrc.eq(drCrcInNext),
            ],
          ),
        ],
      ),
    ]);

    output('dat_byte') <= drShift;
    output('dat_byte_valid') <= drBytePulse;
    output('dat_block_end') <= drEndPulse;
    output('dat_crc_ok') <= drCrcOk;

    // Data transmit. The frame has the same shape the receive path frames:
    // a start bit, the payload bytes most significant bit first, the CRC16
    // and an end bit. The transmitter computes the CRC16 over the bits it
    // puts on the line, with the same step the receiver uses, so the two
    // cannot disagree about the polynomial.
    //
    // The PAYLOAD LENGTH is not a constant here. The caller gives it with
    // the start pulse on `dat_tx_len` and the link latches it, because a
    // card sends a whole block for CMD17 and CMD18, 8 bytes for the SCR of
    // ACMD51 and 64 bytes for the switch status of CMD6. The receive path
    // still reads one whole block, because a host writes blocks alone.
    //
    // The counter widths come from the same constants the receive path
    // uses, so a block length that changes moves both paths together.
    final dtStartPhase = Const(sdDataTxPhaseStart, width: sdDataTxPhaseBits);
    final dtPayloadPhase = Const(
      sdDataTxPhasePayload,
      width: sdDataTxPhaseBits,
    );
    final dtCrcPhaseVal = Const(sdDataTxPhaseCrc, width: sdDataTxPhaseBits);
    final dtEndPhase = Const(sdDataTxPhaseEnd, width: sdDataTxPhaseBits);

    final dtBit = Logic(name: 'dt_bit', width: 3);
    final dtByte = Logic(name: 'dt_byte', width: byteWidth);
    final dtCrcCount = Logic(name: 'dt_crc_count', width: crcCountWidth);
    final dtShift = Logic(name: 'dt_shift', width: 8);
    final dtCrc = Logic(name: 'dt_crc', width: sdDataCrcBits);
    final dtDonePulse = Logic(name: 'dt_done_pulse');

    final dtInStart = dtPhase.eq(dtStartPhase).named('dt_in_start');
    final dtInPayload = dtPhase.eq(dtPayloadPhase).named('dt_in_payload');
    final dtInCrc = dtPhase.eq(dtCrcPhaseVal).named('dt_in_crc');

    // The length of the frame that is going out now, less one, so the
    // compare below is one equality and not a subtraction on every clock.
    //
    // The length is LATCHED, and that is the point. The caller gives it
    // with the start pulse and the link holds it for the whole frame, so a
    // caller that moves on to another length in the middle of a frame
    // cannot cut the frame short. The register resets to a whole block,
    // which is the frame a card sends most.
    final dtLenLast = Logic(name: 'dt_len_last', width: byteWidth);

    final dtLastBit = dtBit.eq(Const(7, width: 3)).named('dt_last_bit');
    final dtLastByte = dtByte.eq(dtLenLast).named('dt_last_byte');
    final dtLastCrcBit = dtCrcCount
        .eq(Const(sdDataCrcBits - 1, width: crcCountWidth))
        .named('dt_last_crc_bit');

    // The clock in which the link TAKES a byte off dat_tx_byte. It is the
    // start bit clock for byte 0, and the last bit clock of every byte but
    // the last one for the bytes after it. The count is therefore exactly
    // sdBlockBytes pulses and the last one takes the last byte.
    //
    // The pulse is combinational and not a register, because the link
    // samples dat_tx_byte on the same clock edge that the caller uses to
    // move to the next byte. A registered pulse would arrive one clock
    // after the load and the caller would be one byte behind.
    final dtLoad = (dtInStart | (dtInPayload & dtLastBit & ~dtLastByte)).named(
      'dt_load',
    );

    // A block starts only while DAT0 is free. The status token holds the
    // same rule from its side, so the two can never drive together.
    final dtGo = (input('dat_tx_start') & ~dtActive & ~stActive & ~drActive)
        .named('dt_go');

    // The bit on the line now. The end phase drives the end bit 1, which
    // is also what a released line reads.
    final dtBitOut = mux(
      dtInStart,
      Const(0),
      mux(
        dtInPayload,
        dtShift[7],
        mux(dtInCrc, dtCrc[sdDataCrcBits - 1], Const(1)),
      ),
    ).named('dt_bit_out');

    final dtCrcNext = _crc16Step(dtCrc, dtShift[7], 'dt_crc_step');
    final dtShiftNext = [
      dtShift.slice(6, 0),
      Const(0),
    ].swizzle().named('dt_shift_next');
    final dtCrcShift = [
      dtCrc.slice(sdDataCrcBits - 2, 0),
      Const(0),
    ].swizzle().named('dt_crc_shift');

    Sequential(
      clk,
      reset: reset,
      resetValues: {
        dtPhase: dtIdlePhase,
        dtBit: Const(0, width: 3),
        dtByte: Const(0, width: byteWidth),
        dtCrcCount: Const(0, width: crcCountWidth),
        dtShift: Const(0, width: 8),
        dtCrc: Const(0, width: sdDataCrcBits),
        dtDonePulse: Const(0),
        // A whole block, so a start pulse that arrives before any length
        // was given sends the frame a card sends most and never a frame of
        // one byte.
        dtLenLast: Const(sdBlockBytes - 1, width: byteWidth),
      },
      [
        dtDonePulse < Const(0),
        Case(dtPhase, [
          CaseItem(dtIdlePhase, [
            If(
              dtGo,
              then: [
                // Every counter and the CRC start from zero here, so the
                // state of the frame before cannot enter the new frame.
                dtPhase < dtStartPhase,
                dtBit < Const(0, width: 3),
                dtByte < Const(0, width: byteWidth),
                dtCrcCount < Const(0, width: crcCountWidth),
                dtCrc < Const(0, width: sdDataCrcBits),
                // The length of THIS frame, taken in the same clock the link
                // takes the start pulse. The payload phase reads the
                // register alone, so the port is free after this clock.
                dtLenLast < input('dat_tx_len') - oneByte,
              ],
            ),
          ]),
          CaseItem(dtStartPhase, [
            // The start bit is on the line this clock. It is not part of the
            // CRC, so only the first byte is loaded here.
            dtShift < input('dat_tx_byte'),
            dtPhase < dtPayloadPhase,
            dtBit < Const(0, width: 3),
          ]),
          CaseItem(dtPayloadPhase, [
            // The bit on the line joins the CRC and the byte shifts on.
            dtShift < dtShiftNext,
            dtCrc < dtCrcNext,
            dtBit < dtBit + oneBit3,
            If(
              dtLastBit,
              then: [
                dtBit < Const(0, width: 3),
                If(
                  dtLastByte,
                  then: [
                    dtPhase < dtCrcPhaseVal,
                    dtCrcCount < Const(0, width: crcCountWidth),
                  ],
                  orElse: [
                    dtByte < dtByte + oneByte,
                    // The load wins over the shift above it, which is what
                    // the first bit of the next byte needs.
                    dtShift < input('dat_tx_byte'),
                  ],
                ),
              ],
            ),
          ]),
          CaseItem(dtCrcPhaseVal, [
            dtCrc < dtCrcShift,
            dtCrcCount < dtCrcCount + oneCrcCount,
            If(dtLastCrcBit, then: [dtPhase < dtEndPhase]),
          ]),
          CaseItem(dtEndPhase, [dtPhase < dtIdlePhase, dtDonePulse < Const(1)]),
        ]),
      ],
    );

    output('dat_tx_next') <= dtLoad;
    output('dat_tx_busy') <= dtActive;
    output('dat_tx_done') <= dtDonePulse;

    // DAT0 carries the block, then the token, and rests high when the card
    // drives neither. The other data lines stay released, because the
    // receive and the transmit datapaths are both one line wide.
    // DAT0 rests high, the busy level pulls it low, and either sender
    // beats the busy level: a frame or a token that is already going out
    // cannot be cut in half by a level that a card personality holds.
    final datBit = mux(
      dtActive,
      dtBitOut,
      mux(stActive, stBit, ~input('dat_busy')),
    ).named('dat_bit');
    output('dat_out') <=
        (busWidth == 1
            ? datBit
            : [Const(1, width: busWidth - 1, fill: true), datBit].swizzle());
    output('dat_oe') <= stActive | dtActive | input('dat_busy');
  }
}
