// MimicSdCard: a Wishbone B4 slave that carries the Mimic CSR map.
//
// The map holds the plain registers, the channels of the block READ path
// and the block WRITE path, and the event register. The interrupt
// machinery arrives in a later phase.
// Behavior:
//   - ID and VERSION return fixed constants.
//   - CTRL, NUM_BLOCKS, SCRATCH and IRQ_ENABLE are read-write storage.
//     Reset value 0.
//   - STATUS reads 0.
//   - DATA_OUT reads the word at the head of the write data channel, with
//     NO side effect, and DATA_OUT_POP takes it away. DATA_OUT_COUNT
//     reports the words waiting on that channel. WRITE_ACK retires one
//     block write and releases the SD host from busy. See the block write
//     path below.
//   - REQ reads word 0 of the record at the head of the request channel
//     and REQ_HI reads word 1, both with no side effect. REQ_POP takes
//     the record away, REQ_COUNT reports the whole records that are
//     waiting, DATA_TAG writes the sequence tag of the block that
//     follows, DATA_IN pushes one word into the data channel and
//     DATA_IN_COUNT reports the FREE SPACE of that channel in words. See
//     the block read path below.
//   - EVENT is RW1C. Bit 0 reports a read the runtime never answered and
//     bit 1 reports a write the runtime never acknowledged.
//   - CARD_STATE reads the `card_state` input, which the SoC has already
//     crossed out of the SD clock domain.
//   - DBG_SD_CLK, DBG_SD_CMD, DBG_SD_CRC_ERR and DBG_SD_RESP read the four
//     bring-up counters, which the SoC has also already crossed out of the
//     SD clock domain. They separate three bring-up faults that CARD_STATE
//     reads `idle` for. See regs.dart.
//   - CSD_0 to CSD_3 are read-write storage that STAGES the 128-bit CSD
//     register of the card. They reset to the DEFAULT CSD. A write to the
//     LAST of the four, CSD_3, also commits all four words into a 128-bit
//     shadow register, and the `csd` output is that shadow. The SoC
//     crosses the shadow into the SD clock domain. A runtime that writes
//     CSD_0 to CSD_3 in that order therefore gives the card one whole CSD
//     and never a value that is part old and part new.
//
// Address map (byte addresses, 12-bit bus). The registers live in the
// region bits [11:8] == 0x0. See regs.dart for the shared constants.
//
// The block read path
//   The card asks the runtime for a block over two FIFOs that the SoC
//   owns, one in each direction. This slave holds the runtime end of both.
//
//   A record is two words and each word has an ADDRESS of its own. REQ
//   (0x18) reads word 0, which holds the opcode and card generation in
//   bits 7 to 0, the sequence tag in bits 15 to 8 and the block count in
//   bits 31 to 16.
//   REQ_HI (0x68) reads word 1, which holds the block address. REQ_COUNT
//   (0x1C) counts whole RECORDS and not words.
//
//   NO READ OF THIS MAP HAS A SIDE EFFECT. Both record reads leave the
//   record where it is, and the record goes away only when the runtime
//   WRITES bit 0 of REQ_POP (0x70). A bulk read of the whole map, a debug
//   tool and anything a person writes later are therefore safe by
//   construction: no order of reads, and no read of any address, can take
//   a record or tear one. The cost is one more bus access for each
//   record.
//
//   A read that popped would put that guarantee at the mercy of an address
//   that every reader has to keep away from, and a runtime that read word
//   0 twice around a foreign access would serve a block address it built
//   out of two copies of word 0.
//
//   DATA_TAG (0x6C) takes the sequence tag of the block that follows, in
//   the low 8 bits. The runtime writes it once before the 128 words of the
//   block. The card compares the tag with the record it waits for and
//   throws a block away that names another record, so a late answer can
//   never be sent as the answer to the next read.
//
//   DATA_IN (0x20) pushes one word into the data channel, LITTLE ENDIAN,
//   so byte 0 of the block is bits 7 to 0 of the first word. DATA_IN_COUNT
//   (0x24) reports the FREE SPACE of that channel in words, so a runtime
//   waits for a whole block of space before it pushes a block. The count
//   is conservative: it reads a block counter that has crossed out of the
//   SD clock domain and may be behind, so it can only ever report LESS
//   free space than there is.
//
// The block write path
//   The card takes 512 bytes off DAT0 and pushes them into a FIFO that the
//   SoC owns, and it posts one record the same way a read does. The record
//   opcode says what the runtime does with the block: 2 writes it and 3
//   drops it, which is what the card asks for after a bad CRC16.
//
//   NO READ OF THIS MAP HAS A SIDE EFFECT here either. DATA_OUT leaves the
//   word where it is, and only a WRITE of bit 0 of DATA_OUT_POP takes it
//   away. One word therefore costs a read and a write.
//
//   The card holds DAT0 LOW while it waits, and the SD host waits with it.
//   A write of WRITE_ACK carrying the sequence tag of the record releases
//   the host. Nothing else does.
//
// All logic runs in the fabric clock domain. Every signal that comes from
// the SD clock domain, `card_state`, the four bring-up counters and the
// count of blocks the card took, arrives already synchronised: the SoC
// owns those crossings, because only the SoC has both clocks. The one
// exception is `sd_read_timeout_toggle`, which is a LEVEL that inverts per
// event: a two-flop synchroniser needs the destination clock alone, and
// this module is the destination, so the synchroniser is here.

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../regs.dart';
import 'sd_card_fsm.dart' show sdCardCsdValue, sdCardCsdWords, sdCardStateBits;
import 'sd_block_cache.dart' show sdCacheDefaultLines, sdCacheLinesValid;
import 'sd_debug.dart' show sdBinaryToGray, sdDbgClkBits, sdDbgEventBits;
import 'sd_link.dart' show sdCommandArgBits, sdResponseRegBits;
import 'sd_read_path.dart'
    show
        sdBlockCountBits,
        sdBlockWords,
        sdDataInFifoWords,
        sdDataWordCountBits,
        sdRequestBits,
        sdRequestSeqBits,
        sdRequestSeqNone,
        sdTagChannelBits,
        sdTagChannelLbaLsb,
        sdTagChannelValidBit;
import 'sd_write_path.dart' show sdWriteAckBits, sdWriteAckFailBit;

// Register map descriptor (for SVD).

// Not const: the reset values of the CSD block come from the default CSD,
// which sd_regs.dart builds at run time.
final _mimicSdCardRegisterMap = HarborDeviceRegisterMap(
  name: 'mimic_sd_card',
  fields: [
    HarborDeviceField(
      name: 'ID',
      width: 4,
      offset: 0x00,
      readOnly: true,
      resetValue: MimicRegValue.id,
    ),
    HarborDeviceField(
      name: 'VERSION',
      width: 4,
      offset: 0x04,
      readOnly: true,
      resetValue: MimicRegValue.version,
    ),
    HarborDeviceField(name: 'CTRL', width: 4, offset: 0x08),
    HarborDeviceField(name: 'STATUS', width: 4, offset: 0x0C, readOnly: true),
    HarborDeviceField(name: 'NUM_BLOCKS', width: 4, offset: 0x10),
    HarborDeviceField(name: 'SCRATCH', width: 4, offset: 0x14),
    HarborDeviceField(
      name: 'REQ',
      width: 4,
      offset: MimicReg.req,
      readOnly: true,
    ),
    HarborDeviceField(
      name: 'REQ_COUNT',
      width: 4,
      offset: 0x1C,
      readOnly: true,
    ),
    HarborDeviceField(name: 'DATA_IN', width: 4, offset: 0x20),
    HarborDeviceField(
      name: 'DATA_IN_COUNT',
      width: 4,
      offset: 0x24,
      readOnly: true,
    ),
    HarborDeviceField(
      name: 'DATA_OUT',
      width: 4,
      offset: MimicReg.dataOut,
      readOnly: true,
    ),
    HarborDeviceField(
      name: 'DATA_OUT_COUNT',
      width: 4,
      offset: 0x2C,
      readOnly: true,
    ),
    HarborDeviceField(name: 'EVENT', width: 4, offset: 0x30),
    HarborDeviceField(name: 'IRQ_ENABLE', width: 4, offset: 0x34),
    HarborDeviceField(
      name: 'CARD_STATE',
      width: 4,
      offset: 0x44,
      readOnly: true,
    ),
    // The CSD register block. The reset values come from the default CSD,
    // so the map that a runtime reads and the register that the card
    // answers CMD9 with cannot drift apart.
    HarborDeviceField(
      name: 'CSD_0',
      width: 4,
      offset: MimicReg.csd0,
      resetValue: sdCardCsdWords[0],
    ),
    HarborDeviceField(
      name: 'CSD_1',
      width: 4,
      offset: MimicReg.csd1,
      resetValue: sdCardCsdWords[1],
    ),
    HarborDeviceField(
      name: 'CSD_2',
      width: 4,
      offset: MimicReg.csd2,
      resetValue: sdCardCsdWords[2],
    ),
    HarborDeviceField(
      name: 'CSD_3',
      width: 4,
      offset: MimicReg.csd3,
      resetValue: sdCardCsdWords[3],
    ),
    // The SD bring-up counters. They read a count that the SoC has already
    // taken out of the SD clock domain, so the slave holds no counter of
    // its own.
    HarborDeviceField(
      name: 'DBG_SD_CLK',
      width: 4,
      offset: MimicReg.dbgSdClk,
      readOnly: true,
    ),
    HarborDeviceField(
      name: 'DBG_SD_CMD',
      width: 4,
      offset: MimicReg.dbgSdCmd,
      readOnly: true,
    ),
    HarborDeviceField(
      name: 'DBG_SD_CRC_ERR',
      width: 4,
      offset: MimicReg.dbgSdCrcErr,
      readOnly: true,
    ),
    HarborDeviceField(
      name: 'DBG_SD_RESP',
      width: 4,
      offset: MimicReg.dbgSdResp,
      readOnly: true,
    ),
    // The rest of the block read path. REQ_HI is a plain read-only word:
    // it has no side effect and a walk that crosses it takes nothing. The
    // two write-only registers hold every side effect of this path.
    HarborDeviceField(
      name: 'REQ_HI',
      width: 4,
      offset: MimicReg.reqHi,
      readOnly: true,
    ),
    HarborDeviceField(name: 'DATA_TAG', width: 4, offset: MimicReg.dataTag),
    HarborDeviceField(name: 'REQ_POP', width: 4, offset: MimicReg.reqPop),
    // The write path. Both are write-only, so every side effect of this
    // path is a WRITE and the read invariant of the map holds.
    HarborDeviceField(
      name: 'DATA_OUT_POP',
      width: 4,
      offset: MimicReg.dataOutPop,
    ),
    HarborDeviceField(name: 'WRITE_ACK', width: 4, offset: MimicReg.writeAck),
    // The block cache. DATA_FILL_LBA is write-only, so the read invariant
    // of the map holds here as well, and the four below are plain
    // read-only words.
    HarborDeviceField(
      name: 'DATA_FILL_LBA',
      width: 4,
      offset: MimicReg.dataFillLba,
    ),
    HarborDeviceField(
      name: 'DBG_CACHE_HIT',
      width: 4,
      offset: MimicReg.dbgCacheHit,
      readOnly: true,
    ),
    HarborDeviceField(
      name: 'DBG_CACHE_MISS',
      width: 4,
      offset: MimicReg.dbgCacheMiss,
      readOnly: true,
    ),
    HarborDeviceField(
      name: 'DBG_CACHE_FILL',
      width: 4,
      offset: MimicReg.dbgCacheFill,
      readOnly: true,
    ),
    HarborDeviceField(
      name: 'CACHE_LINES',
      width: 4,
      offset: MimicReg.cacheLines,
      readOnly: true,
      resetValue: sdCacheDefaultLines,
    ),
    HarborDeviceField(
      name: 'REQ_SNAPSHOT_COUNT',
      width: 4,
      offset: MimicReg.reqSnapshotCount,
      readOnly: true,
    ),
    HarborDeviceField(
      name: 'REQ_SNAPSHOT',
      width: 4,
      offset: MimicReg.reqSnapshot,
      readOnly: true,
    ),
    HarborDeviceField(
      name: 'REQ_SNAPSHOT_HI',
      width: 4,
      offset: MimicReg.reqSnapshotHi,
      readOnly: true,
    ),
    HarborDeviceField(
      name: 'DBG_READ_START',
      width: 4,
      offset: MimicReg.dbgReadStart,
      readOnly: true,
    ),
    HarborDeviceField(
      name: 'DBG_READ_DONE',
      width: 4,
      offset: MimicReg.dbgReadDone,
      readOnly: true,
    ),
    HarborDeviceField(
      name: 'DBG_READ_DROP',
      width: 4,
      offset: MimicReg.dbgReadDrop,
      readOnly: true,
    ),
    HarborDeviceField(
      name: 'DBG_READ_ABORT',
      width: 4,
      offset: MimicReg.dbgReadAbort,
      readOnly: true,
    ),
  ],
);

/// Number of address bits inside one block of the data channel.
///
/// One block is [sdBlockWords] words, so the low bits of the pushed-word
/// counter say where inside a block the next push lands, and the push that
/// makes those bits roll over completes a block.
final int _blockWordBits = (sdBlockWords - 1).bitLength;

/// Bit number of the enable bit of the CTRL register.
///
/// [MimicCtrl.enable] holds the MASK, and the port that carries the bit to
/// the SD clock domain needs the NUMBER. The constructor checks that the
/// mask really is one bit, so a mask that grows cannot pick the wrong bit
/// here without notice.
final int _ctrlEnableBit = MimicCtrl.enable.bitLength - 1;

/// Bit number of the pop bit of the REQ_POP register.
///
/// [MimicReqPop.pop] holds the MASK and the decode below needs the NUMBER.
/// The constructor checks that the mask really is one bit, so a mask that
/// grows cannot pick the wrong bit here without notice.
final int _reqPopBit = MimicReqPop.pop.bitLength - 1;

/// Bit number of the read timeout in the EVENT register.
///
/// [MimicEvent.readTimeout] holds the MASK and the set logic below needs
/// the NUMBER. The constructor checks that the mask really is one bit, so
/// a mask that grows cannot pick the wrong bit here without notice.
final int _eventReadTimeoutBit = MimicEvent.readTimeout.bitLength - 1;

/// Bit number of the write timeout in the EVENT register.
///
/// [MimicEvent.writeTimeout] holds the MASK and the set logic below needs
/// the NUMBER. The constructor checks that the mask really is one bit.
final int _eventWriteTimeoutBit = MimicEvent.writeTimeout.bitLength - 1;

/// Bit number of the dropped DATA_IN push in the EVENT register.
///
/// [MimicEvent.dataInOverflow] holds the MASK and the set logic below
/// needs the NUMBER. The constructor checks that the mask really is one
/// bit.
final int _eventDataInOverflowBit = MimicEvent.dataInOverflow.bitLength - 1;

/// Bit number of the write-back bit of the CTRL register.
///
/// [MimicCtrl.writeBack] holds the MASK, and the port that carries the bit
/// to the SD clock domain needs the NUMBER.
final int _ctrlWriteBackBit = MimicCtrl.writeBack.bitLength - 1;

/// Bit number of the pop bit of the DATA_OUT_POP register.
final int _dataOutPopBit = MimicDataOutPop.pop.bitLength - 1;

// Module

/// Wishbone-driven Mimic SD card CSR interface.
///
/// See the file-level comment for the address map, the block read path and
/// the registers that are still stubs.
class MimicSdCard extends BridgeModule
    with HarborDeviceTreeNodeProvider, HarborSvdPeripheralProvider {
  /// Size of the slave address window in bytes.
  ///
  /// The bus is 12-bit (covers 0x000..0xFFF). The harbor Wishbone decoder
  /// gates each slave with `adr >= start && adr < Const(start+size, width:
  /// addressWidth)`, so the EXCLUSIVE end (start+size) MUST be representable
  /// in the bus address width. A full 4 KiB window (end 0x1000) wraps to
  /// 0x000 in 12 bits and collapses the decode to empty (the slave becomes
  /// unreachable). 0x800 (end 0x800) fits in 12 bits and covers every real
  /// register (the map ends at 0x6F) with room for the later phases.
  static const int windowSize = 0x800;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Wishbone slave port.
  late final BusSlavePort bus;

  /// Number of lines in the block cache of the card this slave serves.
  ///
  /// The slave holds no cache of its own. It publishes the count through
  /// CACHE_LINES, so a runtime reads the geometry of the build it is
  /// talking to and never assumes one.
  final int cacheLines;

  MimicSdCard({
    required this.baseAddress,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
    int? cacheLines,
  }) : cacheLines = cacheLines ?? sdCacheDefaultLines,
       super('MimicSdCard', name: name ?? 'mimic_sd_card') {
    if (!sdCacheLinesValid(this.cacheLines)) {
      throw ArgumentError.value(
        this.cacheLines,
        'cacheLines',
        'must be a power of two, 2 or more. It is the line count of the '
            'block cache and the CACHE_LINES register publishes it.',
      );
    }
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // The card state of the SD card state machine, ALREADY crossed into this
    // clock domain by the SoC. The SD domain is asynchronous to the bus
    // domain and it stops when the host stops clocking the card, so the
    // crossing cannot live here: this module has no SD clock to cross from.
    // The SoC owns the synchroniser and gives this port the settled value.
    createPort('card_state', PortDirection.input, width: sdCardStateBits);

    // The SD bring-up counters, ALREADY crossed into this clock domain by
    // the SoC. They count in the SD clock domain, which stops whenever the
    // host stops clocking, so the crossing cannot live here either: this
    // module has no SD clock. The SoC crosses each one as a gray code and
    // gives this port the binary count. See `sd_debug.dart`.
    //
    // The widths come from that file, so the register and the counter that
    // fills it cannot drift apart.
    createPort('dbg_sd_clk', PortDirection.input, width: sdDbgClkBits);
    createPort('dbg_sd_cmd', PortDirection.input, width: sdDbgEventBits);
    createPort('dbg_sd_crc_err', PortDirection.input, width: sdDbgEventBits);
    createPort('dbg_sd_resp', PortDirection.input, width: sdDbgEventBits);

    // The three block cache counters, ALREADY crossed into this clock
    // domain by the SoC, the way the four above are. They count in the SD
    // clock domain, which stops when the host stops clocking, so the
    // crossing cannot live here.
    createPort('dbg_cache_hit', PortDirection.input, width: sdDbgEventBits);
    createPort('dbg_cache_miss', PortDirection.input, width: sdDbgEventBits);
    createPort('dbg_cache_fill', PortDirection.input, width: sdDbgEventBits);
    createPort('dbg_read_start', PortDirection.input, width: sdDbgEventBits);
    createPort('dbg_read_done', PortDirection.input, width: sdDbgEventBits);
    createPort('dbg_read_drop', PortDirection.input, width: sdDbgEventBits);
    createPort('dbg_read_abort', PortDirection.input, width: sdDbgEventBits);

    // The runtime end of the block read channels. The SoC owns the two
    // FIFOs, so this module drives the read side of the request channel
    // and the write side of the data channel.
    createPort('req_data', PortDirection.input, width: sdRequestBits);
    createPort('req_empty', PortDirection.input);
    createPort('data_full', PortDirection.input);
    // Asserted by the data FIFO when fewer than one whole block remains.
    // This comes from the FIFO write pointer and gates block admission.
    createPort('data_blocked', PortDirection.input);
    // Asserted when the tag FIFO cannot reserve the tag for another block.
    // A block is admitted only when both channels can take their half.
    createPort('tag_full', PortDirection.input);

    // WORDS the card has taken off the data channel, already crossed out
    // of the SD clock domain and turned back into a binary count.
    //
    // WORDS and not blocks. A count that moved a block at a time held
    // still through the whole 4114 clock send of one block, so
    // `DATA_IN_COUNT` reported the same free space for 165 us at 25 MHz
    // and a runtime that waited on it learned nothing from reading it.
    // This count moves as the block drains.
    createPort(
      'words_consumed',
      PortDirection.input,
      width: sdDataWordCountBits,
    );

    // The read timeout event of the card, as a LEVEL that inverts per
    // event. It crosses in this module. See the file header.
    createPort('sd_read_timeout_toggle', PortDirection.input);

    // The write timeout event of the card, as a LEVEL that inverts per
    // event. It crosses in this module, the way the read one does.
    createPort('sd_write_timeout_toggle', PortDirection.input);

    // The runtime end of the block WRITE channel. The SoC owns the FIFO, so
    // this module drives its read side: `out_data` is the word at the head
    // and `out_pop` takes it away.
    createPort('out_data', PortDirection.input, width: 32);
    createPort('out_empty', PortDirection.input);

    // Words the card has pushed into the write channel, already crossed out
    // of the SD clock domain and turned back into a binary count.
    createPort(
      'words_written',
      PortDirection.input,
      width: sdDataWordCountBits,
    );

    addOutput('req_pop');
    addOutput('out_pop');

    // The acknowledge channel back to the card. One push retires one block
    // write and releases the SD host from busy.
    addOutput('ack_word', width: sdWriteAckBits);
    addOutput('ack_push');

    // CTRL bit 4. The SD clock domain reads it to pick write-through or
    // write-back.
    addOutput('write_back');
    addOutput('data_word', width: 32);
    addOutput('data_push');

    // The sequence tag of the block that follows. It goes into a small
    // FIFO of its own beside the data channel, so the card reads the tag
    // and the block from two channels that stay in step: one push here for
    // each block of [sdBlockWords] words pushed into DATA_IN.
    //
    // The FILL ADDRESS rides in the same entry. A block whose tag names no
    // record is a fill, and the address of the block it IS cannot come
    // from a record, so it has to travel with the tag: one entry names one
    // block, and a fill can therefore never take the address of another
    // push. A separate register would need an order the runtime cannot
    // guarantee across a FIFO.
    addOutput('tag_word', width: sdTagChannelBits);
    addOutput('tag_push');
    // The COUNT of whole blocks the runtime has pushed, as a GRAY CODE.
    // The card brings it into its own clock domain, counts the blocks it
    // has taken, and starts a block on DAT only while the two differ: it
    // cannot pause in the middle of a block.
    //
    // A COUNT and not a level that inverts per block. The host owns the SD
    // clock and stops it whenever it likes, and a level that inverted
    // twice while that clock stood still would tell the card about ONE of
    // the two blocks. A gray code carries the whole number, so a card
    // whose clock starts again reads everything it missed, and only one
    // bit of it moves per push, so it cannot be read torn.
    addOutput('data_blocks_pushed_gray', width: sdBlockCountBits);

    // CTRL bit 0. The SD clock domain reads it to decide whether the card
    // answers a read at all.
    addOutput('card_enable');

    // The configured block count. The SoC carries this value into the SD
    // clock domain as one snapshot, where the command decoder rejects a
    // block address that the card does not contain.
    addOutput('num_blocks', width: sdCommandArgBits);

    // The COMMITTED CSD as one 128-bit word, for the SoC to carry into the
    // SD clock domain. The word runs the same way the block does: bit 0 is
    // bit 0 of CSD_0, and bit 127 is bit 31 of CSD_3.
    //
    // This output is the shadow register, not the four CSR words. The
    // runtime writes the CSR words one at a time, so those words hold a
    // value that is part old and part new between two writes, and the
    // crossing that follows takes its snapshots whenever it is free. The
    // shadow loads all 128 bits on ONE bus clock, when the runtime writes
    // the last word of the block, so what leaves this module is always a
    // CSD that the runtime finished writing.
    addOutput('csd', width: sdResponseRegBits);

    if (sdResponseRegBits != MimicReg.csd.length * 32) {
      // Derive nothing from a bare number. A CSD block that does not fill
      // the register would leave the top bits of the port undriven.
      throw StateError(
        'The CSD register is $sdResponseRegBits bits and the CSR block holds '
        '${MimicReg.csd.length} words of 32 bits.',
      );
    }
    if (sdDbgClkBits > 32 || sdDbgEventBits > 32) {
      // The counter has to fit the 32-bit register. `zeroExtend` throws on
      // a value that is already wider, so say what is wrong here.
      throw StateError(
        'The SD bring-up counters are $sdDbgClkBits and $sdDbgEventBits bits '
        'and a CSR register holds 32 bits.',
      );
    }
    if (sdCardCsdWords.length != MimicReg.csd.length) {
      throw StateError(
        'The default CSD holds ${sdCardCsdWords.length} words and the CSR '
        'block holds ${MimicReg.csd.length} registers.',
      );
    }
    if (sdRequestBits != 2 * 32) {
      throw StateError(
        'A request record is $sdRequestBits bits and REQ gives it back in '
        'two reads of 32 bits.',
      );
    }
    if (sdDataInFifoWords > (1 << sdDataWordCountBits)) {
      // The free space is the pushed words less the words the card took.
      // A channel deeper than the counters wrap makes the subtraction
      // report free space that is not there.
      throw StateError(
        'The word counters are $sdDataWordCountBits bits and the read data '
        'channel holds $sdDataInFifoWords words. The counters must wrap at '
        'more words than the channel holds.',
      );
    }
    if (MimicCtrl.enable != (1 << _ctrlEnableBit)) {
      throw StateError(
        'The CTRL enable mask is ${MimicCtrl.enable}, which is not one bit. '
        'The card_enable port carries one bit.',
      );
    }
    if (MimicReqPop.pop != (1 << _reqPopBit) || _reqPopBit >= 32) {
      throw StateError(
        'The REQ_POP pop mask is ${MimicReqPop.pop}, which is not one bit '
        'of a 32-bit register.',
      );
    }
    if (MimicEvent.readTimeout != (1 << _eventReadTimeoutBit) ||
        _eventReadTimeoutBit >= 32) {
      throw StateError(
        'The read timeout mask is ${MimicEvent.readTimeout}, which is not '
        'one bit of a 32-bit register.',
      );
    }
    if (MimicEvent.writeTimeout != (1 << _eventWriteTimeoutBit) ||
        _eventWriteTimeoutBit >= 32) {
      throw StateError(
        'The write timeout mask is ${MimicEvent.writeTimeout}, which is not '
        'one bit of a 32-bit register.',
      );
    }
    if (MimicCtrl.writeBack != (1 << _ctrlWriteBackBit) ||
        _ctrlWriteBackBit >= 32) {
      throw StateError(
        'The CTRL write-back mask is ${MimicCtrl.writeBack}, which is not '
        'one bit of a 32-bit register.',
      );
    }
    if (MimicEvent.dataInOverflow != (1 << _eventDataInOverflowBit) ||
        _eventDataInOverflowBit >= 32 ||
        _eventDataInOverflowBit <= _eventWriteTimeoutBit) {
      throw StateError(
        'The EVENT data channel overflow mask is '
        '${MimicEvent.dataInOverflow}, which is not one bit of a 32-bit '
        'register above the write timeout bit.',
      );
    }
    if (MimicDataOutPop.pop != (1 << _dataOutPopBit) || _dataOutPopBit >= 32) {
      throw StateError(
        'The DATA_OUT_POP pop mask is ${MimicDataOutPop.pop}, which is not '
        'one bit of a 32-bit register.',
      );
    }
    if (MimicWriteAck.tagMask != (1 << sdRequestSeqBits) - 1 ||
        MimicWriteAck.fail != (1 << sdWriteAckFailBit)) {
      throw StateError(
        'The WRITE_ACK tag mask is ${MimicWriteAck.tagMask} and the fail bit '
        'is ${MimicWriteAck.fail}. The card reads a $sdRequestSeqBits bit tag '
        'with the fail bit at $sdWriteAckFailBit.',
      );
    }
    if (MimicReg.dbgReadAbort >= windowSize) {
      // The decode reads the LOW 8 bits of the address, so a register
      // above 0xFF would answer at a second address as well.
      throw StateError(
        'The map ends at ${MimicReg.dbgReadAbort} and the slave window is '
        '$windowSize bytes.',
      );
    }
    if (MimicReg.dbgReadAbort > 0xFF) {
      throw StateError(
        'The map ends at ${MimicReg.dbgReadAbort}, which does not fit in the '
        '8 bits of the register decode.',
      );
    }
    if (sdTagChannelBits != sdRequestSeqBits + sdCommandArgBits + 1) {
      throw StateError(
        'A tag channel entry is $sdTagChannelBits bits and it has to hold a '
        '$sdRequestSeqBits bit tag, a $sdCommandArgBits bit fill address '
        'and one bit that says the address is there.',
      );
    }
    if (sdTagChannelLbaLsb != sdRequestSeqBits ||
        sdTagChannelValidBit != sdRequestSeqBits + sdCommandArgBits) {
      throw StateError(
        'The tag channel entry puts the fill address at bit '
        '$sdTagChannelLbaLsb and the valid bit at $sdTagChannelValidBit, '
        'which is not the layout this module packs.',
      );
    }
    if (sdDataInFifoWords >= (1 << sdDataWordCountBits)) {
      throw StateError(
        'The read data channel holds $sdDataInFifoWords words, which does '
        'not fit in the $sdDataWordCountBits bit occupancy counter.',
      );
    }

    // 12-bit address bus covers 0x000..0xFFF (4 KiB).
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      addressWidth: 12,
      dataWidth: 32,
    );

    final clk = input('clk');
    final reset = input('reset');

    // Read-write storage registers. Reset value 0 for all of them.
    final ctrlReg = Logic(name: 'ctrl_reg', width: 32);
    final numBlocksReg = Logic(name: 'num_blocks_reg', width: 32);
    final scratchReg = Logic(name: 'scratch_reg', width: 32);
    final irqEnableReg = Logic(name: 'irq_enable_reg', width: 32);

    // The CSD register block, which is the STAGING copy. Entry 0 is CSD_0,
    // which holds csd[31:0]. Each one resets to its word of the default
    // CSD, so the card identifies before the runtime writes anything at
    // all. A read of CSD_0 to CSD_3 gives the staging copy back, so a
    // runtime that reads its own writes back sees what it wrote.
    final csdRegs = <Logic>[
      for (var i = 0; i < MimicReg.csd.length; i++)
        Logic(name: 'csd_reg_$i', width: 32),
    ];

    // The COMMITTED copy. It takes all four staging words on one clock, and
    // it is what the SoC carries into the SD clock domain. Its reset value
    // is the default CSD, the same value the staging words reset to.
    final csdShadow = Logic(name: 'csd_shadow', width: sdResponseRegBits);
    output('csd') <= csdShadow;

    // The word whose write commits the block. It is the LAST word, which
    // the runtime writes last (see `cmdCapacity` in the runtime: it writes
    // CSD_0, CSD_1, CSD_2 and then CSD_3). The commit needs no CTRL bit and
    // no second bus cycle.
    final csdCommitIndex = MimicReg.csd.length - 1;

    // Internal bus-access counters (debug). These count Wishbone READ
    // and WRITE accesses directly in the slave's own Sequential, so they
    // work without any external wiring. If the READ count stops
    // incrementing while the host is still sending READ commands, the
    // USB EP1 path is failing.
    final readCount = Logic(name: 'read_count', width: 32);
    final writeCount = Logic(name: 'write_count', width: 32);

    // The block read path. The decode of the bus access is lifted out of
    // the Case below, because the request pop and the data push have to be
    // combinational: the FIFO moves its pointer on the same clock edge
    // that this module registers the word it read.
    final busAccess = (bus.stb & ~bus.ack).named('bus_access');
    final inCsrRegion = bus.addr
        .getRange(8, 12)
        .eq(Const(0x0, width: 4))
        .named('in_csr_region');
    final regOffset = bus.addr.getRange(0, 8).named('reg_offset');
    final atReqPop = regOffset
        .eq(Const(MimicReg.reqPop, width: 8))
        .named('at_req_pop');
    final atDataIn = regOffset
        .eq(Const(MimicReg.dataIn, width: 8))
        .named('at_data_in');
    final atDataTag = regOffset
        .eq(Const(MimicReg.dataTag, width: 8))
        .named('at_data_tag');
    final atEvent = regOffset
        .eq(Const(MimicReg.event, width: 8))
        .named('at_event');
    final atDataOutPop = regOffset
        .eq(Const(MimicReg.dataOutPop, width: 8))
        .named('at_data_out_pop');
    final atWriteAck = regOffset
        .eq(Const(MimicReg.writeAck, width: 8))
        .named('at_write_ack');
    final atDataFillLba = regOffset
        .eq(Const(MimicReg.dataFillLba, width: 8))
        .named('at_data_fill_lba');

    // The pop of a record. It is a WRITE of bit 0 of REQ_POP and nothing
    // else, so no read of this map moves the request channel: a reader may
    // read REQ and REQ_HI in any order, as often as it likes, and with any
    // number of other accesses between them, and it reads the same record
    // every time. See the file header.
    //
    // The bit gate makes a write of 0 a no-op, so a reader that clears the
    // register cannot lose a record by accident.
    final reqEmpty = input('req_empty');
    final reqPopWrite =
        (busAccess & inCsrRegion & atReqPop & bus.we & bus.dataIn[_reqPopBit])
            .named('req_pop_write');
    output('req_pop') <= reqPopWrite & ~reqEmpty;

    final dataWrite = (busAccess & inCsrRegion & atDataIn & bus.we).named(
      'data_in_write',
    );
    output('data_word') <= bus.dataIn;

    // The tag write starts a block transaction. The entry is registered
    // until the payload completes.
    final tagWrite = (busAccess & inCsrRegion & atDataTag & bus.we).named(
      'data_tag_write',
    );

    // The FILL address of the block that follows, and whether one was
    // written. The write of DATA_TAG reserves the block and takes the
    // address away. The last accepted data word commits both channels, so
    // ONE write of DATA_FILL_LBA names ONE block and no more.
    final fillLbaReg = Logic(name: 'fill_lba_reg', width: sdCommandArgBits);
    final fillLbaValid = Logic(name: 'fill_lba_valid');
    final fillLbaWrite = (busAccess & inCsrRegion & atDataFillLba & bus.we)
        .named('data_fill_lba_write');

    // The entry a write of DATA_TAG builds. The bit numbers come from the
    // field constants, so a field that moves takes the whole entry with
    // it.
    final tagEntry = [
      fillLbaValid,
      fillLbaReg,
      bus.dataIn.getRange(0, sdRequestSeqBits),
    ].swizzle().named('tag_entry');

    // The tag WAITS for its block. See [tagPending].
    final tagPending = Logic(name: 'tag_pending', width: sdTagChannelBits);
    final tagPendingValid = Logic(name: 'tag_pending_valid');
    final blockAdmission = Logic(name: 'data_block_admission');

    // The write path. The pop of a word is a WRITE of bit 0 of
    // DATA_OUT_POP and nothing else, so a read of DATA_OUT leaves the word
    // where it is and a bulk read of the map cannot take part of a block.
    // The pop is combinational for the reason the record pop is: the FIFO
    // moves its pointer on the same clock edge.
    final outEmpty = input('out_empty');
    final outPopWrite =
        (busAccess &
                inCsrRegion &
                atDataOutPop &
                bus.we &
                bus.dataIn[_dataOutPopBit])
            .named('data_out_pop_write');
    final outPop = (outPopWrite & ~outEmpty).named('data_out_pop_go');
    output('out_pop') <= outPop;

    // The acknowledge push. It is combinational for the same reason.
    //
    // The tag gate makes a write of 0 a no-op, the way the bit gate does on
    // REQ_POP and on DATA_OUT_POP. Tag 0 is [sdRequestSeqNone], which names
    // NO record at any time, so a write of it can only ever retire a block
    // that nobody took. A reader that clears the whole register, or a bulk
    // write of the map, does nothing here.
    final ackWrite =
        (busAccess &
                inCsrRegion &
                atWriteAck &
                bus.we &
                bus.dataIn
                    .getRange(0, sdRequestSeqBits)
                    .neq(Const(sdRequestSeqNone, width: sdRequestSeqBits)))
            .named('write_ack_write');
    output('ack_word') <= bus.dataIn.getRange(0, sdWriteAckBits);
    output('ack_push') <= ackWrite;

    // CTRL bit 4. The SD clock domain reads it to pick the write policy.
    output('write_back') <= ctrlReg[_ctrlWriteBackBit];

    // Words the runtime has pushed, and the words the card has taken. Both
    // wrap at the same number, so the difference is the true occupancy of
    // the channel through every wrap.
    final pushWords = Logic(name: 'push_words', width: sdDataWordCountBits);
    // The count of taken words crossed out of the SD clock domain as a
    // gray code, so it may LAG. It can therefore only ever report less
    // free space than the channel has, never more, which is the safe
    // direction for a runtime that waits on it.
    final consumedWords = input('words_consumed').named('consumed_words');
    final occupancy = (pushWords - consumedWords).named('data_occupancy');
    final channelWords = Const(sdDataInFifoWords, width: sdDataWordCountBits);
    final freeWords = mux(
      occupancy.gte(channelWords),
      Const(0, width: sdDataWordCountBits),
      channelWords - occupancy,
    ).named('data_free_words');

    // DATA_TAG reserves room for its entire block. The free-space count is
    // conservative because the consumed count crosses from the SD domain,
    // so a successful reservation cannot run out of room halfway through.
    // If the whole block does not fit, its tag and every DATA_IN write are
    // refused together and neither FIFO moves.
    final wholeBlockFits = freeWords
        .gte(Const(sdBlockWords, width: sdDataWordCountBits))
        .named('data_whole_block_fits');
    final tagAccepted =
        (tagWrite &
                ~blockAdmission &
                wholeBlockFits &
                ~input('data_blocked') &
                ~input('data_full') &
                ~input('tag_full'))
            .named('data_tag_accepted');
    final dataAccepted = (dataWrite & blockAdmission & ~input('data_full'))
        .named('data_in_accepted');
    output('data_push') <= dataAccepted;

    // A refused word changes neither channel. Report it so a runtime that
    // ignored DATA_IN_COUNT can diagnose the rejected block.
    final dataDropped = (dataWrite & (~blockAdmission | input('data_full')))
        .named('data_in_dropped');

    // The words waiting on the write channel. The card counts what it
    // PUSHED, and that count crosses out of the SD clock domain as a gray
    // code, so it may be behind. This module counts what it POPPED, which
    // it knows exactly. The difference is therefore conservative: it can
    // only ever report FEWER words than the channel holds, never more, and
    // a reader that waits for a whole block is safe on it.
    //
    // Both counters are [sdDataWordCountBits] bits and both wrap at the
    // same number, so the subtraction is right through every wrap.
    final popWords = Logic(name: 'pop_words', width: sdDataWordCountBits);
    final outAvail = (input('words_written') - popWords).named(
      'data_out_avail',
    );

    // The push that finishes a block. The low bits of the counter say
    // where inside the block the push lands, so the push at the top of
    // that range is the last word of a block.
    final blockDone =
        (dataAccepted &
                pushWords
                    .getRange(0, _blockWordBits)
                    .eq(Const(sdBlockWords - 1, width: _blockWordBits)))
            .named('data_block_done');

    // The tag goes into its channel WITH ITS BLOCK, and never before it.
    //
    // The two channels must not be able to come out of step. A tag pushed
    // at the write of DATA_TAG would stand alone whenever the block behind
    // it did not arrive whole, and from then on every block would be read
    // under the tag and the FILL ADDRESS of another one. The host would
    // get the right block address with the bytes of a different block, a
    // good CRC16 on them and nothing reporting a fault anywhere.
    //
    // So the write of DATA_TAG only REMEMBERS the entry, and the push that
    // carries the last word of a block is what commits it. One block takes
    // exactly one tag, in the order the blocks go in, whatever the bus
    // does. A block that arrives with no tag remembered takes the entry
    // that names no request and carries no address, which is a block
    // nobody can place, and the card throws it away.
    final tagWord = mux(
      tagPendingValid,
      tagPending,
      Const(0, width: sdTagChannelBits),
    ).named('tag_word_commit');
    output('tag_word') <= tagWord;
    output('tag_push') <= blockDone;
    // The count the card watches, and its gray code. It moves TWO bus
    // clocks after the last push of a block, so it can never reach the SD
    // clock domain before the word does: both cross with a two-flop
    // synchroniser, and the count starts its crossing later than the FIFO
    // pointer does.
    //
    // The gray register takes the code of the SAME value the counter
    // takes, so a reader of the code reads the code of the count the
    // counter holds now. Only one bit of a gray code moves per step, so a
    // destination that samples it while it moves reads the value before
    // the step or the value after it and never a value between them.
    final blockDoneDelay = Logic(name: 'data_block_done_delay');
    final blocksPushed = Logic(name: 'blocks_pushed', width: sdBlockCountBits);
    final blocksPushedGray = Logic(
      name: 'blocks_pushed_gray_reg',
      width: sdBlockCountBits,
    );
    final blocksPushedNext = mux(
      blockDoneDelay,
      blocksPushed + Const(1, width: sdBlockCountBits),
      blocksPushed,
    ).named('blocks_pushed_next');
    output('data_blocks_pushed_gray') <= blocksPushedGray;

    // The EVENT register. Bit 0 reports a read the runtime never answered.
    // The event comes out of the SD clock domain as a level that inverts
    // per event, so this module holds the synchroniser and turns each
    // change back into one event.
    final timeoutSync = HarborCdcSync(name: 'sd_read_timeout_sync');
    addSubModule(timeoutSync);
    timeoutSync.input('async_in').srcConnection! <=
        input('sd_read_timeout_toggle');
    timeoutSync.input('dst_clk').srcConnection! <= clk;
    timeoutSync.input('dst_reset').srcConnection! <= reset;
    final timeoutLevel = timeoutSync.output('sync_out');
    final timeoutPrev = Logic(name: 'sd_read_timeout_prev');
    final timeoutEvent = (timeoutLevel ^ timeoutPrev).named(
      'sd_read_timeout_event',
    );

    final eventReg = Logic(name: 'event_reg', width: 32);
    final eventWrite = (busAccess & inCsrRegion & atEvent & bus.we).named(
      'event_write',
    );
    // Write one to clear. A bit that the card raises on the same clock a
    // write clears it stays raised, because the set is applied after the
    // clear in the one assignment below.
    final eventClear = mux(
      eventWrite,
      bus.dataIn,
      Const(0, width: 32),
    ).named('event_clear');
    // The write timeout crosses the same way and in the same place.
    final writeTimeoutSync = HarborCdcSync(name: 'sd_write_timeout_sync');
    addSubModule(writeTimeoutSync);
    writeTimeoutSync.input('async_in').srcConnection! <=
        input('sd_write_timeout_toggle');
    writeTimeoutSync.input('dst_clk').srcConnection! <= clk;
    writeTimeoutSync.input('dst_reset').srcConnection! <= reset;
    final writeTimeoutLevel = writeTimeoutSync.output('sync_out');
    final writeTimeoutPrev = Logic(name: 'sd_write_timeout_prev');
    final writeTimeoutEvent = (writeTimeoutLevel ^ writeTimeoutPrev).named(
      'sd_write_timeout_event',
    );

    // The three event bits, built from their bit NUMBERS so that a bit
    // which moves cannot push another one off the end.
    final eventSet = [
      Const(0, width: 32 - _eventDataInOverflowBit - 1),
      dataDropped,
      Const(0, width: _eventDataInOverflowBit - _eventWriteTimeoutBit - 1),
      writeTimeoutEvent,
      Const(0, width: _eventWriteTimeoutBit - _eventReadTimeoutBit - 1),
      timeoutEvent,
      if (_eventReadTimeoutBit > 0) Const(0, width: _eventReadTimeoutBit),
    ].swizzle().named('event_set');

    // CTRL bit 0 gates the card. The SD clock domain reads it.
    output('card_enable') <= ctrlReg[_ctrlEnableBit];
    output('num_blocks') <= numBlocksReg;

    // Sequential block: register writes + bus handshake.
    Sequential(clk, [
      If(
        reset,
        then: [
          ctrlReg < Const(0, width: 32),
          numBlocksReg < Const(0, width: 32),
          scratchReg < Const(0, width: 32),
          irqEnableReg < Const(0, width: 32),
          for (var i = 0; i < csdRegs.length; i++)
            csdRegs[i] < Const(sdCardCsdWords[i], width: 32),
          csdShadow < Const(sdCardCsdValue, width: sdResponseRegBits),
          readCount < Const(0, width: 32),
          writeCount < Const(0, width: 32),
          pushWords < Const(0, width: sdDataWordCountBits),
          tagPending < Const(0, width: sdTagChannelBits),
          tagPendingValid < Const(0),
          blockAdmission < Const(0),
          blockDoneDelay < Const(0),
          blocksPushed < Const(0, width: sdBlockCountBits),
          blocksPushedGray < Const(0, width: sdBlockCountBits),
          timeoutPrev < Const(0),
          writeTimeoutPrev < Const(0),
          popWords < Const(0, width: sdDataWordCountBits),
          fillLbaReg < Const(0, width: sdCommandArgBits),
          fillLbaValid < Const(0),
          eventReg < Const(0, width: 32),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          // Defaults each cycle. Any register not driven below reads 0, which
          // is exactly the phase-1 contract for the RO registers.
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          // The block read path. These run on every clock and not only on
          // a bus access, because the card raises an event whenever it
          // likes and the block toggle has to follow the pushes by a fixed
          // number of clocks.
          timeoutPrev < timeoutLevel,
          writeTimeoutPrev < writeTimeoutLevel,
          eventReg < (eventReg & ~eventClear) | eventSet,
          If(
            outPop,
            then: [popWords < popWords + Const(1, width: sdDataWordCountBits)],
          ),
          If(
            dataAccepted,
            then: [
              pushWords < pushWords + Const(1, width: sdDataWordCountBits),
            ],
          ),
          blockDoneDelay < blockDone,
          blocksPushed < blocksPushedNext,
          blocksPushedGray < sdBinaryToGray(blocksPushedNext),

          // The fill address. A write of DATA_FILL_LBA takes it, and the
          // write of DATA_TAG that reserves its block takes it away again.
          // The clear comes SECOND, so a bus that somehow did
          // both in one clock leaves no address standing: an address that
          // outlived its block would put the next fill in the wrong line.
          If(
            fillLbaWrite,
            then: [fillLbaReg < bus.dataIn, fillLbaValid < Const(1)],
          ),
          If(tagWrite, then: [fillLbaValid < Const(0)]),

          // The tag that waits for its block. The commit comes FIRST and
          // the load of a new tag comes after it, so a bus that somehow
          // wrote DATA_TAG on the very clock a block finished keeps the
          // new tag for the NEXT block and does not lose it.
          If(
            blockDone,
            then: [tagPendingValid < Const(0), blockAdmission < Const(0)],
          ),
          If(
            tagAccepted,
            then: [
              tagPending < tagEntry,
              tagPendingValid < Const(1),
              blockAdmission < Const(1),
            ],
          ),

          // Bus register interface.
          // Region decode: bits [11:8] of the byte address. The CSR map lives
          // in region 0x0.
          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),
              If(
                bus.we,
                then: [writeCount < writeCount + Const(1, width: 32)],
                orElse: [readCount < readCount + Const(1, width: 32)],
              ),

              Case(bus.addr.getRange(8, 12), [
                // CSR region.
                CaseItem(Const(0x0, width: 4), [
                  Case(bus.addr.getRange(0, 8), [
                    // ID: RO, the 'MIMC' magic.
                    CaseItem(Const(MimicReg.id, width: 8), [
                      bus.dataOut < Const(MimicRegValue.id, width: 32),
                    ]),

                    // VERSION: RO, the packed interface version.
                    CaseItem(Const(MimicReg.version, width: 8), [
                      bus.dataOut < Const(MimicRegValue.version, width: 32),
                    ]),

                    // CTRL: RW.
                    CaseItem(Const(MimicReg.ctrl, width: 8), [
                      If(
                        bus.we,
                        then: [ctrlReg < bus.dataIn],
                        orElse: [bus.dataOut < ctrlReg],
                      ),
                    ]),

                    // STATUS: RO, reads 0.
                    CaseItem(Const(MimicReg.status, width: 8), [
                      bus.dataOut < Const(0, width: 32),
                    ]),

                    // NUM_BLOCKS: RW.
                    CaseItem(Const(MimicReg.numBlocks, width: 8), [
                      If(
                        bus.we,
                        then: [numBlocksReg < bus.dataIn],
                        orElse: [bus.dataOut < numBlocksReg],
                      ),
                    ]),

                    // SCRATCH: RW.
                    CaseItem(Const(MimicReg.scratch, width: 8), [
                      If(
                        bus.we,
                        then: [scratchReg < bus.dataIn],
                        orElse: [bus.dataOut < scratchReg],
                      ),
                    ]),

                    // REQ: RO. Word 0 of the record at the head of the
                    // request channel, with NO side effect. An empty
                    // channel reads 0.
                    CaseItem(Const(MimicReg.req, width: 8), [
                      If(
                        bus.we,
                        then: [],
                        orElse: [
                          If(
                            ~reqEmpty,
                            then: [
                              bus.dataOut < input('req_data').slice(31, 0),
                            ],
                          ),
                        ],
                      ),
                    ]),

                    // REQ_COUNT: RO, whole records that are waiting.
                    //
                    // The channel reports empty or not empty and no depth,
                    // so the count SATURATES at one. It can therefore only
                    // report FEWER records than there are, which is the
                    // safe direction: the runtime reads the count and then
                    // takes that many records with no second look, so a
                    // count that is too large would make it read words
                    // that no card ever pushed.
                    CaseItem(Const(MimicReg.reqCount, width: 8), [
                      bus.dataOut <
                          mux(
                            reqEmpty,
                            Const(0, width: 32),
                            Const(1, width: 32),
                          ),
                    ]),

                    // DATA_IN: WO stream. The push itself is
                    // combinational, above this block, because the FIFO
                    // takes the word on this same clock edge.
                    CaseItem(Const(MimicReg.dataIn, width: 8), [
                      If(bus.we, then: []),
                    ]),

                    // DATA_IN_COUNT: RO, the FREE SPACE of the data
                    // channel in words.
                    CaseItem(Const(MimicReg.dataInCount, width: 8), [
                      bus.dataOut < freeWords.zeroExtend(32),
                    ]),

                    // DATA_OUT: RO. The word at the HEAD of the write
                    // channel, with NO side effect. The word goes away
                    // only on a write of DATA_OUT_POP, so a bulk read of
                    // the map cannot take part of a block. An empty
                    // channel reads 0.
                    CaseItem(Const(MimicReg.dataOut, width: 8), [
                      If(
                        bus.we,
                        then: [],
                        orElse: [
                          If(
                            ~outEmpty,
                            then: [bus.dataOut < input('out_data')],
                          ),
                        ],
                      ),
                    ]),

                    // DATA_OUT_COUNT: RO, the WORDS waiting on the write
                    // channel. See where the count is built: it is
                    // conservative and can only report fewer words than
                    // there are.
                    CaseItem(Const(MimicReg.dataOutCount, width: 8), [
                      bus.dataOut < outAvail.zeroExtend(32),
                    ]),

                    // EVENT: RW1C. The clear itself is combinational,
                    // above this block, so a bit the card raises on the
                    // same clock is not lost.
                    CaseItem(Const(MimicReg.event, width: 8), [
                      If(bus.we, then: [], orElse: [bus.dataOut < eventReg]),
                    ]),

                    // IRQ_ENABLE: RW.
                    CaseItem(Const(MimicReg.irqEnable, width: 8), [
                      If(
                        bus.we,
                        then: [irqEnableReg < bus.dataIn],
                        orElse: [bus.dataOut < irqEnableReg],
                      ),
                    ]),

                    // Debug counters (read-only, internal bus-access counts).
                    CaseItem(Const(MimicReg.dbgCmdCount, width: 8), [
                      bus.dataOut < readCount,
                    ]),

                    CaseItem(Const(MimicReg.dbgInCount, width: 8), [
                      bus.dataOut < writeCount,
                    ]),

                    CaseItem(Const(MimicReg.dbgResetCount, width: 8), [
                      bus.dataOut < Const(0, width: 32),
                    ]),

                    // CARD_STATE: RO, the SD card state in the low bits. The
                    // width comes from the port, so the field cannot drift
                    // from the state machine that makes it.
                    CaseItem(Const(MimicReg.cardState, width: 8), [
                      bus.dataOut < input('card_state').zeroExtend(32),
                    ]),

                    // The SD bring-up counters: RO. Each one is a count
                    // that the SoC crossed out of the SD clock domain, so
                    // the read is a plain zero extend of a settled value.
                    // The width comes from the port, so a counter that
                    // grows cannot silently lose its top bits here.
                    //
                    // DBG_SD_CLK is the register a bring-up reads first: a
                    // 0 that stays 0 over two reads says the SD clock never
                    // reaches the fabric, and CARD_STATE reads `idle` for
                    // that fault and for two others.
                    CaseItem(Const(MimicReg.dbgSdClk, width: 8), [
                      bus.dataOut < input('dbg_sd_clk').zeroExtend(32),
                    ]),

                    CaseItem(Const(MimicReg.dbgSdCmd, width: 8), [
                      bus.dataOut < input('dbg_sd_cmd').zeroExtend(32),
                    ]),

                    CaseItem(Const(MimicReg.dbgSdCrcErr, width: 8), [
                      bus.dataOut < input('dbg_sd_crc_err').zeroExtend(32),
                    ]),

                    CaseItem(Const(MimicReg.dbgSdResp, width: 8), [
                      bus.dataOut < input('dbg_sd_resp').zeroExtend(32),
                    ]),

                    // REQ_HI: RO. Word 1 of the record, which is the block
                    // address. The read has NO side effect, so a reader
                    // may read it as often as it likes and a bulk read
                    // that crosses it takes nothing. REQ_POP below is the
                    // one thing that moves the channel. An empty channel
                    // reads 0.
                    CaseItem(Const(MimicReg.reqHi, width: 8), [
                      If(
                        bus.we,
                        then: [],
                        orElse: [
                          If(
                            ~reqEmpty,
                            then: [
                              bus.dataOut < input('req_data').slice(63, 32),
                            ],
                          ),
                        ],
                      ),
                    ]),

                    // DATA_TAG: WO. The sequence tag of the block that
                    // follows, in the low 8 bits. The push is
                    // combinational, above this block, for the reason the
                    // DATA_IN push is.
                    CaseItem(Const(MimicReg.dataTag, width: 8), [
                      If(bus.we, then: []),
                    ]),

                    // REQ_POP: WO. A write with bit 0 set takes the record
                    // at the head of the request channel away. The pop
                    // itself is combinational, above this block, because
                    // the FIFO moves its pointer on this same clock edge.
                    // A write with the bit clear does nothing, a write to
                    // an empty channel does nothing, and the register
                    // reads 0.
                    CaseItem(Const(MimicReg.reqPop, width: 8), [
                      If(bus.we, then: []),
                    ]),

                    // DATA_OUT_POP: WO. A write with bit 0 set takes one
                    // word off the write channel. The pop itself is
                    // combinational, above this block. A write with the
                    // bit clear does nothing, a write to an empty channel
                    // does nothing, and the register reads 0.
                    CaseItem(Const(MimicReg.dataOutPop, width: 8), [
                      If(bus.we, then: []),
                    ]),

                    // WRITE_ACK: WO. It retires one block write and
                    // releases the SD host from busy. The push is
                    // combinational, above this block, for the reason the
                    // DATA_IN push is.
                    CaseItem(Const(MimicReg.writeAck, width: 8), [
                      If(bus.we, then: []),
                    ]),

                    // DATA_FILL_LBA: WO. The block address of the FILL
                    // that follows. The capture is above this block, for
                    // the reason the DATA_IN push is. The register reads
                    // 0, so every side effect of the fill path is a WRITE
                    // and the read invariant of the map holds.
                    CaseItem(Const(MimicReg.dataFillLba, width: 8), [
                      If(bus.we, then: []),
                    ]),

                    // The three block cache counters: RO. Each one is a
                    // count that the SoC crossed out of the SD clock
                    // domain, so the read is a plain zero extend of a
                    // settled value.
                    //
                    // DBG_CACHE_HIT and DBG_CACHE_MISS read together give
                    // the hit rate. A cache that nobody can measure is a
                    // cache that nobody can tune.
                    CaseItem(Const(MimicReg.dbgCacheHit, width: 8), [
                      bus.dataOut < input('dbg_cache_hit').zeroExtend(32),
                    ]),

                    CaseItem(Const(MimicReg.dbgCacheMiss, width: 8), [
                      bus.dataOut < input('dbg_cache_miss').zeroExtend(32),
                    ]),

                    CaseItem(Const(MimicReg.dbgCacheFill, width: 8), [
                      bus.dataOut < input('dbg_cache_fill').zeroExtend(32),
                    ]),

                    // CACHE_LINES: RO, the number of lines this build has.
                    // The runtime reads the geometry rather than assumes
                    // it, so one runtime serves every build.
                    CaseItem(Const(MimicReg.cacheLines, width: 8), [
                      bus.dataOut < Const(this.cacheLines, width: 32),
                    ]),

                    // A contiguous, read-only view of request count and
                    // both head words. One USB READ can fetch all three.
                    // The record cannot move until REQ_POP is written, so
                    // a count of one makes the following words coherent.
                    CaseItem(Const(MimicReg.reqSnapshotCount, width: 8), [
                      bus.dataOut <
                          mux(
                            reqEmpty,
                            Const(0, width: 32),
                            Const(1, width: 32),
                          ),
                    ]),

                    CaseItem(Const(MimicReg.reqSnapshot, width: 8), [
                      If(
                        ~bus.we & ~reqEmpty,
                        then: [bus.dataOut < input('req_data').slice(31, 0)],
                      ),
                    ]),

                    CaseItem(Const(MimicReg.reqSnapshotHi, width: 8), [
                      If(
                        ~bus.we & ~reqEmpty,
                        then: [bus.dataOut < input('req_data').slice(63, 32)],
                      ),
                    ]),

                    CaseItem(Const(MimicReg.dbgReadStart, width: 8), [
                      bus.dataOut < input('dbg_read_start').zeroExtend(32),
                    ]),

                    CaseItem(Const(MimicReg.dbgReadDone, width: 8), [
                      bus.dataOut < input('dbg_read_done').zeroExtend(32),
                    ]),

                    CaseItem(Const(MimicReg.dbgReadDrop, width: 8), [
                      bus.dataOut < input('dbg_read_drop').zeroExtend(32),
                    ]),

                    CaseItem(Const(MimicReg.dbgReadAbort, width: 8), [
                      bus.dataOut < input('dbg_read_abort').zeroExtend(32),
                    ]),

                    // CSD_0 to CSD_3: RW. The runtime writes the whole CSD
                    // that CMD9 answers with, one word at a time. The
                    // hardware reads no field of it.
                    //
                    // The write of the LAST word also commits the block
                    // into the shadow register. The word that this cycle
                    // carries comes from the bus and not from the staging
                    // register, because both loads happen on this one
                    // clock and the staging register still holds the value
                    // it had before.
                    for (var i = 0; i < csdRegs.length; i++)
                      CaseItem(Const(MimicReg.csd[i], width: 8), [
                        If(
                          bus.we,
                          then: [
                            csdRegs[i] < bus.dataIn,
                            if (i == csdCommitIndex)
                              csdShadow <
                                  [
                                    for (var w = 0; w < csdRegs.length; w++)
                                      if (w == csdCommitIndex)
                                        bus.dataIn
                                      else
                                        csdRegs[w],
                                  ].rswizzle(),
                          ],
                          orElse: [bus.dataOut < csdRegs[i]],
                        ),
                      ]),
                  ]),
                ]),
              ]),
            ],
          ),
        ],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['lilithsemi,mimic-sd-card'],
    reg: BusAddressRange(baseAddress, windowSize),
    properties: {
      'lilithsemi,interface-version': MimicRegValue.version,
      '#address-cells': 1,
      '#size-cells': 1,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'MIMIC_SD_CARD',
    groupName: 'MIMIC',
    description: 'Mimic SD card CSR interface',
    baseAddress: baseAddress,
    size: windowSize,
    registers: _mimicSdCardRegisterMap,
  );
}
