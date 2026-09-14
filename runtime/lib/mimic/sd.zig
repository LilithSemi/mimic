//! The mimic CSR map and fixed register values. Every value here is part of
//! the wire contract between the host and the device. Change a value here,
//! and the device and the Dart side must change with it.
//!
//! All registers are 32 bits wide and sit on 4-byte boundaries. The
//! addresses below are byte addresses. The CSR space starts at 0.

const std = @import("std");

/// One SD card block, in bytes.
pub const BLOCK_SIZE: usize = 512;

/// Base address of the CSR space on the fabric.
pub const CSR_BASE: u32 = 0x00000000;

// Byte offsets of the 32-bit CSR registers.
/// ID: RO, reads the MIMC magic.
pub const REG_ID: u32 = 0x00;
/// VERSION: RO, reads the packed interface version.
pub const REG_VERSION: u32 = 0x04;
/// CTRL: RW, control bits, reset 0.
pub const REG_CTRL: u32 = 0x08;
/// STATUS: RO.
pub const REG_STATUS: u32 = 0x0C;
/// NUM_BLOCKS: RW, block count, reset 0.
pub const REG_NUM_BLOCKS: u32 = 0x10;
/// SCRATCH: RW, test register, reset 0.
pub const REG_SCRATCH: u32 = 0x14;
/// REQ: RO. Word 0 of the record at the head of the request FIFO, with NO
/// side effect. No address of this map has a side effect on read: the
/// record goes away only on a WRITE of REG_REQ_POP, so a burst that
/// crosses this address leaves the record where it is and a read here
/// never depends on what was read before it.
pub const REG_REQ: u32 = 0x18;
/// REQ_COUNT: RO.
pub const REG_REQ_COUNT: u32 = 0x1C;
/// DATA_IN: WO, FIFO stream. Reads have no effect.
pub const REG_DATA_IN: u32 = 0x20;
/// DATA_IN_COUNT: RO.
pub const REG_DATA_IN_COUNT: u32 = 0x24;
/// DATA_OUT: RO. The word at the head of the write data channel, with NO
/// side effect. The word goes away only on a WRITE of REG_DATA_OUT_POP, so
/// a burst that crosses this address takes nothing from a `serve` loop
/// that runs beside it. An empty channel reads 0.
pub const REG_DATA_OUT: u32 = 0x28;
/// DATA_OUT_COUNT: RO. The 32-bit words that the write data channel holds.
///
/// The count is conservative: the card can report fewer words than it
/// holds, never more. So a reader may act on the count it sees, but it
/// must not read a count below the block size as proof that the card
/// dropped the block.
pub const REG_DATA_OUT_COUNT: u32 = 0x2C;
/// EVENT: RW1C.
pub const REG_EVENT: u32 = 0x30;
/// IRQ_ENABLE: RW, reset 0.
pub const REG_IRQ_ENABLE: u32 = 0x34;

/// DBG_CMD_COUNT: RO. Commands received on EP1 OUT. Wraps.
pub const REG_DBG_CMD_COUNT: u32 = 0x38;

/// DBG_IN_COUNT: RO. IN responses sent. Wraps.
pub const REG_DBG_IN_COUNT: u32 = 0x3C;

/// DBG_RESET_COUNT: RO. USB bus resets detected.
pub const REG_DBG_RESET_COUNT: u32 = 0x40;

/// CARD_STATE: RO. The state of the SD card state machine, in the low 4
/// bits. The card drives this from the SD clock domain, so the value is
/// synchronised into the SoC domain before it reaches this register.
pub const REG_CARD_STATE: u32 = 0x44;

/// CSD_0: RW. Bits 31 to 0 of the SD CSD register.
pub const REG_CSD_0: u32 = 0x48;
/// CSD_1: RW. Bits 63 to 32 of the SD CSD register.
pub const REG_CSD_1: u32 = 0x4C;
/// CSD_2: RW. Bits 95 to 64 of the SD CSD register.
pub const REG_CSD_2: u32 = 0x50;
/// CSD_3: RW. Bits 127 to 96 of the SD CSD register.
pub const REG_CSD_3: u32 = 0x54;

/// DBG_SD_CLK: RO. SD clock ticks seen by the card. It shows that the host
/// clock reaches the FPGA, even when no command is framed. Wraps.
pub const REG_DBG_SD_CLK: u32 = 0x58;

/// DBG_SD_CMD: RO. Commands framed on the CMD line. Wraps.
pub const REG_DBG_SD_CMD: u32 = 0x5C;

/// DBG_SD_CRC_ERR: RO. Framed commands that failed the CRC7 check. Wraps.
pub const REG_DBG_SD_CRC_ERR: u32 = 0x60;

/// DBG_SD_RESP: RO. Responses the card started to send. Wraps.
pub const REG_DBG_SD_RESP: u32 = 0x64;

/// REQ_HI: RO. Word 1 of the record at the head of the request FIFO, which
/// is the block address.
///
/// The read has NO side effect. The record stays at the head of the FIFO
/// until a write of REG_REQ_POP takes it away, so `mimic-cli info`, a bulk
/// read of the whole map, and any tool a person writes later cannot take a
/// record away from a `serve` loop that runs beside them.
pub const REG_REQ_HI: u32 = 0x68;

/// DATA_TAG: WO. The sequence tag of the block that follows, in the low 8
/// bits.
///
/// The tag is bits 15 to 8 of word 0 of the record. The serve loop writes
/// it once, immediately before it pushes the 128 words of the block into
/// DATA_IN. The card compares the tag with the record it waits for and
/// throws away a block that names another record, so an answer that
/// arrives after the card gave up can never be sent to the host as the
/// answer to the NEXT read. Tag 0 names no record, so a block that no tag
/// names is thrown away as well.
pub const REG_DATA_TAG: u32 = 0x6C;

/// REQ_POP: WO. A write with REQ_POP_BIT set takes the record at the head
/// of the request FIFO away.
///
/// This register exists so that NO read of the map has a side effect. The
/// serve loop reads REG_REQ, reads REG_REQ_HI and then writes this
/// register, and any number of other accesses may come between the three.
/// The runtime normally combines the snapshot read and this write in one
/// transport operation. Separate CSR accesses keep the same explicit rule.
///
/// A write with the bit clear does nothing, and a write to an empty FIFO
/// does nothing. The register reads 0.
pub const REG_REQ_POP: u32 = 0x70;

/// Bit 0 of REQ_POP: take the record at the head of the request FIFO away.
pub const REQ_POP_BIT: u32 = 1 << 0;

/// DATA_OUT_POP: WO. A write with DATA_OUT_POP_BIT set takes ONE word off
/// the write data channel.
///
/// This register exists for the same reason as REQ_POP: NO read of the map
/// has a side effect. The serve loop reads REG_DATA_OUT and then writes
/// this register, so one word of a block costs two accesses and any other
/// access between the two changes nothing.
///
/// A write with the bit clear does nothing, and a write to an empty
/// channel does nothing. The register reads 0.
pub const REG_DATA_OUT_POP: u32 = 0x74;

/// Bit 0 of DATA_OUT_POP: take the word at the head of the write data
/// channel away.
pub const DATA_OUT_POP_BIT: u32 = 1 << 0;

/// WRITE_ACK: WO. One acknowledgement of a write record.
///
/// Bits 7 to 0 carry the sequence tag of the record that the runtime
/// retires, and bit 8 says that the runtime could not keep the block.
///
/// The card holds the SD host busy on DAT0 until this write arrives, so
/// the serve loop must write it as soon as it has taken the whole block. A
/// loop that takes a block and never acknowledges it stops the host until
/// the card times out on its own.
pub const REG_WRITE_ACK: u32 = 0x78;

/// The bits of WRITE_ACK that hold the sequence tag of the record.
pub const WRITE_ACK_TAG_MASK: u32 = 0xFF;

/// Bit 8 of WRITE_ACK: the runtime could not write the block. The card
/// reports the fault to the host instead of saying that the block is safe.
pub const WRITE_ACK_FAIL: u32 = 1 << 8;

/// DATA_FILL_LBA: WO, the block address of the FILL that follows.
///
/// A FILL is a block that the card never asked for. The runtime writes the
/// block address here, writes DATA_TAG with `DATA_TAG_FILL`, which names no
/// record, and then streams the 128 words into DATA_IN. The card writes the
/// block into the cache line that the address maps to and sends nothing on
/// the SD bus, so a later read of that block costs no round trip at all.
///
/// The order is fixed: this address first and the tag second. The address
/// travels with the tag through one channel, so one write here names one
/// block. A block with the fill tag and no address before it is thrown
/// away, so a runtime that forgets this write loses the fill and never
/// fills the wrong line.
pub const REG_DATA_FILL_LBA: u32 = 0x7C;

/// The DATA_TAG value that names NO record and marks a FILL.
///
/// The card never gives this tag to a record, so a block that carries it
/// answers nothing.
pub const DATA_TAG_FILL: u32 = 0;

/// DBG_CACHE_HIT: RO, reads that the block cache answered by itself, with
/// no record posted. It wraps at 16 bits.
pub const REG_DBG_CACHE_HIT: u32 = 0x80;

/// DBG_CACHE_MISS: RO, reads that the block cache did not hold, each of
/// which posted one record. It wraps at 16 bits.
///
/// Read with `REG_DBG_CACHE_HIT` it gives the hit rate. A cache that
/// nobody can measure is a cache that nobody can tune.
pub const REG_DBG_CACHE_MISS: u32 = 0x84;

/// DBG_CACHE_FILL: RO, lines that the block cache finished filling. A line
/// counts only when the LAST word of the block has landed. It wraps at 16
/// bits.
pub const REG_DBG_CACHE_FILL: u32 = 0x88;

/// CACHE_LINES: RO, the number of lines the block cache of this build has.
///
/// The line count is a build parameter, because different boards have
/// different budgets. The runtime reads it rather than assumes it, so one
/// runtime serves every build. One line holds ONE block.
pub const REG_CACHE_LINES: u32 = 0x8C;

/// REQ_SNAPSHOT_COUNT: RO. Alias of REQ_COUNT at the start of a contiguous
/// three-word request snapshot.
pub const REG_REQ_SNAPSHOT_COUNT: u32 = 0x90;
/// REQ_SNAPSHOT: RO. Alias of word 0 at the request FIFO head.
pub const REG_REQ_SNAPSHOT: u32 = 0x94;
/// REQ_SNAPSHOT_HI: RO. Alias of word 1 at the request FIFO head.
pub const REG_REQ_SNAPSHOT_HI: u32 = 0x98;
/// DBG_READ_START: RO. Demand data frames started on DAT.
pub const REG_DBG_READ_START: u32 = 0x9C;
/// DBG_READ_DONE: RO. Demand data frames completed on DAT.
pub const REG_DBG_READ_DONE: u32 = 0xA0;
/// DBG_READ_DROP: RO. Blocks discarded because they did not match a request.
pub const REG_DBG_READ_DROP: u32 = 0xA4;
/// DBG_READ_ABORT: RO. Reads stopped by the SD host or disabled runtime.
pub const REG_DBG_READ_ABORT: u32 = 0xA8;

/// The bits of CARD_STATE that hold the state. The other bits read 0.
pub const CARD_STATE_MASK: u32 = 0xF;

/// The states of the SD card state machine. The values are the state codes
/// of the SD Physical Layer specification.
pub const CardState = enum(u4) {
    idle = 0,
    ready = 1,
    ident = 2,
    stby = 3,
    tran = 4,
    data = 5,
    rcv = 6,
    prg = 7,
    dis = 8,
    _,

    /// The name of the state. A code that the card must not give reads as
    /// "unknown".
    pub fn name(self: CardState) []const u8 {
        return switch (self) {
            .idle => "idle",
            .ready => "ready",
            .ident => "ident",
            .stby => "stby",
            .tran => "tran",
            .data => "data",
            .rcv => "rcv",
            .prg => "prg",
            .dis => "dis",
            _ => "unknown",
        };
    }
};

/// The ID register magic: 'MIMC'.
pub const ID_MAGIC: u32 = 0x4D494D43;

/// The interface version this runtime speaks, packed major << 16 |
/// minor << 8 | patch.
pub const INTERFACE_VERSION: u32 = 0x00010100;

// CTRL register bits.
/// Bit 0: enable the device.
pub const CTRL_ENABLE: u32 = 1 << 0;
/// Bit 1: drive the test pattern.
pub const CTRL_TEST_PATTERN: u32 = 1 << 1;
/// Bit 2: force read-only behavior.
pub const CTRL_READ_ONLY: u32 = 1 << 2;
/// Bit 3: bypass the host cache.
pub const CTRL_CACHE_BYPASS: u32 = 1 << 3;
/// Bit 4: keep a written block in the card and acknowledge the host before
/// the runtime has it. A clear bit is write-through, which is what the
/// runtime uses today: the card releases the host only after the runtime
/// writes REG_WRITE_ACK.
pub const CTRL_WRITE_BACK: u32 = 1 << 4;

// EVENT register bits. The card sets a bit and the host clears it with a
// write of the same bit.
/// Bit 0: a read that the runtime never answered.
pub const EVENT_READ_TIMEOUT: u32 = 1 << 0;
/// Bit 1: a write that the runtime never acknowledged with REG_WRITE_ACK.
pub const EVENT_WRITE_TIMEOUT: u32 = 1 << 1;
/// Bit 2: a push into a FULL read data channel that the card threw away.
///
/// The block that word belonged to is short, so the card can no longer
/// tell where a block starts and every block after it on that channel
/// holds part of one block and part of the next.
///
/// It must never be set. `REG_DATA_IN_COUNT` reports the free space in
/// WORDS and under-states it rather than over-states it, so a runtime that
/// spends the count it read cannot fill the channel. A run that reports
/// this bit served the host bytes that belong to no single block.
pub const EVENT_DATA_IN_OVERFLOW: u32 = 1 << 2;

/// An interface version split into its fields.
pub const InterfaceVersion = struct {
    major: u16,
    minor: u8,
    patch: u8,
};

/// Splits a VERSION register value into major, minor, and patch.
pub fn decodeInterfaceVersion(value: u32) InterfaceVersion {
    return .{
        .major = @intCast(value >> 16),
        .minor = @intCast((value >> 8) & 0xFF),
        .patch = @intCast(value & 0xFF),
    };
}

// The SD CSD register, version 2.0.
//
// The FPGA holds no capacity of its own. This runtime builds the whole
// register and writes it to CSD_0 through CSD_3, so the card reports the
// size that the operator asks for. The layout below follows the SD
// Physical Layer specification and the Dart reference in
// `ip/lib/src/sd_regs.dart`, byte for byte. The device and the reference
// must never disagree, because a host reads this register once and then
// trusts it.

/// Number of bytes in the CSD register.
pub const CSD_BYTES: usize = 16;

/// Number of 512-byte blocks in one step of the C_SIZE field.
///
/// A version 2.0 CSD holds `capacity / 1024 - 1` in C_SIZE, so the card
/// can only report a capacity that is a whole number of these steps.
pub const CSD_CAPACITY_UNIT_BLOCKS: u64 = 1024;

/// Largest value that the 22-bit C_SIZE field holds.
pub const CSD_MAX_C_SIZE: u32 = 0x3F_FFFF;

/// Largest block count that a version 2.0 CSD reports.
pub const CSD_MAX_CAPACITY_BLOCKS: u64 =
    (@as(u64, CSD_MAX_C_SIZE) + 1) * CSD_CAPACITY_UNIT_BLOCKS;

/// The faults that a capacity from the operator causes.
pub const CsdError = error{
    /// The block count is less than one C_SIZE step, so the card has no
    /// capacity to report.
    CapacityTooSmall,
    /// The block count is not a whole number of C_SIZE steps.
    CapacityNotAligned,
    /// The block count does not fit in the 22 bits of C_SIZE.
    CapacityTooLarge,
};

/// The write protect bits of the CSD.
pub const CsdOptions = struct {
    /// TMP_WRITE_PROTECT: the card refuses a write until somebody clears
    /// the bit.
    temporary_write_protect: bool = false,
    /// PERM_WRITE_PROTECT: the card never accepts a write again.
    permanent_write_protect: bool = false,
};

/// CRC7 of an SD command, response, or register. The polynomial is
/// x^7 + x^3 + 1.
///
/// The wire puts the result in bits 7 to 1 of the last byte, with the end
/// bit in bit 0.
pub fn crc7(bytes: []const u8) u7 {
    var crc: u7 = 0;
    for (bytes) |byte| {
        var mask: u8 = 0x80;
        while (mask != 0) : (mask >>= 1) {
            const bit: u1 = @intFromBool(byte & mask != 0);
            const high: u1 = @truncate(crc >> 6);
            crc <<= 1;
            if (high != bit) crc ^= 0x09;
        }
    }
    return crc;
}

/// Builds the 128-bit CSD register of a version 2.0 card, most significant
/// byte first.
///
/// `capacity_blocks` is the number of 512-byte blocks that the card
/// reports. It must be a whole number of `CSD_CAPACITY_UNIT_BLOCKS` steps.
/// Use `fitCapacityBlocks` or `growCapacityBlocks` to get such a count
/// from an image size.
///
/// Every field other than C_SIZE has a fixed value, because a version 2.0
/// card always reads and writes 512-byte blocks.
pub fn csdV2(capacity_blocks: u64, options: CsdOptions) CsdError![CSD_BYTES]u8 {
    if (capacity_blocks < CSD_CAPACITY_UNIT_BLOCKS) return error.CapacityTooSmall;
    if (capacity_blocks % CSD_CAPACITY_UNIT_BLOCKS != 0) return error.CapacityNotAligned;
    if (capacity_blocks > CSD_MAX_CAPACITY_BLOCKS) return error.CapacityTooLarge;

    const c_size: u32 = @intCast(capacity_blocks / CSD_CAPACITY_UNIT_BLOCKS - 1);
    var csd: [CSD_BYTES]u8 = .{
        // CSD_STRUCTURE 01, then six reserved bits.
        0x40,
        // TAAC: the read access time is fixed at 1 ms.
        0x0E,
        // NSAC: the read access time has no clock cycle part.
        0x00,
        // TRAN_SPEED: 25 Mbit/s, the default speed.
        0x32,
        // CCC 0x5B5: command classes 0, 2, 4, 5, 7, 8 and 10.
        0x5B,
        // The last four bits of CCC, then READ_BL_LEN 9 for 512 bytes.
        0x59,
        // READ_BL_PARTIAL, WRITE_BLK_MISALIGN, READ_BLK_MISALIGN, DSR_IMP
        // and four reserved bits. This card reads whole blocks only.
        0x00,
        // Two reserved bits, then the top six bits of C_SIZE.
        @intCast((c_size >> 16) & 0x3F),
        @intCast((c_size >> 8) & 0xFF),
        @intCast(c_size & 0xFF),
        // One reserved bit, ERASE_BLK_EN 1, then the top six bits of
        // SECTOR_SIZE, which is fixed at 0x7F.
        0x7F,
        // The last bit of SECTOR_SIZE, then WP_GRP_SIZE 0.
        0x80,
        // WP_GRP_ENABLE 0, two reserved bits, R2W_FACTOR 010 for a factor
        // of 4, then the top two bits of WRITE_BL_LEN.
        0x0A,
        // The last two bits of WRITE_BL_LEN, which is 9 for 512 bytes,
        // WRITE_BL_PARTIAL 0 and five reserved bits.
        0x40,
        // FILE_FORMAT_GRP 0, COPY 1, the two write protect bits,
        // FILE_FORMAT 00 and two reserved bits. COPY 1 says that the
        // content is a copy and not the original content of a card maker,
        // which is true of this card.
        0x40 |
            @as(u8, if (options.permanent_write_protect) 0x20 else 0x00) |
            @as(u8, if (options.temporary_write_protect) 0x10 else 0x00),
        // The CRC7 byte, filled in below.
        0x00,
    };
    csd[CSD_BYTES - 1] = (@as(u8, crc7(csd[0 .. CSD_BYTES - 1])) << 1) | 1;
    return csd;
}

/// The C_SIZE field of a version 2.0 CSD, or null when CSD_STRUCTURE is
/// not 01. The same bits hold other fields in a version 1.0 CSD, so a
/// register that the device gives back is checked before it is read.
pub fn csdCSize(csd: *const [CSD_BYTES]u8) ?u32 {
    if ((csd[0] >> 6) & 0x3 != 1) return null;
    return (@as(u32, csd[7] & 0x3F) << 16) | (@as(u32, csd[8]) << 8) | csd[9];
}

/// The capacity of a version 2.0 CSD in 512-byte blocks, or null when the
/// register is not version 2.0.
pub fn csdCapacityBlocks(csd: *const [CSD_BYTES]u8) ?u64 {
    const c_size = csdCSize(csd) orelse return null;
    return (@as(u64, c_size) + 1) * CSD_CAPACITY_UNIT_BLOCKS;
}

/// The CSD as the four CSR words. Index 0 goes to CSD_0 and index 3 goes
/// to CSD_3.
///
/// Byte 0 of the register is the most significant byte, and CSD_0 holds
/// bits 31 to 0, so CSD_0 takes the last four bytes.
pub fn csdToWords(csd: *const [CSD_BYTES]u8) [4]u32 {
    var words: [4]u32 = undefined;
    for (&words, 0..) |*word, i| {
        const offset = CSD_BYTES - 4 * (i + 1);
        word.* = std.mem.readInt(u32, csd[offset..][0..4], .big);
    }
    return words;
}

/// The 16 register bytes of the four CSR words. This is the reverse of
/// `csdToWords`, and it decodes what the device gives back.
pub fn csdFromWords(words: [4]u32) [CSD_BYTES]u8 {
    var csd: [CSD_BYTES]u8 = undefined;
    for (words, 0..) |word, i| {
        const offset = CSD_BYTES - 4 * (i + 1);
        std.mem.writeInt(u32, csd[offset..][0..4], word, .big);
    }
    return csd;
}

/// A block count trimmed down to a whole number of C_SIZE steps.
pub const CapacityFit = struct {
    /// The block count that the card reports.
    advertised_blocks: u64,
    /// The blocks that the image holds but the card cannot address.
    lost_blocks: u64,

    /// True when the block count needed no trim.
    pub fn exact(self: CapacityFit) bool {
        return self.lost_blocks == 0;
    }
};

/// Trims a block count down to the next lower whole number of C_SIZE
/// steps.
///
/// The trim is deliberate and the caller must report it. Rounding up would
/// make the card claim more space than the image holds, and the host would
/// then write data that the card cannot keep. Rounding down only hides the
/// last blocks of the image.
pub fn fitCapacityBlocks(blocks: u64) CsdError!CapacityFit {
    if (blocks < CSD_CAPACITY_UNIT_BLOCKS) return error.CapacityTooSmall;
    const advertised = blocks - blocks % CSD_CAPACITY_UNIT_BLOCKS;
    if (advertised > CSD_MAX_CAPACITY_BLOCKS) return error.CapacityTooLarge;
    return .{ .advertised_blocks = advertised, .lost_blocks = blocks - advertised };
}

/// Raises a block count to the next whole number of C_SIZE steps. A count
/// that is already a whole number of steps does not change.
///
/// The caller must make the image as large as the result before it writes
/// the CSD, else the card reports space that the image does not hold.
pub fn growCapacityBlocks(blocks: u64) CsdError!u64 {
    if (blocks == 0) return error.CapacityTooSmall;
    const remainder = blocks % CSD_CAPACITY_UNIT_BLOCKS;
    const grown = if (remainder == 0) blocks else blocks + (CSD_CAPACITY_UNIT_BLOCKS - remainder);
    if (grown > CSD_MAX_CAPACITY_BLOCKS) return error.CapacityTooLarge;
    return grown;
}

/// The number of whole 512-byte blocks in a file of `bytes` bytes. A part
/// of a block at the end is not addressable, so it does not count.
pub fn blocksInBytes(bytes: u64) u64 {
    return bytes / BLOCK_SIZE;
}

/// The file size that an image must have before the card can report every
/// byte of it.
///
/// There are two alignment levels and this applies both, in order. First a
/// file that ends part way into a 512-byte block grows to a whole block,
/// because the card addresses whole blocks only. Then the block count
/// grows to a whole number of C_SIZE steps, because the CSD holds no other
/// capacity. The result is never smaller than `bytes`.
pub fn growTargetBytes(bytes: u64) CsdError!u64 {
    const partial = bytes % BLOCK_SIZE;
    const whole_block_bytes = if (partial == 0) bytes else bytes + (BLOCK_SIZE - partial);
    const blocks = try growCapacityBlocks(whole_block_bytes / BLOCK_SIZE);
    return blocks * BLOCK_SIZE;
}

test "ID magic spells MIMC little-endian" {
    // Bytes on the wire, LSB first: 43 4d 49 4d.
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, ID_MAGIC, .little);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x43, 0x4D, 0x49, 0x4D }, &b);
}

test "interface version packs 1.1.0 and decodes back" {
    try std.testing.expectEqual(@as(u32, 0x00010100), INTERFACE_VERSION);
    const v = decodeInterfaceVersion(INTERFACE_VERSION);
    try std.testing.expectEqual(@as(u16, 1), v.major);
    try std.testing.expectEqual(@as(u8, 1), v.minor);
    try std.testing.expectEqual(@as(u8, 0), v.patch);
}

test "decodeInterfaceVersion splits an arbitrary packed value" {
    const v = decodeInterfaceVersion(0x0102_0304);
    try std.testing.expectEqual(@as(u16, 0x0102), v.major);
    try std.testing.expectEqual(@as(u8, 0x03), v.minor);
    try std.testing.expectEqual(@as(u8, 0x04), v.patch);
}

test "the CSR map sits on consecutive 4-byte steps" {
    const regs = [_]u32{
        REG_ID,         REG_VERSION,       REG_CTRL,     REG_STATUS,
        REG_NUM_BLOCKS, REG_SCRATCH,       REG_REQ,      REG_REQ_COUNT,
        REG_DATA_IN,    REG_DATA_IN_COUNT, REG_DATA_OUT, REG_DATA_OUT_COUNT,
        REG_EVENT,      REG_IRQ_ENABLE,
    };
    for (regs, 0..) |r, i| try std.testing.expectEqual(@as(u32, @intCast(i * 4)), r);
}

test "every card state gives a name" {
    try std.testing.expectEqualStrings("idle", CardState.idle.name());
    try std.testing.expectEqualStrings("tran", CardState.tran.name());
    const bad: CardState = @enumFromInt(15);
    try std.testing.expectEqualStrings("unknown", bad.name());
}

test "every side effect of the map is a WRITE, and the write-only registers follow the counters" {
    // No address of this map has a side effect on READ, so a bulk read of
    // the whole map, `mimic-cli info` and any tool a person writes later
    // are safe by construction. REQ_POP and DATA_TAG are the two addresses
    // that change the state of the device and both are write-only.
    try std.testing.expect(REG_REQ_HI > REG_DBG_SD_RESP);
    try std.testing.expect(REG_DATA_TAG > REG_DBG_SD_RESP);
    try std.testing.expectEqual(REG_DBG_SD_RESP + 4, REG_REQ_HI);
    try std.testing.expectEqual(REG_REQ_HI + 4, REG_DATA_TAG);
    try std.testing.expectEqual(REG_DATA_TAG + 4, REG_REQ_POP);
    try std.testing.expectEqual(@as(u32, 0x68), REG_REQ_HI);
    try std.testing.expectEqual(@as(u32, 0x6C), REG_DATA_TAG);
    try std.testing.expectEqual(@as(u32, 0x70), REG_REQ_POP);
    try std.testing.expectEqual(@as(u32, 1), REQ_POP_BIT);
    // The write path adds two more addresses that change the state of the
    // device, and both are write-only as well. DATA_OUT and REQ keep the
    // rule: the head moves only on the write that follows the read.
    try std.testing.expect(REG_DATA_OUT_POP > REG_DBG_SD_RESP);
    try std.testing.expect(REG_WRITE_ACK > REG_DBG_SD_RESP);
    try std.testing.expectEqual(REG_REQ_POP + 4, REG_DATA_OUT_POP);
    try std.testing.expectEqual(REG_DATA_OUT_POP + 4, REG_WRITE_ACK);
    try std.testing.expectEqual(@as(u32, 0x74), REG_DATA_OUT_POP);
    try std.testing.expectEqual(@as(u32, 0x78), REG_WRITE_ACK);
    try std.testing.expectEqual(@as(u32, 1), DATA_OUT_POP_BIT);
}

test "the WRITE_ACK fields do not overlap, so a tag cannot read as a failure" {
    // The tag is the low byte of the record and the fail bit sits above
    // it. A tag of 0xFF, which is a real tag, must leave the fail bit
    // clear.
    try std.testing.expectEqual(@as(u32, 0xFF), WRITE_ACK_TAG_MASK);
    try std.testing.expectEqual(@as(u32, 0x100), WRITE_ACK_FAIL);
    try std.testing.expectEqual(@as(u32, 0), WRITE_ACK_TAG_MASK & WRITE_ACK_FAIL);
}

test "the new CTRL and EVENT bits sit above the bits that already ship" {
    try std.testing.expectEqual(@as(u32, 0x10), CTRL_WRITE_BACK);
    try std.testing.expectEqual(@as(u32, 0), CTRL_WRITE_BACK & CTRL_CACHE_BYPASS);
    try std.testing.expectEqual(@as(u32, 1), EVENT_READ_TIMEOUT);
    try std.testing.expectEqual(@as(u32, 2), EVENT_WRITE_TIMEOUT);
    try std.testing.expectEqual(@as(u32, 4), EVENT_DATA_IN_OVERFLOW);
    try std.testing.expectEqual(
        @as(u32, 0),
        EVENT_DATA_IN_OVERFLOW & (EVENT_READ_TIMEOUT | EVENT_WRITE_TIMEOUT),
    );
}

test "CARD_STATE follows DBG_RESET_COUNT" {
    try std.testing.expectEqual(REG_DBG_RESET_COUNT + 4, REG_CARD_STATE);
}

test "the CSD registers follow CARD_STATE on consecutive 4-byte steps" {
    const regs = [_]u32{ REG_CSD_0, REG_CSD_1, REG_CSD_2, REG_CSD_3 };
    for (regs, 0..) |r, i| {
        try std.testing.expectEqual(REG_CARD_STATE + 4 * @as(u32, @intCast(i + 1)), r);
    }
    try std.testing.expectEqual(@as(u32, 0x48), REG_CSD_0);
    try std.testing.expectEqual(@as(u32, 0x54), REG_CSD_3);
}

test "crc7 of the first 15 CSD bytes gives the byte the SD wire carries" {
    // The last byte of the known vector is 0xB9, which is the CRC in bits
    // 7 to 1 and the end bit in bit 0.
    const head = [_]u8{
        0x40, 0x0E, 0x00, 0x32, 0x5B, 0x59, 0x00, 0x00,
        0x1D, 0x8A, 0x7F, 0x80, 0x0A, 0x40, 0x40,
    };
    try std.testing.expectEqual(@as(u7, 0x5C), crc7(&head));
    try std.testing.expectEqual(@as(u8, 0xB9), (@as(u8, crc7(&head)) << 1) | 1);
}

test "csdV2 reproduces the Dart reference vector for 7563 units byte for byte" {
    // The vector comes from sdCsdV2 in ip/lib/src/sd_regs.dart. The device
    // and the Dart model must never disagree about this register.
    const csd = try csdV2(7563 * CSD_CAPACITY_UNIT_BLOCKS, .{});
    const want = [_]u8{
        0x40, 0x0E, 0x00, 0x32, 0x5B, 0x59, 0x00, 0x00,
        0x1D, 0x8A, 0x7F, 0x80, 0x0A, 0x40, 0x40, 0xB9,
    };
    try std.testing.expectEqualSlices(u8, &want, &csd);
}

test "csdV2 then csdCapacityBlocks returns the block count that went in" {
    const blocks: u64 = 1024 * 1024; // 512 MiB, a whole number of steps.
    const csd = try csdV2(blocks, .{});
    try std.testing.expectEqual(@as(?u32, 1023), csdCSize(&csd));
    try std.testing.expectEqual(@as(?u64, blocks), csdCapacityBlocks(&csd));
}

test "csdV2 rejects a capacity that no C_SIZE holds" {
    try std.testing.expectError(error.CapacityTooSmall, csdV2(1023, .{}));
    try std.testing.expectError(error.CapacityNotAligned, csdV2(3_309_569, .{}));
    try std.testing.expectError(
        error.CapacityTooLarge,
        csdV2(CSD_MAX_CAPACITY_BLOCKS + CSD_CAPACITY_UNIT_BLOCKS, .{}),
    );
}

test "csdV2 builds the largest capacity that C_SIZE holds" {
    const csd = try csdV2(CSD_MAX_CAPACITY_BLOCKS, .{});
    try std.testing.expectEqual(@as(?u32, CSD_MAX_C_SIZE), csdCSize(&csd));
    try std.testing.expectEqual(@as(?u64, CSD_MAX_CAPACITY_BLOCKS), csdCapacityBlocks(&csd));
}

test "the write protect bits change only the last field byte" {
    const plain = try csdV2(1024, .{});
    const both = try csdV2(1024, .{ .temporary_write_protect = true, .permanent_write_protect = true });
    try std.testing.expectEqualSlices(u8, plain[0..14], both[0..14]);
    try std.testing.expectEqual(@as(u8, 0x40), plain[14]);
    try std.testing.expectEqual(@as(u8, 0x70), both[14]);
}

test "csdCSize refuses a CSD that is not version 2.0" {
    // A version 1.0 CSD has CSD_STRUCTURE 00 and holds other fields in the
    // same bits, so reading C_SIZE there would report a wrong capacity.
    var v1 = try csdV2(1024, .{});
    v1[0] = 0x00;
    try std.testing.expectEqual(@as(?u32, null), csdCSize(&v1));
    try std.testing.expectEqual(@as(?u64, null), csdCapacityBlocks(&v1));
}

test "csdToWords puts the first register byte in CSD_3 and the last in CSD_0" {
    const csd = [_]u8{
        0x40, 0x0E, 0x00, 0x32, 0x5B, 0x59, 0x00, 0x00,
        0x1D, 0x8A, 0x7F, 0x80, 0x0A, 0x40, 0x40, 0xB9,
    };
    const words = csdToWords(&csd);
    try std.testing.expectEqual(@as(u32, 0x0A4040B9), words[0]);
    try std.testing.expectEqual(@as(u32, 0x1D8A7F80), words[1]);
    try std.testing.expectEqual(@as(u32, 0x5B590000), words[2]);
    try std.testing.expectEqual(@as(u32, 0x400E0032), words[3]);
    try std.testing.expectEqualSlices(u8, &csd, &csdFromWords(words));
}

test "fitCapacityBlocks trims 3309569 blocks down, because the card must not claim more than the image holds" {
    // The target image is 1,694,499,328 bytes, which is 3,309,569 blocks.
    // That is one block above the 3232-step boundary at 3,309,568 blocks,
    // so one block is unreachable and C_SIZE is 3231.
    const fit = try fitCapacityBlocks(3_309_569);
    try std.testing.expectEqual(@as(u64, 3_309_568), fit.advertised_blocks);
    try std.testing.expectEqual(@as(u64, 1), fit.lost_blocks);
    try std.testing.expect(!fit.exact());
    const csd = try csdV2(fit.advertised_blocks, .{});
    try std.testing.expectEqual(@as(?u32, 3231), csdCSize(&csd));
    try std.testing.expectEqual(@as(?u64, 3_309_568), csdCapacityBlocks(&csd));
    // The advertised size never exceeds the image size.
    try std.testing.expect(csdCapacityBlocks(&csd).? <= 3_309_569);
}

test "fitCapacityBlocks leaves an aligned block count alone" {
    const fit = try fitCapacityBlocks(3_309_568);
    try std.testing.expectEqual(@as(u64, 3_309_568), fit.advertised_blocks);
    try std.testing.expectEqual(@as(u64, 0), fit.lost_blocks);
    try std.testing.expect(fit.exact());
}

test "fitCapacityBlocks refuses an image smaller than one C_SIZE step" {
    try std.testing.expectError(error.CapacityTooSmall, fitCapacityBlocks(0));
    try std.testing.expectError(error.CapacityTooSmall, fitCapacityBlocks(1023));
}

test "growCapacityBlocks raises 3309569 blocks to the next whole step" {
    // The grow path appends zeros, so the count goes up to 3233 steps at
    // 3,310,592 blocks and the image gains 1,023 blocks.
    const grown = try growCapacityBlocks(3_309_569);
    try std.testing.expectEqual(@as(u64, 3_310_592), grown);
    try std.testing.expectEqual(@as(u64, 1_023), grown - 3_309_569);
    const csd = try csdV2(grown, .{});
    try std.testing.expectEqual(@as(?u32, 3232), csdCSize(&csd));
}

test "growCapacityBlocks is safe to run twice on an aligned block count" {
    const once = try growCapacityBlocks(3_310_592);
    try std.testing.expectEqual(@as(u64, 3_310_592), once);
    try std.testing.expectEqual(once, try growCapacityBlocks(once));
}

test "growTargetBytes pads a file that ends part way into a block up to a whole block" {
    // Level 1 alone: the file ends 38 bytes into the last block, so it
    // needs 474 bytes to reach the block boundary. The block count is then
    // 3,309,568, which is already a whole number of steps, so level 2 adds
    // nothing.
    const bytes: u64 = 3_309_567 * BLOCK_SIZE + 38;
    const target = try growTargetBytes(bytes);
    try std.testing.expectEqual(@as(u64, 474), target - bytes);
    try std.testing.expectEqual(@as(u64, 3_309_568 * BLOCK_SIZE), target);
    // The result is a whole number of blocks and a whole number of steps.
    try std.testing.expectEqual(@as(u64, 0), target % BLOCK_SIZE);
}

test "growTargetBytes applies the block level and then the step level" {
    // Both levels: the file ends 38 bytes into block 3,309,569, so it goes
    // to 3,309,570 whole blocks and then up to 3,310,592 blocks.
    const bytes: u64 = 3_309_569 * BLOCK_SIZE + 38;
    const target = try growTargetBytes(bytes);
    try std.testing.expectEqual(@as(u64, 3_310_592 * BLOCK_SIZE), target);
    try std.testing.expectEqual(@as(u64, 0), target % (CSD_CAPACITY_UNIT_BLOCKS * BLOCK_SIZE));
    try std.testing.expect(target > bytes);
}

test "growTargetBytes leaves the target image size alone once it is grown" {
    const aligned: u64 = 3_310_592 * BLOCK_SIZE;
    try std.testing.expectEqual(aligned, try growTargetBytes(aligned));
}

test "blocksInBytes drops a part of a block at the end of the image" {
    try std.testing.expectEqual(@as(u64, 3_309_569), blocksInBytes(1_694_499_328));
    try std.testing.expectEqual(@as(u64, 3_309_569), blocksInBytes(1_694_499_328 + 511));
    try std.testing.expectEqual(@as(u64, 0), blocksInBytes(511));
}
