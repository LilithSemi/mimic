// MimicSdReadPath: the block read sequencer of the SD card personality.
//
// The card holds no image of its own. A host that asks for a block gets it
// from the runtime, which sits on the far side of the CSR bus and of a
// clock domain crossing. This module is the card side of that exchange:
// it posts one REQUEST record, it waits for the 512 bytes to arrive, and
// it feeds them to [MimicSdLink] one byte at a time.
//
// All logic here runs in the SD clock domain, which the host drives and
// can stop. Both channels are FIFOs that the SoC owns, because only the
// SoC has both clocks. This module drives the SD end of each one: it
// pushes a record into the request FIFO and it pops words out of the data
// FIFO.
//
// The data channel carries no length. What tells the card how many whole
// blocks wait on it is `blocks_pushed`, the COUNT of complete blocks of
// [sdBlockWords] words the runtime has pushed. The card counts the blocks
// it has taken, and it starts a block on DAT only while the two counts
// differ. The card must never start a block on DAT that it cannot finish,
// because the SD bus has no way to say wait in the middle of one, so it
// waits for a whole block and never for a FIFO that is merely not empty.
//
// A COUNT and not a pulse. The host owns this clock and stops it whenever
// it likes, and a pulse made from a level that inverts once per block is
// LOST when the runtime pushes two blocks while the clock stands still.
// The card would then wait for a block it already holds.
//
// The channel DOES carry a tag. Each record holds a sequence number, the
// runtime gives the same number back with the block, and `block_tag`
// carries it here. The card sends a block only when the tag names the
// request it is waiting for. Without the tag the card would have to guess
// from timing alone whether a block that arrives late belongs to the
// record it gave up on or to the record it holds now, and a wrong guess
// gives the host the bytes of another read with a good CRC16 on them.

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'sd_link.dart' show sdBlockBytes, sdCommandArgBits;

/// Number of 32-bit words in one SD data block.
///
/// The block length is fixed at [sdBlockBytes] bytes and the CSR data
/// channel is 32 bits wide, so this is the number of pushes that answer
/// one request.
const int sdBlockWords = sdBlockBytes ~/ 4;

/// Number of whole blocks the READ data channel holds.
///
/// One block is the smallest channel that WORKS: the card cannot start a
/// block on DAT before it holds all of it. One block is not enough to be
/// FAST. A block leaves the channel in one 4114 clock send, which is 165
/// us at 25 MHz, and a USB full-speed round trip is about 1 ms, so a
/// runtime that can hold only one block always answers late. The runtime
/// must be able to push the blocks of a CMD18 stream BEFORE the card asks
/// for them, and it needs somewhere to put them.
///
/// Four costs nothing. The channel is on one DP16KD, which is 16 kbit, so
/// it holds 512 words of 32 bits. 128 words used one whole DP16KD and left
/// three quarters of it empty.
const int sdDataInFifoBlocks = 4;

/// Number of words the READ data channel holds. See
/// [sdDataInFifoBlocks].
const int sdDataInFifoWords = sdDataInFifoBlocks * sdBlockWords;

/// Number of words the WRITE data channel between the card and the runtime
/// holds.
///
/// It is exactly one block, and one block is all it needs: the card takes
/// one write at a time and holds the SD host busy until the runtime has
/// taken the bytes, so a deeper channel would carry nothing.
const int sdDataFifoWords = sdBlockWords;

/// Number of bits in the counters of whole blocks on the read channel.
///
/// The CSR slave counts the blocks it has pushed and publishes that count
/// as a gray code. The card counts the blocks it has taken. The difference
/// is the number of whole blocks that wait on the channel, and both
/// counters wrap at the same number, so the difference is right through
/// every wrap.
///
/// A COUNT and not a pulse. A level that inverts once per block loses
/// events whenever the runtime pushes two blocks while the SD clock stands
/// still, which the host can do at any time, and the card would then wait
/// for a block it already holds. A gray coded count cannot lose one: it
/// carries the whole number, so a card whose clock starts again reads what
/// it missed.
const int sdBlockCountBits = 9;

/// Number of bits in the word counters of both data channels.
///
/// The free space of the read channel is the words the runtime pushed less
/// the words the card took, and the card reports what it took in WORDS, so
/// both counters are this wide and wrap at the same number. The write
/// channel counts its words the same way.
///
/// It must hold more words than either channel does, with room for the
/// blocks in flight. [sdBlockCountBits] blocks of [sdBlockWords] words is
/// far more than either channel carries.
final int sdDataWordCountBits = sdBlockCountBits + (sdBlockWords - 1).bitLength;

/// Request opcode 1, read_blocks.
///
/// It is the only opcode the runtime knows. An unknown opcode still takes
/// two words off the request channel, so a record the runtime cannot serve
/// leaves the channel in step.
const int sdRequestOpReadBlocks = 0x01;

/// Number of 32-bit words in one request record.
///
/// Word 0 holds the opcode in bits 3 to 0, the card generation in bits 7 to
/// 4, the sequence tag in bits 15 to 8 and the block count in bits 31 to 16.
/// Word 1 holds the block address.
const int sdRequestWords = 2;

/// Number of bits in one request record.
const int sdRequestBits = sdRequestWords * 32;

/// Number of bits in the block count field of a request record.
const int sdRequestBlocksBits = 16;

/// Number of bits in the opcode field of a request record.
const int sdRequestOpBits = 4;

/// Number of bits in the card generation field of a request record.
///
/// CMD0 advances this value. The runtime uses it to discard a cache model
/// that describes the card before CMD0 invalidated its cache.
const int sdRequestEpochBits = 4;

/// Number of bits in the sequence tag field of a request record.
///
/// The tag sits in bits 15 to 8 of word 0, which the first version of this
/// interface left reserved. The runtime gives the tag back with the block
/// that answers the record.
const int sdRequestSeqBits = 8;

/// The sequence tag that names NO request.
///
/// The counter never gives this value to a record, so a block that arrives
/// with it, and a channel that holds no tag at all, name no request and
/// are thrown away. It is the value the tag channel reads while it is
/// empty.
const int sdRequestSeqNone = 0;

/// Number of records the request channel holds.
///
/// One is enough for the traffic this card makes, because the card is in
/// the data state while a read runs and takes no second read there. The
/// depth is 4 so that a card which timed out and was asked again does not
/// drop the second record.
const int sdRequestFifoDepth = 4;

/// Number of bits in one entry of the tag channel.
///
/// One entry names one block: the sequence tag in the low
/// [sdRequestSeqBits] bits, the FILL ADDRESS above it and a bit at the top
/// that says whether that address is there. A fill answers no record, so
/// its address cannot come from one, and it travels here rather than in a
/// register of its own: a FIFO gives no order between a register and an
/// entry, and a fill that took the address of another push would write the
/// wrong line.
const int sdTagChannelBits = sdRequestSeqBits + sdCommandArgBits + 1;

/// Bit number of the first bit of the fill address in a tag entry.
const int sdTagChannelLbaLsb = sdRequestSeqBits;

/// Bit number of the bit that says a tag entry carries a fill address.
const int sdTagChannelValidBit = sdRequestSeqBits + sdCommandArgBits;

/// Number of tags the tag channel holds.
///
/// One tag answers one block, and the tag leaves the channel when the card
/// TAKES the block it names, so the channel must hold as many tags as the
/// data channel holds blocks. The depth must be a power of two.
const int sdTagFifoDepth = sdDataInFifoBlocks;

/// SD clocks the card waits for the answer to one request.
///
/// The value is a compromise between two faults. Too short, and a runtime
/// that is merely slow loses a read it would have answered. Too long, and
/// a host waits for data that is never coming. 1048576 clocks was 42 ms at
/// 25 MHz. That was too close to host scheduling stalls on the USB runtime
/// and could fail a healthy long read after thousands of blocks. 4194304
/// clocks is 168 ms at 25 MHz. A successful answer still starts as soon as
/// it arrives, so the longer limit does not add read latency.
///
/// A test gives a small number here so that the timeout is reachable in a
/// simulation.
const int sdReadTimeoutClocks = 1 << 22;

/// Read state 0: no read is in progress.
const int sdReadStateIdle = 0;

/// Read state 1: the request is posted and the card waits for the block.
const int sdReadStateWait = 1;

/// Read state 2: the block is going out on DAT.
const int sdReadStateSend = 2;

/// Read state 3: a block is being taken off the channel and thrown away.
const int sdReadStateDrop = 3;

/// Read state 4: the block cache is being asked whether it holds the block.
///
/// A lookup takes two clocks: a block RAM read port is a register, so the
/// tag of the line arrives one clock after the address, and the compare of
/// it is registered as well because the SD clock domain cannot carry the
/// output of a block RAM through a compare and a mux in one clock. The
/// card waits here for both, and the wait costs one clock in the 4114 that
/// a block takes on DAT.
const int sdReadStateLookup = 4;

/// Number of bits in the read state register.
final int sdReadStateBits = sdReadStateLookup.bitLength;

/// The block read sequencer.
///
/// A pulse on `start` with the block address on `lba` asks the BLOCK CACHE
/// first. `busy` is high from that clock until the block has gone out or
/// the wait has timed out.
///
/// The cache is what removes the round trip
/// A lookup takes one clock, because a block RAM read port is a register.
/// A HIT then serves the 512 bytes straight out of the cache and posts NO
/// record at all: nothing crosses to the runtime, and the host pays the
/// time of the SD bus alone. A MISS posts one record on `req_data` and
/// `req_valid` and waits. The runtime can merge that record with a
/// speculative fill that it already sends. The card writes the arriving
/// block into the line
/// it maps to, so the next read of that block is a hit.
///
/// A block that answers no record is a FILL. The runtime pushes it with
/// the tag [sdRequestSeqNone] and a block address of its own on
/// `block_fill_lba`, and the card writes it into the line that address
/// maps to and sends nothing. That is how a host fills the cache with
/// blocks that nobody has asked for yet.
///
/// Read ahead during a stream
/// A CMD18 never leaves the card idle: the lookup of the block after this
/// one goes out on the clock the link reports the end bit of this one. A
/// fill that reached the card only while it was idle could therefore never
/// reach it during the very command that reads a file, which is where it
/// is worth the most. The card takes ONE waiting block off the channel in
/// the GAP between the blocks of a stream, and at the start of a read, and
/// it looks the next block up after that. A fill absorbed there is what
/// makes the lookup that follows a HIT. The drop costs 128 SD clocks
/// against the 4114 that one block takes on DAT.
///
/// One block per gap, and no more. The stream takes one block out of the
/// cache for each one it absorbs, so one per gap is the rate that keeps
/// up, and a bound of one keeps a runtime that pushes hard from holding
/// the host off the bus.
///
/// The card takes the block off the data channel and gives it to the link:
/// `tx_byte` holds the byte the link takes next and every pulse on
/// `tx_next` moves to the byte after it. `tx_start` opens the block and
/// `tx_done` closes it, and the byte order inside a word is LITTLE ENDIAN,
/// so byte 0 of the block is bits 7 to 0 of the first word.
///
/// `ready` says the card can take a new read. It is low while a read runs
/// and while the card is disabled.
///
/// When no answer comes
/// A record that nothing answers would leave the host waiting for a start
/// bit that never arrives. The card therefore gives up after
/// [timeoutClocks] SD clocks: it pulses `failed`, which returns the card
/// to the transfer state, and it pulses `timeout_event`, which the SoC
/// reports in the EVENT register. It sends NOTHING on DAT, which is what a
/// real card does when a read fails: the host reads a data timeout and
/// recovers with a command of its own.
///
/// A record is posted for each MISS, so the sequence counter and the tags
/// count runtime requests and not reads. A hit moves neither. The runtime
/// merges a request with a speculative line that it already sends.
///
/// A record that goes unanswered leaves an answer that may still be on its
/// way. The TAG is what tells the two apart, and no timer is needed for
/// it: each record carries a sequence number in bits 15 to 8 of word 0,
/// the runtime writes that number back with the block, and `block_tag`
/// carries it here. A block whose tag is not the tag of the record the
/// card waits for is taken off the channel and thrown away, whether the
/// card is idle or waiting. The card can therefore take the next read at
/// once, and it can never send the block of one request as the answer to
/// another.
class MimicSdReadPath extends BridgeModule {
  /// SD clocks the card waits for the answer to one request.
  final int timeoutClocks;

  /// Makes the read sequencer.
  ///
  /// [timeoutClocks] defaults to [sdReadTimeoutClocks]. A test gives a
  /// small number so that the timeout is reachable in a simulation.
  MimicSdReadPath({int? timeoutClocks, String? name})
    : timeoutClocks = timeoutClocks ?? sdReadTimeoutClocks,
      super('MimicSdReadPath', name: name ?? 'sd_read_path') {
    if (this.timeoutClocks < 2) {
      throw ArgumentError.value(
        this.timeoutClocks,
        'timeoutClocks',
        'must be 2 or more. The counter is as wide as the count, and a '
            'timeout of 0 or 1 clock gives up before a block can arrive.',
      );
    }
    if (sdBlockBytes % 4 != 0) {
      throw StateError(
        'A block is $sdBlockBytes bytes, which is not a whole number of '
        '32-bit words. The data channel carries words.',
      );
    }
    if (sdDataInFifoWords > (1 << sdDataWordCountBits)) {
      throw StateError(
        'The read data channel holds $sdDataInFifoWords words and the word '
        'counters are $sdDataWordCountBits bits. A channel deeper than the '
        'counters wrap makes the free space that DATA_IN_COUNT reports '
        'wrong.',
      );
    }
    if (sdDataInFifoBlocks > (1 << sdBlockCountBits)) {
      throw StateError(
        'The read data channel holds $sdDataInFifoBlocks blocks and the '
        'block counters are $sdBlockCountBits bits. A channel deeper than '
        'the counters wrap makes the count of blocks that wait wrong.',
      );
    }
    if (sdTagFifoDepth < sdDataInFifoBlocks) {
      throw StateError(
        'The tag channel holds $sdTagFifoDepth tags and the data channel '
        'holds $sdDataInFifoBlocks blocks. One tag names one block, so a '
        'shorter tag channel drops the tag of a block that is on its way.',
      );
    }
    if (sdRequestOpBits +
            sdRequestEpochBits +
            sdRequestSeqBits +
            sdRequestBlocksBits >
        32) {
      throw StateError(
        'Word 0 of a record holds a $sdRequestOpBits bit opcode, a '
        '$sdRequestSeqBits bit sequence tag and a $sdRequestBlocksBits bit '
        'block count, which does not fit in 32 bits.',
      );
    }
    if (sdRequestSeqNone != 0) {
      throw StateError(
        'The tag that names no request is $sdRequestSeqNone. It must be 0, '
        'because an empty tag channel gives 0 and the card must read that '
        'as a block that answers nothing.',
      );
    }
    if (sdRequestBits != sdRequestWords * 32) {
      throw StateError(
        'A record is $sdRequestBits bits and $sdRequestWords words of 32 '
        'bits.',
      );
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // CTRL bit 0 of the CSR block, already brought into this clock domain
    // by the SoC. A card that the runtime has not enabled answers no read,
    // and clearing the bit releases a host that is waiting for one.
    createPort('enable', PortDirection.input);

    createPort('start', PortDirection.input);
    createPort('lba', PortDirection.input, width: sdCommandArgBits);
    createPort('num_blocks', PortDirection.input, width: sdCommandArgBits);
    createPort('epoch', PortDirection.input, width: sdRequestEpochBits);

    // High with `start` for a MULTIPLE block read, CMD18. The card then
    // asks for the block after the one it just sent, and it goes on until
    // `abort` stops it. It is read with `start` alone, so a level that
    // changes later cannot turn a running single block read into a stream.
    createPort('multi', PortDirection.input);
    createPort('abort', PortDirection.input);

    // The link is sending a response on CMD. A card answers the command
    // first and sends the block after it, so the block waits for this to
    // fall.
    createPort('cmd_busy', PortDirection.input);

    // The read side of the data channel. `data_word` is the word at the
    // head of the FIFO and `data_pop` takes it off. `data_empty` stays high
    // until a synchronous block RAM read has put that head word on the port.
    createPort('data_word', PortDirection.input, width: 32);
    createPort('data_empty', PortDirection.input);

    // The tag and data use separate asynchronous FIFOs. Their read pointers
    // cross independently, so either FIFO can become visible one SD clock
    // before the other. A whole block is ready only when both heads are
    // visible. Taking data while the tag still reads empty permanently moves
    // the two channels out of step.
    createPort('block_tag_empty', PortDirection.input);

    // The COUNT of complete blocks the runtime has pushed, already crossed
    // into this clock domain. The card counts the blocks it has taken and
    // the difference is the number of whole blocks that wait on the
    // channel. The card starts a block on DAT only while that difference
    // is not 0, because it cannot pause in the middle of one.
    //
    // A COUNT and not a pulse, because the host stops this clock whenever
    // it likes. A pulse made from a level that inverts per block is lost
    // when two blocks are pushed while the clock stands still, and the
    // card would then wait for a block it already holds. See
    // [sdBlockCountBits].
    createPort('blocks_pushed', PortDirection.input, width: sdBlockCountBits);

    // The sequence tag of the block at the HEAD of the channel, which is
    // the next block the card takes. It is the tag the runtime read out of
    // the record, and it names the request that the block answers.
    // [sdRequestSeqNone] names no request, which is what an empty tag
    // channel gives.
    //
    // It is read straight off the tag channel and never registered here.
    // The channel holds one tag per block and `block_take` takes one off
    // for each block the card takes, so the head of the tag channel always
    // names the head of the data channel. A register would name the block
    // that arrived LAST, which is the wrong one as soon as the channel
    // holds more than one.
    createPort('block_tag', PortDirection.input, width: sdRequestSeqBits);

    // The FILL address of that block, and whether it carries one.
    //
    // A block that answers no request is a FILL: the runtime pushed a
    // block that the card never asked for, so that a later read of it is a
    // hit. It carries the tag [sdRequestSeqNone], which names no request,
    // and the address of the block it IS travels beside the tag. A block
    // with that tag and no address is a block nobody can place, and the
    // card throws it away the way it always has.
    createPort('block_fill_lba', PortDirection.input, width: sdCommandArgBits);
    createPort('block_fill_valid', PortDirection.input);

    // The block cache. A lookup takes TWO clocks: `cache_hit_valid` says
    // that `cache_hit` answers the lookup this read made, and reading
    // `cache_hit` before it would read the verdict of the lookup before
    // this one. `cache_word` holds the word the read pointer of the cache
    // is on. See [MimicSdBlockCache].
    createPort('cache_hit', PortDirection.input);
    createPort('cache_hit_valid', PortDirection.input);
    createPort('cache_word', PortDirection.input, width: 32);

    createPort('tx_next', PortDirection.input);
    createPort('tx_done', PortDirection.input);

    addOutput('req_data', width: sdRequestBits);
    addOutput('req_valid');
    addOutput('data_pop');
    addOutput('tx_start');
    addOutput('tx_byte', width: 8);
    addOutput('busy');
    addOutput('ready');
    addOutput('done');
    addOutput('failed');
    // One pulse for each whole block the card has finished taking off the
    // channel. The free space that `DATA_IN_COUNT` reports is built from
    // the WORD count and not from this, because a count that moved a block
    // at a time held still through the whole 4114 clock send of one block
    // and told a runtime that read it nothing at all. This stays as the
    // observation of whole blocks.
    addOutput('block_consumed');
    addOutput('timeout_event');

    // Diagnostic pulses for the demand read path. The card device counts
    // these in this clock domain and publishes gray codes to the runtime.
    addOutput('dbg_tx_start');
    addOutput('dbg_tx_done');
    addOutput('dbg_drop');
    addOutput('dbg_abort');

    // One pulse for each block the card TAKES off the channel, whatever it
    // then does with it. It takes one entry off the tag channel, so the
    // head of that channel always names the head of the data channel.
    addOutput('block_take');

    // The cache side. A read asks the cache first, and a block that comes
    // off the data channel is written into the line it maps to, so the
    // next read of it needs no round trip at all.
    addOutput('cache_lookup');
    addOutput('cache_lookup_lba', width: sdCommandArgBits);
    addOutput('cache_rd_next');
    addOutput('cache_fill_start');
    addOutput('cache_fill_lba', width: sdCommandArgBits);
    addOutput('cache_fill_word', width: 32);
    addOutput('cache_fill_push');

    final clk = input('clk');
    final reset = input('reset');

    final stateIdle = Const(sdReadStateIdle, width: sdReadStateBits);
    final stateLookup = Const(sdReadStateLookup, width: sdReadStateBits);
    final stateWait = Const(sdReadStateWait, width: sdReadStateBits);
    final stateSend = Const(sdReadStateSend, width: sdReadStateBits);
    final stateDrop = Const(sdReadStateDrop, width: sdReadStateBits);
    final state = Logic(name: 'read_state', width: sdReadStateBits);
    final wordReg = Logic(name: 'read_word', width: 32);
    final byteSel = Logic(name: 'read_byte_sel', width: 2);
    final oneByteSel = Const(1, width: 2);

    // Words of the block that are still on the channel. It counts down and
    // it also counts the words of a block that is thrown away, so the two
    // paths cannot disagree about how long a block is.
    final wordsWidth = sdBlockWords.bitLength;
    final wordsLeft = Logic(name: 'read_words_left', width: wordsWidth);
    final oneWord = Const(1, width: wordsWidth);
    final zeroWords = Const(0, width: wordsWidth);
    final allWords = Const(sdBlockWords, width: wordsWidth);

    // Blocks the card has TAKEN off the channel. The runtime publishes the
    // count it has PUSHED, both wrap at the same number, so the two are
    // equal exactly while the channel holds no whole block.
    //
    // It counts in this clock domain, which the host stops. A stopped
    // clock holds this register still and holds `blocks_pushed` still as
    // far as this domain can see, so the card reads the same answer before
    // and after the stop and loses nothing.
    final blocksTaken = Logic(name: 'blocks_taken', width: sdBlockCountBits);
    final oneBlock = Const(1, width: sdBlockCountBits);

    // The tag of the request the card waits for.
    //
    // The counter moves on every read the card POSTS A RECORD FOR. A read
    // that hits posts nothing and moves nothing. It steps over
    // [sdRequestSeqNone] on a wrap, so that value names no request at any
    // time and an untagged block matches nothing.
    final seq = Logic(name: 'read_seq', width: sdRequestSeqBits);
    final oneSeq = Const(1, width: sdRequestSeqBits);
    final lastSeq = Const(1, width: sdRequestSeqBits, fill: true);
    final firstSeq = Const(sdRequestSeqNone + 1, width: sdRequestSeqBits);
    final noneSeq = Const(sdRequestSeqNone, width: sdRequestSeqBits);
    final seqNext = mux(
      seq.eq(lastSeq),
      firstSeq,
      seq + oneSeq,
    ).named('read_seq_next');

    // The tag of the block at the head of the channel, and the fill
    // address that travels with it. All three are read straight off the
    // tag channel: see the port comments.
    final blockTag = input('block_tag').named('read_block_tag');
    final blockFillLba = input('block_fill_lba').named('read_block_fill_lba');
    final blockFillValid = input('block_fill_valid')
        .named('read_block_fill_valid');

    // High while the block that arrived is still to be thrown away and the
    // card goes back to waiting for its own block afterwards.
    final dropToWait = Logic(name: 'read_drop_to_wait');

    // High while the block being taken off the channel is a FILL that
    // arrived in the GAP of a stream, and the card looks the next block of
    // that stream up when the drop ends.
    //
    // It is what makes read ahead work during CMD18. The card is never
    // idle in a stream, and a fill is taken only while it is idle, so
    // without this the runtime could put nothing on the card while the
    // host was reading a file. See the class doc.
    final dropToLookup = Logic(name: 'read_drop_to_lookup');

    // High while the block being taken off the channel is a FILL and its
    // words go into the cache instead of nowhere.
    final dropFill = Logic(name: 'read_drop_fill');

    // The timeout counter. It measures the wait for the answer to the one
    // record the card holds, and nothing else. It runs on through a block
    // of another record that goes past, so a runtime that sends only the
    // wrong blocks cannot hold the host past the timeout.
    final timerBits = (this.timeoutClocks - 1).bitLength;
    final timer = Logic(name: 'read_timer', width: timerBits);
    final oneTick = Const(1, width: timerBits);
    final zeroTicks = Const(0, width: timerBits);
    final timerLast = Const(this.timeoutClocks - 1, width: timerBits);
    final timerDone = timer.gte(timerLast).named('read_timer_done');

    // The read the card is running now: a stream or one block, the block
    // address it is serving, and the block address of the NEXT record of a
    // stream.
    final multiReg = Logic(name: 'read_multi');
    final curLba = Logic(name: 'read_cur_lba', width: sdCommandArgBits);
    final nextLba = Logic(name: 'read_next_lba', width: sdCommandArgBits);
    final oneLba = Const(1, width: sdCommandArgBits);

    // High while the block going out on DAT comes from the CACHE and not
    // from the data channel. The two differ in one thing alone: where the
    // next word comes from.
    final fromCache = Logic(name: 'read_from_cache');

    // High while the words the card takes off the data channel are also
    // written into the cache line of [curLba]. It is set by a MISS, so a
    // block that answers a record fills the line it maps to and the next
    // read of that block is a hit.
    final fillActive = Logic(name: 'read_fill_active');

    // An abort that arrived while a block was going out on DAT.
    //
    // The link cannot stop in the middle of a frame, so a CMD12 that lands
    // there is remembered and read at the end bit. Without the register the
    // card would take the abort, finish the block and then ask for the
    // block after it, and the host would get a block it stopped.
    final abortSeen = Logic(name: 'read_abort_seen');

    final donePulse = Logic(name: 'read_done_pulse');
    final failedPulse = Logic(name: 'read_failed_pulse');
    final consumedPulse = Logic(name: 'read_consumed_pulse');
    final timeoutPulse = Logic(name: 'read_timeout_pulse');

    final inIdle = state.eq(stateIdle).named('read_in_idle');
    final inLookup = state.eq(stateLookup).named('read_in_lookup');
    final inWait = state.eq(stateWait).named('read_in_wait');
    final inSend = state.eq(stateSend).named('read_in_send');
    final inDrop = state.eq(stateDrop).named('read_in_drop');
    // A whole block waits on the channel. The runtime has pushed more
    // blocks than the card has taken, and both counts wrap at the same
    // number, so the compare is right through every wrap.
    final haveBlock =
        (input('blocks_pushed').neq(blocksTaken) &
                ~input('data_empty') &
                ~input('block_tag_empty'))
            .named('have_block');
    final enable = input('enable');

    // The card takes a read from idle, and ALSO while it is taking a block
    // off the channel that no read of its own is waiting for. It needs the
    // runtime to hold it enabled in both.
    //
    // A block that waits on the channel must not close the read side.
    // Every block carries a tag: the card knows a block of another request
    // from the tag and throws it away, and it knows a FILL from the tag as
    // well and puts that one in the cache. Read ahead leaves blocks
    // waiting by design, and the host STOPS the SD clock between commands,
    // so a block left by the last command is still there when the next one
    // arrives and the card is still taking it off when the command is
    // decoded. A card that refused a read in either window would refuse
    // one CMD18 after another for as long as read ahead kept pushing, and
    // the host would read a file that is part right and part missing.
    //
    // The LAST clock of a drop is not ready. The read the card takes here
    // is served when the drop ends, and a start on the very clock the drop
    // ended would be lost between the two.
    final absorbing =
        (inDrop & ~dropToWait & ~dropToLookup & wordsLeft.gt(oneWord)).named(
          'read_absorbing',
        );
    final ready = ((inIdle | absorbing) & enable).named('read_ready');

    // The request goes out on the clock the LOOKUP MISSES, and not on the
    // clock the read starts. The card asks the cache first, and a read
    // that hits posts no record at all: that is the whole point of the
    // cache.
    //
    // The card asks for exactly ONE BLOCK in every record, whatever
    // command started the read: a missed CMD17 posts one record and a
    // CMD18 posts one for each block of the stream that misses. The widths
    // come from the field constants, so a field that moves cannot push
    // another one off the end.
    //
    // The tag is the NEXT value of the counter and not the value it holds
    // now, because the counter moves on this same clock. The card is
    // therefore waiting for the tag that `seq` holds through the whole
    // wait, which is the value that the compare below reads.
    final reqWord0 = [
      Const(1, width: sdRequestBlocksBits),
      seqNext,
      input('epoch'),
      Const(sdRequestOpReadBlocks, width: sdRequestOpBits),
    ].swizzle().named('req_word0');

    final takeStart = (ready & input('start')).named('read_take_start');

    // A MULTIPLE block read looks the cache up ONCE FOR EACH BLOCK, and
    // the lookup of the block after this one goes out on the clock the
    // link reports the end bit of this one.
    //
    // One record per block and not one record with a count. The runtime
    // reads a record, answers it with one tagged block and pops it, and
    // that loop is what the runtime already does for CMD17: a stream is
    // then the SAME record over and over with the address moved on by one
    // and a tag of its own. A record with a count would need the runtime
    // to push several blocks against one record and one tag, and the tag
    // compare, the block counter and the free space that DATA_IN_COUNT
    // reports would all have to change with it.
    final abortNow = (input('abort') | abortSeen | ~enable).named(
      'read_abort_now',
    );
    final atEnd = (inSend & input('tx_done')).named('read_at_end');
    final nextInRange = nextLba
        .lt(input('num_blocks'))
        .named('read_next_in_range');
    final goOn = (atEnd & multiReg & ~abortNow & nextInRange).named(
      'read_go_on',
    );

    // A block waits on the channel that the card did not ask for now. The
    // card takes it off BEFORE it looks the next block up: a FILL goes
    // into the cache, which is what makes the lookup that follows a hit,
    // and anything else goes nowhere. One block at a time, because the
    // stream takes one block from the cache for each one it absorbs here.
    final gapBlock = haveBlock.named('read_gap_block');

    // The start of a read, split three ways.
    //
    // From IDLE the card looks the block up at once, unless the channel
    // holds a block it has to take off first.
    //
    // From a DROP the card is already taking one off. It holds the read
    // and looks the block up when the drop ends, which costs at most 128
    // SD clocks of the 4114 that one block takes on DAT.
    final startFromIdle = (takeStart & inIdle).named('read_start_from_idle');
    final startNow = (startFromIdle & ~gapBlock).named('read_start_now');
    final startDrop = (startFromIdle & gapBlock).named('read_start_drop');
    final startInDrop = (takeStart & ~inIdle).named('read_start_in_drop');

    // The step of a stream, split the same way. `goOnDrop` is what carries
    // read ahead through a CMD18: the card is never idle in a stream, so
    // this is the only place a fill can reach the cache while one runs.
    final goOnDirect = Logic(name: 'read_go_on_direct');
    final goOnNow = (goOn & ~gapBlock).named('read_go_on_now');
    final goOnDrop = (goOn & gapBlock & ~goOnDirect).named('read_go_on_drop');

    // The lookup that resumes after a gap block went past. It is one clock
    // AFTER the last word of that block, because that word writes the tag
    // of the line it filled and a lookup on the same clock would read the
    // tag RAM while the fill wrote it.
    final dropLookupArm = Logic(name: 'read_drop_lookup_arm');

    // The address of the lookup: the port for the first block of a read,
    // the register that holds the block the card is on for a lookup that
    // resumes after a gap block, and the register that holds the block
    // after it for every other step of a stream.
    // The card leaves the lookup or the wait as soon as the runtime drops
    // CTRL bit 0 or the state machine aborts the read. Both release a host
    // that is waiting for a block, and neither waits out the timeout.
    final release = (inWait & (input('abort') | ~enable)).named('read_release');
    final releaseLookup = (inLookup & (input('abort') | ~enable)).named(
      'read_release_lookup',
    );
    final lookupLba = mux(
      startNow,
      input('lba'),
      mux(dropLookupArm, curLba, nextLba),
    ).named('read_lookup_lba');
    output('cache_lookup') <= startNow | goOnNow | dropLookupArm;
    output('cache_lookup_lba') <= lookupLba;

    // The verdict of the lookup. The card stays in the lookup state until
    // the cache answers, and the cache then holds the answer until the
    // next lookup, so the verdict is correct in every clock of the state
    // from the moment it is valid.
    final verdictReady = (inLookup & ~releaseLookup & input('cache_hit_valid'))
        .named('read_verdict_ready');
    final cacheHit = (verdictReady & input('cache_hit')).named(
      'read_cache_hit',
    );
    final cacheMiss = (verdictReady & ~input('cache_hit')).named(
      'read_cache_miss',
    );

    // The record. It goes out on the clock the lookup misses.
    output('req_data') <= [curLba, reqWord0].swizzle();

    // A HIT. The first word of the line is already on the read port of the
    // cache, because the lookup read it with the tag, so the card can open
    // the block as soon as the link has finished the response.
    final hitLoad = (cacheHit & ~input('cmd_busy')).named('read_hit_load');

    // The tag compare of the data channel. The card sends a block only
    // when its tag names the record the card is waiting for.
    final tagMatch = blockTag.eq(seq).named('read_tag_match');

    // A block that answers NO request and carries an address of its own.
    // It is a fill: the card writes it into the line it maps to and sends
    // nothing.
    final blockIsFill = (blockTag.eq(noneSeq) & blockFillValid).named(
      'read_block_is_fill',
    );

    // A speculative block can answer a read directly when its address is
    // the address the card needs. The compare is mandatory: a fill with any
    // other address must never appear on DAT as the requested block.
    final fillMatchesWait = (blockIsFill & blockFillLba.eq(curLba)).named(
      'read_fill_matches_wait',
    );
    output('req_valid') <= cacheMiss;
    // A fill takes the cache path even when it names the next stream block.
    // Starting it directly on the end clock of the previous block gives the
    // host no command gap in which to issue CMD12. The cache path absorbs the
    // fill first, then uses the normal lookup and transmit sequence.
    goOnDirect <= Const(0);

    // The block leaves the channel one word at a time. The first word is
    // loaded before the link opens the block, because the link takes byte
    // 0 in the very first clock of the frame.
    final loadFirst =
        (inWait &
                ~release &
                haveBlock &
                (tagMatch | fillMatchesWait) &
                ~input('cmd_busy'))
            .named('read_load_first');
    // A block whose tag names no record the card waits for. It is taken
    // off the channel and the card goes back to waiting for its own.
    //
    // The two kinds part here. A FILL goes into the CACHE, and it must:
    // the runtime pushes the fills of one record while the card is already
    // reading the next block of a stream, so this is where a large part of
    // every read ahead lands. A block that is not a fill answers a record
    // the card gave up on and goes nowhere.
    final dropOther =
        (inWait & ~release & haveBlock & ~tagMatch & ~fillMatchesWait).named(
          'read_drop_other',
        );
    final dropFillWait = (dropOther & blockIsFill).named('read_drop_fill_wait');

    // A block that arrives while no read is running. The card asked for no
    // block, so it is either a late answer, which is thrown away, or a
    // FILL, whose words go into the cache.
    final dropIdle = (inIdle & ~takeStart & haveBlock).named('read_drop_idle');

    // Every place the card opens a fill on the line of the block it is
    // taking off the channel, rather than on the line of a read.
    final fillIdle = (dropIdle & blockIsFill).named('read_fill_idle');
    final fillGap = (((startDrop | goOnDrop) & blockIsFill) | dropFillWait)
        .named('read_fill_gap');

    // The card takes one block off the channel on each of these.
    final takeBlock =
        (loadFirst | dropOther | dropIdle | startDrop | goOnDrop | goOnDirect)
            .named('read_take_block');
    // A read that starts while a drop runs takes NO block: the drop it
    // joined already took the one it is working on.
    output('block_take') <= takeBlock;

    final lastByteOfWord = byteSel
        .eq(Const(3, width: 2))
        .named('read_last_byte_of_word');
    final loadNext =
        (inSend & input('tx_next') & lastByteOfWord & wordsLeft.neq(zeroWords))
            .named('read_load_next');
    // The next word comes from the channel for a block that answers a
    // record, and from the cache for a block that hit.
    final loadNextFifo = (loadNext & ~fromCache).named('read_load_next_fifo');
    final loadNextCache = (loadNext & fromCache).named('read_load_next_cache');
    final dropPop = (inDrop & wordsLeft.neq(zeroWords)).named('read_drop_pop');

    output('data_pop') <= loadFirst | loadNextFifo | dropPop | goOnDirect;
    output('tx_start') <= loadFirst | hitLoad | goOnDirect;
    output('dbg_tx_start') <= loadFirst | hitLoad | goOnDirect;
    output('dbg_tx_done') <= inSend & input('tx_done');
    output('dbg_drop') <= dropOther | dropIdle | startDrop | goOnDrop;
    output('dbg_abort') <= release | releaseLookup | (atEnd & abortNow);
    output('cache_rd_next') <= hitLoad | loadNextCache;

    // The fill port of the cache. A MISS opens a fill on the line of the
    // block it asked for, and a fill block that the card takes off the
    // channel opens one on the line of the address it carries.
    //
    // No two of these land on one clock. A miss is decided in the lookup
    // state and the other two are decided in the idle state and at the end
    // bit of a block, and the card is in one state at a time.
    output('cache_fill_start') <= cacheMiss | fillIdle | fillGap;
    output('cache_fill_lba') <= mux(cacheMiss, curLba, blockFillLba);
    output('cache_fill_word') <= input('data_word');
    output('cache_fill_push') <=
        ((loadFirst | loadNextFifo) & fillActive) | (dropPop & dropFill);

    // The word that goes out on DAT. A block that hit takes its words from
    // the cache and a block that answers a record takes them from the
    // channel.
    final sendWord = mux(
      fromCache,
      input('cache_word'),
      input('data_word'),
    ).named('read_send_word');

    // Little endian inside the word: byte 0 of the block is bits 7 to 0 of
    // the first word. This is the byte order of every other value on the
    // CSR wire, and the runtime packs the block that way.
    output('tx_byte') <=
        mux(
          byteSel[1],
          mux(byteSel[0], wordReg.slice(31, 24), wordReg.slice(23, 16)),
          mux(byteSel[0], wordReg.slice(15, 8), wordReg.slice(7, 0)),
        );

    Sequential(
      clk,
      reset: reset,
      resetValues: {
        state: stateIdle,
        wordReg: Const(0, width: 32),
        byteSel: Const(0, width: 2),
        wordsLeft: zeroWords,
        blocksTaken: Const(0, width: sdBlockCountBits),
        seq: Const(sdRequestSeqNone, width: sdRequestSeqBits),
        dropToWait: Const(0),
        dropToLookup: Const(0),
        dropLookupArm: Const(0),
        dropFill: Const(0),
        multiReg: Const(0),
        curLba: Const(0, width: sdCommandArgBits),
        nextLba: Const(0, width: sdCommandArgBits),
        fromCache: Const(0),
        fillActive: Const(0),
        abortSeen: Const(0),
        timer: zeroTicks,
        donePulse: Const(0),
        failedPulse: Const(0),
        consumedPulse: Const(0),
        timeoutPulse: Const(0),
      },
      [
        donePulse < Const(0),
        failedPulse < Const(0),
        consumedPulse < Const(0),
        timeoutPulse < Const(0),

        // The blocks the card has taken off the channel.
        //
        // The runtime publishes what it PUSHED and this counts what the
        // card TOOK, so nothing has to arrive as a pulse and nothing is
        // lost when the host stops the clock. The counter wraps at the
        // same number the published one does.
        If(takeBlock, then: [blocksTaken < blocksTaken + oneBlock]),

        // An abort that lands while a block is going out on DAT. The send
        // runs to its end bit, and this register carries the abort to that
        // clock. It is WRAPPED, because a flat write would clear the
        // register on every clock the state machine holds the line low.
        If(input('abort'), then: [abortSeen < Const(1)]),

        Case(state, [
          CaseItem(stateIdle, [
            If(
              takeStart,
              then: [
                // The lookup goes out on this clock when the channel holds
                // nothing. The card spends the next one in the lookup
                // state, which is where the cache answers, and it posts a
                // record only if the answer is a miss.
                //
                // A block that waits on the channel is taken off FIRST. It
                // is a fill that read ahead left there, or the late answer
                // to a record the card gave up on, and either way the card
                // deals with it before it asks for anything new. The
                // lookup then goes out at the end of the drop.
                state < mux(gapBlock, stateDrop, stateLookup),
                If(
                  startDrop,
                  then: [
                    wordsLeft < allWords,
                    dropFill < blockIsFill,
                    dropToLookup < Const(1),
                    dropToWait < Const(0),
                  ],
                ),
                timer < zeroTicks,
                // The read the card is running now. All three come from
                // the ports in this clock, so a level that changes later
                // cannot reach a read that is already going.
                multiReg < input('multi'),
                curLba < input('lba'),
                nextLba < input('lba') + oneLba,
                fromCache < Const(0),
                fillActive < Const(0),
                abortSeen < Const(0),
              ],
              orElse: [
                If(
                  dropIdle,
                  then: [
                    // A block the card did not ask for. A FILL goes into
                    // the cache and every other one is thrown away, and
                    // either way the channel comes back into step.
                    state < stateDrop,
                    wordsLeft < allWords,
                    dropFill < blockIsFill,
                    dropToWait < Const(0),
                    dropToLookup < Const(0),
                  ],
                ),
              ],
            ),
          ]),
          CaseItem(stateLookup, [
            If(
              releaseLookup,
              then: [
                // The state machine took the card out of the data state,
                // or the runtime dropped CTRL bit 0. The card gives up
                // before it has asked the runtime for anything, so there
                // is no record to leave standing.
                state < stateIdle,
                timer < zeroTicks,
                failedPulse < Const(1),
                multiReg < Const(0),
                abortSeen < Const(0),
              ],
              orElse: [
                If(
                  cacheMiss,
                  then: [
                    state < stateWait,
                    timer < zeroTicks,
                    seq < seqNext,
                    fillActive < Const(1),
                  ],
                  orElse: [
                    If(
                      hitLoad,
                      then: [
                        // The cache holds the block. Nothing is asked of
                        // the runtime at all.
                        wordReg < input('cache_word'),
                        byteSel < Const(0, width: 2),
                        wordsLeft < allWords - oneWord,
                        state < stateSend,
                        fromCache < Const(1),
                        timer < zeroTicks,
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ]),
          CaseItem(stateWait, [
            timer < timer + oneTick,
            If(
              release,
              then: [
                // The state machine took the card out of the data state,
                // or the runtime dropped CTRL bit 0. Either way the host
                // must not wait out the timeout, so the card gives up now.
                //
                // `failed` returns the card to the transfer state. There
                // is no `timeout_event` here, because the read did not run
                // out of time: an operator stopped the card, and EVENT bit
                // 0 reports a runtime that never answered.
                state < stateIdle,
                timer < zeroTicks,
                failedPulse < Const(1),
                multiReg < Const(0),
                fillActive < Const(0),
                abortSeen < Const(0),
              ],
              orElse: [
                If(
                  loadFirst,
                  then: [
                    wordReg < input('data_word'),
                    byteSel < Const(0, width: 2),
                    wordsLeft < allWords - oneWord,
                    state < stateSend,
                    fromCache < Const(0),
                    timer < zeroTicks,
                  ],
                  orElse: [
                    If(
                      dropOther,
                      then: [
                        // A block that answers no record the card waits
                        // for.
                        //
                        // A FILL goes into the CACHE, on the line its own
                        // address names. The runtime pushes the fills of
                        // one record while the card is already asking for
                        // the next block of a stream, so a fill lands here
                        // often, and a card that threw it away would waste
                        // most of every read ahead.
                        //
                        // A fill here CLOSES the write of the block the
                        // card is waiting for. The cache fills one line at
                        // a time, so the two cannot share it, and the fill
                        // of the waited block has written no word yet: it
                        // opened at the miss and its first word arrives
                        // with the block. The line it opened stays
                        // INVALID, so a later read of that block misses
                        // and costs one round trip. A half written line
                        // would cost correctness, which is the trade this
                        // takes.
                        //
                        // Anything else is the answer to a record the card
                        // gave up on, and it goes nowhere.
                        //
                        // The timer keeps running through the drop, so a
                        // runtime that sends only wrong blocks cannot hold
                        // the host past the timeout.
                        state < stateDrop,
                        wordsLeft < allWords,
                        dropToWait < Const(1),
                        dropToLookup < Const(0),
                        dropFill < blockIsFill,
                        If(blockIsFill, then: [fillActive < Const(0)]),
                      ],
                      orElse: [
                        If(
                          timerDone,
                          then: [
                            state < stateIdle,
                            timer < zeroTicks,
                            failedPulse < Const(1),
                            timeoutPulse < Const(1),
                            multiReg < Const(0),
                            fillActive < Const(0),
                            abortSeen < Const(0),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ]),
          CaseItem(stateSend, [
            If(
              input('tx_next'),
              then: [
                byteSel < byteSel + oneByteSel,
                If(
                  lastByteOfWord,
                  then: [
                    byteSel < Const(0, width: 2),
                    If(
                      wordsLeft.neq(zeroWords),
                      then: [
                        wordReg < sendWord,
                        wordsLeft < wordsLeft - oneWord,
                      ],
                    ),
                  ],
                ),
              ],
            ),
            // The link cannot stop in the middle of a block, so the send
            // runs to its end bit whatever else happens. `abort` is
            // therefore not read here.
            If(
              input('tx_done'),
              then: [
                // A block that came from the cache took nothing off the
                // data channel, so it retires nothing there.
                If(~fromCache, then: [consumedPulse < Const(1)]),
                fillActive < Const(0),
                timer < zeroTicks,
                If(
                  goOn,
                  then: [
                    // A stream. The lookup for the block after this one
                    // goes out on this same clock, and the card asks the
                    // runtime only if that lookup misses. `done` does NOT
                    // pulse, because the state machine reads it as the end
                    // of the whole transfer and would take the card out of
                    // the data state.
                    //
                    // A block that WAITS on the channel is taken off
                    // first. This is the GAP of the stream, and it is the
                    // only moment a fill can reach the cache while a
                    // stream runs: the card is never idle in one. The
                    // lookup then goes out at the end of the drop, and the
                    // fill that just landed is what makes it a hit.
                    //
                    // The drop costs 128 SD clocks against the 4114 that
                    // the block before it took, and it saves the whole USB
                    // round trip of the block after it.
                    state < mux(gapBlock, stateDrop, stateLookup),
                    If(
                      goOnDrop,
                      then: [
                        wordsLeft < allWords,
                        dropFill < blockIsFill,
                        dropToLookup < Const(1),
                        dropToWait < Const(0),
                      ],
                    ),
                    If(
                      goOnDirect,
                      then: [
                        // The waiting fill is exactly the next block of the
                        // stream. Start it from the FIFO without a cache
                        // write and read round trip.
                        state < stateSend,
                        wordReg < input('data_word'),
                        byteSel < Const(0, width: 2),
                        wordsLeft < allWords - oneWord,
                      ],
                    ),
                    curLba < nextLba,
                    nextLba < nextLba + oneLba,
                    fromCache < Const(0),
                  ],
                  orElse: [
                    state < stateIdle,
                    donePulse < Const(1),
                    multiReg < Const(0),
                    fromCache < Const(0),
                    abortSeen < Const(0),
                  ],
                ),
              ],
            ),
          ]),
          CaseItem(stateDrop, [
            // The wait for the block of the card runs on while a block of
            // another record goes past, so the drop cannot stretch the
            // time the host waits.
            If(dropToWait, then: [timer < timer + oneTick]),

            // A read that arrived while the card was taking a block off
            // the channel that no read asked for. The card keeps what the
            // read names and looks it up when the drop ends. `ready` is
            // low on the last clock of a drop, so this can never land on
            // the clock the drop below finishes.
            If(
              startInDrop,
              then: [
                multiReg < input('multi'),
                curLba < input('lba'),
                nextLba < input('lba') + oneLba,
                fromCache < Const(0),
                fillActive < Const(0),
                abortSeen < Const(0),
                dropToLookup < Const(1),
                timer < zeroTicks,
              ],
            ),
            // The whole drop sits inside this guard, so the clock after
            // the last word does nothing at all. A lookup that resumes
            // needs that clock: see [dropLookupArm].
            If(
              wordsLeft.neq(zeroWords),
              then: [
                wordsLeft < wordsLeft - oneWord,
                If(
                  wordsLeft.lte(oneWord),
                  then: [
                    wordsLeft < zeroWords,
                    consumedPulse < Const(1),
                    dropFill < Const(0),
                    If(
                      dropToWait,
                      then: [
                        // Back to the wait. A timer that ran out while the
                        // block went past fires on the next clock, in the
                        // wait state, which is where the timeout belongs.
                        state < stateWait,
                        dropToWait < Const(0),
                      ],
                      orElse: [
                        If(
                          dropToLookup,
                          then: [
                            // A gap block of a read or of a stream. The
                            // card stays here for ONE more clock and looks
                            // the block it is on up then. The last word
                            // above is what wrote the tag of the line that
                            // a fill just filled, and a lookup on this
                            // clock would read the tag RAM while the fill
                            // wrote it.
                            dropLookupArm < Const(1),
                            dropToLookup < Const(0),
                          ],
                          orElse: [state < stateIdle, timer < zeroTicks],
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
            // The clock after the last word of a gap block. The lookup
            // goes out now and the card spends the next clock in the
            // lookup state, which is the order every other lookup takes.
            If(
              dropLookupArm,
              then: [state < stateLookup, dropLookupArm < Const(0)],
            ),
          ]),
        ]),
      ],
    );

    output('busy') <= ~inIdle;
    output('ready') <= ready;
    output('done') <= donePulse;
    output('failed') <= failedPulse;
    output('block_consumed') <= consumedPulse;
    output('timeout_event') <= timeoutPulse;
  }
}
