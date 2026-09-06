/// Mimic CSR map and USB command protocol constants.
///
/// Pure Dart. No ROHD imports. The host runtime (Zig) and the tests keep in
/// sync with this file. Every value below is part of the wire contract
/// between the host and the device. Change a value here, and the host and
/// the tests must change with it.
///
/// Register map
///   All registers are 32 bits wide and live on 4-byte boundaries. The
///   addresses below are byte addresses. The CSR space starts at the fabric
///   base [mimicCsrBase] (0x00000000).
///
///   0x00 ID              RO  reads 0x4D494D43 (the 'MIMC' magic)
///   0x04 VERSION         RO  reads 0x00010000 (interface version 1.0.0)
///   0x08 CTRL            RW  reset 0
///   0x0C STATUS          RO  reads 0
///   0x10 NUM_BLOCKS      RW  reset 0
///   0x14 SCRATCH         RW  reset 0
///   0x18 REQ             RO  word 0 of the record at the head, no pop
///   0x1C REQ_COUNT       RO  whole records waiting
///   0x20 DATA_IN         WO  pushes one word of a block
///   0x24 DATA_IN_COUNT   RO  free space of the data channel, in words
///   0x28 DATA_OUT        RO  head word of the write channel, no pop
///   0x2C DATA_OUT_COUNT  RO  words waiting on the write channel
///   0x30 EVENT           RW1C see [MimicEvent]
///   0x34 IRQ_ENABLE      RW  reset 0
///   0x38 DBG_CMD_COUNT   RO  bus reads
///   0x3C DBG_IN_COUNT    RO  bus writes
///   0x40 DBG_RESET_COUNT RO  reads 0
///   0x44 CARD_STATE      RO  the SD card state, low 4 bits
///   0x48 CSD_0           RW  csd[31:0]    reset: the default CSD
///   0x4C CSD_1           RW  csd[63:32]   reset: the default CSD
///   0x50 CSD_2           RW  csd[95:64]   reset: the default CSD
///   0x54 CSD_3           RW  csd[127:96]  reset: the default CSD
///   0x58 DBG_SD_CLK      RO  SD clock ticks
///   0x5C DBG_SD_CMD      RO  commands framed on CMD
///   0x60 DBG_SD_CRC_ERR  RO  framed commands that failed CRC7
///   0x64 DBG_SD_RESP     RO  responses the card started to send
///   0x68 REQ_HI          RO  word 1 of the record, no side effect
///   0x6C DATA_TAG        WO  the sequence tag of the next block
///   0x70 REQ_POP         WO  a write of bit 0 takes the record away
///   0x74 DATA_OUT_POP    WO  a write of bit 0 takes one word away
///   0x78 WRITE_ACK       WO  retires one write and releases the host
///   0x7C DATA_FILL_LBA   WO  the block address of the FILL that follows
///   0x80 DBG_CACHE_HIT   RO  reads the block cache answered itself
///   0x84 DBG_CACHE_MISS  RO  reads the block cache did not hold
///   0x88 DBG_CACHE_FILL  RO  lines the block cache finished filling
///   0x8C CACHE_LINES     RO  lines the block cache of this build has
///
/// NO ADDRESS OF THIS MAP HAS A SIDE EFFECT ON READ.
///   A read of any address, at any time, in any order, changes no state of
///   the device. A bulk read of the whole map, a debug tool, `mimic-cli
///   info` and anything a person writes later are therefore safe by
///   construction and not by an address that they must keep away from.
///   Every side effect of this map is a WRITE.
///
/// Request channel
///   A record is two words and the two words live at two ADDRESSES. REQ
///   gives word 0 and REQ_HI gives word 1, and NEITHER read changes
///   anything. The record stays at the head of the channel until the
///   reader writes bit 0 of REQ_POP, and that write is the only thing that
///   takes it away.
///
///   A reader therefore takes a record with three accesses: read REQ, read
///   REQ_HI, write REQ_POP. Any number of other accesses may come between
///   them, in any order, and the record is the same record throughout. The
///   cost is one more USB round trip for each record, which is nothing
///   against the 42 ms read timeout of the card.
///
///   A write of REQ_POP with bit 0 clear does nothing, and a write to an
///   EMPTY channel does nothing.
///
/// The block cache
///   The card holds whole 512-byte blocks, tagged by block address, and a
///   read that it holds costs NO record and no USB round trip at all. The
///   card does the LOOKUP alone. Every POLICY decision is the runtime's:
///   the runtime chooses what occupies every line, and the card never
///   evicts a line by itself.
///
///   A FILL is a block that answers no request. The runtime writes the
///   block address to DATA_FILL_LBA, writes DATA_TAG with the tag 0, which
///   names no record, and pushes the 128 words into DATA_IN. The card
///   writes the block into the line the address maps to and sends nothing.
///   The two writes belong together: the address travels with the tag
///   through the same channel, so a fill can never take the address of
///   another push, and a block whose tag is 0 with no address before it is
///   thrown away the way an untagged block has always been.
///
///   The card drops a line by itself in ONE case: a CMD24 to a block it
///   holds INVALIDATES that line, because a write must not leave the
///   pre-write bytes where a later read can find them. The runtime sees
///   that write as a record on the channel it already reads, so its model
///   of the store follows with no synchronisation of any kind. A reset and
///   a CMD0 invalidate every line.
///
///   CACHE_LINES reads the number of lines the build has, so a runtime
///   learns the geometry of the card it is talking to and never assumes
///   one. The three DBG_CACHE counters make the hit rate observable, which
///   is the only way a policy can be tuned at all.
///
/// SD bring-up counters
///   The four DBG_SD registers separate three faults that CARD_STATE alone
///   cannot tell apart, because the card reads `idle` for all three:
///     - DBG_SD_CLK 0: no SD clock reaches the FPGA. The pad, the clock
///       buffer or the board wiring is the fault, and nothing else can be
///       diagnosed until it moves.
///     - DBG_SD_CLK moves and DBG_SD_CMD 0: the clock arrives and no
///       command is ever framed. CMD is the fault.
///     - DBG_SD_CMD moves and DBG_SD_CRC_ERR follows it: commands arrive
///       and fail CRC7. The sampling edge or the bit order is the fault.
///     - DBG_SD_CMD moves and DBG_SD_RESP stays at 0: the card hears the
///       host and answers nothing.
///   All four count in the SD clock domain and cross into the SoC domain
///   as gray codes, so a read is always a count the counter really held.
///   They wrap, the same way DBG_CMD_COUNT does.
///
/// CSD register block
///   The four CSD registers hold the 128-bit CSD that the card answers
///   CMD9 with. CSD_0 holds the LOWEST 32 bits, and CSD_3 holds the
///   highest, so the block reads as one little-endian 128-bit number. The
///   runtime writes the register exactly as `sdCsdV2` in sd_regs.dart
///   builds it, with the CRC7 and the end bit in the low byte, and the
///   hardware sends the 128 bits with nothing added.
///
///   NOTE: `sdRegisterToWords` gives the words in WIRE order, which is the
///   most significant word first. That is the opposite of this register
///   order, so a caller that uses it must reverse the list.
///
/// USB command framing
///   The host sends a 7-byte little-endian header on the bulk OUT endpoint:
///   { opcode u8, addr u32, len u16 }. The opcodes are [MimicUsbOpcode].
library;

/// Base address of the CSR space on the SoC fabric.
const int mimicCsrBase = 0x00000000;

/// Byte offsets of the 32-bit CSR registers.
class MimicReg {
  MimicReg._();

  /// ID: reads the 'MIMC' magic.
  static const int id = 0x00;

  /// VERSION: reads the packed interface version.
  static const int version = 0x04;

  /// CTRL: read-write control bits. Reset 0.
  static const int ctrl = 0x08;

  /// STATUS: reads 0.
  static const int status = 0x0C;

  /// NUM_BLOCKS: read-write block count. Reset 0.
  static const int numBlocks = 0x10;

  /// SCRATCH: read-write test register. Reset 0.
  static const int scratch = 0x14;

  /// REQ: read-only. Word 0 of the record at the head of the request
  /// channel, with NO side effect.
  ///
  /// A record is two words. Word 0 holds the opcode in bits 7 to 0, the
  /// SEQUENCE TAG in bits 15 to 8 and the block count in bits 31 to 16.
  /// Word 1 holds the BLOCK address, which is not a byte address, and it
  /// lives at [reqHi]. Opcode 1 is read_blocks and it is the only one
  /// defined. An unknown opcode still takes the whole record, so a reader
  /// that cannot serve a record leaves the channel in step.
  ///
  /// The two words live at two addresses and NEITHER read has a side
  /// effect. A reader takes a record with one read here, one read of
  /// [reqHi] and one write of [reqPop], and any number of other accesses
  /// between them changes nothing.
  ///
  /// The sequence tag names the request. A reader that answers a record
  /// must write the tag to [dataTag] before it pushes the block, or the
  /// card throws the block away. See [dataTag].
  ///
  /// An empty channel reads 0.
  static const int req = 0x18;

  /// REQ_COUNT: read-only. Whole RECORDS waiting on the request channel,
  /// not words.
  ///
  /// The count saturates at 1, so it can only report FEWER records than
  /// there are. That is the safe direction: a reader takes the count and
  /// then reads that many records with no second look, and a count that
  /// was too large would make it read words that no card pushed.
  static const int reqCount = 0x1C;

  /// DATA_IN: write-only stream. A write pushes one 32-bit word into the
  /// data channel of the card.
  ///
  /// The words are LITTLE ENDIAN: byte 0 of the block is bits 7 to 0 of
  /// the first word. One block is 128 words, and the card sends the block
  /// only once all 128 have landed.
  static const int dataIn = 0x20;

  /// DATA_IN_COUNT: read-only. The FREE SPACE of the data channel, in
  /// WORDS, and not the words it holds.
  ///
  /// The count is conservative: part of it comes from a counter that has
  /// crossed out of the SD clock domain and may be behind, so it can only
  /// ever report LESS free space than there is. A writer waits for a whole
  /// block of space before it pushes a block.
  static const int dataInCount = 0x24;

  /// DATA_OUT: read-only. The word at the HEAD of the write data channel.
  ///
  /// The read has NO side effect, the same way the two record reads have
  /// none. The word goes away only on a write of [dataOutPop], so a bulk
  /// read of the map, a debug tool or `mimic-cli info` cannot take a word
  /// of a block by accident and leave the reader with 511 bytes.
  ///
  /// The words are LITTLE ENDIAN and match [dataIn]: byte 0 of the block is
  /// bits 7 to 0 of the FIRST word taken. One block is 128 words.
  ///
  /// An empty channel reads 0.
  static const int dataOut = 0x28;

  /// DATA_OUT_COUNT: read-only. The 32-bit WORDS waiting on the write data
  /// channel.
  ///
  /// The count is conservative: part of it comes from a counter that has
  /// crossed out of the SD clock domain and may be behind, so it can only
  /// ever report FEWER words than there are. A reader waits for a whole
  /// block of 128 words before it takes a block.
  static const int dataOutCount = 0x2C;

  /// EVENT: write-1-to-clear. See [MimicEvent] for the bits.
  static const int event = 0x30;

  /// IRQ_ENABLE: read-write interrupt enable. Reset 0.
  static const int irqEnable = 0x34;

  /// DBG_CMD_COUNT: read-only. Commands received on EP1 OUT (cmd_start
  /// pulses). Wraps at 65535.
  static const int dbgCmdCount = 0x38;

  /// DBG_IN_COUNT: read-only. IN responses sent (in_toggle transitions).
  /// Wraps at 65535.
  static const int dbgInCount = 0x3C;

  /// DBG_RESET_COUNT: read-only. USB bus resets detected. Non-zero means
  /// spurious resets.
  static const int dbgResetCount = 0x40;

  /// CARD_STATE: read-only. The card state of the SD card state machine, in
  /// the low 4 bits, crossed into the SoC clock domain. The runtime reads it
  /// to watch identification progress with no logic analyser: 0 idle, 1
  /// ready, 2 ident, 3 stby, 4 tran. The values are the CURRENT_STATE field
  /// of the SD Physical Layer specification, and `sd_card_fsm.dart` holds
  /// them as the `sdCardState*` constants. The other 28 bits read 0.
  static const int cardState = 0x44;

  /// CSD_0: read-write. Bits 31 to 0 of the CSD register.
  ///
  /// The four CSD registers give the card its capacity and its timing. The
  /// hardware holds NO knowledge of the CSD layout: the runtime owns the
  /// personality and writes the whole 128-bit register. The reset value is
  /// the default CSD, so a host that probes the card before the runtime
  /// writes anything still reads a card that identifies.
  static const int csd0 = 0x48;

  /// CSD_1: read-write. Bits 63 to 32 of the CSD register.
  static const int csd1 = 0x4C;

  /// CSD_2: read-write. Bits 95 to 64 of the CSD register.
  static const int csd2 = 0x50;

  /// CSD_3: read-write. Bits 127 to 96 of the CSD register.
  static const int csd3 = 0x54;

  /// DBG_SD_CLK: read-only. SD clock ticks, counted in the SD clock
  /// domain.
  ///
  /// It counts CLOCK EDGES and nothing gates it: no command, no response
  /// and no card state holds it still. A value that stays at 0 over two
  /// reads therefore says the SD clock never reaches the fabric, and no
  /// other register can say that. A value that moves proves the pad, the
  /// clock buffer and the clock net are alive even when the card answers
  /// nothing. It wraps at 24 bits.
  static const int dbgSdClk = 0x58;

  /// DBG_SD_CMD: read-only. Commands the SD link framed on CMD, whatever
  /// their CRC7. It wraps at 16 bits.
  static const int dbgSdCmd = 0x5C;

  /// DBG_SD_CRC_ERR: read-only. Framed commands whose CRC7 failed. It
  /// counts a subset of DBG_SD_CMD, so the two read together say whether
  /// the CMD line samples correctly. It wraps at 16 bits.
  static const int dbgSdCrcErr = 0x60;

  /// DBG_SD_RESP: read-only. Responses the card started to transmit. A
  /// DBG_SD_CMD that moves with this at 0 says the card hears the host and
  /// answers nothing. It wraps at 16 bits.
  static const int dbgSdResp = 0x64;

  /// REQ_HI: read-only. Word 1 of the record at the head of the request
  /// channel, which is the BLOCK address.
  ///
  /// The read has NO side effect. The record stays at the head of the
  /// channel until a write of [reqPop] takes it away, so a reader may read
  /// this address as often as it likes and a bulk read that crosses it
  /// cannot lose a record. An empty channel reads 0.
  static const int reqHi = 0x68;

  /// DATA_TAG: write-only. The sequence tag of the block that follows.
  ///
  /// The low 8 bits carry the tag, and the other 24 bits are ignored. The
  /// tag is the value that bits 15 to 8 of word 0 of the record held. A
  /// reader writes it ONE time, immediately before it pushes the 128 words
  /// of the block into [dataIn].
  ///
  /// The card compares the tag with the request it is waiting for. A block
  /// whose tag names another request is thrown away, so a late answer can
  /// never become the answer to the next read.
  ///
  /// The tag [MimicDataTag.fill], which is 0, names NO request and marks a
  /// FILL: the block goes into the line that [dataFillLba] names and
  /// nothing is sent on the SD bus. A block that carries that tag with no
  /// [dataFillLba] written before it is thrown away, which is what an
  /// untagged block has always been.
  static const int dataTag = 0x6C;

  /// REQ_POP: write-only. A write with [MimicReqPop.pop] set takes the
  /// record at the head of the request channel away.
  ///
  /// This register exists so that NO read of this map has a side effect.
  /// The pop is an ACTION and not a state bit, so it takes a register of
  /// its own and not a spare bit of [ctrl]: [ctrl] is read-write storage
  /// that reads back what a writer put in it, and a self-clearing bit
  /// inside it would either read back wrong or pop a second record on the
  /// next read-modify-write of [ctrl].
  ///
  /// A write with bit 0 clear does nothing, and a write to an empty
  /// channel does nothing. The register reads 0.
  static const int reqPop = 0x70;

  /// DATA_OUT_POP: write-only. A write with [MimicDataOutPop.pop] set takes
  /// the word at the head of the write data channel away.
  ///
  /// This register exists for the reason [reqPop] exists: NO ADDRESS OF
  /// THIS MAP HAS A SIDE EFFECT ON READ. A reader takes one word with one
  /// read of [dataOut] and one write here, and any number of other
  /// accesses between the two changes nothing.
  ///
  /// A write with bit 0 clear does nothing, and a write to an empty
  /// channel does nothing. The register reads 0.
  static const int dataOutPop = 0x74;

  /// WRITE_ACK: write-only. It retires one block write and releases the SD
  /// host from busy.
  ///
  /// The low 8 bits carry the sequence tag of the record that the write
  /// answers, which is the tag that bits 15 to 8 of word 0 of the record
  /// held. [MimicWriteAck.fail] says that the reader could not write the
  /// block.
  ///
  /// The card holds DAT0 LOW from the CRC status token until this write
  /// arrives, and the SD host waits on that level. A reader that takes a
  /// block and never writes here therefore holds the host until the card
  /// gives up by itself, so the write must follow the last
  /// [dataOutPop] of the block at once.
  ///
  /// The tag is what makes a LATE write safe. Only a tag that names the
  /// block the card is holding the host for releases busy, so a write that
  /// arrives after the card gave up cannot release the host for the wrong
  /// block.
  ///
  /// The tag does NOT decide which block leaves the write data channel.
  /// Every write here retires one block from the count of blocks that the
  /// card believes are on that channel, whatever the tag says, because the
  /// runtime took those 512 bytes whatever record they belonged to. The
  /// channel itself is what holds the next write off: the card refuses a
  /// new write while the FIFO still holds a word. So a write here that
  /// names nothing costs nothing, and a write with the tag 0 does nothing
  /// at all, because 0 names no record.
  static const int writeAck = 0x78;

  /// DATA_FILL_LBA: write-only. The block address of the FILL that
  /// follows.
  ///
  /// A FILL is a block the card never asked for. The runtime writes the
  /// block address here, writes [dataTag] with [MimicDataTag.fill], which
  /// is the tag 0 and names no record, and then pushes the 128 words into
  /// [dataIn]. The card writes the block into the line that address maps
  /// to and sends NOTHING on the SD bus.
  ///
  /// The address travels with the tag through the same channel, so the
  /// order of the two writes is fixed: this address first and the tag
  /// second. The tag reserves room for the whole block, and the last data
  /// word commits the pair. A block whose tag is 0 with no address written
  /// before it is thrown away, the way an untagged block has always been,
  /// so a runtime that forgets this write loses the fill and never fills
  /// the wrong line.
  ///
  /// The register reads 0.
  static const int dataFillLba = 0x7C;

  /// DBG_CACHE_HIT: read-only. Reads the block cache answered by itself,
  /// with no record posted. It wraps at 16 bits.
  static const int dbgCacheHit = 0x80;

  /// DBG_CACHE_MISS: read-only. Reads the block cache did not hold, each
  /// of which posted one record. It wraps at 16 bits.
  ///
  /// Read with [dbgCacheHit] it gives the hit rate. A cache that nobody
  /// can measure is a cache that nobody can tune.
  static const int dbgCacheMiss = 0x84;

  /// DBG_CACHE_FILL: read-only. Lines the block cache finished filling,
  /// whether the block answered a record or was a fill the runtime pushed.
  /// It wraps at 16 bits.
  ///
  /// A fill counts only when the LAST word of the block has landed, so a
  /// count that stands still while blocks go in says the pushes are
  /// short.
  static const int dbgCacheFill = 0x88;

  /// CACHE_LINES: read-only. The number of lines the block cache of this
  /// build has.
  ///
  /// The line count is a build parameter, because the V1 board and the V2
  /// ASIC have different budgets. A runtime reads it rather than assumes
  /// it, so one runtime serves every build. One line holds ONE 512-byte
  /// block, so the store is this many blocks.
  static const int cacheLines = 0x8C;

  /// The three block cache counters, in address order.
  static const List<int> dbgCache = [dbgCacheHit, dbgCacheMiss, dbgCacheFill];

  /// The four SD bring-up counters, in address order.
  static const List<int> dbgSd = [dbgSdClk, dbgSdCmd, dbgSdCrcErr, dbgSdResp];

  /// The four CSD registers, from the lowest 32 bits to the highest.
  ///
  /// The index of an entry is the word number, so entry 0 holds
  /// `csd[31:0]`. A caller that walks the block writes it in this order.
  static const List<int> csd = [csd0, csd1, csd2, csd3];
}

/// Fixed register values.
class MimicRegValue {
  MimicRegValue._();

  /// ID register magic: 'MIMC' packed little-endian.
  static const int id = 0x4D494D43;

  /// VERSION register: interface version 1.0.0 packed as
  /// major << 16 | minor << 8 | patch.
  static const int version = 0x00010000;

  /// Interface version as a dotted string.
  static const String versionString = '1.0.0';
}

/// CTRL register bits.
class MimicCtrl {
  MimicCtrl._();

  /// Bit 0: enable the device.
  static const int enable = 1 << 0;

  /// Bit 1: drive the test pattern.
  static const int testPattern = 1 << 1;

  /// Bit 2: force read-only behavior.
  static const int readOnly = 1 << 2;

  /// Bit 3: bypass the host cache.
  static const int cacheBypass = 1 << 3;

  /// Bit 4: write-back. A 0 means write-through.
  ///
  /// Write-through holds the SD host on busy until the reader has taken
  /// the block, so an acknowledged write is a write the reader holds.
  /// Write-back releases the host as soon as the block is on the channel,
  /// which hides the round trip but loses an acknowledged write if the
  /// link dies before the reader takes it. An `fsync` on the SD host
  /// cannot prevent that, because the card already said the write was
  /// done.
  static const int writeBack = 1 << 4;
}

/// DATA_OUT_POP register bits.
class MimicDataOutPop {
  MimicDataOutPop._();

  /// Bit 0: take the word at the head of the write data channel away.
  ///
  /// A write with this bit clear does nothing at all, so a reader that
  /// writes 0 cannot lose a word by accident.
  static const int pop = 1 << 0;
}

/// WRITE_ACK register fields.
class MimicWriteAck {
  MimicWriteAck._();

  /// Bits 7 to 0: the sequence tag of the record being retired.
  static const int tagMask = 0xFF;

  /// Bit 8: the reader could not write the block.
  ///
  /// The card has already sent the CRC status token by the time this
  /// arrives, so the SD host is not told. The bit is here so that a later
  /// phase which holds the token back can send the write error code, and
  /// so that a runtime log can name the block that failed.
  static const int fail = 1 << 8;
}

/// REQ_POP register bits.
class MimicReqPop {
  MimicReqPop._();

  /// Bit 0: take the record at the head of the request channel away.
  ///
  /// A write with this bit clear does nothing at all, so a reader that
  /// writes 0 cannot lose a record by accident.
  static const int pop = 1 << 0;
}

/// DATA_TAG register values that are not a request tag.
class MimicDataTag {
  MimicDataTag._();

  /// The tag that names NO request, which marks a FILL.
  ///
  /// The card never gives this tag to a record, so a block that carries it
  /// answers nothing. A block with this tag goes into the line that
  /// [MimicReg.dataFillLba] names, and a block with this tag and no such
  /// address is thrown away.
  static const int fill = 0;
}

/// EVENT register bits. Every bit is write-one-to-clear.
class MimicEvent {
  MimicEvent._();

  /// Bit 0: a read the runtime never answered.
  ///
  /// The card asked for a block and no answer came before its timeout ran
  /// out. It sent nothing on DAT, returned to the transfer state and
  /// refused the next read until it knew whether a late answer was on its
  /// way. A runtime that reads this bit is either too slow or refused a
  /// record, and either way the host lost a read.
  static const int readTimeout = 1 << 0;

  /// Bit 1: a write the runtime never acknowledged.
  ///
  /// The card took a block, posted the record and held the SD host on busy
  /// until its own timeout ran out. It then released busy and returned to
  /// the transfer state. The block STAYS on the write channel, because
  /// only the runtime can take it off, so the card refuses every new write
  /// with the ERROR bit until the runtime answers.
  static const int writeTimeout = 1 << 1;

  /// Bit 2: a read data word was refused.
  ///
  /// The runtime wrote DATA_IN without a successful whole-block
  /// reservation, or the channel reported full after a reservation. The
  /// word went nowhere. The pending tag also stays out of the tag channel,
  /// so later blocks cannot be paired with it.
  ///
  /// This must never happen. DATA_IN_COUNT reports the free space in
  /// WORDS and it under-states it rather than over-states it, so a runtime
  /// that spends the count it read cannot fill the channel. The bit is
  /// here so that a runtime which does fill it FAILS LOUDLY instead of
  /// hiding a refused block.
  static const int dataInOverflow = 1 << 2;
}

/// USB command opcodes. The host sends these in the first byte of every
/// command frame.
class MimicUsbOpcode {
  MimicUsbOpcode._();

  /// WRITE: write `len` data bytes starting at `addr`. The address
  /// auto-increments once per 32-bit word.
  static const int write = 0x01;

  /// READ: the device returns `len` data bytes starting at `addr`.
  static const int read = 0x02;

  /// WRITE_STREAM: like WRITE, but the address stays fixed. Each full word
  /// lands on the same address, so the target acts as a FIFO.
  static const int writeStream = 0x03;
}
