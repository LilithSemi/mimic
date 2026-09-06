// MimicSdBlockCache: the block store that removes the USB round trip.
//
// A read that the card cannot answer costs one request record, one USB
// round trip and one block push, which is about a millisecond at full
// speed. A read the host has seen before does not have to cost that. This
// module holds the blocks the runtime chose to leave on the card, and a
// CMD17 that names one of them is answered from here with NO record at all.
//
// The card does LOOKUP. The card does NO POLICY.
//   CMD17 has to decide hit or miss in a few SD clocks, so the tag compare
//   cannot live anywhere but in the gateware. Everything else can, and does
//   not live here: there is no replacement algorithm, no prefetch guess and
//   no eviction of the card's own. The HOST chooses what occupies every
//   line, because the host has orders of magnitude more compute for the
//   prediction and because a policy in software costs no bitstream when it
//   changes. The card stores by LBA and reports a miss through the request
//   channel it already has.
//
//   The host therefore owns the model of what the card holds, and it can,
//   because it decided every fill. The one place the card drops a line by
//   itself is a WRITE to a line it holds, and the runtime sees that write
//   as a record on the same channel, so its model follows with no
//   synchronisation of any kind. See `inval`.
//
// One 512-byte block per line, tagged by LBA.
//   A larger line suits the sequential reads of boot and hurts everywhere
//   else: normal work after boot is random, and a large line then reads
//   more than the host asked for and cuts the effective capacity by the
//   line multiple. Read ahead needs no large line, because the host owns
//   the policy and simply fills more lines.
//
// Direct mapped, with a POWER OF TWO line count.
//   The index is then the low bits of the LBA and costs nothing. A line
//   count that is not a power of two needs a modulo, which is a divider in
//   the lookup path, and the lookup path is the SD clock domain.
//
// The tags live in BLOCK RAM and the VALID BITS live in flops.
//   [lines] tags of [tagBits] bits is thousands of bits, which is nothing
//   as a block RAM and thousands of flip-flops in fabric. The valid bits
//   are one bit per line and they stay in fabric on purpose: a reset and a
//   CMD0 must invalidate EVERY line at once, and a flop array does that in
//   one clock while a block RAM would need a clear loop of [lines] clocks
//   on a clock the host can stop.
//
// The timing of a lookup
//   A lookup takes TWO clocks and `hit_valid` says which. `lookup` presents
//   the index, the tag comes out of the block RAM on the next clock, and
//   the compare is REGISTERED, so `hit` and `hit_valid` are both correct
//   from the clock after that until the next lookup.
//
//   The compare is registered because of the SD clock domain. A DP16KD
//   output is 5.8 ns after its clock edge on this part, and the first
//   build that fed that output straight through the compare, the read
//   decision, the word pointer and back into the address of the data store
//   made a path of 20 ns: the SD domain fell from 74 MHz to 44.7 MHz and
//   FAILED the 48 MHz constraint. One flop cuts the path in half and costs
//   one SD clock per BLOCK, which is one clock in 4114.

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'sd_block_ram.dart';
import 'sd_link.dart' show sdCommandArgBits;
import 'sd_read_path.dart' show sdBlockWords;

/// Number of cache lines a build takes when it names none.
///
/// 128 lines of 512 bytes is 64 KiB, which is 32 DP16KD of the 56 the
/// ECP5-25F has, plus one for the tags. The two block FIFOs take one each,
/// so the part still has room.
///
/// It is a PARAMETER and not a fixed number, because the V1 board and the
/// V2 ASIC have different budgets. See [MimicSdBlockCache].
const int sdCacheDefaultLines = 128;

/// The number of index bits for [lines] cache lines.
int sdCacheIndexBits(int lines) => (lines - 1).bitLength;

/// The number of tag bits for [lines] cache lines.
///
/// A line is named by a whole block address, so the tag is the part of the
/// address that the index does not carry.
int sdCacheTagBits(int lines) => sdCommandArgBits - sdCacheIndexBits(lines);

/// Number of address bits inside one cache line.
///
/// One line holds one block, which is [sdBlockWords] words.
final int sdCacheWordBits = (sdBlockWords - 1).bitLength;

/// True while [lines] is a legal line count.
///
/// It must be a power of two, so that the index is the low bits of the
/// block address and needs no divider, and it must be 2 or more, because a
/// cache of one line has no index at all.
bool sdCacheLinesValid(int lines) =>
    lines >= 2 && (lines & (lines - 1)) == 0 && lines <= (1 << 24);

/// A direct mapped store of whole 512-byte blocks, tagged by LBA.
///
/// A LOOKUP starts with one clock of `lookup` and the block address on
/// `lookup_lba`. TWO clocks later `hit_valid` rises and `hit` says whether
/// the store holds that block, and both hold until the next lookup.
/// `rd_word` holds word 0 of the line from the first of those two clocks.
/// Each pulse on `rd_next` moves to the word after it, and the word is on
/// `rd_word` one clock later, which is far sooner than the link asks for
/// it: the link takes 32 SD clocks to send one word.
///
/// A reader must wait for `hit_valid`. `hit` alone answers the lookup
/// BEFORE that, which is the verdict of the lookup before this one.
///
/// A FILL starts with one clock of `fill_start` and the block address on
/// `fill_lba`. The line that address maps to becomes INVALID at once, so
/// nothing can read a line that is half written, and each pulse on
/// `fill_push` writes one word of `fill_word` into it. The push that
/// carries the last word of the block writes the tag and makes the line
/// valid, and it pulses `fill_event`. A fill that stops early therefore
/// leaves an invalid line and never a wrong one.
///
/// An INVALIDATE is one clock of `inval` with the block address on
/// `inval_lba`. The line that address maps to loses its valid bit ONLY if
/// its tag names that same address, so a write to a block the store does
/// not hold costs nothing. It takes two clocks, because the tag comes out
/// of a block RAM.
///
/// `inval_all` clears every line in one clock. Reset does the same.
///
/// The three counters are one-clock pulses. `hit_event` and `miss_event`
/// answer every lookup, exactly one of the two per lookup, and
/// `fill_event` answers every line that a fill completed.
class MimicSdBlockCache extends BridgeModule {
  /// Number of cache lines. A power of two.
  final int lines;

  /// Number of index bits, which is the low part of the block address.
  final int indexBits;

  /// Number of tag bits, which is the rest of the block address.
  final int tagBits;

  /// Number of bytes the store holds.
  int get bytes => lines * sdBlockWords * 4;

  /// Makes the store.
  ///
  /// [lines] defaults to [sdCacheDefaultLines] and must be a power of two.
  MimicSdBlockCache({int? lines, String? name})
    : lines = lines ?? sdCacheDefaultLines,
      indexBits = sdCacheIndexBits(lines ?? sdCacheDefaultLines),
      tagBits = sdCacheTagBits(lines ?? sdCacheDefaultLines),
      super(
        // The shape decides the module, so two caches of different sizes
        // are two definitions and ROHD emits both.
        'MimicSdBlockCache_${lines ?? sdCacheDefaultLines}',
        name: name ?? 'sd_block_cache',
        reserveDefinitionName: true,
      ) {
    if (!sdCacheLinesValid(this.lines)) {
      throw ArgumentError.value(
        this.lines,
        'lines',
        'must be a power of two, 2 or more. The index is the low bits of '
            'the block address, and any other count needs a divider in the '
            'lookup path.',
      );
    }
    if (indexBits >= sdCommandArgBits) {
      throw ArgumentError.value(
        this.lines,
        'lines',
        'needs $indexBits index bits and a block address is only '
            '$sdCommandArgBits bits, so no bit is left for a tag.',
      );
    }
    if (indexBits + tagBits != sdCommandArgBits) {
      throw StateError(
        'The index is $indexBits bits and the tag is $tagBits bits, which '
        'is not the $sdCommandArgBits bits of a block address. A line would '
        'then answer for more than one block.',
      );
    }
    if (sdBlockWords != (1 << sdCacheWordBits)) {
      throw StateError(
        'A block is $sdBlockWords words, which is not a power of two. The '
        'address inside a line is the low bits of the word number.',
      );
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    createPort('inval_all', PortDirection.input);
    createPort('inval', PortDirection.input);
    createPort('inval_lba', PortDirection.input, width: sdCommandArgBits);

    createPort('lookup', PortDirection.input);
    createPort('lookup_lba', PortDirection.input, width: sdCommandArgBits);
    createPort('rd_next', PortDirection.input);

    createPort('fill_start', PortDirection.input);
    createPort('fill_lba', PortDirection.input, width: sdCommandArgBits);
    createPort('fill_word', PortDirection.input, width: 32);
    createPort('fill_push', PortDirection.input);

    addOutput('hit');
    addOutput('hit_valid');
    addOutput('rd_word', width: 32);
    addOutput('hit_event');
    addOutput('miss_event');
    addOutput('fill_event');

    final clk = input('clk');
    final reset = input('reset');

    final zeroIndex = Const(0, width: indexBits);
    final zeroWord = Const(0, width: sdCacheWordBits);
    final oneWord = Const(1, width: sdCacheWordBits);
    final lastWord = Const(sdBlockWords - 1, width: sdCacheWordBits);

    // The two halves of an address. The index is the LOW bits, which is
    // what makes a direct mapped store free of any divider.
    Logic indexOf(Logic lba, String name) =>
        lba.getRange(0, indexBits).named(name);
    Logic tagOf(Logic lba, String name) =>
        lba.getRange(indexBits, sdCommandArgBits).named(name);

    // The lookup context. It holds the index and the tag of the address
    // that the last `lookup` or `inval` named, so `hit` stays correct
    // while the read path waits for the link to finish the response.
    //
    // A lookup and an invalidate share it, because the card is in ONE
    // state at a time: a read runs from the data state and a write from
    // the rcv state, and the state machine takes neither command out of
    // tran while the other runs.
    final lookIndex = Logic(name: 'cache_look_index', width: indexBits);
    final lookTag = Logic(name: 'cache_look_tag', width: tagBits);
    final lookPending = Logic(name: 'cache_look_pending');
    final invalPending = Logic(name: 'cache_inval_pending');

    // The verdict of the last lookup, and whether it is ready.
    //
    // The compare is registered HERE and not read through combinationally.
    // See the file header: the output of a block RAM is slow, and a
    // lookup that fed it straight into the read decision and back into
    // the address of the data store cost the SD clock domain 30 MHz.
    final hitReg = Logic(name: 'cache_hit_reg');
    final hitValid = Logic(name: 'cache_hit_valid');
    final verdictPulse = Logic(name: 'cache_verdict_pulse');

    // The verdict of the last invalidate, and whether it is ready. It is
    // registered for the reason the lookup verdict is: the compare that
    // reads the tag store cannot also reach the valid bits in one clock
    // of the SD domain. An invalidate has thousands of clocks to spare,
    // because the 512 bytes of the write it belongs to are still arriving
    // on DAT.
    final invalHit = Logic(name: 'cache_inval_hit');
    final invalGo = Logic(name: 'cache_inval_go');

    // The fill context. It is separate from the lookup context on purpose:
    // a fill runs for a whole block, and on a multiple block read the
    // lookup of the next block follows the last word of this one closely.
    final fillIndex = Logic(name: 'cache_fill_index', width: indexBits);
    final fillTag = Logic(name: 'cache_fill_tag', width: tagBits);
    final fillWord = Logic(name: 'cache_fill_word', width: sdCacheWordBits);
    final fillActive = Logic(name: 'cache_fill_active');

    // The valid bits, one per line, in FLOPS. See the file header for why
    // they are not in the block RAM with the tags.
    final valid = Logic(name: 'cache_valid', width: this.lines);

    // The word pointer of a hit read.
    final rdAddr = Logic(
      name: 'cache_rd_addr',
      width: indexBits + sdCacheWordBits,
    );

    final lookup = input('lookup');
    final inval = input('inval');
    final invalAll = input('inval_all');
    final fillStart = input('fill_start');
    final fillPush = input('fill_push');
    final rdNext = input('rd_next');

    final lookupIndex = indexOf(input('lookup_lba'), 'cache_lookup_index');
    final lookupTag = tagOf(input('lookup_lba'), 'cache_lookup_tag');
    final invalIndex = indexOf(input('inval_lba'), 'cache_inval_index');
    final invalTag = tagOf(input('inval_lba'), 'cache_inval_tag');
    final fillStartIndex = indexOf(input('fill_lba'), 'cache_fill_start_index');
    final fillStartTag = tagOf(input('fill_lba'), 'cache_fill_start_tag');

    // The push that carries the LAST word of a block. It is what makes the
    // line valid, so a fill that stops early leaves the line invalid and
    // never leaves a line that holds part of one block and part of
    // another.
    final fillTake = (fillPush & fillActive).named('cache_fill_take');
    final fillDone = (fillTake & fillWord.eq(lastWord)).named(
      'cache_fill_done',
    );

    // The tag store. One read port for the lookup and the invalidate, one
    // write port for the end of a fill.
    //
    // A plain ROHD [Module] takes its parent from the signals it reads, so
    // it is NOT registered with `addSubModule`, which takes a
    // [BridgeModule] alone.
    final tagRam = MimicBlockRam(
      clk,
      reset: reset,
      width: tagBits,
      depth: this.lines,
      wrEn: fillDone,
      wrAddr: fillIndex,
      wrData: fillTag,
      rdEn: (lookup | inval).named('cache_tag_rd_en'),
      rdAddr: mux(inval, invalIndex, lookupIndex).named('cache_tag_rd_addr'),
      name: 'cache_tag_ram',
    );

    // The data store. The address inside it is the line index above the
    // word number, so one line is a contiguous block of the memory.
    //
    // The read address is COMBINATIONAL, because a block RAM registers the
    // address it is given: a register in front of it would add a second
    // clock to every word.
    final rdAddrNext = mux(
      lookup,
      [lookupIndex, zeroWord].swizzle(),
      mux(rdNext, rdAddr + Const(1, width: rdAddr.width), rdAddr),
    ).named('cache_rd_addr_next');
    final dataRam = MimicBlockRam(
      clk,
      reset: reset,
      width: 32,
      depth: this.lines * sdBlockWords,
      wrEn: fillTake,
      wrAddr: [fillIndex, fillWord].swizzle().named('cache_wr_addr'),
      wrData: input('fill_word'),
      rdEn: (lookup | rdNext).named('cache_data_rd_en'),
      rdAddr: rdAddrNext,
      name: 'cache_data_ram',
    );

    // The one-hot decoders that pick a valid bit. They are built from a
    // comparison per line and not from a shift of one, because a variable
    // shift of a word this wide is a barrel shifter and a decoder is not.
    Logic oneHot(Logic index, String name) => [
      for (var line = this.lines - 1; line >= 0; line--)
        index.eq(Const(line, width: indexBits)),
    ].swizzle().named(name);

    final fillHot = oneHot(fillIndex, 'cache_fill_hot');
    final fillStartHot = oneHot(fillStartIndex, 'cache_fill_start_hot');
    final lookHot = oneHot(lookIndex, 'cache_look_hot');

    // The compare. It is correct in the clock after `lookup`, which is the
    // clock the tag read port holds the tag of the line.
    final validSel = valid[lookIndex].named('cache_valid_sel');
    final tagMatch = tagRam.rdData.eq(lookTag).named('cache_tag_match');
    final verdict = (validSel & tagMatch).named('cache_verdict');

    // The published verdict, which is the REGISTER and not the compare.
    output('hit') <= hitReg;
    output('hit_valid') <= hitValid;
    output('rd_word') <= dataRam.rdData;

    // One lookup gives exactly one of the two. The pulse comes with the
    // verdict, two clocks after the lookup.
    output('hit_event') <= verdictPulse & hitReg;
    output('miss_event') <= verdictPulse & ~hitReg;
    output('fill_event') <= fillDone;

    // A write to a line the store holds. The tag is compared, so a write
    // to a block that maps to a line holding ANOTHER block leaves that
    // line alone and the host model of what the card holds stays right.
    //
    // It reads the REGISTER and not the compare, so nothing walks from the
    // tag store to the valid bits in one clock.
    final invalMatch = (invalGo & invalHit).named('cache_inval_match');

    // The valid bits, in ONE expression. A clear and a set can land on the
    // same clock, and the CLEAR wins: a line that a write invalidates must
    // not come back valid, and a miss costs a round trip while stale data
    // costs correctness.
    final setMask = mux(
      fillDone,
      fillHot,
      Const(0, width: this.lines),
    ).named('cache_valid_set');
    final clearMask = mux(
      invalAll,
      // Every bit set. `fill` repeats the VALUE across the width, so the
      // value has to be 1: `Const(0, fill: true)` is a word of zeros and
      // would clear nothing at all.
      Const(1, width: this.lines, fill: true),
      mux(
        fillStart,
        fillStartHot,
        mux(invalMatch, lookHot, Const(0, width: this.lines)),
      ),
    ).named('cache_valid_clear');

    Sequential(
      clk,
      reset: reset,
      resetValues: {
        valid: Const(0, width: this.lines),
        lookIndex: zeroIndex,
        lookTag: Const(0, width: tagBits),
        lookPending: Const(0),
        invalPending: Const(0),
        hitReg: Const(0),
        hitValid: Const(0),
        verdictPulse: Const(0),
        invalHit: Const(0),
        invalGo: Const(0),
        fillIndex: zeroIndex,
        fillTag: Const(0, width: tagBits),
        fillWord: zeroWord,
        fillActive: Const(0),
        rdAddr: Const(0, width: rdAddr.width),
      },
      [
        // All three are pulses of one clock. The default is here and the
        // branches below beat it.
        lookPending < Const(0),
        invalPending < Const(0),
        verdictPulse < Const(0),
        invalGo < Const(0),

        // The verdict of an invalidate, taken one clock after the tag left
        // the block RAM. The clear of the valid bit follows one clock
        // after that.
        If(invalPending, then: [invalHit < verdict, invalGo < Const(1)]),

        // The verdict of the lookup, taken one clock after the tag left
        // the block RAM. A new lookup takes the verdict away first, so
        // `hit_valid` never answers a lookup with the verdict of the one
        // before it.
        If(lookup, then: [hitValid < Const(0)]),
        If(
          lookPending,
          then: [
            hitReg < verdict,
            hitValid < Const(1),
            verdictPulse < Const(1),
          ],
        ),

        rdAddr < rdAddrNext,

        // The valid bits. See [clearMask]: the clear is applied last, so
        // it wins over a set on the same clock.
        valid < (valid | setMask) & ~clearMask,

        // The lookup context. A lookup and an invalidate share it, and an
        // invalidate wins a clock they somehow shared, because a stale
        // line is worse than a lost lookup: the read that lost its lookup
        // reads a miss and costs one round trip.
        If(
          inval,
          then: [
            lookIndex < invalIndex,
            lookTag < invalTag,
            invalPending < Const(1),
          ],
          orElse: [
            If(
              lookup,
              then: [
                lookIndex < lookupIndex,
                lookTag < lookupTag,
                lookPending < Const(1),
              ],
            ),
          ],
        ),

        // The fill. `fill_start` sets the context and the word counter,
        // and the push that carries the last word closes it.
        If(
          fillStart,
          then: [
            fillIndex < fillStartIndex,
            fillTag < fillStartTag,
            fillWord < zeroWord,
            fillActive < Const(1),
          ],
          orElse: [
            If(
              fillTake,
              then: [
                fillWord < fillWord + oneWord,
                If(fillDone, then: [fillActive < Const(0)]),
              ],
            ),
          ],
        ),

        // A clear of the whole store ABANDONS a fill that is in flight.
        // It comes last, so it beats the branch above. Without it a fill
        // that a CMD0 landed in the middle of would finish afterwards and
        // leave one valid line behind, and the host model of what the card
        // holds would then be one line wrong with nothing to correct it.
        If(invalAll, then: [fillActive < Const(0)]),
      ],
    );
  }
}
