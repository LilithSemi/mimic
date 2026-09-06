// MimicSdWritePath: the block write sequencer of the SD card personality.
//
// This module is the mirror of [MimicSdReadPath]. The read path asks the
// runtime for 512 bytes and puts them on DAT. This path takes 512 bytes
// off DAT and gives them to the runtime.
//
// All logic here runs in the SD clock domain, which the host drives and
// can stop. Both channels are FIFOs that the SoC owns, because only the
// SoC has both clocks. This module drives the SD end of each one: it
// pushes the record and the block words out, and it pops the
// acknowledgements that come back.
//
// The sequence of one CMD24
//   1. The state machine accepts CMD24 in the transfer state and pulses
//      `start`. The card answers R1 by itself.
//   2. This module raises `rx_enable`, and the link frames the block that
//      the host sends: a start bit, 512 bytes and a CRC16.
//   3. The link checks the CRC16 and pulses `rx_end` with the verdict on
//      `rx_crc_ok`.
//   4. This module posts ONE record with the block address and a sequence
//      tag of its own, and it sends the CRC status token: 010 for a good
//      block and 101 for a bad CRC16.
//   5. A good block holds DAT0 LOW for busy, and the card is in the prg
//      state. This is what hides the round trip to the runtime.
//   6. The runtime takes the block off the channel and writes it, then
//      acknowledges with the tag of the record. The card releases busy.
//
// Why the card pushes a record for a BAD block as well
//   The words of the block go on to the channel as they arrive, because
//   512 bytes of flip-flops in this clock domain cost far more than the
//   channel does. A bad CRC16 therefore leaves a whole block on a channel
//   that holds exactly one block, and the next write would find no room.
//   The card posts a DISCARD record for such a block, which asks the
//   runtime to take the 512 bytes and drop them. The card refuses a new
//   write until that record is acknowledged, and it refuses it the way it
//   refuses a read it cannot serve: R1 with the ERROR bit.
//
// The sequence tag
//   Each record carries a tag, and the runtime gives the tag back with the
//   acknowledgement. The tag is what makes a LATE or a REPEATED
//   acknowledgement safe: only a tag that names the block the card is
//   holding the host for releases busy.
//
//   The tag does NOT decide when the card may take the next write. The
//   FIFO decides that, through `out_room`. An acknowledgement is a message
//   from the runtime and the card cannot check it, so a stray one, a
//   repeated one or one that the runtime never meant to send must not be
//   able to say that the channel is clear. Only the channel says that.

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'sd_link.dart' show sdCommandArgBits, sdStatusCodeBits;
import 'sd_read_path.dart'
    show
        sdBlockWords,
        sdRequestBits,
        sdRequestBlocksBits,
        sdRequestOpBits,
        sdRequestSeqBits,
        sdRequestSeqNone;

/// Request opcode 2, write_blocks.
///
/// The 512 bytes of the block follow on the write data channel. The
/// runtime takes them and writes them into the image at the block address
/// of the record.
const int sdRequestOpWriteBlocks = 0x02;

/// Request opcode 3, write_discard.
///
/// The 512 bytes of the block follow on the write data channel in the same
/// way, and the runtime takes them and DROPS them. The card sends this
/// opcode for a block whose CRC16 failed: the host is told about the fault
/// by the CRC status token, and this record only clears the channel.
const int sdRequestOpWriteDiscard = 0x03;

/// CRC status token 010, the block is accepted.
const int sdStatusCodeAccepted = 0x2;

/// CRC status token 101, the CRC16 of the block was wrong.
const int sdStatusCodeCrcError = 0x5;

/// CRC status token 110, the card could not write the block.
///
/// The card sends the token before the runtime has written anything, so no
/// path of this module can send this code today. The constant is here
/// because the three codes belong together, and a later phase that holds
/// the block back until the runtime answers can send it.
const int sdStatusCodeWriteError = 0x6;

/// Number of bits in one acknowledgement from the runtime.
///
/// The low [sdRequestSeqBits] bits carry the sequence tag of the record
/// that the acknowledgement retires. The bit above them says that the
/// runtime could not write the block.
const int sdWriteAckBits = sdRequestSeqBits + 1;

/// Bit number of the failure bit inside one acknowledgement.
const int sdWriteAckFailBit = sdRequestSeqBits;

/// Number of acknowledgements the acknowledge channel holds.
///
/// The card holds the host on busy for one block at a time, so one entry
/// carries the traffic. Four entries hold every late acknowledgement that
/// a timeout can leave behind, and the depth must be a power of two.
const int sdWriteAckFifoDepth = 4;

/// SD clocks the card holds the host on busy with no answer.
///
/// 4194304 clocks is 168 ms at 25 MHz. A Linux mmc host computes the write
/// timeout of an SD card from the CSD and uses 250 ms for a card that asks
/// for no more, so the card gives up before the host does. The value is
/// four times the read timeout because a write costs the runtime a disk
/// write as well as a USB round trip.
///
/// A test gives a small number here so that the timeout is reachable in a
/// simulation.
const int sdWriteTimeoutClocks = 1 << 22;

/// Write state 0: no write is in progress.
const int sdWriteStateIdle = 0;

/// Write state 1: the card waits for the block on DAT and takes it.
const int sdWriteStateRecv = 1;

/// Write state 2: the gap between the end bit of the block and the token.
const int sdWriteStateGap = 2;

/// Write state 3: the CRC status token goes out on DAT0.
const int sdWriteStateToken = 3;

/// Write state 4: the card waits for the runtime to take the block.
const int sdWriteStateWait = 4;

/// Number of bits in the write state register.
final int sdWriteStateBits = sdWriteStateWait.bitLength;

/// Number of bits in the counter of blocks that wait on the write channel.
///
/// The channel holds one block, so the count is 0 or 1 in every case the
/// hardware can reach. Two bits hold more than the channel can carry.
const int sdWriteTrackBits = 2;

/// The block write sequencer.
///
/// A pulse on `start` with the block address on `lba` opens one write. The
/// card takes the block, checks the CRC16 through the link, posts one
/// record and sends the CRC status token. A good block then holds DAT0 low
/// through `dat_busy` until the runtime acknowledges the record.
///
/// `ready` says the card can take a new write. It is low while a write
/// runs, while the card is disabled and while the write data channel still
/// holds a word, which `out_room` reports from the FIFO itself. The state
/// machine reads it and answers CMD24 with the ERROR bit when it is low,
/// so the host learns at once and never waits for a block the card will
/// not take.
///
/// When no acknowledgement comes
/// The card gives up after [timeoutClocks] SD clocks: it releases busy, it
/// pulses `failed`, which returns the card to the transfer state, and it
/// pulses `timeout_event`, which the SoC reports in the EVENT register.
/// The host then reads the card status and finds the card out of prg.
///
/// The block STAYS on the channel after such a timeout, because only the
/// runtime can take it off. `ready` therefore stays low until the runtime
/// answers, and every new write is refused with the ERROR bit until then.
/// A card that took a new write instead would push a second block into a
/// channel that holds one, and the two blocks would mix.
class MimicSdWritePath extends BridgeModule {
  /// SD clocks the card holds the host on busy with no answer.
  final int timeoutClocks;

  /// Makes the write sequencer.
  ///
  /// [timeoutClocks] defaults to [sdWriteTimeoutClocks]. A test gives a
  /// small number so that the timeout is reachable in a simulation.
  MimicSdWritePath({int? timeoutClocks, String? name})
    : timeoutClocks = timeoutClocks ?? sdWriteTimeoutClocks,
      super('MimicSdWritePath', name: name ?? 'sd_write_path') {
    if (this.timeoutClocks < 2) {
      throw ArgumentError.value(
        this.timeoutClocks,
        'timeoutClocks',
        'must be 2 or more. The counter is as wide as the count, and a '
            'timeout of 0 or 1 clock gives up before an answer can arrive.',
      );
    }
    if (sdRequestOpBits + sdRequestSeqBits + sdRequestBlocksBits > 32) {
      throw StateError(
        'Word 0 of a record holds a $sdRequestOpBits bit opcode, a '
        '$sdRequestSeqBits bit sequence tag and a $sdRequestBlocksBits bit '
        'block count, which does not fit in 32 bits.',
      );
    }
    if (sdRequestOpWriteBlocks >= (1 << sdRequestOpBits) ||
        sdRequestOpWriteDiscard >= (1 << sdRequestOpBits)) {
      throw StateError(
        'The write opcodes are $sdRequestOpWriteBlocks and '
        '$sdRequestOpWriteDiscard, and the opcode field is '
        '$sdRequestOpBits bits.',
      );
    }
    if (sdStatusCodeAccepted >= (1 << sdStatusCodeBits) ||
        sdStatusCodeCrcError >= (1 << sdStatusCodeBits) ||
        sdStatusCodeWriteError >= (1 << sdStatusCodeBits)) {
      throw StateError(
        'A CRC status code is $sdStatusCodeBits bits, and one of the three '
        'codes does not fit in it.',
      );
    }
    if (sdWriteAckBits <= sdWriteAckFailBit) {
      throw StateError(
        'The failure bit is bit $sdWriteAckFailBit of an acknowledgement of '
        '$sdWriteAckBits bits.',
      );
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // CTRL bit 0 of the CSR block, already brought into this clock domain
    // by the SoC. A card that the runtime has not enabled takes no write,
    // and clearing the bit releases a host that is held on busy.
    createPort('enable', PortDirection.input);

    // CTRL bit 4, also already in this clock domain. A 0 means
    // write-through, which holds the host on busy until the runtime has
    // taken the block. A 1 means write-back, which releases the host as
    // soon as the block is on the channel.
    createPort('write_back', PortDirection.input);

    createPort('start', PortDirection.input);
    createPort('lba', PortDirection.input, width: sdCommandArgBits);
    createPort('abort', PortDirection.input);

    // The receive side of the link. `rx_byte` holds one byte of the block
    // while `rx_byte_valid` is high, `rx_end` pulses after the last CRC bit
    // and `rx_crc_ok` holds the verdict of the block while that pulse is
    // high.
    createPort('rx_byte', PortDirection.input, width: 8);
    createPort('rx_byte_valid', PortDirection.input);
    createPort('rx_end', PortDirection.input);
    createPort('rx_crc_ok', PortDirection.input);

    // The write data channel, as the WRITE side of the FIFO reports it.
    // Both flags are in this clock domain already, because this module
    // drives the write side of that FIFO.
    //
    // `out_room` is high while the channel holds NO word. It is what
    // decides whether the card can take a new write: the count of records
    // the card keeps cannot say that, because a record and the 512 bytes
    // behind it are two different things and only the FIFO knows how many
    // bytes are still on it.
    //
    // `out_full` is the flag that the FIFO itself drives, and the FIFO
    // DROPS a push into a full channel. The count of words pushed reads it
    // so that it counts what the channel TOOK.
    createPort('out_room', PortDirection.input);
    createPort('out_full', PortDirection.input);

    // The acknowledge channel from the runtime. `ack_data` is the entry at
    // the head of the FIFO and `ack_empty` is its empty flag, both in this
    // clock domain.
    createPort('ack_data', PortDirection.input, width: sdWriteAckBits);
    createPort('ack_empty', PortDirection.input);

    // The link side.
    addOutput('rx_enable');
    addOutput('status_send');
    addOutput('status_code', width: sdStatusCodeBits);
    addOutput('dat_busy');

    // The SoC side: the record channel and the block channel.
    addOutput('req_data', width: sdRequestBits);
    addOutput('req_valid');
    addOutput('out_word', width: 32);
    addOutput('out_push');
    addOutput('ack_pop');

    // The state machine side.
    addOutput('busy');
    addOutput('ready');
    addOutput('done');
    addOutput('failed');
    addOutput('in_prg');
    addOutput('block_pushed');
    addOutput('timeout_event');

    final clk = input('clk');
    final reset = input('reset');

    final stateIdle = Const(sdWriteStateIdle, width: sdWriteStateBits);
    final stateRecv = Const(sdWriteStateRecv, width: sdWriteStateBits);
    final stateGap = Const(sdWriteStateGap, width: sdWriteStateBits);
    final stateToken = Const(sdWriteStateToken, width: sdWriteStateBits);
    final stateWait = Const(sdWriteStateWait, width: sdWriteStateBits);

    final state = Logic(name: 'write_state', width: sdWriteStateBits);

    // The three bytes of the word that is being built. The byte that
    // arrives goes in at the TOP and the register shifts right by one
    // byte, so byte 0 of a word ends up in bits 7 to 0. That is the little
    // endian order the read channel already uses.
    final accum = Logic(name: 'write_accum', width: 24);
    final byteSel = Logic(name: 'write_byte_sel', width: 2);
    final oneByteSel = Const(1, width: 2);
    final lastByteOfWord = byteSel
        .eq(Const(3, width: 2))
        .named('write_last_byte_of_word');

    // The block address of the write that is running, and the verdict of
    // the CRC16 of its block.
    final lbaReg = Logic(name: 'write_lba', width: sdCommandArgBits);
    final crcGood = Logic(name: 'write_crc_good');

    // The write policy of the write that is running. It is read with the
    // start pulse, so a runtime that changes CTRL in the middle of a write
    // cannot move a host that is already on busy.
    final writeBackReg = Logic(name: 'write_back_reg');

    // High once a byte of the block has arrived. The link cannot stop in
    // the middle of a block, so an abort is only safe before the first
    // byte: after it, the block runs to its end bit and the card posts the
    // record for it.
    final rxOpen = Logic(name: 'write_rx_open');

    // Blocks that are on the channel and that the runtime has not taken.
    // It holds at the top rather than wrapping, because a wrap would let
    // the card take a write into a channel that is already full.
    final onChannel = Logic(name: 'write_on_channel', width: sdWriteTrackBits);
    final zeroBlocks = Const(0, width: sdWriteTrackBits);
    // The TOP of the counter, which is every bit set. The counter holds
    // there instead of wrapping, and the name says what the value is: it
    // is the largest number the register can carry and not a limit on the
    // blocks that the channel takes. `out_room` above is what holds the
    // channel to one block.
    final countTop = Const(1, width: sdWriteTrackBits, fill: true);

    // The tag of the record the card waits for.
    //
    // The counter moves on every write the card takes and steps over
    // [sdRequestSeqNone] on a wrap, so that value names no record at any
    // time. An acknowledgement that carries it therefore matches nothing.
    final seq = Logic(name: 'write_seq', width: sdRequestSeqBits);
    final oneSeq = Const(1, width: sdRequestSeqBits);
    final lastSeq = Const(1, width: sdRequestSeqBits, fill: true);
    final firstSeq = Const(sdRequestSeqNone + 1, width: sdRequestSeqBits);
    final seqNext = mux(
      seq.eq(lastSeq),
      firstSeq,
      seq + oneSeq,
    ).named('write_seq_next');

    final timerBits = (this.timeoutClocks - 1).bitLength;
    final timer = Logic(name: 'write_timer', width: timerBits);
    final oneTick = Const(1, width: timerBits);
    final zeroTicks = Const(0, width: timerBits);
    final timerLast = Const(this.timeoutClocks - 1, width: timerBits);
    final timerDone = timer.gte(timerLast).named('write_timer_done');

    final donePulse = Logic(name: 'write_done_pulse');
    final failedPulse = Logic(name: 'write_failed_pulse');
    final pushedPulse = Logic(name: 'write_pushed_pulse');
    final timeoutPulse = Logic(name: 'write_timeout_pulse');

    final inIdle = state.eq(stateIdle).named('write_in_idle');
    final inRecv = state.eq(stateRecv).named('write_in_recv');
    final inToken = state.eq(stateToken).named('write_in_token');
    final inWait = state.eq(stateWait).named('write_in_wait');

    final enable = input('enable');
    final channelClear = onChannel.eq(zeroBlocks).named('write_channel_clear');

    // The card takes a write only from idle, with the channel clear and
    // with the runtime holding the card enabled. A block the runtime has
    // not taken yet keeps this low, because the channel holds exactly one
    // block and a second one would mix with it.
    //
    // `out_room` is the FIFO ITSELF, and it is what makes this safe. The
    // count of records above moves on every acknowledgement, whatever the
    // acknowledgement named, so one write of WRITE_ACK that named nothing
    // took that count to 0 while 512 bytes were still on the channel. The
    // card then took the next write, the FIFO dropped all 128 pushes of
    // that block because it was full, and the runtime read the OLD block
    // and wrote it at the address of the NEW one. The FIFO cannot be
    // talked into saying it is empty, so it is read here as well.
    final ready = (inIdle & channelClear & enable & input('out_room')).named(
      'write_ready',
    );
    final takeStart = (ready & input('start')).named('write_take_start');

    // The receive window. The link starts a block only while this is high,
    // and the class doc of [MimicSdLink] asks the personality to hold it
    // high until the end of the block.
    output('rx_enable') <= inRecv;

    // One word leaves for the channel on every fourth byte. The word is
    // built here and not from the register alone, because the byte that
    // completes it is on the port in this same clock.
    final pushWord = [
      input('rx_byte'),
      accum,
    ].swizzle().named('write_push_word');
    final pushNow = (inRecv & input('rx_byte_valid') & lastByteOfWord).named(
      'write_push_now',
    );
    output('out_word') <= pushWord;
    output('out_push') <= pushNow;

    // The push that the channel TOOK. The FIFO drops a push into a full
    // channel, so a count of the pushes OFFERED would tell the runtime
    // that words are waiting which the channel never holds. This is the
    // shape the read direction already uses for its own free space count.
    final pushAccepted = (pushNow & ~input('out_full')).named(
      'write_push_accepted',
    );

    // The end of the block. `rx_crc_ok` carries the verdict of the block
    // only while `rx_end` is high, so both terms are read in this clock.
    final blockEnd = (inRecv & input('rx_end')).named('write_block_end');

    // The record. It carries ONE block, the tag of this write and the
    // opcode that says whether the runtime writes the block or drops it.
    final reqOp = mux(
      input('rx_crc_ok'),
      Const(sdRequestOpWriteBlocks, width: sdRequestOpBits),
      Const(sdRequestOpWriteDiscard, width: sdRequestOpBits),
    ).named('write_req_op');
    final reqWord0 = [
      Const(1, width: sdRequestBlocksBits),
      seq,
      reqOp,
    ].swizzle().named('write_req_word0');
    output('req_data') <= [lbaReg, reqWord0].swizzle();
    output('req_valid') <= blockEnd;

    // The CRC status token. It goes out one clock after the end bit, which
    // gives the two clock gap (Nwr) the specification asks for.
    output('status_send') <= inToken;
    output('status_code') <=
        mux(
          crcGood,
          Const(sdStatusCodeAccepted, width: sdStatusCodeBits),
          Const(sdStatusCodeCrcError, width: sdStatusCodeBits),
        );

    // Busy on DAT0. This is the whole point of the write path: the card
    // holds the line low and the host waits, and the round trip to the
    // runtime happens inside that wait.
    //
    // A bad block gets NO busy, because a real card refuses such a block
    // and never programs it. Write-back gets no busy either, because the
    // buffer has already accepted the block.
    final busyHold = (inWait & crcGood & ~writeBackReg).named(
      'write_busy_hold',
    );
    output('dat_busy') <= busyHold;

    // The acknowledge channel. The card takes an entry whenever one is
    // there, in any state, because a late acknowledgement still retires
    // the block that the runtime took off the channel.
    final ackTake = (~input('ack_empty')).named('write_ack_take');
    final ackTag = input('ack_data')
        .getRange(0, sdRequestSeqBits)
        .named('write_ack_tag');
    final ackMatch = ackTag.eq(seq).named('write_ack_match');

    // The acknowledgement that retires the write the card is holding the
    // host for. Only a tag that names THIS record releases busy, so a late
    // or a repeated acknowledgement can never retire the wrong block.
    final ackRetire = (inWait & ackTake & ackMatch).named('write_ack_retire');

    output('ack_pop') <= ackTake;

    // The card leaves a write as soon as the state machine aborts it or
    // the runtime drops CTRL bit 0. An abort in the middle of a block is
    // NOT one of these: the link cannot stop inside a frame, so a block
    // that is already open runs to its end bit and the runtime is asked to
    // take it.
    final stopped = (input('abort') | ~enable).named('write_stopped');
    final release = ((inRecv & ~rxOpen & stopped) | (inWait & stopped)).named(
      'write_release',
    );

    // The timer runs while the card waits for something outside itself:
    // the block from the host, and the acknowledgement from the runtime.
    // It does not run inside a block, which takes a fixed 4114 clocks.
    final timerRuns = ((inRecv & ~rxOpen) | inWait).named('write_timer_runs');

    Sequential(
      clk,
      reset: reset,
      resetValues: {
        state: stateIdle,
        accum: Const(0, width: 24),
        byteSel: Const(0, width: 2),
        lbaReg: Const(0, width: sdCommandArgBits),
        crcGood: Const(0),
        writeBackReg: Const(0),
        rxOpen: Const(0),
        onChannel: zeroBlocks,
        seq: Const(sdRequestSeqNone, width: sdRequestSeqBits),
        timer: zeroTicks,
        donePulse: Const(0),
        failedPulse: Const(0),
        pushedPulse: Const(0),
        timeoutPulse: Const(0),
      },
      [
        donePulse < Const(0),
        failedPulse < Const(0),
        pushedPulse < Const(0),
        timeoutPulse < Const(0),

        // The count of blocks on the channel, in ONE expression. A block
        // can reach the channel on the same clock an acknowledgement takes
        // one off, and both moves must land. Two statements would not: a
        // later write in one Sequential overrides an earlier one whole.
        onChannel <
            onChannel +
                (blockEnd & onChannel.lt(countTop)).zeroExtend(
                  sdWriteTrackBits,
                ) -
                (ackTake & onChannel.neq(zeroBlocks)).zeroExtend(
                  sdWriteTrackBits,
                ),

        // The byte that arrives goes into the word being built. This is
        // WRAPPED, because a flat write would shift the register on every
        // clock of the block and lose the bytes between the pulses.
        If(
          inRecv & input('rx_byte_valid'),
          then: [
            accum < [input('rx_byte'), accum.slice(23, 8)].swizzle(),
            byteSel < byteSel + oneByteSel,
            rxOpen < Const(1),
          ],
        ),
        If(pushAccepted, then: [pushedPulse < Const(1)]),

        Case(state, [
          CaseItem(stateIdle, [
            If(
              takeStart,
              then: [
                state < stateRecv,
                timer < zeroTicks,
                seq < seqNext,
                lbaReg < input('lba'),
                writeBackReg < input('write_back'),
                byteSel < Const(0, width: 2),
                accum < Const(0, width: 24),
                rxOpen < Const(0),
                crcGood < Const(0),
              ],
            ),
          ]),
          CaseItem(stateRecv, [
            If(timerRuns, then: [timer < timer + oneTick]),
            If(
              release,
              then: [
                // The state machine took the card out of the receive
                // state, or the runtime dropped CTRL bit 0. No byte has
                // arrived, so nothing is on the channel and no record is
                // posted.
                state < stateIdle,
                timer < zeroTicks,
                failedPulse < Const(1),
              ],
              orElse: [
                If(
                  blockEnd,
                  then: [
                    // The record went out on this same clock. The verdict
                    // is caught here, because `rx_crc_ok` holds it only
                    // while `rx_end` is high.
                    crcGood < input('rx_crc_ok'),
                    state < stateGap,
                    timer < zeroTicks,
                    rxOpen < Const(0),
                  ],
                  orElse: [
                    If(
                      timerRuns & timerDone,
                      then: [
                        // The host never sent the block. The card gives
                        // up and sends no token at all, which is what a
                        // real card does when it sees no start bit.
                        state < stateIdle,
                        timer < zeroTicks,
                        failedPulse < Const(1),
                        timeoutPulse < Const(1),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ]),
          CaseItem(stateGap, [state < stateToken]),
          CaseItem(stateToken, [
            // The token is on `status_send` in this clock. The link takes
            // it, because nothing else drives DAT0 here.
            timer < zeroTicks,
            If(
              crcGood & ~writeBackReg,
              then: [
                // Write-through. The card holds the host on busy until
                // the runtime has taken the block.
                state < stateWait,
              ],
              orElse: [
                // A block the card refused, or write-back. Neither holds
                // the host: a real card programs nothing after a bad
                // CRC16, and write-back counts the block as done as soon
                // as the buffer holds it.
                //
                // The card returns to the transfer state at once, and the
                // record STAYS on the channel: `ready` is low until the
                // runtime takes it, so the next write is refused with the
                // ERROR bit and no block is ever mixed with another.
                state < stateIdle,
                If(
                  crcGood,
                  then: [donePulse < Const(1)],
                  orElse: [failedPulse < Const(1)],
                ),
              ],
            ),
          ]),
          CaseItem(stateWait, [
            timer < timer + oneTick,
            If(
              ackRetire,
              then: [
                // The runtime took the block. Busy releases on the next
                // clock and the card returns to the transfer state.
                state < stateIdle,
                timer < zeroTicks,
                donePulse < Const(1),
              ],
              orElse: [
                If(
                  release,
                  then: [
                    // An operator stopped the card, or the state machine
                    // aborted the write. The host must not wait out the
                    // timeout. There is no `timeout_event` here, because
                    // EVENT bit 1 reports a runtime that never answered.
                    state < stateIdle,
                    timer < zeroTicks,
                    failedPulse < Const(1),
                  ],
                  orElse: [
                    If(
                      timerDone,
                      then: [
                        // No answer came. Busy releases, the card returns
                        // to the transfer state and the event tells the
                        // runtime what happened. The block STAYS on the
                        // channel, so `ready` holds the next write off
                        // until the runtime takes it.
                        state < stateIdle,
                        timer < zeroTicks,
                        failedPulse < Const(1),
                        timeoutPulse < Const(1),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ]),
        ]),
      ],
    );

    output('busy') <= ~inIdle;
    output('ready') <= ready;
    output('done') <= donePulse;
    output('failed') <= failedPulse;
    // One pulse for each word that the channel TOOK. See [pushAccepted].
    output('block_pushed') <= pushedPulse;
    output('timeout_event') <= timeoutPulse;

    // The card is programming. The state machine reads it and puts the
    // card in the prg state, which is what CMD13 reports to a host that
    // polls for the end of a write.
    output('in_prg') <= busyHold;

    if (sdBlockWords * 4 != 512) {
      throw StateError(
        'A block is ${sdBlockWords * 4} bytes on the channel and the link '
        'frames 512 bytes. The two must agree.',
      );
    }
  }
}
