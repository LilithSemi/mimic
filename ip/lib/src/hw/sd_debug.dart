// Bring-up counters for the SD clock domain, and the crossing that carries
// them into the SoC clock domain.
//
// The card has one observation register today, CARD_STATE, and it reads
// `idle` for three faults that need three different repairs:
//   1. No SD clock reaches the FPGA at all.
//   2. The clock arrives, and no command is ever framed.
//   3. Commands are framed, and they fail CRC7.
// Four free-running counters separate them. DBG_SD_CLK counts SD clock
// edges and nothing else, so it moves even when the card is deaf: a
// DBG_SD_CLK that stays at 0 says the pad or the clock buffer is dead, and
// no other counter can say that.
//
// The crossing
// A counter of this kind lives in the SD clock domain, which is
// asynchronous to the SoC domain and STOPS when the host stops clocking.
// Neither house pattern of the SoC fits it. A synchroniser per bit tears,
// because the SoC clock can sample a multi-bit counter while several bits
// change and read a number the counter never held. A handshake never
// retires, because the value changes on every SD clock and the source
// would start a new transfer before the last one ends.
//
// GRAY CODE is the answer for a free-running counter. Two numbers one
// apart differ in exactly ONE bit of their gray code, so at every instant
// at most one bit of the gray word is moving. A destination flop that
// samples the word therefore reads the old count or the new count, and
// the bit that was moving settles to one of the two through the two-flop
// synchroniser. Both readings are counts the counter really held. The
// value can be stale, and it cannot be torn.
//
// The gray code is converted back to binary in the DESTINATION domain,
// where the word is already stable.

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Number of bits in the SD clock tick counter.
///
/// The counter wraps, the same way `DBG_CMD_COUNT` does. What it has to
/// answer is "does the clock arrive", and two reads that differ answer it
/// whatever the wrap. The width buys the second question, which is "at
/// what rate": 24 bits wrap after 16777216 clocks, which is 42 s at the
/// 400 kHz identification rate and 0.67 s at 25 MHz, so a reader can time
/// two polls and get the rate as well.
const int sdDbgClkBits = 24;

/// Number of bits in each SD event counter.
///
/// The commands, the CRC7 failures and the responses of a bring-up are
/// counted in tens, not in millions. 16 bits hold 65535 of them, which no
/// hand-driven bring-up reaches, and each bit costs four flip-flops: one
/// in the counter, one in the gray register and two in the synchroniser.
const int sdDbgEventBits = 16;

/// The gray code of [value], as combinational logic.
///
/// Gray code of a binary number is the number exclusive OR'd with itself
/// shifted right by one, so the top bit passes through and every bit below
/// it is the exclusive OR of that bit and the bit above it. Two numbers
/// one apart differ in exactly one bit of the result.
///
/// The bits are built one at a time on purpose. The ROHD `>>` operator is
/// an ARITHMETIC shift, which copies the top bit down instead of shifting
/// a 0 in, and the gray code that comes out of it is wrong in the top bit.
Logic sdBinaryToGray(Logic value) {
  final bits = <Logic>[
    // Most significant bit first, because swizzle puts the FIRST element
    // in the most significant place.
    value[value.width - 1],
    for (var i = value.width - 2; i >= 0; i--) value[i] ^ value[i + 1],
  ];
  return bits.swizzle();
}

/// The binary number whose gray code is [gray], as combinational logic.
///
/// Bit `i` of the binary value is the exclusive OR of every gray bit from
/// `i` up to the top, so the top bit passes through and each bit below it
/// takes the bit above it. This is the exact inverse of [sdBinaryToGray].
Logic sdGrayToBinary(Logic gray) {
  final bits = <Logic>[];
  // Walk down from the most significant bit. Each step folds in one more
  // gray bit, so `running` holds bit i of the binary value.
  Logic? running;
  for (var i = gray.width - 1; i >= 0; i--) {
    running = running == null ? gray[i] : running ^ gray[i];
    bits.add(running);
  }
  // `bits` runs from the most significant bit down, and swizzle puts the
  // FIRST element in the most significant place, so it needs no reverse.
  return bits.swizzle();
}

/// A free-running counter in one clock domain, published as a gray code.
///
/// The counter adds 1 on every clock while `inc` is high. `gray` is a
/// REGISTER that holds the gray code of the count, so it changes by
/// exactly one bit per clock and another domain can sample it safely. See
/// the file comment for why gray code and not a handshake.
///
/// The counter wraps at [width] bits. A wrap is one more increment, so the
/// gray code still changes by one bit and the crossing stays safe.
///
/// [reset] must be the reset of the domain that [clk] belongs to. In this
/// design that is the output of `MimicResetSync`, which asserts with no
/// clock at all and releases in step with the SD clock.
///
/// Both registers take that reset ASYNCHRONOUSLY. This is the one place
/// where the card and the counters differ, and the difference is the whole
/// point of the counters. A synchronous reset needs a clock edge while the
/// reset is high, so a board whose SD clock never ticks would leave both
/// registers with no value at all and the CSR would read X. X is the worst
/// possible answer here: the register that has to say "no clock arrives"
/// would say nothing that a runtime can read. With the asynchronous
/// assert, a counter whose clock never runs holds exactly 0 and the
/// crossing carries that 0 to the CSR.
class MimicSdGrayCounter extends BridgeModule {
  /// Number of bits in the counter and in the gray code.
  final int width;

  /// The width goes in the DEFINITION name, not only in the instance name.
  ///
  /// Two instances of one module class with different constructor
  /// parameters are two different module definitions. ROHD would give the
  /// second one a name of its own, and the file it emits per module can
  /// then disagree with the name the netlist instantiates. A definition
  /// name that carries the width keeps the two in step and reads clearly
  /// in a netlist.
  MimicSdGrayCounter({required this.width, String? name})
    : super('MimicSdGrayCounter_$width', name: name ?? 'sd_gray_counter') {
    if (width < 2) {
      // One bit is its own gray code and counts nothing useful. Refuse it
      // here rather than emit a counter that cannot be read.
      throw ArgumentError.value(
        width,
        'width',
        'must be at least 2. A counter of one bit carries no count.',
      );
    }
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('inc', PortDirection.input);
    addOutput('gray', width: width);

    final clk = input('clk');
    final reset = input('reset');

    final count = Logic(name: 'count', width: width);
    final gray = Logic(name: 'gray_reg', width: width);

    // The value the counter takes on this clock. The gray register takes
    // the gray code of that SAME value, so the two never disagree by a
    // clock: a reader of `gray` reads the code of the count the counter
    // holds now.
    final next = mux(input('inc'), count + Const(1, width: width), count);

    // Both registers reset to 0, and the assert needs NO clock edge. See
    // the class doc: a synchronous reset would leave a counter whose clock
    // never ticked holding X, and X is exactly the answer this register
    // must never give. `asyncReset` emits
    // `always_ff @(posedge clk, posedge reset)`.
    //
    // Every register here has a reset value. An unreset ROHD register
    // holds X and carries it on with no message.
    Sequential(
      clk,
      reset: reset,
      asyncReset: true,
      resetValues: {
        count: Const(0, width: width),
        gray: Const(0, width: width),
      },
      [count < next, gray < sdBinaryToGray(next)],
    );

    // The published word is held at 0 while the domain is in reset, and it
    // is the REGISTER that drives it at every other time.
    //
    // The gate is not a repeat of the asynchronous reset above. It makes
    // the word that leaves this clock domain 0 whatever the registers hold,
    // so a domain that never gets one clock edge publishes a count of 0 and
    // not the value its flops powered up with. That case is the whole
    // reason the counters exist: a board where no SD clock arrives must
    // read DBG_SD_CLK as 0.
    //
    // The gate adds no transition of its own. The registers already hold 0
    // when the reset releases, so the word does not move at the release.
    output('gray') <= mux(reset, Const(0, width: width), gray);
  }
}

/// The destination side of a gray counter crossing.
///
/// It puts one [HarborCdcSync] on each bit of the gray word and converts
/// the settled word back to binary. The two-flop synchroniser is what
/// makes a bit that was moving when the destination sampled it settle to a
/// 0 or a 1 before any logic reads it. Only one bit of a gray word moves
/// at a time, so whichever way it settles the word is a count the source
/// really held.
///
/// [clk] and [reset] are the DESTINATION domain. The source domain drives
/// `gray_in` and needs no port here: a gray crossing carries no
/// acknowledge, which is why it still works while the source clock is
/// stopped.
///
/// `count` is combinational from the last synchroniser flop, so a reader
/// in the destination domain reads it like any other synchronised value.
class MimicSdGraySync extends BridgeModule {
  /// Number of bits in the gray word and in the count.
  final int width;

  /// Number of synchroniser stages on each bit. Minimum 2.
  final int stages;

  /// The width and the stage count both go in the DEFINITION name. See
  /// [MimicSdGrayCounter] for why.
  MimicSdGraySync({required this.width, this.stages = 2, String? name})
    : super('MimicSdGraySync_${width}_$stages', name: name ?? 'sd_gray_sync') {
    if (width < 2) {
      throw ArgumentError.value(
        width,
        'width',
        'must be at least 2, to match MimicSdGrayCounter.',
      );
    }
    if (stages < 2) {
      throw ArgumentError.value(
        stages,
        'stages',
        'must be at least 2. One flop gives a moving bit no time to settle.',
      );
    }
    createPort('gray_in', PortDirection.input, width: width);
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    addOutput('count', width: width);

    final synced = <Logic>[];
    for (var i = 0; i < width; i++) {
      final sync = HarborCdcSync(stages: stages, name: 'gray_sync_$i');
      addSubModule(sync);
      sync.input('async_in').srcConnection! <= input('gray_in')[i];
      sync.input('dst_clk').srcConnection! <= input('clk');
      sync.input('dst_reset').srcConnection! <= input('reset');
      synced.add(sync.output('sync_out'));
    }

    // rswizzle puts element 0 in the least significant bit, which is the
    // bit it came from.
    output('count') <= sdGrayToBinary(synced.rswizzle());
  }
}
