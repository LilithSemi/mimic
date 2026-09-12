// MimicSdCardDevice: the SD card personality, link plus state machine.
//
// This module is the whole card as far as the SD bus is concerned. It holds
// [MimicSdLink], which owns the wire, and [MimicSdCardFsm], which owns the
// meaning, and it connects the two. A host that drives the pins of this
// module sees a card that answers the identification commands and ends in
// the transfer state.
//
// Ports stay split (`sd_cmd_in`, `sd_cmd_out`, `sd_cmd_oe`, and the same
// three names for DAT). The board level owns the tristate, in the same
// shape as MimicUsbDevice. A split port is also much easier to drive from
// a ROHD test than a shared bidirectional net.
//
// All logic here runs in the SD clock domain, which the host drives.

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'package:harbor/harbor.dart';

import 'sd_block_cache.dart';
import 'sd_card_fsm.dart';
import 'sd_debug.dart';
import 'sd_link.dart';
import '../sd_regs.dart' show sdSwitchStatusBytes;
import 'sd_read_path.dart';
import 'sd_write_path.dart';
import 'sd_reg_tx.dart';

/// The SD card personality: the link layer under the card state machine.
///
/// The command path runs up: the link frames a command on CMD, checks its
/// CRC7 and pulses `cmd_valid`, and the state machine reads `cmd_index`,
/// `cmd_arg` and `cmd_crc_ok` in that clock. The response path runs down:
/// the state machine raises `resp_start` with `resp_data` and `resp_kind`,
/// and the link sends the frame back on CMD. `resp_busy` closes the loop,
/// so the state machine starts a response only while the link is free.
///
/// `card_state` reports the state register of the state machine. It is an
/// observation port. Nothing on the SD bus reads it.
///
/// `csd` and `csd_valid` carry the CSD register that CMD9 answers with.
/// The runtime owns the personality of the card, so it writes the whole
/// 128-bit register over the CSR block and the SoC moves the value into
/// this clock domain. This module holds the destination register of that
/// crossing: it loads all 128 bits on one clock while `csd_valid` is high,
/// and it holds the DEFAULT CSD until the first such clock. A host that
/// probes the card before the runtime writes anything therefore still
/// reads a card that identifies.
///
/// The CSD that arrives is already whole. [MimicSdCard] commits its four
/// CSR words into a shadow register on one bus clock, and the crossing
/// carries that shadow, so the card cannot send a CSD that is part old and
/// part new.
///
/// The data receive path of the link and the CRC status token are off in
/// this phase. The three inputs that start them are held low here, because
/// an input that nothing drives holds X and the X reaches the receive
/// registers as soon as the host pulls DAT low. The write path of phase 3
/// replaces the constants with the signals of a card personality that
/// takes a block.
///
/// The block READ path is on. [MimicSdReadPath] posts one request record
/// per CMD17 and feeds the block it gets back to the link. Both channels
/// are FIFOs the SoC owns, and this module drives their SD ends:
/// `req_data` with `req_valid` pushes a record, and `data_pop` takes one
/// word off the data channel with the word on `data_word`.
///
/// Values come the other way, from the SoC clock domain into this one.
/// `card_enable` is CTRL bit 0, a single bit that crosses through a
/// two-flop synchroniser HERE and not in the SoC, because a two-flop
/// synchroniser needs the DESTINATION clock alone and this module is the
/// destination. `data_blocks_pushed_gray` is the COUNT of whole blocks the
/// runtime has pushed, and it crosses here as well, through the gray
/// synchroniser that every free running counter of this design uses. The
/// CSD goes the other way and crosses in the SoC, because a handshake
/// needs both clocks.
///
/// The block count is a COUNT and not a pulse or a level. The two clocks
/// have no ratio, and the host stops this one whenever it likes: a level
/// that inverts once per block loses every event but the last one when the
/// runtime pushes several blocks while the clock stands still, and the
/// card would then wait for a block it already holds. A gray coded count
/// carries the whole number, so a card whose clock starts again reads
/// everything it missed.
class MimicSdCardDevice extends BridgeModule {
  /// Number of data lines. Only 1 is legal today.
  ///
  /// The value goes to [MimicSdLink], which refuses every other width
  /// because its receive datapath reads DAT0 alone. The DAT ports of this
  /// module follow the same width, so the pins and the link cannot
  /// disagree.
  final int busWidth;

  /// Makes the card personality.
  ///
  /// [decode] replaces the command set of [MimicSdCardFsm]. It defaults to
  /// the command set of that module, which is the identification set.
  ///
  /// [cid] is the CID register that CMD2 answers with. The build resolves
  /// the manufacture date inside it and passes the whole register down. It
  /// defaults to [sdCardCidValue], the CID of a build that named no date.
  /// SD clocks the read path waits for the answer to one request.
  ///
  /// It defaults to [sdReadTimeoutClocks]. A test gives a small number so
  /// that the timeout is reachable in a simulation.
  final int readTimeoutClocks;

  /// SD clocks the write path holds the host on busy with no answer.
  ///
  /// It defaults to [sdWriteTimeoutClocks]. A test gives a small number so
  /// that the timeout is reachable in a simulation.
  final int writeTimeoutClocks;

  /// Number of lines in the block cache. See [MimicSdBlockCache].
  final int cacheLines;

  MimicSdCardDevice({
    this.busWidth = 1,
    String? name,
    SdCommandDecode? decode,
    BigInt? cid,
    int? readTimeoutClocks,
    int? writeTimeoutClocks,
    int? cacheLines,
  }) : readTimeoutClocks = readTimeoutClocks ?? sdReadTimeoutClocks,
       writeTimeoutClocks = writeTimeoutClocks ?? sdWriteTimeoutClocks,
       cacheLines = cacheLines ?? sdCacheDefaultLines,
       super('MimicSdCardDevice', name: name ?? 'sd_card_device') {
    if (busWidth != 1) {
      // MimicSdLink refuses every width but 1, because its receive
      // datapath reads DAT0 alone. Check the width here too, ahead of the
      // createPort calls below, so a bad width gives this message and not
      // a raw ROHD port width error.
      throw ArgumentError.value(
        busWidth,
        'busWidth',
        'must be 1. The receive path is 1-bit only. Widths 4 and 8 are '
            'planned and need a per-line receive datapath first.',
      );
    }
    if (sdCardCsdValue.bitLength > sdResponseRegBits) {
      // Const truncates a value that is too wide with no message, and a
      // truncated CSD is a card that reports a capacity it does not have.
      throw StateError(
        'The default CSD needs ${sdCardCsdValue.bitLength} bits and the CSD '
        'register is $sdResponseRegBits bits.',
      );
    }
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('sd_cmd_in', PortDirection.input);
    createPort('sd_dat_in', PortDirection.input, width: busWidth);
    createPort('csd', PortDirection.input, width: sdResponseRegBits);
    createPort('csd_valid', PortDirection.input);

    // The block read channels. `card_enable` and `data_blocks_pushed_gray`
    // are RAW signals of the SoC clock domain and cross in this module.
    // See the class doc.
    createPort('card_enable', PortDirection.input);
    createPort('data_word', PortDirection.input, width: 32);
    createPort('data_empty', PortDirection.input);
    createPort(
      'data_blocks_pushed_gray',
      PortDirection.input,
      width: sdBlockCountBits,
    );

    // The tag channel. It is a FIFO of its own beside the data channel and
    // the SoC owns it, so this module drives its read side. One entry
    // holds the sequence tag of one block. `data_tag_empty` is the empty
    // flag of that FIFO, in THIS clock domain, and an empty channel names
    // no request at all.
    createPort('data_tag', PortDirection.input, width: sdRequestSeqBits);
    createPort('data_tag_empty', PortDirection.input);

    // The FILL address that travels with the tag, and whether the tag
    // channel carries one for this block.
    //
    // A block whose tag is [sdRequestSeqNone] answers no request. That is
    // what a FILL is: the runtime pushed a block that nobody asked for, so
    // that a later read of it is a hit. The address of the block therefore
    // cannot come from a record, and it travels beside the tag through the
    // SAME channel. One entry names one block, so a fill can never take
    // the address of another push.
    createPort('data_fill_lba', PortDirection.input, width: sdCommandArgBits);
    createPort('data_fill_valid', PortDirection.input);

    // The block WRITE channels. `out_word` with `out_push` puts one word of
    // a block that the host wrote into the channel that carries it to the
    // runtime, and the acknowledge channel brings the answer back. CTRL bit
    // 4 is a raw SoC domain level and crosses in this module, the way CTRL
    // bit 0 does.
    createPort('write_back', PortDirection.input);
    // The two flags of the WRITE side of that channel. `out_room` is high
    // while the channel holds no word, and the card refuses a new write
    // while it is low: only the FIFO knows how many bytes are still on the
    // channel. `out_full` is the flag the FIFO drives, and the card counts
    // the pushes that it TOOK, because a full channel drops a push. Both
    // belong to the SD clock domain, which is where the FIFO is written.
    createPort('out_room', PortDirection.input);
    createPort('out_full', PortDirection.input);
    createPort('ack_data', PortDirection.input, width: sdWriteAckBits);
    createPort('ack_empty', PortDirection.input);

    addOutput('req_data', width: sdRequestBits);
    addOutput('req_valid');
    addOutput('data_pop');
    addOutput('data_tag_pop');
    addOutput('out_word', width: 32);
    addOutput('out_push');
    addOutput('ack_pop');

    // WORDS the card has taken off the data channel, as a GRAY CODE. The
    // SoC turns it back into a count and reports the free space of the
    // channel from it. It counts in this clock domain, which the host
    // stops, so it crosses the way the bring-up counters do.
    //
    // WORDS and not blocks. A count that moved a block at a time reported
    // the same free space through the whole 4114 clock send of a block,
    // which is 165 us at 25 MHz, so a runtime that read it learned nothing
    // and polled the link hundreds of times for one block. This count
    // moves as the block drains.
    addOutput('words_consumed_gray', width: sdDataWordCountBits);

    // Words the card has pushed into the write channel, as a GRAY CODE. The
    // SoC turns it back into a count and reports the words waiting from it.
    // It counts in this clock domain, which the host stops, so it crosses
    // the way the bring-up counters do.
    addOutput('words_written_gray', width: sdDataWordCountBits);

    // A read that no answer came for, published as a LEVEL that inverts
    // once per event, for the same reason `sd_activity_toggle` is a level.
    addOutput('read_timeout_toggle');

    // A write that the runtime never acknowledged, published the same way.
    addOutput('write_timeout_toggle');

    addOutput('sd_cmd_out');
    addOutput('sd_cmd_oe');
    addOutput('sd_dat_out', width: busWidth);
    addOutput('sd_dat_oe');
    addOutput('card_state', width: sdCardStateBits);

    // The bring-up counters, published as GRAY CODES. Each one counts in
    // this clock domain, which the host owns and stops, so the SoC cannot
    // read the count directly. See sd_debug.dart for why a gray code and
    // not a synchroniser per bit or a handshake.
    addOutput('dbg_sd_clk_gray', width: sdDbgClkBits);
    addOutput('dbg_sd_cmd_gray', width: sdDbgEventBits);
    addOutput('dbg_sd_crc_err_gray', width: sdDbgEventBits);
    addOutput('dbg_sd_resp_gray', width: sdDbgEventBits);

    // The three block cache counters, published as GRAY CODES for the
    // reason the bring-up counters are. A hit rate that nobody can read is
    // a cache nobody can tune, and the DBG_SD counters have already turned
    // one all-day hardware mystery into a two-minute diagnosis.
    addOutput('dbg_cache_hit_gray', width: sdDbgEventBits);
    addOutput('dbg_cache_miss_gray', width: sdDbgEventBits);
    addOutput('dbg_cache_fill_gray', width: sdDbgEventBits);

    // The SD activity event for the board LED. It is a level that inverts
    // once per event, not a pulse. See where it is built, below.
    addOutput('sd_activity_toggle');

    final clk = input('clk');
    final reset = input('reset');

    final link = MimicSdLink(busWidth: busWidth, name: 'sd_link');
    addSubModule(link);
    final fsm = MimicSdCardFsm(name: 'sd_card_fsm', decode: decode, cid: cid);
    addSubModule(fsm);

    link.input('clk').srcConnection! <= clk;
    link.input('reset').srcConnection! <= reset;
    fsm.input('clk').srcConnection! <= clk;
    fsm.input('reset').srcConnection! <= reset;

    // The pins. The link samples inputs on the rising edge. Card outputs are
    // launched on the falling edge, which gives the host half an SD clock of
    // setup time before it samples the next rising edge. Driving the pads
    // directly from positive-edge state makes both ends use the same edge and
    // leaves hardware correctness to clock-tree and pad delay.
    link.input('cmd_in').srcConnection! <= input('sd_cmd_in');
    link.input('dat_in').srcConnection! <= input('sd_dat_in');
    final cmdOut = Logic(name: 'sd_cmd_out_negedge');
    final cmdOe = Logic(name: 'sd_cmd_oe_negedge');
    final datOut = Logic(name: 'sd_dat_out_negedge', width: busWidth);
    final datOe = Logic(name: 'sd_dat_oe_negedge');
    Sequential.multi(
      const [],
      negedgeTriggers: [clk],
      reset: reset,
      asyncReset: true,
      resetValues: {
        cmdOut: Const(1),
        cmdOe: Const(0),
        datOut: Const(1, width: busWidth, fill: true),
        datOe: Const(0),
      },
      [
        cmdOut < link.output('cmd_out'),
        cmdOe < link.output('cmd_oe'),
        datOut < link.output('dat_out'),
        datOe < link.output('dat_oe'),
      ],
    );
    // Hold the external bus released while reset stands. This also covers a
    // clock that has not produced its first falling edge yet.
    output('sd_cmd_out') <= mux(reset, Const(1), cmdOut);
    output('sd_cmd_oe') <= mux(reset, Const(0), cmdOe);
    output('sd_dat_out') <=
        mux(reset, Const(1, width: busWidth, fill: true), datOut);
    output('sd_dat_oe') <= mux(reset, Const(0), datOe);

    // The command path, link to state machine. The four signals belong to
    // one clock: `cmd_valid` is a pulse of one clock and the other three
    // hold the result of that frame while the pulse is high.
    fsm.input('cmd_index').srcConnection! <= link.output('cmd_index');
    fsm.input('cmd_arg').srcConnection! <= link.output('cmd_arg');
    fsm.input('cmd_valid').srcConnection! <= link.output('cmd_valid');
    fsm.input('cmd_crc_ok').srcConnection! <= link.output('cmd_crc_ok');

    // The response path, state machine to link, and the busy line back.
    // The link drops a pulse on `resp_start` that comes while `resp_busy`
    // is high, and the state machine reads the same `resp_busy` to hold
    // its answer until the link is free, so the two agree on the slot.
    link.input('resp_start').srcConnection! <= fsm.output('resp_start');
    link.input('resp_data').srcConnection! <= fsm.output('resp_data');
    link.input('resp_kind').srcConnection! <= fsm.output('resp_kind');
    fsm.input('resp_busy').srcConnection! <= link.output('resp_busy');

    // The two single-bit values that come out of the SoC clock domain.
    // Each one is quasi-static or a level, so a two-flop synchroniser per
    // bit is the right crossing and it needs the destination clock alone.
    final writeBackSync = HarborCdcSync(name: 'write_back_sync');
    addSubModule(writeBackSync);
    writeBackSync.input('async_in').srcConnection! <= input('write_back');
    writeBackSync.input('dst_clk').srcConnection! <= clk;
    writeBackSync.input('dst_reset').srcConnection! <= reset;
    final writeBack = writeBackSync.output('sync_out').named('write_back_sd');

    final enableSync = HarborCdcSync(name: 'card_enable_sync');
    addSubModule(enableSync);
    enableSync.input('async_in').srcConnection! <= input('card_enable');
    enableSync.input('dst_clk').srcConnection! <= clk;
    enableSync.input('dst_reset').srcConnection! <= reset;
    final cardEnable = enableSync.output('sync_out').named('card_enable_sd');

    // The count of whole blocks the runtime has pushed, brought into this
    // clock domain. It is a free running counter of the SoC domain, so it
    // takes the gray road that every other count of this design takes.
    final blocksPushedSync = MimicSdGraySync(
      width: sdBlockCountBits,
      name: 'data_blocks_pushed_sync',
    );
    addSubModule(blocksPushedSync);
    blocksPushedSync.input('gray_in').srcConnection! <=
        input('data_blocks_pushed_gray');
    blocksPushedSync.input('clk').srcConnection! <= clk;
    blocksPushedSync.input('reset').srcConnection! <= reset;
    final blocksPushed = blocksPushedSync.output('count');

    // One tag leaves the tag channel for each block the card TAKES, so the
    // head of the tag channel always names the head of the data channel.
    //
    // It is the TAKE and not the arrival. The data channel holds several
    // blocks, so a register loaded when a block arrived would hold the tag
    // of the block that arrived LAST and the card would read it as the tag
    // of the block at the head.
    //
    // The tag FIFO and data FIFO pointers cross independently. The completed
    // block count starts crossing after both entries are committed, but it
    // does not impose an order on the two FIFO synchronisers. The read path
    // therefore also waits for this tag channel to become nonempty.
    final blockTag = mux(
      input('data_tag_empty'),
      Const(sdRequestSeqNone, width: sdRequestSeqBits),
      input('data_tag'),
    ).named('data_tag_value');

    // The fill address travels with the tag. An EMPTY channel carries no
    // address at all, so a block that arrives with nothing in the channel
    // is a block nobody can place and the card throws it away, which is
    // what it has always done with an untagged block.
    final blockFillLba = mux(
      input('data_tag_empty'),
      Const(0, width: sdCommandArgBits),
      input('data_fill_lba'),
    ).named('data_fill_lba_value');
    final blockFillValid = (~input('data_tag_empty') & input('data_fill_valid'))
        .named('data_fill_valid_value');

    // The block read sequencer. It sits between the state machine, which
    // decides that a read starts, and the link, which puts the bytes on
    // the wire.
    final readPath = MimicSdReadPath(
      timeoutClocks: this.readTimeoutClocks,
      name: 'sd_read_path',
    );
    addSubModule(readPath);
    readPath.input('clk').srcConnection! <= clk;
    readPath.input('reset').srcConnection! <= reset;
    readPath.input('enable').srcConnection! <= cardEnable;
    readPath.input('start').srcConnection! <= fsm.output('read_start');
    readPath.input('lba').srcConnection! <= fsm.output('read_lba');
    readPath.input('abort').srcConnection! <= fsm.output('read_abort');
    readPath.input('cmd_busy').srcConnection! <= link.output('resp_busy');
    readPath.input('data_word').srcConnection! <= input('data_word');
    readPath.input('data_empty').srcConnection! <= input('data_empty');
    readPath.input('block_tag_empty').srcConnection! <= input('data_tag_empty');
    readPath.input('blocks_pushed').srcConnection! <= blocksPushed;
    readPath.input('block_tag').srcConnection! <= blockTag;
    // One tag leaves the tag channel for each block the card takes. See
    // the comment above [blockTag].
    output('data_tag_pop') <= readPath.output('block_take');
    readPath.input('tx_next').srcConnection! <= link.output('dat_tx_next');
    readPath.input('tx_done').srcConnection! <= link.output('dat_tx_done');
    readPath.input('multi').srcConnection! <= fsm.output('read_multi');
    readPath.input('block_fill_lba').srcConnection! <= blockFillLba;
    readPath.input('block_fill_valid').srcConnection! <= blockFillValid;

    // The block cache. It sits beside the read path and holds the blocks
    // the runtime chose to leave on the card. A read that it holds costs
    // NO record and no USB round trip at all, which is the whole reason it
    // is here.
    //
    // The card does the LOOKUP and no policy: the host chooses what
    // occupies every line, through the fill path, and the card never
    // evicts a line by itself. The one exception is a WRITE to a line the
    // cache holds, below, and the runtime sees that write as a record on
    // the channel it already reads, so its model of the store follows with
    // no synchronisation of any kind.
    final cache = MimicSdBlockCache(lines: this.cacheLines, name: 'sd_cache');
    addSubModule(cache);
    cache.input('clk').srcConnection! <= clk;
    cache.input('reset').srcConnection! <= reset;
    cache.input('lookup').srcConnection! <= readPath.output('cache_lookup');
    cache.input('lookup_lba').srcConnection! <=
        readPath.output('cache_lookup_lba');
    cache.input('rd_next').srcConnection! <= readPath.output('cache_rd_next');
    cache.input('fill_start').srcConnection! <=
        readPath.output('cache_fill_start');
    cache.input('fill_lba').srcConnection! <= readPath.output('cache_fill_lba');
    cache.input('fill_word').srcConnection! <=
        readPath.output('cache_fill_word');
    cache.input('fill_push').srcConnection! <=
        readPath.output('cache_fill_push');
    readPath.input('cache_hit').srcConnection! <= cache.output('hit');
    readPath.input('cache_hit_valid').srcConnection! <=
        cache.output('hit_valid');
    readPath.input('cache_word').srcConnection! <= cache.output('rd_word');

    // A WRITE must not leave stale data behind. CMD24 to a block the cache
    // holds INVALIDATES that line, and it does not update it.
    //
    // Invalidate and not update, for two reasons. A write can FAIL: the
    // runtime may refuse the block or never acknowledge it, and a line
    // that had been updated would then hold data the image does not have,
    // which is the one fault a cache must never have. And an update would
    // need the 512 bytes of the write to run into the cache in parallel
    // with the channel, which is a second write port on the data store.
    // The cost of invalidating is one miss, which is one round trip.
    //
    // The tag is compared, so a write to a block that maps to a line
    // holding ANOTHER block leaves that line alone.
    cache.input('inval').srcConnection! <= fsm.output('write_start');
    cache.input('inval_lba').srcConnection! <= fsm.output('write_lba');

    // CMD0 throws the whole store away. A card that a new host
    // re-identifies must not answer out of the store the last host filled,
    // and reset does the same through the valid bits.
    cache.input('inval_all').srcConnection! <= fsm.output('go_idle');

    // The block write sequencer. It is the mirror of the read path: it
    // takes the 512 bytes the host sends, checks the CRC16 through the
    // link, posts one record and holds DAT0 low until the runtime has
    // taken the block.
    final writePath = MimicSdWritePath(
      timeoutClocks: this.writeTimeoutClocks,
      name: 'sd_write_path',
    );
    addSubModule(writePath);
    writePath.input('clk').srcConnection! <= clk;
    writePath.input('reset').srcConnection! <= reset;
    writePath.input('enable').srcConnection! <= cardEnable;
    writePath.input('write_back').srcConnection! <= writeBack;
    writePath.input('start').srcConnection! <= fsm.output('write_start');
    writePath.input('lba').srcConnection! <= fsm.output('write_lba');
    writePath.input('abort').srcConnection! <= fsm.output('write_abort');
    writePath.input('rx_byte').srcConnection! <= link.output('dat_byte');
    writePath.input('rx_byte_valid').srcConnection! <=
        link.output('dat_byte_valid');
    writePath.input('rx_end').srcConnection! <= link.output('dat_block_end');
    writePath.input('rx_crc_ok').srcConnection! <= link.output('dat_crc_ok');
    writePath.input('out_room').srcConnection! <= input('out_room');
    writePath.input('out_full').srcConnection! <= input('out_full');
    writePath.input('ack_data').srcConnection! <= input('ack_data');
    writePath.input('ack_empty').srcConnection! <= input('ack_empty');

    // The receive side of the link and the CRC status token belong to the
    // write path alone, so they come straight out of it.
    link.input('dat_rx_enable').srcConnection! <= writePath.output('rx_enable');
    link.input('dat_status_send').srcConnection! <=
        writePath.output('status_send');
    link.input('dat_status_code').srcConnection! <=
        writePath.output('status_code');
    link.input('dat_busy').srcConnection! <= writePath.output('dat_busy');

    output('out_word') <= writePath.output('out_word');
    output('out_push') <= writePath.output('out_push');
    output('ack_pop') <= writePath.output('ack_pop');

    // The card register sender. It puts the SCR on DAT for ACMD51, which
    // Linux reads right after it selects the card and BEFORE any read, and
    // the switch status on DAT for CMD6. The value comes from the state
    // machine, so this module holds no knowledge of any register.
    //
    // The length is the LONGEST of those values, because the port carries
    // both and a shorter value sits at the top of it.
    final regTx = MimicSdRegTx(
      maxBytes: sdSwitchStatusBytes,
      name: 'sd_reg_tx',
    );
    addSubModule(regTx);
    regTx.input('clk').srcConnection! <= clk;
    regTx.input('reset').srcConnection! <= reset;
    regTx.input('start').srcConnection! <= fsm.output('reg_send');
    regTx.input('data').srcConnection! <= fsm.output('reg_data');
    regTx.input('bytes').srcConnection! <= fsm.output('reg_bytes');
    regTx.input('cmd_busy').srcConnection! <= link.output('resp_busy');
    regTx.input('tx_next').srcConnection! <= link.output('dat_tx_next');
    regTx.input('tx_done').srcConnection! <= link.output('dat_tx_done');

    fsm.input('card_enable').srcConnection! <= cardEnable;
    fsm.input('read_ready').srcConnection! <= readPath.output('ready');
    fsm.input('read_done').srcConnection! <= readPath.output('done');
    fsm.input('read_failed').srcConnection! <= readPath.output('failed');
    fsm.input('reg_ready').srcConnection! <= regTx.output('ready');
    fsm.input('write_ready').srcConnection! <= writePath.output('ready');
    fsm.input('write_done').srcConnection! <= writePath.output('done');
    fsm.input('write_failed').srcConnection! <= writePath.output('failed');
    fsm.input('write_prg').srcConnection! <= writePath.output('in_prg');

    // The two senders share the transmit port of the link. They cannot run
    // together: the read path sends in the DATA state and the register
    // sender in the TRAN state, and each holds the other off through the
    // ready bit the state machine reads before it starts one. The select
    // is the BUSY of the register sender, which is high from the start
    // pulse and through the whole frame.
    final regBusy = regTx.output('busy').named('reg_tx_busy');
    link.input('dat_tx_start').srcConnection! <=
        (readPath.output('tx_start') | regTx.output('tx_start'));
    link.input('dat_tx_byte').srcConnection! <=
        mux(regBusy, regTx.output('tx_byte'), readPath.output('tx_byte'));
    link.input('dat_tx_len').srcConnection! <=
        mux(
          regBusy,
          regTx.output('tx_len'),
          Const(sdBlockBytes, width: sdDataTxLenBits),
        );

    // The record channel is SHARED. A read and a write can never post a
    // record on the same clock, because the card is in one state at a
    // time: a read runs from the data state and a write from the rcv
    // state, and the state machine takes neither command out of tran while
    // the other runs. The select is the write valid, so a record that both
    // paths somehow raised would go out as the write, and the read path
    // would then time out rather than send the host a block of another
    // request.
    final writeReqValid = writePath.output('req_valid').named('write_req_go');
    output('req_data') <=
        mux(
          writeReqValid,
          writePath.output('req_data'),
          readPath.output('req_data'),
        );
    output('req_valid') <= readPath.output('req_valid') | writeReqValid;
    output('data_pop') <= readPath.output('data_pop');

    // The WORDS the card took off the channel, as a gray code. It takes
    // the same shape the bring-up counters take, and for the same reason:
    // the SoC cannot read a binary counter of this domain without tearing.
    //
    // It counts every pop of the data channel, which is every word of
    // every block the card takes, whether that block went out on DAT, went
    // into the cache as a fill, or went nowhere. The SoC counts the words
    // it PUSHED, so the difference is the true occupancy of the channel.
    //
    // WORDS and not blocks. See `words_consumed_gray`.
    final wordsConsumed = MimicSdGrayCounter(
      width: sdDataWordCountBits,
      name: 'words_consumed_counter',
    );
    addSubModule(wordsConsumed);
    wordsConsumed.input('clk').srcConnection! <= clk;
    wordsConsumed.input('reset').srcConnection! <= reset;
    wordsConsumed.input('inc').srcConnection! <= readPath.output('data_pop');
    output('words_consumed_gray') <= wordsConsumed.output('gray');

    // The words the card pushed into the write channel, as a gray code and
    // for the same reason.
    //
    // `block_pushed` counts what the channel TOOK and not what the card
    // offered, because the FIFO drops a push into a full channel. See
    // `pushAccepted` in [MimicSdWritePath].
    final wordsCounter = MimicSdGrayCounter(
      width: sdDataWordCountBits,
      name: 'words_written_counter',
    );
    addSubModule(wordsCounter);
    wordsCounter.input('clk').srcConnection! <= clk;
    wordsCounter.input('reset').srcConnection! <= reset;
    wordsCounter.input('inc').srcConnection! <=
        writePath.output('block_pushed');
    output('words_written_gray') <= wordsCounter.output('gray');

    // The three block cache counters. Each one counts in this clock domain,
    // which the host owns and stops, so each takes the gray road that the
    // bring-up counters take.
    final cacheCounters = <String, String>{
      'dbg_cache_hit_gray': 'hit_event',
      'dbg_cache_miss_gray': 'miss_event',
      'dbg_cache_fill_gray': 'fill_event',
    };
    cacheCounters.forEach((port, event) {
      final counter = MimicSdGrayCounter(
        width: sdDbgEventBits,
        name: '${port}_counter',
      );
      addSubModule(counter);
      counter.input('clk').srcConnection! <= clk;
      counter.input('reset').srcConnection! <= reset;
      counter.input('inc').srcConnection! <= cache.output(event);
      output(port) <= counter.output('gray');
    });

    // The timeout event, published as a level for the SoC domain. It takes
    // the reset ASYNCHRONOUSLY for the reason the activity toggle below
    // does: a board whose SD clock never ticks would otherwise hold X here
    // and the X would cross into the SoC domain.
    final timeoutToggle = Logic(name: 'read_timeout_toggle_reg');
    Sequential(
      clk,
      reset: reset,
      asyncReset: true,
      resetValues: {timeoutToggle: Const(0)},
      [
        If(
          readPath.output('timeout_event'),
          then: [timeoutToggle < ~timeoutToggle],
        ),
      ],
    );
    output('read_timeout_toggle') <= mux(reset, Const(0), timeoutToggle);

    // The write timeout event, published the same way and for the same
    // reason.
    final writeTimeoutToggle = Logic(name: 'write_timeout_toggle_reg');
    Sequential(
      clk,
      reset: reset,
      asyncReset: true,
      resetValues: {writeTimeoutToggle: Const(0)},
      [
        If(
          writePath.output('timeout_event'),
          then: [writeTimeoutToggle < ~writeTimeoutToggle],
        ),
      ],
    );
    output('write_timeout_toggle') <= mux(reset, Const(0), writeTimeoutToggle);

    // The destination register of the CSD crossing. All 128 bits load
    // together on one clock, so this register never holds part of one
    // snapshot and part of the next. What makes the snapshot itself whole
    // is the shadow register at the SOURCE, in [MimicSdCard]: it commits
    // the four CSR words in one bus clock, so every snapshot that arrives
    // here is a CSD that the runtime finished writing.
    //
    // The reset value is the default CSD, which is what CMD9 answers until
    // the first transfer lands.
    //
    // The SD clock is the host clock, so this register stands still while
    // the host stops the clock. A transfer that cannot finish for that
    // reason keeps the value that the register already holds, and the card
    // cannot answer a command in that time either.
    final csdReg = Logic(name: 'csd_reg', width: sdResponseRegBits);
    Sequential(
      clk,
      reset: reset,
      resetValues: {csdReg: Const(sdCardCsdValue, width: sdResponseRegBits)},
      [
        If(input('csd_valid'), then: [csdReg < input('csd')]),
      ],
    );
    fsm.input('csd').srcConnection! <= csdReg;

    output('card_state') <= fsm.output('card_state');

    // The bring-up counters.
    //
    // DBG_SD_CLK is the one that answers the first question of a bring-up.
    // Its `inc` is a constant 1, so it counts every SD clock edge and
    // nothing gates it: no command, no response and no state of the card
    // can hold it still. A counter that moves proves the pad, the clock
    // buffer and the clock net are alive even when the card hears nothing.
    // A counter that stays at 0 proves the clock never arrives, and that
    // is the only reading no other counter can give.
    //
    // All four take the SAME reset the card takes, which asserts with no
    // clock at all and releases in step with the SD clock. They therefore
    // read exactly 0, and never X, on a board whose SD clock never ticks.
    final counters = <String, ({int width, Logic inc})>{
      'dbg_sd_clk_gray': (width: sdDbgClkBits, inc: Const(1)),
      // One count per command the link framed, whatever its CRC7. A
      // DBG_SD_CLK that moves with this counter at 0 says the clock
      // arrives and no command is ever framed.
      'dbg_sd_cmd_gray': (
        width: sdDbgEventBits,
        // A name of its own. Without it the netlist calls this net `inc`,
        // after the port it reached first, and a reader cannot tell what
        // the counter counts.
        inc: link.output('cmd_valid').named('dbg_cmd_framed'),
      ),
      // The framed commands whose CRC7 failed. `cmd_crc_ok` only carries a
      // verdict while `cmd_valid` is high, so the gate is needed: without
      // it the counter would count every clock in which no frame ended.
      'dbg_sd_crc_err_gray': (
        width: sdDbgEventBits,
        inc: (link.output('cmd_valid') & ~link.output('cmd_crc_ok')).named(
          'dbg_cmd_crc_bad',
        ),
      ),
      // The responses the card really started to send. The link DROPS a
      // `resp_start` that arrives while it is busy, so the count takes the
      // same gate the link takes and never counts a start it refused.
      'dbg_sd_resp_gray': (
        width: sdDbgEventBits,
        inc: (fsm.output('resp_start') & ~link.output('resp_busy')).named(
          'dbg_resp_started',
        ),
      ),
    };
    counters.forEach((port, spec) {
      final counter = MimicSdGrayCounter(
        width: spec.width,
        name: '${port.replaceAll('_gray', '')}_counter',
      );
      addSubModule(counter);
      counter.input('clk').srcConnection! <= clk;
      counter.input('reset').srcConnection! <= reset;
      counter.input('inc').srcConnection! <= spec.inc;
      output(port) <= counter.output('gray');
    });

    // The activity event, published as a TOGGLE for the SoC clock domain.
    //
    // The activity light times its flash in the SoC domain, because the SD
    // clock is the host clock and it STOPS. A flash timed on a clock that
    // stops would freeze part way through and hold the LED lit.
    //
    // The event therefore leaves this domain as a LEVEL that inverts once
    // per event, and the SoC domain reads one event from each EDGE of it.
    // A pulse of one SD clock cannot cross at all: the two clocks have no
    // ratio, and a two-flop synchroniser that samples a pulse narrower
    // than its own clock period misses it. A level has no width to miss.
    // The gray crossing of the counters above answers a different
    // question, which is how to carry a VALUE that moves every clock, and
    // a handshake answers a third one. A handshake is wrong here: it waits
    // for an acknowledge that this domain cannot give while the host holds
    // the clock still.
    //
    // Phase 2 has no block transfer, so the event is a framed COMMAND.
    // `cmd_valid` is the same signal the DBG_SD_CMD counter counts, so the
    // light and that counter cannot disagree about what activity is. This
    // widens to the data transfers when the block path lands.
    //
    // The register takes the reset ASYNCHRONOUSLY, for the reason
    // [MimicSdGrayCounter] takes it that way: a board whose SD clock never
    // ticks would otherwise hold X here, and X crossing into the SoC
    // domain would light the LED of a card that no host ever clocked.
    final activityToggle = Logic(name: 'sd_activity_toggle_reg');
    Sequential(
      clk,
      reset: reset,
      asyncReset: true,
      resetValues: {activityToggle: Const(0)},
      [
        If(link.output('cmd_valid'), then: [activityToggle < ~activityToggle]),
      ],
    );
    // Held at 0 while the domain is in reset, the same way `card_state` and
    // the gray words are. The gate adds no edge of its own, because the
    // register already holds 0 when the reset releases.
    output('sd_activity_toggle') <= mux(reset, Const(0), activityToggle);
  }
}
