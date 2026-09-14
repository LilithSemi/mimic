//! The block read and write paths of the mimic runtime.
//!
//! The FPGA holds no disk. When the emulated card gets a read that it cannot
//! answer from its own cache, it posts a request record, and this code
//! answers with the bytes of a disk image on the PC. A write goes the other
//! way: the card takes the block off the SD bus, puts it on the write data
//! channel, posts a record, and waits. It holds the host busy on DAT0 until
//! this code writes WRITE_ACK, so every write record ends with that write.
//!
//! The channel is ordered AND tagged. The device posts requests in order,
//! this code takes them in order, and it pushes the answering bytes into
//! DATA_IN in the same order. Order alone is not enough: the device gives
//! up on a request that this code answers too late, and the block that
//! then arrives would be read as the answer to the NEXT request. Each
//! record therefore carries a sequence tag, this code writes the tag back
//! to DATA_TAG before it pushes the block, and the device throws away a
//! block whose tag names a request it already gave up on.
//!
//! Every register that this code touches is in `sd.zig`, which is the wire
//! contract that the gateware and the Dart model share.

const std = @import("std");
const Io = std.Io;
const sd = @import("sd.zig");
const Device = @import("device.zig").Device;
const WriteStreamGroup = @import("device.zig").WriteStreamGroup;

/// Words in one request record.
pub const REQUEST_WORDS: usize = 2;

/// Words in one 512-byte block.
pub const BLOCK_WORDS: usize = sd.BLOCK_SIZE / 4;

/// Words the transport reads in one READ frame.
///
/// It is here only so that the round trip count of the write path is
/// honest. The transport owns the real number and this must follow it.
const READ_WORDS_PER_TRIP: u64 = 32;

/// Blocks that ONE transport transaction carries.
///
/// The transport streams at most 2048 words in one transfer and the read
/// data channel of the card holds sixteen blocks, so sixteen is both
/// limits at once. It is also the largest batch the card can accept
/// without waiting for the SD bus to drain part of it.
///
/// The transfer size alone is worth little. `mimic-cli pushtest` on the
/// OrangeCrab measured 672.2 KiB/s for a 4 block transfer and 702.1 KiB/s
/// for a 16 block one, which is 4 percent. The win is that the runtime can
/// be sixteen blocks ahead of the card instead of four, so it stops
/// waiting for the channel to drain between batches.
pub const PUSH_BATCH_BLOCKS: u8 = 16;

/// One block of a push batch.
///
/// `tag` is the sequence tag of the record the block answers, or
/// `sd.DATA_TAG_FILL` for a block that answers no record. A fill also
/// needs its own address on the wire, which `lba` gives.
const PushEntry = struct {
    lba: u64,
    tag: u8,
    /// True while the card keeps this block in its cache, so the host
    /// model must keep it too.
    ///
    /// A block that answers a SINGLE block record, and a fill, both land
    /// in a cache line. A block of a STREAM does not: the card reads each
    /// block of a stream once and writes no line for it, so a model that
    /// claimed one would skip a fill the card needs and would read the
    /// next record for that block as a lost cache.
    model: bool = true,
};

comptime {
    // The FIFO carries 32-bit words, so a block that is not a whole number
    // of words could not be pushed without a partial word at the end, and
    // the code below has no place to put one.
    if (sd.BLOCK_SIZE % 4 != 0)
        @compileError("BLOCK_SIZE must be a whole number of 32-bit words");
    // The sequence tag of a record is a u8 and it goes back to the card in
    // the tag field of WRITE_ACK. A field that is not one byte wide would
    // drop the top of a tag, and the card would then release the host for
    // the wrong record.
    if (sd.WRITE_ACK_TAG_MASK != std.math.maxInt(u8))
        @compileError("WRITE_ACK must hold the whole sequence tag in one byte");
}

/// What the device asks the runtime to do.
///
/// The value is the low nibble of the first word of a request record. The
/// high nibble of that byte carries the card generation.
///
/// The two write opcodes carry one 512-byte block each on the write data
/// channel, so a write record is one block and the `blocks` field of the
/// record does not size the channel.
pub const RequestOp = enum(u8) {
    /// Send `blocks` blocks, starting at `lba`, into DATA_IN.
    read_blocks = 0x01,
    /// Take 512 bytes off DATA_OUT and write them at `lba`.
    write_blocks = 0x02,
    /// Take 512 bytes off DATA_OUT and DROP them. The card saw a bad CRC16
    /// on the SD bus, so the bytes are not the bytes the host sent. The
    /// runtime still has to take them, else the channel goes out of step
    /// with the records.
    write_discard = 0x03,
};

/// One request record, as the device posts it.
///
/// The record is two 32-bit words, read from the REQ FIFO in order:
///
///     word 0: op:u4 [3:0], epoch:u4 [7:4], seq:u8 [15:8],
///             blocks:u16 [31:16]
///     word 1: lba:u32
///
/// Word 0 comes from REG_REQ and word 1 from REG_REQ_HI. NEITHER read has
/// a side effect. The record goes away only on the WRITE of REQ_POP_BIT to
/// REG_REQ_POP that follows the two reads, so any access between the three
/// changes nothing.
///
/// `lba` is a block address and not a byte address, because the card
/// addresses blocks and a byte address of a 2 TiB card does not fit 32
/// bits. `blocks` counts the blocks that one record asks for, so a
/// multi-block read costs one record.
///
/// `seq` names the request. The device counts the reads it takes, and it
/// throws away a block whose tag is not the tag of the request it waits
/// for. This code gives the tag back with every block of the record, so a
/// block that arrives after the device gave up is thrown away instead of
/// being sent to the host as the answer to another read.
pub const Request = struct {
    op: u8,
    blocks: u16,
    lba: u32,
    seq: u8 = 0,
    epoch: u4 = 0,

    pub fn words(self: Request) [REQUEST_WORDS]u32 {
        return .{
            (@as(u32, self.op) & 0x0F) | (@as(u32, self.epoch) << 4) |
                (@as(u32, self.seq) << 8) |
                (@as(u32, self.blocks) << 16),
            self.lba,
        };
    }
};

/// Decodes a request record. The record comes from the device, so no field
/// is trusted here. `serveRequest` checks each one.
pub fn decodeRequest(words: [REQUEST_WORDS]u32) Request {
    return .{
        .op = @truncate(words[0] & 0x0F),
        .epoch = @truncate(words[0] >> 4),
        .seq = @truncate(words[0] >> 8),
        .blocks = @truncate(words[0] >> 16),
        .lba = words[1],
    };
}

/// The faults that a request or a disk image causes. The device and the
/// image are both outside this code, so each of these is recovered from and
/// reported, never asserted away.
pub const Error = error{
    /// The request names a block that the card does not report.
    BlockOutOfRange,
    /// The image gave fewer bytes than a whole block. The file shrank
    /// under the runtime.
    ShortImageRead,
    /// A write reached an image that the operator opened read only.
    ImageReadOnly,
    /// The DATA_IN FIFO did not take the block within the poll limit. The
    /// device stopped draining it.
    DataInFull,
    /// The write data channel did not hold a whole block within the poll
    /// limit. The record and the channel are out of step, so the bytes of
    /// the block are gone and no guess can replace them.
    DataOutShort,
    /// The block count of the card does not fit the 32 bits of NUM_BLOCKS.
    NumBlocksTooLarge,
};

/// The disk image that backs the card.
pub const Image = struct {
    io: Io,
    file: Io.File,
    /// The blocks that the card reports. A read above this is refused, so
    /// the reachable size of the image and the size that the host sees are
    /// the same number.
    blocks: u64,
    /// True when the operator asked for an image that is never written.
    read_only: bool,

    /// Reads one block into `buf`.
    ///
    /// The read is positional, so it does not move a file offset and it
    /// needs no seek of its own.
    pub fn readBlock(self: Image, lba: u64, buf: *[sd.BLOCK_SIZE]u8) !void {
        if (lba >= self.blocks) return Error.BlockOutOfRange;
        const offset = lba * sd.BLOCK_SIZE;
        const read = try self.file.readPositionalAll(self.io, buf, offset);
        if (read != sd.BLOCK_SIZE) return Error.ShortImageRead;
    }

    /// Writes one block from `buf`.
    ///
    /// The write is positional as well, so a read and a write of the same
    /// image need no seek between them.
    ///
    /// A read-only image refuses the write here and not at the file
    /// handle. The operator asked for an image that never changes, so the
    /// refusal is a decision of this code and it carries a name that the
    /// caller can act on.
    pub fn writeBlock(self: Image, lba: u64, buf: *const [sd.BLOCK_SIZE]u8) !void {
        if (self.read_only) return Error.ImageReadOnly;
        if (lba >= self.blocks) return Error.BlockOutOfRange;
        try self.file.writePositionalAll(self.io, buf, lba * sd.BLOCK_SIZE);
    }
};

/// The limits that the serve loop holds itself to. Every one of them bounds
/// work that a value from the device would otherwise size.
pub const Options = struct {
    /// Requests taken from one poll of REQ_COUNT. A count that the device
    /// reports wrong cannot make the loop run away.
    max_requests_per_poll: u32 = 64,
    /// Blocks that one record may ask for.
    max_blocks_per_request: u16 = 256,
    /// Reads of DATA_IN_COUNT before the loop gives up waiting for FIFO
    /// space.
    space_poll_limit: u32 = 1000,
    /// Microseconds to wait between two reads of DATA_IN_COUNT.
    ///
    /// Every read is a USB round trip of about 100 us, and the card drains
    /// the channel on the SD CLOCK, which no register write of this side
    /// makes go faster. A loop with no wait therefore spends the whole
    /// drain asking, hundreds of times for one block.
    ///
    /// One block leaves the channel in 4114 SD clocks, which is 165 us at
    /// 25 MHz and 686 us at 6 MHz, so a wait of a few hundred microseconds
    /// costs at most one short sleep per block and saves every round trip
    /// but one.
    ///
    /// It is 0 here, so a library caller and every test get no sleep at
    /// all and the loop behaves exactly as it reads. The CLI sets a real
    /// number.
    space_poll_wait_us: u32 = 0,
    /// Reads of DATA_OUT_COUNT before the loop gives up waiting for a whole
    /// block on the write data channel.
    block_poll_limit: u32 = 1000,
    /// Blocks to FILL into the card cache after the blocks a record asked
    /// for. A read of block N also puts N+1 up to N+k into the card, so a
    /// host that walks a file pays one round trip for k+1 blocks.
    ///
    /// It is 0 here and the CLI sets a small number, because a library
    /// caller that asked for nothing must get exactly the traffic the
    /// record asked for. `--read-ahead` is the flag.
    ///
    /// The host opens a window only after consecutive requests prove a
    /// sequential walk. The policy lives on this side of the link so that it
    /// can change with no bitstream change.
    read_ahead: u16 = 0,
    /// Blocks that ONE transport transaction may carry.
    ///
    /// The ceiling is `PUSH_BATCH_BLOCKS`, which is what the transport and
    /// the data channel of the card both hold. A smaller number sends the
    /// same blocks in more transactions, which costs round trips and is
    /// the way to tell a fault of the link from a fault of the policy.
    max_batch_blocks: u8 = PUSH_BATCH_BLOCKS,
    /// Chunks of ONE stream that `serveRead` carries on in place before it
    /// gives the loop back to its caller.
    ///
    /// A chunk that carries on costs no round trip, so a bound of one
    /// would give the whole win away. A bound is still needed: the caller
    /// is what notices a stop, and a host that reads a whole card in one
    /// CMD18 would otherwise never let it look. 64 chunks is 2048 blocks,
    /// which is a few seconds of a full speed link.
    max_stream_chunks: u16 = 64,
};

/// Microseconds the CLI waits between two reads of DATA_IN_COUNT.
///
/// It is under the 686 us that one block takes on a 6 MHz SD clock and
/// over the 100 us that one USB round trip costs, so a wait replaces
/// several round trips and never adds a whole block of delay. See
/// `Options.space_poll_wait_us`.
pub const CLI_SPACE_POLL_WAIT_US: u32 = 200;

/// Microseconds the CLI waits after an idle request-channel poll.
///
/// The USB transaction itself paces the loop, but a continuously queued next
/// poll can still monopolize host-controller scheduling. This backoff is less
/// than one percent of the card's demand timeout and leaves room for the block
/// transfer that answers a request.
pub const CLI_IDLE_POLL_WAIT_US: u32 = 200;

/// What the serve loop did. `--stats` reports these.
pub const Stats = struct {
    /// Records taken from the REQ FIFO.
    requests: u64 = 0,
    /// Blocks pushed into DATA_IN.
    blocks: u64 = 0,
    /// Blocks taken off DATA_OUT and written into the image.
    written: u64 = 0,
    /// Blocks taken off DATA_OUT and dropped. A dropped block is a block
    /// that the card could not trust or that this code could not keep, so
    /// the count is the write side of `refused`.
    dropped: u64 = 0,
    /// Records that this code would not answer.
    refused: u64 = 0,
    /// Reads of REQ_COUNT.
    polls: u64 = 0,
    /// Records that the card posted and this side never saw.
    ///
    /// The card gives every record a sequence tag one above the last, and
    /// it steps over 0 on a wrap. A tag that is more than one above the
    /// tag before it therefore counts the records that went missing
    /// between the two, and a missing record is a read that nothing
    /// answers and a host that waits out the whole card timeout.
    records_lost: u64 = 0,
    /// Reads of DATA_IN_COUNT that the answer to a record had to wait
    /// for, because the data channel had no room for the block.
    ///
    /// Every one of them is a USB round trip AND a sleep while the SD
    /// host waits for data, so a number near the count of records says
    /// that the read ahead has taken the room the answers need.
    space_polls: u64 = 0,
    /// The most reads of DATA_IN_COUNT that ONE answer waited through.
    space_polls_max: u32 = 0,
    /// Transactions the loop sent over the transport.
    ///
    /// One transaction is ONE USB round trip, which full speed pays for in
    /// about a millisecond whatever it carries. This count divided by the
    /// blocks the card served is the number that caps the throughput of
    /// the link, so it is the number to watch and not the byte rate.
    round_trips: u64 = 0,
    /// Blocks pushed as a FILL, which no record asked for.
    fills: u64 = 0,
    /// Read ahead blocks that the host model says the card already holds,
    /// so no block went out for them. It is the work the model saved.
    fills_skipped: u64 = 0,
    /// Read ahead blocks that were dropped because the card had another
    /// record waiting. A fill pushed in front of a record the card is
    /// waiting for delays the block the host is actually reading.
    ahead_deferred_busy: u64 = 0,
    /// Read ahead blocks that were dropped because the data channel had no
    /// room for one more block. It is the count that says the channel is
    /// too shallow for the read ahead depth that is set.
    ahead_deferred_space: u64 = 0,
    /// Chunks of a stream that the loop took WITHOUT going back to the
    /// request channel for them.
    ///
    /// The card asks for a stream one chunk at a time, and the read behind
    /// the last push of a chunk finds the record for the next one. Every
    /// one of these is a chunk boundary that cost no round trip and no
    /// idle poll. See `Server.chunkContinues`.
    streams_continued: u64 = 0,
    /// Streams that a new record cut short.
    ///
    /// The card asks for a chunk of blocks in one record and the host may
    /// stop the stream in the middle of that chunk. Every one of these is
    /// a chunk whose remaining blocks were never pushed, so the count is
    /// the work the early stop saved. The blocks that DID go out under the
    /// old tag are thrown away by the card.
    streams_cut: u64 = 0,
    /// Chunks that were dropped because the card took no block of them
    /// within the poll limit and asked for nothing else.
    ///
    /// The blocks of a chunk past the ones the host has read are
    /// speculative, so a channel that never makes room for them is not a
    /// reason to end the serve loop. A number that grows beside a boot
    /// that reads correctly is a host that stops the SD clock after it
    /// stops a stream. A number that grows beside READ TIMEOUTS in EVENT
    /// is a card that stopped draining a chunk it was still serving.
    streams_stalled: u64 = 0,
    /// Times the host model was cleared because the card asked for a
    /// block the model said it held. See `CacheModel`.
    model_resets: u64 = 0,

    pub fn bytes(self: Stats) u64 {
        return (self.blocks + self.fills) * sd.BLOCK_SIZE;
    }
};

/// The most cache lines the host model holds.
///
/// The model is a plain array inside `Server`, so it needs no allocator
/// and has no failure path. 1024 lines is 8 KiB and covers every build of
/// this project with room to spare. A card that reports MORE lines than
/// this turns the model off: every fill then goes out whether the card
/// holds the block or not, which costs bandwidth and is never wrong.
pub const MODEL_LINES: usize = 1024;

/// The value that marks a model line as holding no block.
const NO_BLOCK: u64 = std.math.maxInt(u64);

/// Consecutive read requests required before speculative traffic starts.
/// Short filesystem metadata walks must not occupy the FIFO, while a file
/// stream quickly clears this threshold.
const READ_AHEAD_SEQUENCE: u8 = 8;

/// The host model of what the card cache holds.
///
/// The card does the LOOKUP and no policy, so the HOST chooses what
/// occupies every line and the card never evicts one by itself. The host
/// can therefore keep this model, and it needs it: a fill of a block the
/// card already holds is a whole block of USB traffic for nothing.
///
/// It is DIRECT MAPPED by the rule the card uses, which is the low bits of
/// the block address. `lines` is a power of two, so the rule is a mask.
///
/// The model can drift in exactly one way. The card throws its whole store
/// away on a CMD0, and no command of the SD bus reaches this side, so the
/// model can claim a block the card no longer holds. `Server.serveRead`
/// catches that and clears the model: a record for a block the model
/// claims proves the card lost it.
pub const CacheModel = struct {
    /// Lines the card has, or 0 while the model is off.
    lines: usize = 0,
    /// The block each line holds, or `NO_BLOCK` for a line that holds
    /// none.
    blocks: [MODEL_LINES]u64 = @splat(NO_BLOCK),
    /// True when the named block was sent as a speculative fill but may
    /// still be crossing the data channel into the card cache.
    pending: [MODEL_LINES]bool = @splat(false),

    /// Sizes the model from what CACHE_LINES reported.
    ///
    /// A count that is not a power of two, or one above `MODEL_LINES`,
    /// turns the model OFF rather than model the card wrong. A wrong model
    /// would skip a fill the card needs, and the read that followed would
    /// cost the round trip the cache exists to remove.
    pub fn configure(self: *CacheModel, reported: u32) void {
        const lines: usize = reported;
        const usable = lines >= 2 and
            lines <= MODEL_LINES and
            lines & (lines - 1) == 0;
        self.lines = if (usable) lines else 0;
        self.clear();
    }

    /// Forgets every line.
    pub fn clear(self: *CacheModel) void {
        self.blocks = @splat(NO_BLOCK);
        self.pending = @splat(false);
    }

    /// The line that `lba` maps to.
    fn index(self: *const CacheModel, lba: u64) usize {
        return @intCast(lba & (self.lines - 1));
    }

    /// True while the model says the card holds `lba`.
    ///
    /// A model that is off says no to everything, so every fill goes out.
    pub fn holds(self: *const CacheModel, lba: u64) bool {
        if (self.lines == 0) return false;
        return self.blocks[self.index(lba)] == lba;
    }

    /// Records that the card now holds `lba`, which takes the line away
    /// from whatever held it before. The card does the same.
    pub fn insert(self: *CacheModel, lba: u64) void {
        if (self.lines == 0) return;
        const line = self.index(lba);
        self.blocks[line] = lba;
        self.pending[line] = false;
    }

    /// Records a speculative fill that has entered the transport but may
    /// not yet have reached the card cache.
    pub fn insertPending(self: *CacheModel, lba: u64) void {
        if (self.lines == 0) return;
        const line = self.index(lba);
        self.blocks[line] = lba;
        self.pending[line] = true;
    }

    /// True when `lba` is a speculative fill still in flight.
    pub fn isPending(self: *const CacheModel, lba: u64) bool {
        if (!self.holds(lba)) return false;
        return self.pending[self.index(lba)];
    }

    /// Marks an in-flight fill as committed after the card asks for it.
    pub fn commit(self: *CacheModel, lba: u64) void {
        if (!self.holds(lba)) return;
        self.pending[self.index(lba)] = false;
    }

    /// Records that the card no longer holds `lba`.
    ///
    /// The card invalidates the line a CMD24 names, and only that line: a
    /// write to a block that maps to a line holding ANOTHER block leaves
    /// that line alone. This does the same, so the model follows the card
    /// with no message between them.
    pub fn remove(self: *CacheModel, lba: u64) void {
        if (self.lines == 0) return;
        const line = self.index(lba);
        if (self.blocks[line] == lba) {
            self.blocks[line] = NO_BLOCK;
            self.pending[line] = false;
        }
    }
};

/// Serves read requests from one device out of one image.
pub const Server = struct {
    device: Device,
    image: Image,
    options: Options = .{},
    /// Where a refusal is reported. A refusal that nobody sees is a silent
    /// failure, so the CLI always gives a writer here. A caller that has no
    /// writer passes null and reads `stats.refused` instead.
    log: ?*Io.Writer = null,
    stats: Stats = .{},

    /// Words that DATA_IN was last known to accept.
    ///
    /// A push that the channel has no room for is DROPPED by the card and
    /// nothing reports it, so the loop spends this credit and never sends
    /// more than it holds. The status read of every pass refreshes it, so
    /// it costs no round trip of its own. The card reports the free space
    /// through a counter that crossed out of the SD clock domain, which
    /// can only ever report LESS room than the channel has, so a spender
    /// of this count is safe in the one direction that matters.
    credit_words: u32 = 0,

    /// Words the read data channel holds in all.
    ///
    /// It is read once, while the card is still off and the channel is
    /// therefore empty. Nothing but the depth of the channel bounds how
    /// far a read ahead can run in front of the card.
    channel_words: u32 = 0,

    /// What the card cache holds, as far as this side knows.
    cache: CacheModel = .{},

    /// The sequence tag of the last READ record this side took.
    ///
    /// It counts the records the card posted that never arrived here. See
    /// `Stats.records_lost`.
    last_read_seq: ?u8 = null,

    /// The sequence tag of the last WRITE record this side took.
    ///
    /// The card counts read records and write records on SEPARATE
    /// counters, because the read path and the write path each hold one of
    /// their own. One counter on this side would read every change from a
    /// read record to a write record as a gap and would report records
    /// that were never lost.
    last_write_seq: ?u8 = null,

    /// The generation carried by the last request.
    ///
    /// CMD0 advances it after the card invalidates every cache line. The
    /// first request of a new generation clears the host model before a
    /// pending line can suppress the answer that the card now needs.
    card_epoch: ?u4 = null,

    /// The next block and fixed end of the read-ahead window.
    ///
    /// The read ahead runs AFTER the batch of records, not inside it. The
    /// card takes a fill only while its read path is idle, and a record
    /// that is still waiting says it is not.
    ahead_from: u64 = 0,
    ahead_end: u64 = 0,
    ahead_owed: bool = false,
    /// End of the last read request. A new request that starts here proves
    /// a sequential access before speculative traffic is sent.
    last_read_end: u64 = NO_BLOCK,
    /// Length of the current run of consecutive read requests.
    sequential_reads: u8 = 0,

    /// A record this loop took off the card but has not answered yet.
    ///
    /// The pushes of a STREAM carry a status read behind them in the same
    /// transaction, and that read POPS. A record that comes back there is
    /// therefore already off the card, so it is held here and the next
    /// pass answers it. A record that was dropped instead would leave the
    /// host waiting out the whole read timeout.
    held: ?Request = null,

    /// True while a record this loop has READ is still on the card.
    ///
    /// No read of the register map takes a record away, so the record at
    /// the head goes only on a WRITE of REQ_POP. The loop reads the status
    /// window first and writes that pop after it, for the record the read
    /// gave it and for no other.
    ///
    /// The pop used to ride behind the window read in the same transport
    /// command. That took the head away whether the read had seen a record
    /// or not, so a poll that found the channel EMPTY still popped, and a
    /// record the card posted in the microseconds between the read and the
    /// pop went away unseen. The card then waited out its whole read
    /// timeout for an answer nothing would send, and the host read a data
    /// timeout. It is rare, one record in about fifteen hundred, and a
    /// 63.9 MB file is four thousand records long.
    ///
    /// The pop costs no round trip of its own. It rides in FRONT of the
    /// next push, which is the transaction that answers the record it
    /// takes away. When NO push follows, it rides in front of the next
    /// poll instead. See `readStatus`.
    pop_owed: bool = false,

    /// Reads one CSR and counts the round trip it cost.
    ///
    /// Every single register access of this file goes through these two,
    /// so `stats.round_trips` counts the whole traffic of the loop and not
    /// a part of it. The bulk paths count their own transaction.
    fn csrRead(self: *Server, addr: u32) !u32 {
        self.stats.round_trips += 1;
        return self.device.regRead(addr);
    }

    /// Writes one CSR and counts the round trip it cost. See `csrRead`.
    fn csrWrite(self: *Server, addr: u32, value: u32) !void {
        self.stats.round_trips += 1;
        return self.device.regWrite(addr, value);
    }

    /// Writes NUM_BLOCKS, so the card reports the size of the image.
    pub fn publishCapacity(self: *Server) !void {
        const blocks = std.math.cast(u32, self.image.blocks) orelse
            return Error.NumBlocksTooLarge;
        try self.csrWrite(sd.REG_NUM_BLOCKS, blocks);
    }

    /// Reads CACHE_LINES and sizes the host model from it.
    ///
    /// The line count is a build parameter of the gateware, so it is read
    /// and never assumed. A card that reports a count this model cannot
    /// hold turns the model off, and every fill then goes out. See
    /// `CacheModel.configure`.
    pub fn learnCache(self: *Server) !void {
        self.cache.configure(try self.csrRead(sd.REG_CACHE_LINES));
    }

    /// Seeds the DATA_IN credit before the card starts.
    ///
    /// The card is off here, so the channel is empty and the count is its
    /// whole depth. The first demand can then send its block without
    /// paying a register read while the SD host waits for data, and the
    /// read ahead knows how many blocks one batch may hold.
    pub fn learnDataInCredit(self: *Server) !void {
        self.credit_words = try self.csrRead(sd.REG_DATA_IN_COUNT);
        self.channel_words = self.credit_words;
    }

    /// Turns the card on. A read-only image also sets the read-only bit, so
    /// the card refuses a write of the host instead of taking one that the
    /// runtime cannot keep.
    pub fn enable(self: *Server) !void {
        const ctrl = try self.csrRead(sd.REG_CTRL);
        var next = ctrl | sd.CTRL_ENABLE;
        if (self.image.read_only) next |= sd.CTRL_READ_ONLY;
        try self.csrWrite(sd.REG_CTRL, next);
    }

    /// Brings the write data channel back into step before the loop runs.
    ///
    /// Returns the words it dropped, which is 0 on a card that no earlier
    /// run left in the middle of a write.
    ///
    /// A `serve` that stopped between the block and the acknowledgement
    /// leaves the 512 bytes of that block on the channel, and the card
    /// still counts one block that nobody took. The card refuses every
    /// later write while that block is there, and a runtime that pulled
    /// the next block would read the OLD bytes. Neither clears by itself,
    /// because only this code can take a word off the channel.
    ///
    /// So the channel is drained and, when it held anything at all, ONE
    /// acknowledgement goes out to retire the block that the card counts.
    ///
    /// The acknowledgement carries the largest tag and the FAIL bit. The
    /// tag must not be 0, because 0 names no record and the card ignores a
    /// write of it. The fail bit is set because this code did NOT write
    /// the bytes it just dropped, so a tag that does name the record the
    /// card holds the SD host for tells that host the write failed instead
    /// of telling it the data is safe.
    pub fn resyncWriteChannel(self: *Server) !u32 {
        const waiting = try self.csrRead(sd.REG_DATA_OUT_COUNT);
        var dropped: u32 = 0;
        while (dropped < waiting) : (dropped += 1) {
            try self.csrWrite(sd.REG_DATA_OUT_POP, sd.DATA_OUT_POP_BIT);
        }
        if (waiting != 0) {
            try self.csrWrite(
                sd.REG_WRITE_ACK,
                sd.WRITE_ACK_TAG_MASK | sd.WRITE_ACK_FAIL,
            );
        }
        return dropped;
    }

    /// Turns the card off and leaves the other control bits alone.
    ///
    /// The serve loop calls this before it exits. A host that is in the
    /// middle of a transfer then sees the card go away, which it recovers
    /// from, instead of waiting for data that nothing will ever send.
    pub fn disable(self: *Server) !void {
        const ctrl = try self.csrRead(sd.REG_CTRL);
        try self.csrWrite(sd.REG_CTRL, ctrl & ~sd.CTRL_ENABLE);
    }

    /// Takes every request that the device has ready and answers it.
    /// Returns the number of records taken, which is 0 when the device has
    /// none.
    ///
    /// ONE transport read opens the pass. It brings back the free space of
    /// the read data channel, the number of records that wait and the
    /// record at the head, and it pops that record on the way out. Reading
    /// those three things apart cost three round trips and gave the loop a
    /// credit that was already stale by the time it spent it.
    ///
    /// One call is one pass of the loop. The caller decides when to stop,
    /// so a signal stops the loop between passes and never in the middle of
    /// a block.
    pub fn servePending(self: *Server) !u32 {
        // A record that a stream push already took off the card. It costs
        // no round trip here, and it must be answered before any other
        // work: the host is blocked on it.
        if (self.held) |request| {
            self.held = null;
            _ = try self.serveRequest(request, 0);
            return 1;
        }

        var status: [sd.STATUS_WORDS]u32 = undefined;
        try self.readStatus(&status);
        const pending = status[sd.STATUS_REQ_COUNT];
        if (pending == 0) return 0;

        var words = [REQUEST_WORDS]u32{
            status[sd.STATUS_REQ],
            status[sd.STATUS_REQ_HI],
        };
        // The read took no record away. The pop that does rides in front
        // of the push that answers this record. See `pop_owed`.
        self.pop_owed = true;

        const take = @min(pending, self.options.max_requests_per_poll);
        var taken: u32 = 0;
        while (taken < take) : (taken += 1) {
            // `pending` is the count this pass READ, so the records still
            // known to be waiting cost no round trip of their own. A read
            // ahead rides behind the answer to this record ONLY while that
            // count is 0. See `appendReadAhead`.
            _ = try self.serveRequest(decodeRequest(words), pending - taken - 1);
            if (taken + 1 < take) {
                // A backend may report more than one record. Read and pop
                // the next complete snapshot so a larger FIFO stays ordered.
                try self.readStatus(&status);
                words = .{ status[sd.STATUS_REQ], status[sd.STATUS_REQ_HI] };
                self.pop_owed = true;
            }
        }
        return taken;
    }

    /// Reads the status window. NO address in it has a side effect, so
    /// this takes no record away.
    ///
    /// The record the last read gave is popped FIRST, so the window
    /// reports the one after it. See `pop_owed`.
    fn readStatus(self: *Server, status: *[sd.STATUS_WORDS]u32) !void {
        if (self.pop_owed) {
            // The pop rides in FRONT of the read inside ONE transaction.
            // The device parses the frames in order, so the record is
            // gone before the window is read and the window reports the
            // one after it. It is the byte stream that a separate write
            // and read produce, with no transfer boundary between them.
            self.pop_owed = false;
            try self.device.writeRegsRead(
                &.{.{ sd.REG_REQ_POP, sd.REQ_POP_BIT }},
                sd.REG_STATUS_FIRST,
                status,
            );
        } else {
            try self.device.readRegs(sd.REG_STATUS_FIRST, status);
        }
        self.stats.round_trips += 1;
        self.stats.polls += 1;
        // The device answers this read after it has taken every push that
        // went before it, so the count it gives is never older than the
        // credit this side was carrying.
        self.credit_words = status[sd.STATUS_DATA_IN_COUNT];
    }

    /// Extends the sequential prefetch while no new request is pending.
    ///
    /// A cache hit and a directly consumed fill post no record. The main
    /// loop must therefore keep the channel full without waiting for
    /// another record to tell it that the SD host advanced.
    ///
    /// The caller reaches this only after a status read said that NO
    /// record waits, so the check that guards the demand path is already
    /// paid for.
    pub fn continueReadAhead(self: *Server) !void {
        var entries: [PUSH_BATCH_BLOCKS]PushEntry = undefined;
        const count = self.appendReadAhead(&entries, 0, 0);
        if (count == 0) return;
        try self.pushBatch(entries[0..count]);
    }

    /// Counts the records of one class that the card posted and this side
    /// never saw.
    ///
    /// The card gives every record of a class a tag one above the last one
    /// of that class, and it steps over 0 on a wrap, so a tag more than one
    /// above the tag before it names the records that went missing between
    /// the two. The READ path and the WRITE path each count on a counter of
    /// their own, so each class is measured against its own last tag.
    fn countLostRecords(self: *Server, op: RequestOp, seq: u8) void {
        const last = switch (op) {
            .read_blocks => &self.last_read_seq,
            .write_blocks, .write_discard => &self.last_write_seq,
        };
        if (last.*) |previous| {
            const expected: u8 = if (previous == 0xFF) 1 else previous + 1;
            if (seq != expected) {
                self.stats.records_lost +|= seq -% expected;
            }
        }
        last.* = seq;
    }

    fn serveRequest(self: *Server, request: Request, still_pending: u32) !bool {
        self.stats.requests += 1;
        // A generation the card did not have before. CMD0 advances it
        // after the card invalidates every cache line, and no command of
        // the SD bus reaches this side, so this is the only news of it.
        const new_card = if (self.card_epoch) |epoch|
            epoch != request.epoch
        else
            false;
        if (new_card) {
            self.cache.clear();
            self.stats.model_resets += 1;
            self.last_read_end = NO_BLOCK;
            self.sequential_reads = 0;
            self.ahead_owed = false;
        }
        self.card_epoch = request.epoch;

        // A CMD0 restarts both counters, so the first record of a new
        // generation compares with nothing: counting it would report the
        // whole restart as lost records.
        if (new_card) {
            self.last_read_seq = null;
            self.last_write_seq = null;
        }
        const op = std.enums.fromInt(RequestOp, request.op) orelse {
            try self.refuse("unknown opcode 0x{X:0>2}", .{request.op});
            return false;
        };
        self.countLostRecords(op, request.seq);
        return switch (op) {
            .read_blocks => try self.serveRead(request, still_pending),
            .write_blocks, .write_discard => blk: {
                try self.serveWrite(request, op);
                break :blk false;
            },
        };
    }

    /// Answers one read record and, in the SAME transfer, sends the blocks
    /// the host is about to ask for.
    ///
    /// The demand blocks go FIRST. The card takes the words of one
    /// transfer in order, so a speculative block behind them cannot delay
    /// the block the host is blocked on, and the loop never starts a fill
    /// batch of its own while a record stands.
    fn serveRead(self: *Server, request: Request, still_pending: u32) !bool {
        if (request.blocks == 0) {
            try self.refuse("read of 0 blocks at {d}", .{request.lba});
            return false;
        }
        if (request.blocks > self.options.max_blocks_per_request) {
            try self.refuse("read of {d} blocks is above the limit of {d}", .{
                request.blocks,
                self.options.max_blocks_per_request,
            });
            return false;
        }

        // The end is computed in u64, because lba + blocks passes the top of
        // u32 for a read of the last blocks of a full size card.
        const end = @as(u64, request.lba) + request.blocks;
        if (end > self.image.blocks) {
            try self.refuse("read of {d} blocks at {d} ends past block {d}", .{
                request.blocks,
                request.lba,
                self.image.blocks,
            });
            return false;
        }

        // A record that asks for more than one block is a STREAM. The card
        // reads such a chunk straight off the channel: it asks the cache
        // for nothing and it writes no line for what it sends, because a
        // stream reads each block once and a line it took would push out a
        // line that a metadata read wants.
        //
        // The record of a stream IS the read ahead, so no fill rides
        // behind it either. A fill sent there would be a block the card
        // throws away.
        const stream = request.blocks > 1;

        // The card asked for a block the model says it HOLDS. The card
        // does not evict a line by itself, so the store went away whole,
        // which is what a CMD0 does. No command of the SD bus reaches this
        // side, so this record is the only news of it. The model is
        // cleared rather than left to lie: a model that claims blocks the
        // card lost skips the fills that would put them back.
        //
        // A line that the model calls a fill STILL IN FLIGHT is not that
        // news. The record and the fill crossed, which says nothing about
        // what the card holds, so the model stands.
        //
        // Either way the block goes out under the tag of the record. The
        // card sends a fill whose address matches the read it waits for,
        // but a fill that reached the cache and was pushed out of it again
        // answers nothing, and the host then waits out the whole read
        // timeout. One duplicate block costs one transfer; a timeout costs
        // the boot.
        if (stream) {
            // The walk that the last records made is over, so the window
            // goes back to this record the way `scheduleReadAhead` retires
            // one that stopped being sequential.
            self.last_read_end = end;
            self.ahead_from = end;
            self.ahead_end = end;
            self.sequential_reads = 0;
            self.ahead_owed = false;
        } else {
            if (self.cache.isPending(request.lba)) {
                self.cache.commit(request.lba);
            } else if (self.cache.holds(request.lba)) {
                self.cache.clear();
                self.stats.model_resets += 1;
                self.last_read_end = NO_BLOCK;
                self.sequential_reads = 0;
            }

            // The window is opened BEFORE the blocks go out, so the fills
            // of it can travel in the same transfer as the answer.
            self.scheduleReadAhead(request.lba, end);
        }

        // The block this call is on, the end of the CHUNK it serves and
        // the tag that chunk carries.
        //
        // All three move when the card asks for the NEXT chunk of the same
        // stream. See `chunkContinues`.
        var lba: u64 = request.lba;
        var chunk_end: u64 = end;
        var tag: u8 = request.seq;
        var chunks: u16 = 0;
        while (lba < chunk_end) {
            // A record must be answered, so this one waits for room. A
            // fill never does: see `appendReadAhead`.
            //
            // A STREAM waits differently. A channel that holds no room
            // says the card is not taking the blocks of this chunk, and
            // the reason is usually that the host stopped the stream. The
            // wait therefore reads the whole STATUS on every poll, so the
            // same round trip that asks for room also says whether the
            // card has taken a new read.
            if (stream) {
                const found = self.awaitStreamSpace() catch |e| switch (e) {
                    // The card took no block of this chunk within the poll
                    // limit and asked for nothing else. The rest of the
                    // chunk is speculative, so it is dropped and counted
                    // rather than ending the serve loop. See
                    // `awaitStreamSpace`.
                    Error.DataInFull => {
                        self.stats.streams_stalled += 1;
                        return true;
                    },
                    else => return e,
                };
                if (found) |next_record| {
                    // The chunk still owes blocks, so the card cannot have
                    // taken the whole of it and cannot be asking for the
                    // next one. This record is a new read. See
                    // `chunkContinues`.
                    self.held = next_record;
                    self.stats.streams_cut += 1;
                    return true;
                }
            } else {
                try self.awaitSpace(BLOCK_WORDS);
            }
            var entries: [PUSH_BATCH_BLOCKS]PushEntry = undefined;
            var count: usize = 0;
            while (lba < chunk_end and
                count < entries.len and
                self.batchFits(count + 1)) : (lba += 1)
            {
                entries[count] = .{
                    .lba = lba,
                    .tag = tag,
                    .model = !stream,
                };
                count += 1;
            }
            // The wait above found room for one whole block, whichever
            // of the two it was.
            std.debug.assert(count > 0);
            if (!stream) {
                if (lba >= chunk_end) {
                    count = self.appendReadAhead(&entries, count, still_pending);
                }
                try self.pushBatch(entries[0..count]);
                continue;
            }

            // A stream carries the status read BEHIND every push, in the
            // same transaction, so it costs no round trip of its own. It
            // pays for two things.
            //
            // The free space it reports is the space AFTER the card took
            // these blocks, so the batch after this one never has to poll
            // for room.
            //
            // A RECORD in it is one of two things, and `chunkContinues`
            // tells them apart.
            //
            // The card asks for one CHUNK at a time. When the chunk runs
            // out it looks the next block up and posts a record for the
            // chunk after it, under a tag of its own. That record CARRIES
            // ON the stream this call is already serving, so the loop
            // takes it here and keeps pushing. It costs no round trip: the
            // read that found it rode behind the push.
            //
            // Anything else is a new read. The host stopped this stream
            // with CMD12 and started something else, so every block of
            // this chunk that is left would be pushed for nobody.
            //
            // The blocks already pushed are safe either way. The card gave
            // the new read a sequence tag of its own, so blocks of this
            // chunk that are still on the channel carry the OLD tag, and
            // the card takes each one off and throws it away.
            var status: [sd.STATUS_WORDS]u32 = undefined;
            try self.pushBatchStatus(entries[0..count], &status);
            if (status[sd.STATUS_REQ_COUNT] != 0) {
                self.pop_owed = true;
                const next_record = decodeRequest(.{
                    status[sd.STATUS_REQ],
                    status[sd.STATUS_REQ_HI],
                });
                if (chunks < self.options.max_stream_chunks and
                    self.chunkContinues(next_record, request, lba, chunk_end))
                {
                    chunks += 1;
                    self.stats.requests += 1;
                    self.stats.streams_continued += 1;
                    self.countLostRecords(.read_blocks, next_record.seq);
                    tag = next_record.seq;
                    chunk_end = @as(u64, next_record.lba) + next_record.blocks;
                    // The walk goes on, so the read ahead window follows
                    // the stream the way the first chunk set it.
                    self.last_read_end = chunk_end;
                    self.ahead_from = chunk_end;
                    self.ahead_end = chunk_end;
                    continue;
                }
                self.held = next_record;
                self.stats.streams_cut += 1;
                return true;
            }
        }
        return true;
    }

    /// True while `next` is the NEXT CHUNK of the stream this call serves.
    ///
    /// The card asks for a stream one chunk at a time. It takes the blocks
    /// of a chunk off the channel one by one, and only when the last of
    /// them has gone does it look the next block up and post a record for
    /// the chunk after it. Such a record is the same read going on, and
    /// the loop must answer it and not read it as an abort.
    ///
    /// Three things must hold, and each rules out a different mistake.
    ///
    /// The chunk this call serves owes NOTHING more (`lba` has reached
    /// `end`). While it still owes blocks the card cannot have taken the
    /// whole chunk, so it cannot be asking for the next one, and a record
    /// there is a read the host started after it stopped this one.
    ///
    /// The record starts EXACTLY where this chunk ends. A read that starts
    /// anywhere else is another read, whatever else it looks like.
    ///
    /// The record is a READ of MORE than one block from the SAME card
    /// generation. A single block read is a CMD17 and never the chunk of a
    /// stream, and a generation that moved means a CMD0 threw the card
    /// state away between the two records.
    ///
    /// A record that fails any of these goes back to `servePending`, which
    /// checks and refuses it the way it checks every other record. Nothing
    /// is lost by rejecting a real continuation here: it costs one round
    /// trip and the stream goes on.
    fn chunkContinues(
        self: *const Server,
        next: Request,
        request: Request,
        lba: u64,
        end: u64,
    ) bool {
        if (lba != end) return false;
        if (next.lba != end) return false;
        if (next.op != @intFromEnum(RequestOp.read_blocks)) return false;
        if (next.blocks <= 1) return false;
        if (next.epoch != request.epoch) return false;
        // The same range check `serveRead` makes for a record of its own.
        // A chunk that ran past the image would read a block the file does
        // not hold.
        const next_end = @as(u64, next.lba) + next.blocks;
        if (next_end > self.image.blocks) return false;
        if (next.blocks > self.options.max_blocks_per_request) return false;
        return true;
    }

    /// True while one transaction may carry `blocks` blocks: the data
    /// channel holds room for all of them and the batch limit allows them.
    fn batchFits(self: *const Server, blocks: usize) bool {
        if (blocks > self.options.max_batch_blocks) return false;
        return blocks * BLOCK_WORDS <= self.credit_words;
    }

    /// Opens a read-ahead window once consecutive requests prove a
    /// sequential walk. Filesystem metadata is often scattered, and filling
    /// after each isolated access spends the channel on blocks the host
    /// will not ask for.
    ///
    /// A record CONTINUES the walk when it names a block from the end of
    /// the last record up to the frontier this side has already sent
    /// ahead. The second half of that rule is what keeps a working read
    /// ahead working: the host reads a whole window out of the card cache
    /// and posts no record for any block of it, so the record that follows
    /// the window names a block far past the last one this side served,
    /// and a plain next-block test would read that as a jump and shut the
    /// read ahead down after every window.
    fn scheduleReadAhead(self: *Server, lba: u64, end: u64) void {
        const frontier = @max(self.last_read_end, self.ahead_from);
        const sequential = self.last_read_end != NO_BLOCK and
            lba >= self.last_read_end and lba <= frontier;
        self.last_read_end = end;
        if (!sequential) {
            // The frontier belongs to the run that just ended, so it goes
            // back to the record. A window left standing would send the
            // blocks of the old file after the host moved to another one.
            self.ahead_from = end;
            self.ahead_end = end;
            self.sequential_reads = 1;
            self.ahead_owed = false;
            return;
        }
        self.sequential_reads +|= 1;
        if (self.sequential_reads < READ_AHEAD_SEQUENCE) {
            self.ahead_owed = false;
            return;
        }
        self.ahead_from = @max(end, self.ahead_from);
        self.ahead_end = @min(
            self.ahead_from + self.options.read_ahead,
            self.image.blocks,
        );
        self.ahead_owed = self.ahead_from < self.ahead_end;
    }

    /// Puts the blocks after the record into the free places of a batch.
    ///
    /// `used` is how many demand blocks the batch already holds and
    /// `still_pending` is how many records the last status read said are
    /// still waiting. Returns the new length of the batch.
    ///
    /// NOTHING is appended while a record stands. A record that stands is
    /// a block the host is already blocked on, and the loop must go back
    /// for it rather than spend the transfer on a guess. This is the whole
    /// of the rule: a demand read always takes priority over a fill, the
    /// check comes before every batch, and the demand blocks of a batch
    /// always sit in front of the fills of it.
    ///
    /// A fill never waits for room and never fails. It goes only into the
    /// credit that is already known to be free, so a batch that the card
    /// would refuse is never built.
    ///
    /// A block the model says the card already holds costs nothing at all,
    /// which is why the model is worth keeping.
    fn appendReadAhead(
        self: *Server,
        entries: *[PUSH_BATCH_BLOCKS]PushEntry,
        used: usize,
        still_pending: u32,
    ) usize {
        var count = used;
        if (!self.ahead_owed or self.options.read_ahead == 0) return count;
        if (still_pending != 0) {
            self.stats.ahead_deferred_busy += 1;
            return count;
        }
        while (count < entries.len and self.ahead_from < self.ahead_end) {
            const lba = self.ahead_from;
            if (self.cache.holds(lba)) {
                self.stats.fills_skipped += 1;
                self.ahead_from = lba + 1;
                continue;
            }
            if (!self.batchFits(count + 1)) {
                self.stats.ahead_deferred_space += 1;
                break;
            }
            entries[count] = .{ .lba = lba, .tag = sd.DATA_TAG_FILL };
            count += 1;
            self.ahead_from = lba + 1;
        }
        // One record opens exactly one bounded window. Leaving this set
        // turns read ahead into an unbounded image scan, which can run
        // thousands of blocks beyond the SD host and fill every line of
        // the card cache with blocks that nobody asked for.
        if (self.ahead_from >= self.ahead_end) self.ahead_owed = false;
        return count;
    }

    /// True when the record names blocks that this image holds.
    ///
    /// The record comes from the device, so every field of it is checked
    /// here, the way `serveRead` checks the same three fields. A record
    /// that fails a check is counted and reported, and the caller writes
    /// nothing.
    fn writeInRange(self: *Server, request: Request) !bool {
        if (request.blocks == 0) {
            try self.refuse("write of 0 blocks at {d}", .{request.lba});
            return false;
        }
        if (request.blocks > self.options.max_blocks_per_request) {
            try self.refuse("write of {d} blocks is above the limit of {d}", .{
                request.blocks,
                self.options.max_blocks_per_request,
            });
            return false;
        }
        // The end is computed in u64 for the reason `serveRead` computes it
        // there: lba + blocks passes the top of u32 at the end of a full
        // size card.
        const end = @as(u64, request.lba) + request.blocks;
        if (end > self.image.blocks) {
            try self.refuse("write of {d} blocks at {d} ends past block {d}", .{
                request.blocks,
                request.lba,
                self.image.blocks,
            });
            return false;
        }
        return true;
    }

    /// Takes one block off the write data channel and retires the record.
    ///
    /// The order of the three steps is fixed by the card.
    ///
    /// The block comes off the channel FIRST, whatever this code then does
    /// with it. The records and the channel are two streams of one
    /// conversation, so a record that leaves its 128 words behind puts
    /// every later write on the wrong block. The checks of the record
    /// therefore come AFTER the block, and a record that fails one of them
    /// still leaves the channel empty.
    ///
    /// The acknowledgement goes out LAST. The card holds the SD host busy
    /// on DAT0 until it arrives, so a loop that takes the block and never
    /// acknowledges it stops the host until the card times out.
    fn serveWrite(self: *Server, request: Request, op: RequestOp) !void {
        var block: [sd.BLOCK_SIZE]u8 = undefined;
        try self.pullBlock(&block);

        // The card invalidates the line a CMD24 names, whatever this code
        // then does with the block, so the model drops it here and not on
        // the success path. A line that the model kept would hold the
        // bytes from before the write and no fill would ever replace it.
        self.cache.remove(request.lba);

        const in_range = switch (op) {
            .read_blocks => unreachable,
            // A discard writes nothing, so the address it names reaches no
            // block of the image and there is nothing to check. The record
            // is reported below whatever this says.
            .write_discard => true,
            .write_blocks => try self.writeInRange(request),
        };

        // A discard fails nothing here: the card saw the bad CRC16 and
        // threw the block away itself, so the acknowledgement of a discard
        // carries no fail bit.
        const write_error: ?anyerror = switch (op) {
            .read_blocks => unreachable,
            .write_discard => null,
            .write_blocks => blk: {
                if (!in_range) break :blk Error.BlockOutOfRange;
                self.image.writeBlock(request.lba, &block) catch |err| break :blk err;
                break :blk null;
            },
        };
        const kept = op == .write_blocks and write_error == null;
        if (kept) self.stats.written += 1 else self.stats.dropped += 1;

        // The acknowledgement goes out BEFORE the log line, because the
        // card holds the host busy until it arrives. A log writer that
        // fails must not keep the host waiting for a block that this code
        // already took.
        try self.ackWrite(request.seq, write_error != null);

        if (op == .write_discard) {
            try self.refuse(
                "block {d} arrived with a bad CRC16 on the SD bus",
                .{request.lba},
            );
        } else if (!in_range) {
            // `writeInRange` already said why, and it counted the refusal.
        } else if (write_error) |err| switch (err) {
            Error.ImageReadOnly => try self.refuse(
                "write of block {d} on a read only image",
                .{request.lba},
            ),
            else => try self.refuse(
                "write of block {d} failed: {s}",
                .{ request.lba, @errorName(err) },
            ),
        };
    }

    /// Takes one block off the write data channel into `buf`.
    ///
    /// One explicit read-and-pop stream takes the full block. The transport
    /// reads DATA_OUT and writes DATA_OUT_POP for every word inside the
    /// device, so an ordinary register read still has no side effect.
    ///
    /// Byte 0 of the block is bits 7 to 0 of the FIRST word, which is the
    /// little endian order that DATA_IN and every other value on this wire
    /// use.
    ///
    /// The whole block is waited for FIRST. A read of DATA_OUT on an empty
    /// channel gives 0, so a pull that did not wait would put ZERO bytes
    /// in `buf` and report nothing wrong, and those zeros would then be
    /// written over a block of the image.
    fn pullBlock(self: *Server, buf: *[sd.BLOCK_SIZE]u8) !void {
        try self.awaitBlock(BLOCK_WORDS);
        var words: [BLOCK_WORDS]u32 = undefined;
        try self.device.readStream(sd.REG_DATA_OUT, &words);
        // The transport splits a block into READ frames of its own, and
        // each one is a round trip.
        self.stats.round_trips += (BLOCK_WORDS + READ_WORDS_PER_TRIP - 1) /
            READ_WORDS_PER_TRIP;
        for (words, 0..) |word, i| {
            std.mem.writeInt(u32, buf[i * 4 ..][0..4], word, .little);
        }
    }

    /// Waits until DATA_OUT holds `words` words.
    ///
    /// This is the mirror of `awaitSpace` on the other channel, and the
    /// register map asks for it: part of DATA_OUT_COUNT comes from a
    /// counter that crossed out of the SD clock domain, so the count can
    /// only ever report FEWER words than the channel holds. A reader that
    /// waits on it therefore never takes a word the card did not push.
    ///
    /// The count is read on every pass. The card pushes the words of a
    /// block as the bytes arrive on DAT, so the count of a channel that is
    /// filling changes without this code writing anything.
    fn awaitBlock(self: *Server, words: u32) !void {
        var polls: u32 = 0;
        while (polls < self.options.block_poll_limit) : (polls += 1) {
            const have = try self.csrRead(sd.REG_DATA_OUT_COUNT);
            if (have >= words) return;
        }
        return Error.DataOutShort;
    }

    /// Retires one write record under the tag `seq`.
    ///
    /// `failed` says that this code did not keep the block, so the card
    /// reports the fault to the host instead of saying that the data is
    /// safe. A block that the card itself threw away is not a failure of
    /// this code, so it retires with the bit clear.
    fn ackWrite(self: *Server, seq: u8, failed: bool) !void {
        var value: u32 = seq;
        if (failed) value |= sd.WRITE_ACK_FAIL;
        try self.csrWrite(sd.REG_WRITE_ACK, value);
    }

    /// Pushes a batch of blocks into DATA_IN in ONE transport transaction.
    ///
    /// The batch carries two kinds of block and both keep the same rule:
    /// the setup writes of a block come immediately in front of its 512
    /// bytes, and the last data word of the block commits the pair inside
    /// the card. The transport keeps the frames of one transfer in order,
    /// so four blocks cross the link for the price of one round trip.
    ///
    /// A block that answers a RECORD goes out under the tag of that
    /// record. The card throws away a block whose tag names a request it
    /// already gave up on, so a late answer can never be read as the
    /// answer to another read.
    ///
    /// A block that answers NO record is a FILL. Its address goes out
    /// first and its tag is `sd.DATA_TAG_FILL`, which names no record. The
    /// card writes it into the line the address maps to and sends nothing
    /// on the SD bus. A fill and a record answer therefore stay apart by
    /// construction: the tag alone decides which one the card is holding.
    ///
    /// Byte 0 of a block goes in bits 7 to 0 of its first word, which
    /// matches the little endian byte order of every other value on this
    /// wire.
    ///
    /// The CALLER must hold credit for the whole batch. The card DROPS a
    /// push that its channel has no room for, and it drops the tag with
    /// it, so a batch that does not fit loses blocks and reports nothing.
    fn pushBatch(self: *Server, entries: []const PushEntry) !void {
        return self.pushBatchInner(entries, null);
    }

    /// Pushes a batch and reads the status window behind it, in ONE
    /// transport transaction.
    ///
    /// The card answers the read at the END of the command stream, so the
    /// free space and the record count it reports are the ones that follow
    /// these blocks. The read POPS, so a record that comes back is off the
    /// card and the caller MUST answer it.
    fn pushBatchStatus(
        self: *Server,
        entries: []const PushEntry,
        status: *[sd.STATUS_WORDS]u32,
    ) !void {
        return self.pushBatchInner(entries, status);
    }

    fn pushBatchInner(
        self: *Server,
        entries: []const PushEntry,
        status: ?*[sd.STATUS_WORDS]u32,
    ) !void {
        std.debug.assert(entries.len > 0);
        std.debug.assert(entries.len <= PUSH_BATCH_BLOCKS);
        const batch_words: u32 = @intCast(entries.len * BLOCK_WORDS);
        std.debug.assert(self.credit_words >= batch_words);

        var words: [PUSH_BATCH_BLOCKS * BLOCK_WORDS]u32 = undefined;
        var setup: [PUSH_BATCH_BLOCKS][3][2]u32 = undefined;
        var groups: [PUSH_BATCH_BLOCKS]WriteStreamGroup = undefined;
        var block: [sd.BLOCK_SIZE]u8 = undefined;
        // The pop of the record this batch answers rides in FRONT of the
        // first block, so it costs no round trip. It takes away the record
        // the loop has already READ and can take away no other: the head
        // cannot change while a record stands there. See `pop_owed`.
        //
        // The flag is cleared only once the transaction has GONE. A block
        // that the image refuses leaves this function before the write,
        // and the record must then still be popped by whatever comes next.
        const pop_first: usize = if (self.pop_owed) 1 else 0;
        for (entries, 0..) |entry, i| {
            try self.image.readBlock(entry.lba, &block);
            const block_words = words[i * BLOCK_WORDS ..][0..BLOCK_WORDS];
            for (block_words, 0..) |*word, word_index| {
                word.* = std.mem.readInt(
                    u32,
                    block[word_index * 4 ..][0..4],
                    .little,
                );
            }
            // Only the FIRST group carries the pop. A later one would send
            // it after blocks that answer the record it takes away.
            const lead: usize = if (i == 0) pop_first else 0;
            if (lead == 1) setup[i][0] = .{ sd.REG_REQ_POP, sd.REQ_POP_BIT };
            const before: []const [2]u32 = if (entry.tag == sd.DATA_TAG_FILL) blk: {
                const addr = std.math.cast(u32, entry.lba) orelse
                    return Error.BlockOutOfRange;
                setup[i][lead] = .{ sd.REG_DATA_FILL_LBA, addr };
                setup[i][lead + 1] = .{ sd.REG_DATA_TAG, sd.DATA_TAG_FILL };
                break :blk setup[i][0 .. lead + 2];
            } else blk: {
                // A record answer writes DATA_TAG and nothing else. The
                // write of the tag also clears the fill address that a
                // fill before it left, so the two never mix.
                setup[i][lead] = .{ sd.REG_DATA_TAG, entry.tag };
                break :blk setup[i][0 .. lead + 1];
            };
            groups[i] = .{
                .before = before,
                .addr = sd.REG_DATA_IN,
                .values = block_words,
            };
        }
        // The status read of the next pass does NOT ride behind this
        // transfer, although the transport can carry it there. Measured on
        // the SG2000 it made the boot WORSE: the read comes back before
        // the card has put the block on DAT, so it reports no record, the
        // loop sleeps and reads again, and the pass costs more than it
        // saved. `mimic-cli pushtest` still proves the shape works.
        if (status) |window| {
            try self.device.writeStreamGroupsRead(
                groups[0..entries.len],
                sd.REG_STATUS_FIRST,
                window,
            );
            self.stats.round_trips += 1;
            self.stats.polls += 1;
            if (pop_first == 1) self.pop_owed = false;
            // The count comes back AFTER the card took these blocks, so it
            // is never older than the credit this side was carrying.
            self.credit_words = window[sd.STATUS_DATA_IN_COUNT];
        } else {
            try self.device.writeStreamGroups(groups[0..entries.len]);
            self.stats.round_trips += 1;
            if (pop_first == 1) self.pop_owed = false;
            self.credit_words -= batch_words;
        }
        for (entries) |entry| {
            if (entry.tag == sd.DATA_TAG_FILL) {
                self.stats.fills += 1;
                self.cache.insertPending(entry.lba);
            } else {
                self.stats.blocks += 1;
                // The card writes a block that answers a SINGLE block
                // record into the line it maps to, so the model follows it
                // with no message. A block of a stream takes no line.
                if (entry.model) self.cache.insert(entry.lba);
            }
        }
    }

    /// Waits until DATA_IN holds `words` free words.
    ///
    /// DATA_IN_COUNT reports the free space in WORDS and the card moves it
    /// as the block drains, so every read of it says something new. The
    /// count is built from a counter that crossed out of the SD clock
    /// domain, so it can only ever report LESS free space than the channel
    /// has, never more, and a writer that spends what it read can never
    /// fill the channel.
    ///
    /// The loop SLEEPS between reads. The card drains the channel on the
    /// SD CLOCK, which no register access of this side makes go faster, so
    /// a read that finds no room is a whole USB round trip that changes
    /// nothing. One block takes 4114 SD clocks, which is 165 us at 25 MHz
    /// and 686 us at 6 MHz, and a wait of a fraction of that replaces
    /// several round trips. `space_poll_wait_us` is 0 for a library caller
    /// and for every test, so neither sleeps at all.
    fn awaitSpace(self: *Server, words: u32) !void {
        if (self.credit_words >= words) return;
        var polls: u32 = 0;
        defer {
            self.stats.space_polls += polls;
            if (polls > self.stats.space_polls_max) {
                self.stats.space_polls_max = polls;
            }
        }
        while (polls < self.options.space_poll_limit) : (polls += 1) {
            self.credit_words = try self.csrRead(sd.REG_DATA_IN_COUNT);
            if (self.credit_words >= words) {
                polls += 1;
                return;
            }
            if (self.options.space_poll_wait_us != 0) {
                self.image.io.sleep(
                    Io.Duration.fromMicroseconds(self.options.space_poll_wait_us),
                    .awake,
                ) catch {};
            }
        }
        return Error.DataInFull;
    }

    /// Waits for room for one block of a STREAM.
    ///
    /// It returns the RECORD that ended the stream, or null when the
    /// channel now holds room for a block.
    ///
    /// Every poll reads the whole status window, so one round trip asks
    /// for room AND asks whether the card has taken a new read. The card
    /// posts a record only while it is not serving a chunk, so a record
    /// here proves that the host stopped this stream and that every block
    /// of the chunk that is left would be pushed for nobody.
    ///
    /// The read POPS, so a record it returns is already off the card and
    /// the caller MUST answer it.
    ///
    /// A poll limit that runs out with NO record ABANDONS the chunk, and
    /// `Error.DataInFull` says so to the caller.
    ///
    /// The blocks of a chunk that the host has not reached yet are
    /// SPECULATIVE: the card asked for a whole chunk and the host reads as
    /// much of it as it likes. A channel that holds no room says the card
    /// is not taking them, and a host that stopped the SD clock after it
    /// stopped a stream leaves exactly that picture. Killing the serve
    /// loop there would end the boot over blocks that nobody wanted.
    ///
    /// The caller therefore counts the chunk as stalled and goes back to
    /// the request channel. If the card really was waiting, it times out
    /// and the host retries the read, which the loop then answers.
    fn awaitStreamSpace(self: *Server) !?Request {
        if (self.credit_words >= BLOCK_WORDS) return null;
        var polls: u32 = 0;
        defer {
            self.stats.space_polls += polls;
            if (polls > self.stats.space_polls_max) {
                self.stats.space_polls_max = polls;
            }
        }
        var status: [sd.STATUS_WORDS]u32 = undefined;
        while (polls < self.options.space_poll_limit) : (polls += 1) {
            try self.readStatus(&status);
            if (status[sd.STATUS_REQ_COUNT] != 0) {
                self.pop_owed = true;
                return decodeRequest(.{
                    status[sd.STATUS_REQ],
                    status[sd.STATUS_REQ_HI],
                });
            }
            if (self.credit_words >= BLOCK_WORDS) {
                polls += 1;
                return null;
            }
            if (self.options.space_poll_wait_us != 0) {
                self.image.io.sleep(
                    Io.Duration.fromMicroseconds(self.options.space_poll_wait_us),
                    .awake,
                ) catch {};
            }
        }
        return Error.DataInFull;
    }

    /// Counts a request that this code will not answer and says why.
    ///
    /// The device gets no data for the record. A card that asks for a block
    /// outside its own reported size has a fault of its own, and answering
    /// with any bytes at all would hand the host data that belongs to no
    /// block.
    fn refuse(self: *Server, comptime fmt: []const u8, args: anytype) !void {
        self.stats.refused += 1;
        if (self.log) |out| {
            try out.print("refused: " ++ fmt ++ "\n", args);
        }
    }
};

// Tests. The device here is a fake that holds a scripted request FIFO and
// records what the code under test pushed. No test needs hardware.

/// A `Device` that answers from a script and keeps what it was given.
///
/// It models the register map that the gateware implements: REQ gives word
/// 0 of the record at the head and REQ_HI gives word 1, both with NO side
/// effect, and a write of REQ_POP_BIT to REQ_POP takes the record away. A
/// code under test that never writes REQ_POP therefore reads the same
/// record for ever, here and on the device.
const FakeDevice = struct {
    /// The record words, in order, two per record.
    req: []const u32 = &.{},
    /// Index of word 0 of the record at the head.
    req_read: usize = 0,
    /// What REQ_COUNT reports.
    req_count: u32 = 0,
    /// What DATA_IN_COUNT reports, as free words.
    space_words: u32 = 4096,
    /// What DATA_IN_COUNT reports from the SECOND read onward, or null to
    /// report `space_words` every time.
    ///
    /// The fake does not model the card taking words off the channel, so
    /// this is how a test says that the channel filled up. A read ahead
    /// that found no room must push nothing and must not wait.
    space_words_later: ?u32 = null,
    ctrl: u32 = 0,
    num_blocks: u32 = 0,
    /// Words pushed to DATA_IN, in order.
    pushed: [64 * BLOCK_WORDS]u32 = undefined,
    pushed_len: usize = 0,
    /// Reads of DATA_IN_COUNT, which shows how often the code asked for
    /// space instead of spending what it had.
    space_reads: usize = 0,
    /// The tag that DATA_TAG last took, one entry per block pushed.
    tags: [64]u8 = undefined,
    tags_len: usize = 0,
    /// The tag that no push has claimed yet. A push with no tag in front
    /// of it is a fault, so the value starts outside the u8 range.
    pending_tag: ?u8 = null,
    /// What REQ_COUNT reports from the SECOND read of a poll onward.
    ///
    /// The read ahead reads REQ_COUNT again to learn whether the card is
    /// idle, and it pushes a fill only when it is. A test that wants the
    /// read ahead to run leaves this at 0.
    req_count_later: u32 = 0,
    /// Reads of REQ_COUNT.
    req_count_reads: usize = 0,
    /// The fill address that no push has claimed yet.
    pending_fill: ?u32 = null,
    /// The fill address of each block pushed, or null for a block that
    /// answers a record. One entry per entry of `tags`.
    fills: [64]?u32 = undefined,
    /// The words on the write data channel, in order, 128 per block.
    data_out: []const u32 = &.{},
    /// Index of the word at the head of the write data channel.
    data_out_head: usize = 0,
    /// Reads of DATA_OUT. A read takes nothing away, so this count shows
    /// whether the code under test reads and pops each word once.
    data_out_reads: usize = 0,
    /// Writes of DATA_OUT_POP that took a word away.
    data_out_pops: usize = 0,
    /// What WRITE_ACK took, in order, one entry per record retired.
    acks: [64]u32 = undefined,
    acks_len: usize = 0,
    /// Reads of DATA_OUT_COUNT.
    data_out_count_reads: usize = 0,
    /// Reads of DATA_OUT_COUNT that report an EMPTY channel before the
    /// count tells the truth. The card publishes a word only once it has
    /// pushed it, so a runtime that reads the count while the block is
    /// still arriving on DAT sees fewer words than the block holds.
    data_out_late_polls: usize = 0,
    /// USB FRAMES the code under test has cost.
    ///
    /// It is the number that decides how fast the link runs. One frame is
    /// one transfer on the wire: a register read, a register write, one
    /// write of several pairs, or one stream of a whole block. At full
    /// speed a frame is of the order of 100 us whatever it carries, so a
    /// block that costs ten frames costs a millisecond and a block that
    /// costs five hundred costs a twentieth of a second.
    frames: usize = 0,

    fn regWrite(self: *FakeDevice, addr: u32, value: u32) anyerror!void {
        self.frames += 1;
        switch (addr) {
            sd.REG_CTRL => self.ctrl = value,
            sd.REG_NUM_BLOCKS => self.num_blocks = value,
            sd.REG_DATA_TAG => self.pending_tag = @truncate(value),
            // The address of a FILL. It is staged and the write of
            // DATA_TAG commits the pair, which is the order the card
            // asks for.
            sd.REG_DATA_FILL_LBA => self.pending_fill = value,
            // The one write that moves the request FIFO. A write with the
            // bit clear does nothing, the way the gateware does nothing.
            sd.REG_REQ_POP => {
                if (value & sd.REQ_POP_BIT == 0) return;
                if (self.req_read + 1 >= self.req.len) return error.RequestFifoEmpty;
                self.req_read += REQUEST_WORDS;
            },
            // The one write that moves the write data channel. A pop of an
            // empty channel does nothing, the way the gateware does
            // nothing.
            sd.REG_DATA_OUT_POP => {
                if (value & sd.DATA_OUT_POP_BIT == 0) return;
                if (self.data_out_head >= self.data_out.len) return;
                self.data_out_head += 1;
                self.data_out_pops += 1;
            },
            sd.REG_WRITE_ACK => {
                if (self.acks_len == self.acks.len) return error.FakeAckOverflow;
                self.acks[self.acks_len] = value;
                self.acks_len += 1;
            },
            else => return error.UnexpectedRegisterWrite,
        }
    }

    fn regRead(self: *FakeDevice, addr: u32) anyerror!u32 {
        self.frames += 1;
        return switch (addr) {
            sd.REG_REQ_COUNT, sd.REG_REQ_SNAPSHOT_COUNT => blk: {
                self.req_count_reads += 1;
                if (self.req_count_reads > 1) break :blk self.req_count_later;
                break :blk self.req_count;
            },
            // The line count of the card cache. A power of two, the way
            // the gateware guarantees.
            sd.REG_CACHE_LINES => 128,
            sd.REG_DATA_IN_COUNT => blk: {
                self.space_reads += 1;
                if (self.space_reads > 1) {
                    if (self.space_words_later) |later| break :blk later;
                }
                break :blk self.space_words;
            },
            sd.REG_CTRL => self.ctrl,
            sd.REG_NUM_BLOCKS => self.num_blocks,
            // A register that `mimic-cli info` reads, so a test can put a
            // foreign access in the middle of a record.
            sd.REG_ID => sd.ID_MAGIC,
            // Word 0 of the record at the head. No side effect: the head
            // does not move and the value does not change.
            sd.REG_REQ => blk: {
                if (self.req_read >= self.req.len) return error.RequestFifoEmpty;
                break :blk self.req[self.req_read];
            },
            // Word 1 of the record at the head. No side effect either: the
            // head moves only on a write of REQ_POP.
            sd.REG_REQ_HI => blk: {
                if (self.req_read + 1 >= self.req.len) return error.RequestFifoEmpty;
                break :blk self.req[self.req_read + 1];
            },
            // The word at the head of the write data channel. No side
            // effect either: the head moves only on a write of
            // DATA_OUT_POP, and an empty channel reads 0.
            sd.REG_DATA_OUT => blk: {
                self.data_out_reads += 1;
                if (self.data_out_head >= self.data_out.len) break :blk 0;
                break :blk self.data_out[self.data_out_head];
            },
            sd.REG_DATA_OUT_COUNT => blk: {
                self.data_out_count_reads += 1;
                if (self.data_out_count_reads <= self.data_out_late_polls) break :blk 0;
                break :blk @intCast(self.data_out.len - self.data_out_head);
            },
            else => error.UnexpectedRegisterRead,
        };
    }

    fn readStream(self: *FakeDevice, addr: u32, words: []u32) anyerror!void {
        self.frames += 1;
        if (addr != sd.REG_DATA_OUT) return error.UnexpectedStreamAddress;
        for (words) |*word| {
            word.* = try self.regRead(addr);
            try self.regWrite(sd.REG_DATA_OUT_POP, sd.DATA_OUT_POP_BIT);
        }
        // The transport coalesces every read and pop into one command.
        self.frames -= words.len * 2;
    }

    fn readRegs(self: *FakeDevice, addr: u32, words: []u32) anyerror!void {
        self.frames += 1;
        // The status window. It takes NO record away, the way no read of
        // the register map does. The pop is a write of its own.
        if (addr == sd.REG_STATUS_FIRST and words.len == sd.STATUS_WORDS) {
            self.fillStatus(words);
            return;
        }
        if (addr != sd.REG_REQ_SNAPSHOT or words.len != REQUEST_WORDS) {
            return error.UnexpectedReadRegs;
        }
        words[0] = if (self.req_read < self.req.len) self.req[self.req_read] else 0;
        words[1] = if (self.req_read + 1 < self.req.len) self.req[self.req_read + 1] else 0;
    }

    /// Answers the whole status window from the same state the single
    /// register reads use, so a test that sets `space_words` or
    /// `req_count` sees it here as well.
    fn fillStatus(self: *FakeDevice, words: []u32) void {
        @memset(words, 0);

        self.space_reads += 1;
        words[sd.STATUS_DATA_IN_COUNT] = blk: {
            if (self.space_reads > 1) {
                if (self.space_words_later) |later| break :blk later;
            }
            break :blk self.space_words;
        };
        words[sd.STATUS_DATA_OUT_COUNT] =
            @intCast(self.data_out.len - self.data_out_head);

        self.req_count_reads += 1;
        // A channel whose script has run out reports NO record, the way an
        // empty channel on the card does. Without this a test script would
        // hand the loop a record of zero words.
        const more = self.req_read + 1 < self.req.len;
        const count: u32 = if (self.req_count_reads > 1)
            self.req_count_later
        else
            self.req_count;
        words[sd.STATUS_REQ_COUNT] = if (more) count else 0;
        words[sd.STATUS_REQ] =
            if (self.req_read < self.req.len) self.req[self.req_read] else 0;
        words[sd.STATUS_REQ_HI] =
            if (self.req_read + 1 < self.req.len) self.req[self.req_read + 1] else 0;
    }

    /// The one status read of the serve loop.
    ///
    /// It answers the whole window from DATA_IN_COUNT to REQ_SNAPSHOT_HI
    /// and then pops the record, the way the gateware does. Every address
    /// of the window is answered from the same state the single register
    /// reads use, so a test that sets `space_words` or `req_count` sees it
    /// here as well.
    /// Writes the pairs and then reads the window, in the order the
    /// transport puts them on the wire.
    fn writeRegsRead(
        self: *FakeDevice,
        pairs: []const [2]u32,
        addr: u32,
        words: []u32,
    ) anyerror!void {
        for (pairs) |pair| try self.regWrite(pair[0], pair[1]);
        try self.readRegs(addr, words);
        // The pairs and the read cross the link in ONE transaction.
        self.frames -= pairs.len;
    }

    fn readRegsPop(
        self: *FakeDevice,
        addr: u32,
        pop_addr: u32,
        words: []u32,
    ) anyerror!void {
        self.frames += 1;
        if (addr != sd.REG_STATUS_FIRST or
            pop_addr != sd.REG_REQ_POP or
            words.len != sd.STATUS_WORDS)
        {
            return error.UnexpectedReadRegsPop;
        }
        self.fillStatus(words);
        if (self.req_read + 1 < self.req.len) {
            self.req_read += REQUEST_WORDS;
        }
    }

    fn writeStream(self: *FakeDevice, addr: u32, values: []const u32) anyerror!void {
        // One block is 512 bytes, which the backend sends in one frame.
        self.frames += 1;
        if (addr != sd.REG_DATA_IN) return error.UnexpectedStreamAddress;
        if (self.pushed_len + values.len > self.pushed.len) return error.FakeFifoOverflow;
        // The device throws away a block that no tag names, so a push with
        // no DATA_TAG write in front of it is a fault of the code under
        // test and not something to accept quietly.
        const tag = self.pending_tag orelse return error.UntaggedBlock;
        // A block that answers no record is a FILL and it must carry an
        // address, or the card cannot place it and throws it away.
        if (tag == sd.DATA_TAG_FILL and self.pending_fill == null) {
            return error.UnplacedFill;
        }
        if (self.tags_len == self.tags.len) return error.FakeTagOverflow;
        self.tags[self.tags_len] = tag;
        self.fills[self.tags_len] = self.pending_fill;
        self.tags_len += 1;
        self.pending_tag = null;
        self.pending_fill = null;
        @memcpy(self.pushed[self.pushed_len..][0..values.len], values);
        self.pushed_len += values.len;
    }

    fn writeRegsStreamRegs(
        self: *FakeDevice,
        before: []const [2]u32,
        addr: u32,
        values: []const u32,
        after: []const [2]u32,
    ) anyerror!void {
        for (before) |pair| try self.regWrite(pair[0], pair[1]);
        try self.writeStream(addr, values);
        for (after) |pair| try self.regWrite(pair[0], pair[1]);
        self.frames -= before.len + after.len;
    }

    /// A grouped push with the status read of the next pass behind it.
    ///
    /// It is ONE transaction on the wire, so the frame count grows by one
    /// and not by two.
    fn writeStreamGroupsReadPop(
        self: *FakeDevice,
        groups: []const WriteStreamGroup,
        addr: u32,
        pop_addr: u32,
        words: []u32,
    ) anyerror!void {
        try self.writeStreamGroups(groups);
        try self.readRegsPop(addr, pop_addr, words);
        self.frames -= 1;
    }

    /// A grouped push with the status read of the next pass behind it and
    /// NO pop behind that read. See `Server.pop_owed`.
    fn writeStreamGroupsRead(
        self: *FakeDevice,
        groups: []const WriteStreamGroup,
        addr: u32,
        words: []u32,
    ) anyerror!void {
        try self.writeStreamGroups(groups);
        try self.readRegs(addr, words);
        self.frames -= 1;
    }

    fn writeStreamGroups(
        self: *FakeDevice,
        groups: []const WriteStreamGroup,
    ) anyerror!void {
        for (groups) |group| {
            try self.writeRegsStreamRegs(
                group.before,
                group.addr,
                group.values,
                group.after,
            );
        }
        if (groups.len > 0) self.frames -= groups.len - 1;
    }

    fn device(self: *FakeDevice) Device {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn cast(ptr: *anyopaque) *FakeDevice {
        return @ptrCast(@alignCast(ptr));
    }

    const vtable = Device.VTable{
        .reg_write = struct {
            fn f(p: *anyopaque, a: u32, v: u32) anyerror!void {
                return cast(p).regWrite(a, v);
            }
        }.f,
        .reg_read = struct {
            fn f(p: *anyopaque, a: u32) anyerror!u32 {
                return cast(p).regRead(a);
            }
        }.f,
        .write_regs = struct {
            // A backend may coalesce the pairs into one frame, but it
            // keeps their ORDER, so the fake applies them one at a time
            // and every write reaches the same place it would alone.
            fn f(p: *anyopaque, pairs: []const [2]u32) anyerror!void {
                const self = cast(p);
                for (pairs) |pair| try self.regWrite(pair[0], pair[1]);
                // The pairs went out in ONE frame, so the per-write count
                // above is undone and one frame is counted for the lot.
                self.frames -= pairs.len;
                self.frames += 1;
            }
        }.f,
        .read_regs = struct {
            fn f(p: *anyopaque, a: u32, words: []u32) anyerror!void {
                return cast(p).readRegs(a, words);
            }
        }.f,
        .write_regs_read = struct {
            fn f(
                p: *anyopaque,
                pairs: []const [2]u32,
                a: u32,
                words: []u32,
            ) anyerror!void {
                return cast(p).writeRegsRead(pairs, a, words);
            }
        }.f,
        .read_regs_pop = struct {
            fn f(p: *anyopaque, a: u32, pop: u32, words: []u32) anyerror!void {
                return cast(p).readRegsPop(a, pop, words);
            }
        }.f,
        .write_stream = struct {
            fn f(p: *anyopaque, a: u32, v: []const u32) anyerror!void {
                return cast(p).writeStream(a, v);
            }
        }.f,
        .write_regs_stream_regs = struct {
            fn f(
                p: *anyopaque,
                before: []const [2]u32,
                a: u32,
                v: []const u32,
                after: []const [2]u32,
            ) anyerror!void {
                return cast(p).writeRegsStreamRegs(before, a, v, after);
            }
        }.f,
        .write_stream_groups = struct {
            fn f(p: *anyopaque, groups: []const WriteStreamGroup) anyerror!void {
                return cast(p).writeStreamGroups(groups);
            }
        }.f,
        .read_stream = struct {
            fn f(p: *anyopaque, a: u32, w: []u32) anyerror!void {
                return cast(p).readStream(a, w);
            }
        }.f,
        .write_stream_groups_read_pop = struct {
            fn f(
                p: *anyopaque,
                groups: []const WriteStreamGroup,
                a: u32,
                pop: u32,
                w: []u32,
            ) anyerror!void {
                return cast(p).writeStreamGroupsReadPop(groups, a, pop, w);
            }
        }.f,
        .write_stream_groups_read = struct {
            fn f(
                p: *anyopaque,
                groups: []const WriteStreamGroup,
                a: u32,
                w: []u32,
            ) anyerror!void {
                return cast(p).writeStreamGroupsRead(groups, a, w);
            }
        }.f,
    };

    /// The bytes that the fake was given, decoded back from the words.
    fn pushedBytes(self: *const FakeDevice, buf: []u8) []u8 {
        std.debug.assert(buf.len >= self.pushed_len * 4);
        for (self.pushed[0..self.pushed_len], 0..) |word, i| {
            std.mem.writeInt(u32, buf[i * 4 ..][0..4], word, .little);
        }
        return buf[0 .. self.pushed_len * 4];
    }
};

/// Fills `buf` with a pattern that names its own block and offset, so a
/// block served from the wrong place cannot look right by chance.
fn patternBlock(lba: u64, buf: *[sd.BLOCK_SIZE]u8) void {
    for (buf, 0..) |*b, i| b.* = @truncate(lba *% 31 +% i);
}

/// Makes an image of `blocks` blocks in `dir`, every block holding the
/// pattern of its own address.
fn writePatternImage(dir: Io.Dir, name: []const u8, blocks: u64) !void {
    const io = std.testing.io;
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);
    var block: [sd.BLOCK_SIZE]u8 = undefined;
    var lba: u64 = 0;
    while (lba < blocks) : (lba += 1) {
        patternBlock(lba, &block);
        try file.writePositionalAll(io, &block, lba * sd.BLOCK_SIZE);
    }
}

fn openTestImage(dir: Io.Dir, name: []const u8, blocks: u64, read_only: bool) !Image {
    const io = std.testing.io;
    const mode: Io.File.OpenFlags.Mode = if (read_only) .read_only else .read_write;
    return .{
        .io = io,
        .file = try dir.openFile(io, name, .{ .mode = mode }),
        .blocks = blocks,
        .read_only = read_only,
    };
}

/// The 128 channel words of one block that the card sends to the runtime.
///
/// The first two words hold `head0` and `head1`, and the rest hold `fill`.
/// A test names the bytes it expects by hand, so nothing here is allowed
/// to build them the way `pullBlock` builds them.
fn channelBlock(head0: u32, head1: u32, fill: u32) [BLOCK_WORDS]u32 {
    var words: [BLOCK_WORDS]u32 = @splat(fill);
    words[0] = head0;
    words[1] = head1;
    return words;
}

/// Checks the block at `lba` of the image file on disk: the first bytes
/// against `head`, byte for byte, and every byte after them against `fill`.
fn expectImageBlock(
    dir: Io.Dir,
    name: []const u8,
    lba: u64,
    head: []const u8,
    fill: u8,
) !void {
    const io = std.testing.io;
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    var got: [sd.BLOCK_SIZE]u8 = undefined;
    const read = try file.readPositionalAll(io, &got, lba * sd.BLOCK_SIZE);
    try std.testing.expectEqual(got.len, read);
    try std.testing.expectEqualSlices(u8, head, got[0..head.len]);
    for (got[head.len..]) |byte| try std.testing.expectEqual(fill, byte);
}

/// Checks that the block at `lba` still holds the pattern that
/// `writePatternImage` put there, so a test can prove that a write went
/// nowhere near it.
fn expectImageUntouched(dir: Io.Dir, name: []const u8, lba: u64) !void {
    const io = std.testing.io;
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    var got: [sd.BLOCK_SIZE]u8 = undefined;
    const read = try file.readPositionalAll(io, &got, lba * sd.BLOCK_SIZE);
    try std.testing.expectEqual(got.len, read);
    var want: [sd.BLOCK_SIZE]u8 = undefined;
    patternBlock(lba, &want);
    try std.testing.expectEqualSlices(u8, &want, &got);
}

test "a request record packs the opcode, the tag, the block count and the LBA" {
    const request: Request = .{
        .op = @intFromEnum(RequestOp.read_blocks),
        .blocks = 8,
        .lba = 0xDEADBEEF,
        .seq = 0x5A,
        .epoch = 0xC,
    };
    const words = request.words();
    try std.testing.expectEqual(@as(u32, 0x0008_5AC1), words[0]);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), words[1]);

    const back = decodeRequest(words);
    try std.testing.expectEqual(request.op, back.op);
    try std.testing.expectEqual(request.blocks, back.blocks);
    try std.testing.expectEqual(request.lba, back.lba);
    try std.testing.expectEqual(request.seq, back.seq);
    try std.testing.expectEqual(request.epoch, back.epoch);
}

test "decodeRequest reads the tag byte as neither the opcode nor the count" {
    // Bits 15 to 8 hold the tag. A tag of any value must not change the
    // opcode or the block count that this code sees.
    const request = decodeRequest(.{ 0x0004_FF01, 12 });
    try std.testing.expectEqual(@as(u8, 0x01), request.op);
    try std.testing.expectEqual(@as(u8, 0xFF), request.seq);
    try std.testing.expectEqual(@as(u16, 4), request.blocks);
    try std.testing.expectEqual(@as(u32, 12), request.lba);
}

test "a read of block N serves exactly the 512 bytes at offset N times 512" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 64);
    const image = try openTestImage(tmp.dir, "card.img", 64, false);
    defer image.file.close(std.testing.io);

    const request: Request = .{ .op = 0x01, .blocks = 1, .lba = 37, .seq = 1 };
    var fake: FakeDevice = .{ .req = &request.words(), .req_count = 1 };
    var server: Server = .{ .device = fake.device(), .image = image };

    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try std.testing.expectEqual(@as(usize, BLOCK_WORDS), fake.pushed_len);

    var got: [sd.BLOCK_SIZE]u8 = undefined;
    var want: [sd.BLOCK_SIZE]u8 = undefined;
    patternBlock(37, &want);
    try std.testing.expectEqualSlices(u8, &want, fake.pushedBytes(&got));
    try std.testing.expectEqual(@as(u64, 1), server.stats.blocks);
    try std.testing.expectEqual(@as(u64, 0), server.stats.refused);
}

test "queued requests are served in the order that the device posted them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 64);
    const image = try openTestImage(tmp.dir, "card.img", 64, false);
    defer image.file.close(std.testing.io);

    // Out of address order on purpose: the answer follows the order of the
    // records and not the order of the addresses.
    const order = [_]u32{ 9, 2, 40 };
    var script: [order.len * REQUEST_WORDS]u32 = undefined;
    for (order, 0..) |lba, i| {
        const words = (Request{ .op = 0x01, .blocks = 1, .lba = lba, .seq = 1 }).words();
        script[i * REQUEST_WORDS] = words[0];
        script[i * REQUEST_WORDS + 1] = words[1];
    }
    var fake: FakeDevice = .{ .req = &script, .req_count = order.len };
    var server: Server = .{ .device = fake.device(), .image = image };

    try std.testing.expectEqual(@as(u32, order.len), try server.servePending());

    var got: [order.len * sd.BLOCK_SIZE]u8 = undefined;
    const bytes = fake.pushedBytes(&got);
    try std.testing.expectEqual(order.len * sd.BLOCK_SIZE, bytes.len);
    for (order, 0..) |lba, i| {
        var want: [sd.BLOCK_SIZE]u8 = undefined;
        patternBlock(lba, &want);
        try std.testing.expectEqualSlices(u8, &want, bytes[i * sd.BLOCK_SIZE ..][0..sd.BLOCK_SIZE]);
    }
}

test "a multi block request serves consecutive blocks in one record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 64);
    const image = try openTestImage(tmp.dir, "card.img", 64, false);
    defer image.file.close(std.testing.io);

    const request: Request = .{ .op = 0x01, .blocks = 3, .lba = 10, .seq = 1 };
    var fake: FakeDevice = .{ .req = &request.words(), .req_count = 1 };
    var server: Server = .{ .device = fake.device(), .image = image };

    _ = try server.servePending();
    try std.testing.expectEqual(@as(u64, 3), server.stats.blocks);

    var got: [3 * sd.BLOCK_SIZE]u8 = undefined;
    const bytes = fake.pushedBytes(&got);
    for (0..3) |i| {
        var want: [sd.BLOCK_SIZE]u8 = undefined;
        patternBlock(10 + i, &want);
        try std.testing.expectEqualSlices(u8, &want, bytes[i * sd.BLOCK_SIZE ..][0..sd.BLOCK_SIZE]);
    }
}

test "a read past the end of the image serves no bytes at all" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    // Block 8 is one past the last block, and the second record straddles
    // the end. Neither may give the host any bytes.
    var script: [2 * REQUEST_WORDS]u32 = undefined;
    const past = (Request{ .op = 0x01, .blocks = 1, .lba = 8, .seq = 1 }).words();
    const straddle = (Request{ .op = 0x01, .blocks = 4, .lba = 6, .seq = 1 }).words();
    script[0] = past[0];
    script[1] = past[1];
    script[2] = straddle[0];
    script[3] = straddle[1];

    var fake: FakeDevice = .{ .req = &script, .req_count = 2 };
    var log_buf: [512]u8 = undefined;
    var log: Io.Writer = .fixed(&log_buf);
    var server: Server = .{ .device = fake.device(), .image = image, .log = &log };

    try std.testing.expectEqual(@as(u32, 2), try server.servePending());
    try std.testing.expectEqual(@as(usize, 0), fake.pushed_len);
    try std.testing.expectEqual(@as(u64, 0), server.stats.blocks);
    try std.testing.expectEqual(@as(u64, 2), server.stats.refused);
    try std.testing.expect(std.mem.indexOf(u8, log.buffered(), "ends past block 8") != null);
}

test "the last block of the image is still served" {
    // The boundary the test above rejects must stay reachable from the
    // other side, else the card would lose its last block.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    const request: Request = .{ .op = 0x01, .blocks = 1, .lba = 7, .seq = 1 };
    var fake: FakeDevice = .{ .req = &request.words(), .req_count = 1 };
    var server: Server = .{ .device = fake.device(), .image = image };

    _ = try server.servePending();
    try std.testing.expectEqual(@as(u64, 1), server.stats.blocks);
    var got: [sd.BLOCK_SIZE]u8 = undefined;
    var want: [sd.BLOCK_SIZE]u8 = undefined;
    patternBlock(7, &want);
    try std.testing.expectEqualSlices(u8, &want, fake.pushedBytes(&got));
}

test "an unknown opcode is refused and serves no bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    const request: Request = .{ .op = 0x7E, .blocks = 1, .lba = 0 };
    var fake: FakeDevice = .{ .req = &request.words(), .req_count = 1 };
    var log_buf: [256]u8 = undefined;
    var log: Io.Writer = .fixed(&log_buf);
    var server: Server = .{ .device = fake.device(), .image = image, .log = &log };

    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try std.testing.expectEqual(@as(usize, 0), fake.pushed_len);
    try std.testing.expectEqual(@as(u64, 1), server.stats.refused);
    try std.testing.expect(std.mem.indexOf(u8, log.buffered(), "unknown opcode 0x0E") != null);
}

test "the pop of a record the loop cannot answer rides in front of the next poll" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    // Two records with an opcode the loop refuses. A refused record sends
    // NO block, so the pop it owes cannot ride in front of a push and has
    // to ride in front of the next poll instead.
    const first: Request = .{ .op = 0x7E, .blocks = 1, .lba = 0 };
    const second: Request = .{ .op = 0x7E, .blocks = 1, .lba = 1 };
    const records: [2 * REQUEST_WORDS]u32 = first.words() ++ second.words();
    var log_buf: [256]u8 = undefined;
    var log: Io.Writer = .fixed(&log_buf);
    var fake: FakeDevice = .{ .req = &records, .req_count = 1 };
    var server: Server = .{ .device = fake.device(), .image = image, .log = &log };

    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try std.testing.expect(server.pop_owed);
    try std.testing.expectEqual(@as(usize, 1), fake.frames);

    // ONE frame more, not two. The pop and the window read cross the link
    // in the same transaction, in that order.
    try std.testing.expectEqual(@as(u32, 0), try server.servePending());
    try std.testing.expect(!server.pop_owed);
    try std.testing.expectEqual(@as(usize, 2), fake.frames);
    // The pop went FIRST, so the head stands on the second record.
    try std.testing.expectEqual(@as(usize, REQUEST_WORDS), fake.req_read);
}

test "a request for 0 blocks is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    const request: Request = .{ .op = 0x01, .blocks = 0, .lba = 0, .seq = 1 };
    var fake: FakeDevice = .{ .req = &request.words(), .req_count = 1 };
    var server: Server = .{ .device = fake.device(), .image = image };

    _ = try server.servePending();
    try std.testing.expectEqual(@as(usize, 0), fake.pushed_len);
    try std.testing.expectEqual(@as(u64, 1), server.stats.refused);
}

test "a block count above the limit is refused before any block is read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    const request: Request = .{ .op = 0x01, .blocks = 0xFFFF, .lba = 0, .seq = 1 };
    var fake: FakeDevice = .{ .req = &request.words(), .req_count = 1 };
    var server: Server = .{ .device = fake.device(), .image = image, .options = .{ .max_blocks_per_request = 4 } };

    _ = try server.servePending();
    try std.testing.expectEqual(@as(usize, 0), fake.pushed_len);
    try std.testing.expectEqual(@as(u64, 1), server.stats.refused);
}

test "servePending takes no requests when REQ_COUNT reads 0" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    var fake: FakeDevice = .{ .req_count = 0 };
    var server: Server = .{ .device = fake.device(), .image = image };
    try std.testing.expectEqual(@as(u32, 0), try server.servePending());
    try std.testing.expectEqual(@as(usize, 0), fake.pushed_len);
    try std.testing.expectEqual(@as(u64, 1), server.stats.polls);
}

test "a REQ_COUNT above the limit takes only the limit, so a bad count cannot run away" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    var script: [2 * REQUEST_WORDS]u32 = undefined;
    for (0..2) |i| {
        const words = (Request{ .op = 0x01, .blocks = 1, .lba = @intCast(i), .seq = 1 }).words();
        script[i * REQUEST_WORDS] = words[0];
        script[i * REQUEST_WORDS + 1] = words[1];
    }
    // The device claims a thousand pending records and holds two.
    var fake: FakeDevice = .{ .req = &script, .req_count = 1000 };
    var server: Server = .{ .device = fake.device(), .image = image, .options = .{ .max_requests_per_poll = 2 } };

    try std.testing.expectEqual(@as(u32, 2), try server.servePending());
    try std.testing.expectEqual(@as(u64, 2), server.stats.blocks);
}

test "the FIFO credit is spent before DATA_IN_COUNT is read again" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    // Space for four blocks, and a record that asks for four. The status
    // read of the pass reports the free space, the four blocks then go out
    // in ONE push, and the status read that rides behind that push reports
    // the free space again. NEITHER is a wait: the blocks spend credit the
    // code already held, and `space_polls` counts every read that a block
    // had to wait through.
    const request: Request = .{ .op = 0x01, .blocks = 4, .lba = 0, .seq = 1 };
    var fake: FakeDevice = .{
        .req = &request.words(),
        .req_count = 1,
        .space_words = 4 * BLOCK_WORDS,
    };
    var server: Server = .{ .device = fake.device(), .image = image };

    _ = try server.servePending();
    try std.testing.expectEqual(@as(u64, 4), server.stats.blocks);
    try std.testing.expectEqual(@as(usize, 2), fake.space_reads);
    try std.testing.expectEqual(@as(u64, 0), server.stats.space_polls);
    // Two transactions in all: the status read of the pass and the one
    // push that carries the four blocks and the next status with them.
    try std.testing.expectEqual(@as(u64, 2), server.stats.round_trips);
}

test "a stream record pushes every block under the one tag of the record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 32);
    const image = try openTestImage(tmp.dir, "card.img", 32, false);
    defer image.file.close(std.testing.io);

    // One record for eight blocks is what CMD18 posts. The card counts the
    // blocks of the chunk against ONE sequence tag, so every block of the
    // chunk must carry that tag and no other.
    const request: Request = .{ .op = 0x01, .blocks = 8, .lba = 0, .seq = 7 };
    var fake: FakeDevice = .{ .req = &request.words(), .req_count = 1 };
    var server: Server = .{ .device = fake.device(), .image = image };

    _ = try server.servePending();
    try std.testing.expectEqual(@as(u64, 8), server.stats.blocks);
    try std.testing.expectEqual(@as(usize, 8), fake.tags_len);
    for (fake.tags[0..fake.tags_len]) |tag| {
        try std.testing.expectEqual(@as(u8, 7), tag);
    }
    // One status read of the pass, then one transaction for each batch of
    // the chunk. A record for each block would have cost three
    // transactions per block.
    const pushes = (8 + PUSH_BATCH_BLOCKS - 1) / PUSH_BATCH_BLOCKS;
    try std.testing.expectEqual(@as(u64, 1 + pushes), server.stats.round_trips);
}

test "a stream leaves the host cache model alone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 32);
    const image = try openTestImage(tmp.dir, "card.img", 32, false);
    defer image.file.close(std.testing.io);

    // The card writes no cache line for a block of a stream, so a model
    // that claimed one would skip a fill the card needs.
    const request: Request = .{ .op = 0x01, .blocks = 4, .lba = 0, .seq = 1 };
    var fake: FakeDevice = .{ .req = &request.words(), .req_count = 1 };
    var server: Server = .{ .device = fake.device(), .image = image };
    server.cache.configure(128);

    _ = try server.servePending();
    try std.testing.expectEqual(@as(u64, 4), server.stats.blocks);
    for (0..4) |lba| {
        try std.testing.expect(!server.cache.holds(lba));
    }

    // A SINGLE block record still puts its block in the model, because the
    // card still writes that one into a line.
    const single: Request = .{ .op = 0x01, .blocks = 1, .lba = 9, .seq = 2 };
    var one: FakeDevice = .{ .req = &single.words(), .req_count = 1 };
    var lone: Server = .{ .device = one.device(), .image = image };
    lone.cache.configure(128);
    _ = try lone.servePending();
    try std.testing.expect(lone.cache.holds(9));
}

test "a record that lands mid stream stops the stream and is answered next" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 128);
    const image = try openTestImage(tmp.dir, "card.img", 128, false);
    defer image.file.close(std.testing.io);

    // A chunk of TWO batches that the host stops after the first one. The
    // card answers the next CMD18 with a record of its own, and that
    // record comes back behind the push that carried the first batch. The
    // rest of the chunk must NOT go out: nobody reads it.
    //
    // The chunk is two batches and not a fixed number of blocks, so the
    // test still cuts a chunk in half when `PUSH_BATCH_BLOCKS` changes.
    const chunk: u16 = 2 * PUSH_BATCH_BLOCKS;
    const batch: u64 = PUSH_BATCH_BLOCKS;
    var script: [2 * REQUEST_WORDS]u32 = undefined;
    const first = (Request{ .op = 0x01, .blocks = chunk, .lba = 0, .seq = 1 }).words();
    const second = (Request{ .op = 0x01, .blocks = chunk, .lba = 40, .seq = 2 }).words();
    script[0] = first[0];
    script[1] = first[1];
    script[2] = second[0];
    script[3] = second[1];
    var fake: FakeDevice = .{
        .req = &script,
        .req_count = 1,
        .req_count_later = 1,
    };
    var server: Server = .{ .device = fake.device(), .image = image };

    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try std.testing.expectEqual(batch, server.stats.blocks);
    try std.testing.expectEqual(@as(u64, 1), server.stats.streams_cut);
    try std.testing.expect(server.held != null);
    try std.testing.expectEqual(@as(u32, 40), server.held.?.lba);

    // The held record is already off the card, so the next pass answers it
    // and pays NO status read for it. The script holds no third record, so
    // the whole chunk goes out in two pushes, and each push is one
    // transaction that carries its own status read.
    const before = server.stats.round_trips;
    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try std.testing.expectEqual(batch + 2 * batch, server.stats.blocks);
    try std.testing.expectEqual(@as(u64, 2), server.stats.round_trips - before);
}

test "the next chunk of a stream carries on in place and costs no poll" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 64);
    const image = try openTestImage(tmp.dir, "card.img", 64, false);
    defer image.file.close(std.testing.io);

    // The card asks for a stream one CHUNK at a time. It posts the record
    // for the next chunk when the last block of this one has gone off the
    // channel, and that record starts exactly where this chunk ends. The
    // loop must answer it in place, under the tag the NEW record carries.
    var script: [2 * REQUEST_WORDS]u32 = undefined;
    const first = (Request{ .op = 0x01, .blocks = 4, .lba = 0, .seq = 1 }).words();
    const next = (Request{ .op = 0x01, .blocks = 4, .lba = 4, .seq = 2 }).words();
    script[0] = first[0];
    script[1] = first[1];
    script[2] = next[0];
    script[3] = next[1];
    var fake: FakeDevice = .{
        .req = &script,
        .req_count = 1,
        .req_count_later = 1,
    };
    var server: Server = .{ .device = fake.device(), .image = image };

    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    // Both chunks went out in ONE call, so nothing was cut.
    try std.testing.expectEqual(@as(u64, 8), server.stats.blocks);
    try std.testing.expectEqual(@as(u64, 1), server.stats.streams_continued);
    try std.testing.expectEqual(@as(u64, 0), server.stats.streams_cut);
    try std.testing.expect(server.held == null);
    // Two records, and the loop counted both.
    try std.testing.expectEqual(@as(u64, 2), server.stats.requests);
    try std.testing.expectEqual(@as(u64, 0), server.stats.records_lost);

    // The blocks of each chunk carry the tag of the record that asked for
    // them. A block of the second chunk under the first tag would be
    // thrown away by the card and the host would wait out the timeout.
    try std.testing.expectEqual(@as(usize, 8), fake.tags_len);
    for (fake.tags[0..4]) |tag| try std.testing.expectEqual(@as(u8, 1), tag);
    for (fake.tags[4..8]) |tag| try std.testing.expectEqual(@as(u8, 2), tag);
}

test "a record that starts elsewhere still cuts the stream, even at a chunk end" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 64);
    const image = try openTestImage(tmp.dir, "card.img", 64, false);
    defer image.file.close(std.testing.io);

    // A CMD12 abort and a new read can land exactly when a chunk runs out.
    // The record then names another block, which is what tells the two
    // apart, so this one is held and answered as a request of its own.
    var script: [2 * REQUEST_WORDS]u32 = undefined;
    const first = (Request{ .op = 0x01, .blocks = 4, .lba = 0, .seq = 1 }).words();
    const other = (Request{ .op = 0x01, .blocks = 4, .lba = 40, .seq = 2 }).words();
    script[0] = first[0];
    script[1] = first[1];
    script[2] = other[0];
    script[3] = other[1];
    var fake: FakeDevice = .{
        .req = &script,
        .req_count = 1,
        .req_count_later = 1,
    };
    var server: Server = .{ .device = fake.device(), .image = image };

    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try std.testing.expectEqual(@as(u64, 4), server.stats.blocks);
    try std.testing.expectEqual(@as(u64, 0), server.stats.streams_continued);
    try std.testing.expectEqual(@as(u64, 1), server.stats.streams_cut);
    try std.testing.expect(server.held != null);
    try std.testing.expectEqual(@as(u32, 40), server.held.?.lba);
}

test "a single block record at the chunk end is held and not carried on" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 64);
    const image = try openTestImage(tmp.dir, "card.img", 64, false);
    defer image.file.close(std.testing.io);

    // A CMD17 asks for ONE block and is never the next chunk of a stream.
    // The card reads such a block through its cache, so answering it
    // inside the stream loop would write no cache line for it.
    var script: [2 * REQUEST_WORDS]u32 = undefined;
    const first = (Request{ .op = 0x01, .blocks = 4, .lba = 0, .seq = 1 }).words();
    const single = (Request{ .op = 0x01, .blocks = 1, .lba = 4, .seq = 2 }).words();
    script[0] = first[0];
    script[1] = first[1];
    script[2] = single[0];
    script[3] = single[1];
    var fake: FakeDevice = .{
        .req = &script,
        .req_count = 1,
        .req_count_later = 1,
    };
    var server: Server = .{ .device = fake.device(), .image = image };
    server.cache.configure(128);

    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try std.testing.expectEqual(@as(u64, 4), server.stats.blocks);
    try std.testing.expectEqual(@as(u64, 0), server.stats.streams_continued);
    try std.testing.expectEqual(@as(u64, 1), server.stats.streams_cut);
    try std.testing.expect(server.held != null);
    try std.testing.expectEqual(@as(u32, 4), server.held.?.lba);
    // The stream wrote no line, so the model still holds nothing.
    try std.testing.expect(!server.cache.holds(0));
}

test "a poll of an empty request channel writes no pop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 16);
    const image = try openTestImage(tmp.dir, "card.img", 16, false);
    defer image.file.close(std.testing.io);

    // The pop used to ride behind the status read. It took the record at
    // the head away whether the read had seen one or not, so a record the
    // card posted in the microseconds between the two went away unseen and
    // the card waited out its whole read timeout. The fake refuses a pop
    // of an empty channel, so a pop here fails this test.
    var fake: FakeDevice = .{ .req = &.{}, .req_count = 0 };
    var server: Server = .{ .device = fake.device(), .image = image };

    try std.testing.expectEqual(@as(u32, 0), try server.servePending());
    try std.testing.expectEqual(@as(u32, 0), try server.servePending());
    // Two reads and nothing else.
    try std.testing.expectEqual(@as(usize, 2), fake.frames);
    try std.testing.expect(!server.pop_owed);
}

test "the pop of a record rides in front of the blocks that answer it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 16);
    const image = try openTestImage(tmp.dir, "card.img", 16, false);
    defer image.file.close(std.testing.io);

    // One record, one push of one block. The pop costs no round trip of
    // its own: it travels in the same transaction as the block.
    const request: Request = .{ .op = 0x01, .blocks = 1, .lba = 3, .seq = 5 };
    var fake: FakeDevice = .{ .req = &request.words(), .req_count = 1 };
    var server: Server = .{ .device = fake.device(), .image = image };

    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try std.testing.expect(!server.pop_owed);
    // One status read and one push. The pop is inside the push.
    try std.testing.expectEqual(@as(u64, 2), server.stats.round_trips);
}

test "a stream that finds no room stops when the card takes a new read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 64);
    const image = try openTestImage(tmp.dir, "card.img", 64, false);
    defer image.file.close(std.testing.io);

    // The channel holds no room at all. The card is therefore not taking
    // the blocks of this chunk, and the poll that asks for room finds the
    // record of the read that replaced it. NOTHING of the chunk goes out.
    var script: [2 * REQUEST_WORDS]u32 = undefined;
    const first = (Request{ .op = 0x01, .blocks = 16, .lba = 0, .seq = 1 }).words();
    const second = (Request{ .op = 0x01, .blocks = 8, .lba = 40, .seq = 2 }).words();
    script[0] = first[0];
    script[1] = first[1];
    script[2] = second[0];
    script[3] = second[1];
    var fake: FakeDevice = .{
        .req = &script,
        .req_count = 1,
        .req_count_later = 1,
        .space_words = 0,
    };
    var server: Server = .{ .device = fake.device(), .image = image };

    _ = try server.servePending();
    try std.testing.expectEqual(@as(u64, 0), server.stats.blocks);
    try std.testing.expectEqual(@as(usize, 0), fake.pushed_len);
    try std.testing.expectEqual(@as(u64, 1), server.stats.streams_cut);
    try std.testing.expect(server.held != null);
    try std.testing.expectEqual(@as(u32, 40), server.held.?.lba);
}

test "a stream whose card stops draining is dropped and counted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 64);
    const image = try openTestImage(tmp.dir, "card.img", 64, false);
    defer image.file.close(std.testing.io);

    // No room and NO new record. The rest of the chunk is speculative, so
    // it is dropped and counted and the loop goes on. A serve that ended
    // here would end the boot over blocks that nobody asked for.
    const request: Request = .{ .op = 0x01, .blocks = 16, .lba = 0, .seq = 1 };
    var fake: FakeDevice = .{
        .req = &request.words(),
        .req_count = 1,
        .space_words = 0,
    };
    var server: Server = .{
        .device = fake.device(),
        .image = image,
        .options = .{ .space_poll_limit = 8 },
    };

    _ = try server.servePending();
    try std.testing.expectEqual(@as(usize, 0), fake.pushed_len);
    try std.testing.expectEqual(@as(u64, 1), server.stats.streams_stalled);
    try std.testing.expect(server.held == null);
    // The poll limit was reached and every poll of it is counted, so a
    // stall is never silent.
    try std.testing.expectEqual(@as(u64, 8), server.stats.space_polls);
}

test "a DATA_IN FIFO that never drains fails instead of blocking forever" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    const request: Request = .{ .op = 0x01, .blocks = 1, .lba = 0, .seq = 1 };
    var fake: FakeDevice = .{ .req = &request.words(), .req_count = 1, .space_words = 0 };
    var server: Server = .{ .device = fake.device(), .image = image, .options = .{ .space_poll_limit = 8 } };

    try std.testing.expectError(Error.DataInFull, server.servePending());
    // The status read of the pass reports the free space as well, so the
    // eight reads of the poll limit follow one that the pass already made.
    try std.testing.expectEqual(@as(usize, 9), fake.space_reads);
    try std.testing.expectEqual(@as(usize, 0), fake.pushed_len);
}

test "a read only image serves blocks and its bytes never change" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, true);
    defer image.file.close(std.testing.io);

    const request: Request = .{ .op = 0x01, .blocks = 8, .lba = 0, .seq = 1 };
    var fake: FakeDevice = .{ .req = &request.words(), .req_count = 1 };
    var server: Server = .{ .device = fake.device(), .image = image };
    _ = try server.servePending();
    try std.testing.expectEqual(@as(u64, 8), server.stats.blocks);

    // Read the whole file back through a second handle. A serve loop that
    // wrote anything would show here.
    const check = try tmp.dir.openFile(std.testing.io, "card.img", .{});
    defer check.close(std.testing.io);
    var got: [8 * sd.BLOCK_SIZE]u8 = undefined;
    try std.testing.expectEqual(got.len, try check.readPositionalAll(std.testing.io, &got, 0));
    var want: [8 * sd.BLOCK_SIZE]u8 = undefined;
    for (0..8) |i| patternBlock(i, want[i * sd.BLOCK_SIZE ..][0..sd.BLOCK_SIZE]);
    try std.testing.expectEqualSlices(u8, &want, &got);
}

test "enable sets the read only bit for a read only image and keeps the other bits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, true);
    defer image.file.close(std.testing.io);

    var fake: FakeDevice = .{ .ctrl = sd.CTRL_TEST_PATTERN };
    var server: Server = .{ .device = fake.device(), .image = image };
    try server.enable();
    try std.testing.expectEqual(
        sd.CTRL_TEST_PATTERN | sd.CTRL_ENABLE | sd.CTRL_READ_ONLY,
        fake.ctrl,
    );
}

test "disable clears only the enable bit, so the card stops on a clean exit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    var fake: FakeDevice = .{ .ctrl = sd.CTRL_ENABLE | sd.CTRL_CACHE_BYPASS };
    var server: Server = .{ .device = fake.device(), .image = image };
    try server.disable();
    try std.testing.expectEqual(sd.CTRL_CACHE_BYPASS, fake.ctrl);
}

test "publishCapacity writes the block count of the image to NUM_BLOCKS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    var image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);
    image.blocks = 3_309_568;

    var fake: FakeDevice = .{};
    var server: Server = .{ .device = fake.device(), .image = image };
    try server.publishCapacity();
    try std.testing.expectEqual(@as(u32, 3_309_568), fake.num_blocks);
}

test "publishCapacity refuses a block count that NUM_BLOCKS cannot hold" {
    // NUM_BLOCKS is 32 bits, and a version 2.0 CSD reports up to 2^32
    // blocks, so the largest card the CSD can describe is one block above
    // what the register holds.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    var image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);
    image.blocks = sd.CSD_MAX_CAPACITY_BLOCKS;

    var fake: FakeDevice = .{};
    var server: Server = .{ .device = fake.device(), .image = image };
    try std.testing.expectError(Error.NumBlocksTooLarge, server.publishCapacity());
}

test "readBlock refuses a block above the reported capacity even when the file holds it" {
    // The image on disk is larger than the capacity that the card reports,
    // which is what the rounding of the CSD leaves behind. Those blocks are
    // unreachable and must stay unreachable.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 16);
    const image = try openTestImage(tmp.dir, "card.img", 10, false);
    defer image.file.close(std.testing.io);

    var block: [sd.BLOCK_SIZE]u8 = undefined;
    try image.readBlock(9, &block);
    try std.testing.expectError(Error.BlockOutOfRange, image.readBlock(10, &block));
}

test "readBlock reports a short read when the image shrank under the runtime" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 4);
    // The capacity says four blocks, but the file now holds three and a
    // half. The last read must fail and not give back a part block.
    {
        const file = try tmp.dir.openFile(std.testing.io, "card.img", .{ .mode = .read_write });
        defer file.close(std.testing.io);
        try file.setLength(std.testing.io, 3 * sd.BLOCK_SIZE + 100);
    }
    const image = try openTestImage(tmp.dir, "card.img", 4, false);
    defer image.file.close(std.testing.io);

    var block: [sd.BLOCK_SIZE]u8 = undefined;
    try image.readBlock(2, &block);
    try std.testing.expectError(Error.ShortImageRead, image.readBlock(3, &block));
}

// The regression tests of the two Critical faults that the read path
// review found.

test "no read of any address between the two record reads changes anything" {
    // Critical 2. The two words of a record used to come from ONE address,
    // and the device moved a half pointer that any other access cleared.
    // A `mimic-cli info` beside `serve` therefore made this code read word
    // 0 twice and serve the block address 0x00010001 for every read after
    // it, forever, because the record never popped.
    //
    // No read of the map has a side effect now, so this holds by
    // CONSTRUCTION and not by an order that a reader must keep. The test
    // reads every address that the old map made dangerous, REQ_HI itself
    // among them, in the middle of the record.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 64);
    const image = try openTestImage(tmp.dir, "card.img", 64, false);
    defer image.file.close(std.testing.io);

    const request: Request = .{ .op = 0x01, .blocks = 1, .lba = 41, .seq = 7 };
    var fake: FakeDevice = .{ .req = &request.words(), .req_count = 1 };
    var server: Server = .{ .device = fake.device(), .image = image };

    // Word 0 read on its own, then foreign reads, REQ_HI among them, and
    // then the record taken the way the serve loop takes it. The record
    // must be whole.
    try std.testing.expectEqual(request.words()[0], try fake.regRead(sd.REG_REQ));
    _ = try fake.regRead(sd.REG_ID);
    try std.testing.expectEqual(request.words()[1], try fake.regRead(sd.REG_REQ_HI));
    try std.testing.expectEqual(request.words()[1], try fake.regRead(sd.REG_REQ_HI));
    try std.testing.expectEqual(request.words()[0], try fake.regRead(sd.REG_REQ));
    // A write of REQ_POP with the bit clear is a no-op as well.
    try fake.regWrite(sd.REG_REQ_POP, 0);
    try std.testing.expectEqual(@as(usize, 0), fake.req_read);

    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try std.testing.expectEqual(@as(u64, 1), server.stats.blocks);
    try std.testing.expectEqual(@as(u64, 0), server.stats.refused);

    var got: [sd.BLOCK_SIZE]u8 = undefined;
    var want: [sd.BLOCK_SIZE]u8 = undefined;
    patternBlock(41, &want);
    try std.testing.expectEqualSlices(u8, &want, fake.pushedBytes(&got));

    // The record popped EXACTLY once: the script holds one record and the
    // whole script is spent.
    try std.testing.expectEqual(request.words().len, fake.req_read);
}

test "every block goes out under the tag of the record it answers" {
    // Critical 1. The data channel carried no tag, so a block that this
    // code sent after the device gave up was framed and sent to the host
    // as the answer to the NEXT read, with a good CRC16 on it.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 64);
    const image = try openTestImage(tmp.dir, "card.img", 64, false);
    defer image.file.close(std.testing.io);

    // Two records with tags of their own, the second asking for 3 blocks.
    const one = (Request{ .op = 0x01, .blocks = 1, .lba = 5, .seq = 200 }).words();
    const two = (Request{ .op = 0x01, .blocks = 3, .lba = 20, .seq = 201 }).words();
    const script = [_]u32{ one[0], one[1], two[0], two[1] };
    var fake: FakeDevice = .{ .req = &script, .req_count = 2 };
    var server: Server = .{ .device = fake.device(), .image = image };

    try std.testing.expectEqual(@as(u32, 2), try server.servePending());
    try std.testing.expectEqual(@as(u64, 4), server.stats.blocks);

    // One tag per block, and every block of a record carries the tag of
    // that record.
    try std.testing.expectEqual(@as(usize, 4), fake.tags_len);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 200, 201, 201, 201 },
        fake.tags[0..fake.tags_len],
    );
}

test "a refused record pushes no block and writes no tag" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    const request: Request = .{ .op = 0x01, .blocks = 1, .lba = 99, .seq = 3 };
    var fake: FakeDevice = .{ .req = &request.words(), .req_count = 1 };
    var server: Server = .{ .device = fake.device(), .image = image };

    _ = try server.servePending();
    try std.testing.expectEqual(@as(u64, 1), server.stats.refused);
    try std.testing.expectEqual(@as(usize, 0), fake.pushed_len);
    try std.testing.expectEqual(@as(usize, 0), fake.tags_len);
    try std.testing.expectEqual(@as(?u8, null), fake.pending_tag);
}

// The write path. Every test drives the whole record: the runtime takes
// the 128 words off the channel, keeps or drops the block, and retires the
// record with WRITE_ACK.

test "a write_blocks record takes 128 words off the channel and writes those bytes at the LBA" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    const channel = channelBlock(0x4433_2211, 0x8877_6655, 0xA5A5_A5A5);
    const request: Request = .{ .op = 0x02, .blocks = 1, .lba = 3, .seq = 0x5A };
    var fake: FakeDevice = .{
        .req = &request.words(),
        .req_count = 1,
        .data_out = &channel,
    };
    var server: Server = .{ .device = fake.device(), .image = image };

    try std.testing.expectEqual(@as(u32, 1), try server.servePending());

    // One read and one pop for every word of the block. The read takes
    // nothing away, so a runtime that popped on the read would show a pop
    // count of 0 here.
    try std.testing.expectEqual(BLOCK_WORDS, fake.data_out_reads);
    try std.testing.expectEqual(BLOCK_WORDS, fake.data_out_pops);
    try std.testing.expectEqual(channel.len, fake.data_out_head);

    // Byte 0 of the block is bits 7 to 0 of the FIRST word. The bytes
    // below are written out by hand and not built the way pullBlock builds
    // them, so a byte order fault cannot hide in a shared expression.
    const head = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    try expectImageBlock(tmp.dir, "card.img", 3, &head, 0xA5);
    // The blocks on both sides of it never moved.
    try expectImageUntouched(tmp.dir, "card.img", 2);
    try expectImageUntouched(tmp.dir, "card.img", 4);

    try std.testing.expectEqual(@as(u64, 1), server.stats.written);
    try std.testing.expectEqual(@as(u64, 0), server.stats.dropped);
    try std.testing.expectEqual(@as(u64, 0), server.stats.refused);
}

test "the acknowledgement of a written block carries the tag of the record and no fail bit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    const channel = channelBlock(0x0000_0001, 0x0000_0002, 0);
    const request: Request = .{ .op = 0x02, .blocks = 1, .lba = 1, .seq = 0xC7 };
    var fake: FakeDevice = .{
        .req = &request.words(),
        .req_count = 1,
        .data_out = &channel,
    };
    var server: Server = .{ .device = fake.device(), .image = image };

    _ = try server.servePending();
    try std.testing.expectEqual(@as(usize, 1), fake.acks_len);
    try std.testing.expectEqual(@as(u32, 0xC7), fake.acks[0]);
    try std.testing.expectEqual(@as(u32, 0), fake.acks[0] & sd.WRITE_ACK_FAIL);
}

test "a read only image takes the whole block, writes nothing, and fails the acknowledgement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, true);
    defer image.file.close(std.testing.io);

    const channel = channelBlock(0xDEAD_BEEF, 0xFEED_FACE, 0xFFFF_FFFF);
    const request: Request = .{ .op = 0x02, .blocks = 1, .lba = 3, .seq = 0x11 };
    var fake: FakeDevice = .{
        .req = &request.words(),
        .req_count = 1,
        .data_out = &channel,
    };
    var log_buf: [256]u8 = undefined;
    var log: Io.Writer = .fixed(&log_buf);
    var server: Server = .{ .device = fake.device(), .image = image, .log = &log };

    _ = try server.servePending();

    // The channel is empty even though the block went nowhere. A record
    // that left its words behind would put every later write on the wrong
    // block.
    try std.testing.expectEqual(BLOCK_WORDS, fake.data_out_pops);
    try std.testing.expectEqual(channel.len, fake.data_out_head);

    try expectImageUntouched(tmp.dir, "card.img", 3);
    try std.testing.expectEqual(@as(u64, 0), server.stats.written);
    try std.testing.expectEqual(@as(u64, 1), server.stats.dropped);
    try std.testing.expectEqual(@as(u64, 1), server.stats.refused);
    try std.testing.expect(std.mem.indexOf(u8, log.buffered(), "read only image") != null);

    // The host must learn that the block is not safe, so the tag comes
    // back with the fail bit on it.
    try std.testing.expectEqual(@as(usize, 1), fake.acks_len);
    try std.testing.expectEqual(sd.WRITE_ACK_FAIL | 0x11, fake.acks[0]);
}

test "a write_discard record takes the whole block and writes nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    const channel = channelBlock(0x1234_5678, 0x9ABC_DEF0, 0x0F0F_0F0F);
    const request: Request = .{ .op = 0x03, .blocks = 1, .lba = 5, .seq = 0x22 };
    var fake: FakeDevice = .{
        .req = &request.words(),
        .req_count = 1,
        .data_out = &channel,
    };
    var log_buf: [256]u8 = undefined;
    var log: Io.Writer = .fixed(&log_buf);
    var server: Server = .{ .device = fake.device(), .image = image, .log = &log };

    _ = try server.servePending();

    try std.testing.expectEqual(BLOCK_WORDS, fake.data_out_pops);
    try expectImageUntouched(tmp.dir, "card.img", 5);
    try std.testing.expectEqual(@as(u64, 0), server.stats.written);
    try std.testing.expectEqual(@as(u64, 1), server.stats.dropped);
    try std.testing.expect(std.mem.indexOf(u8, log.buffered(), "bad CRC16") != null);

    // Nothing failed on the runtime side, so the fail bit stays clear.
    try std.testing.expectEqual(@as(usize, 1), fake.acks_len);
    try std.testing.expectEqual(@as(u32, 0x22), fake.acks[0]);
}

test "a write past the end of the image takes the block and fails the acknowledgement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    // The file holds eight blocks and the card reports four, which is what
    // the rounding of the CSD leaves behind. Block 4 is unreachable and it
    // must stay unreachable.
    const image = try openTestImage(tmp.dir, "card.img", 4, false);
    defer image.file.close(std.testing.io);

    const channel = channelBlock(0xAAAA_AAAA, 0xBBBB_BBBB, 0xCCCC_CCCC);
    const request: Request = .{ .op = 0x02, .blocks = 1, .lba = 4, .seq = 0x33 };
    var fake: FakeDevice = .{
        .req = &request.words(),
        .req_count = 1,
        .data_out = &channel,
    };
    var server: Server = .{ .device = fake.device(), .image = image };

    _ = try server.servePending();

    try std.testing.expectEqual(BLOCK_WORDS, fake.data_out_pops);
    try expectImageUntouched(tmp.dir, "card.img", 4);
    try std.testing.expectEqual(@as(u64, 0), server.stats.written);
    try std.testing.expectEqual(sd.WRITE_ACK_FAIL | 0x33, fake.acks[0]);
}

test "two write records in one pass leave no state behind" {
    // The whole sequence runs twice. A runtime that kept a channel index,
    // a block buffer, or a tag from the first record would put the second
    // block in the wrong place or retire it under the wrong tag.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    const first = (Request{ .op = 0x02, .blocks = 1, .lba = 2, .seq = 0x41 }).words();
    const second = (Request{ .op = 0x02, .blocks = 1, .lba = 6, .seq = 0x42 }).words();
    const script = [_]u32{ first[0], first[1], second[0], second[1] };

    var channel: [2 * BLOCK_WORDS]u32 = undefined;
    channel[0..BLOCK_WORDS].* = channelBlock(0x4433_2211, 0x8877_6655, 0xA5A5_A5A5);
    channel[BLOCK_WORDS..].* = channelBlock(0xDDCC_BBAA, 0x11FF_EE00, 0x5A5A_5A5A);

    var fake: FakeDevice = .{ .req = &script, .req_count = 2, .data_out = &channel };
    var server: Server = .{ .device = fake.device(), .image = image };

    try std.testing.expectEqual(@as(u32, 2), try server.servePending());

    try std.testing.expectEqual(@as(usize, 2 * BLOCK_WORDS), fake.data_out_pops);
    try std.testing.expectEqual(channel.len, fake.data_out_head);

    const head_one = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    const head_two = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0x00, 0xEE, 0xFF, 0x11 };
    try expectImageBlock(tmp.dir, "card.img", 2, &head_one, 0xA5);
    try expectImageBlock(tmp.dir, "card.img", 6, &head_two, 0x5A);
    try expectImageUntouched(tmp.dir, "card.img", 3);

    try std.testing.expectEqual(@as(u64, 2), server.stats.written);
    try std.testing.expectEqual(@as(u64, 0), server.stats.refused);
    try std.testing.expectEqual(@as(usize, 2), fake.acks_len);
    try std.testing.expectEqualSlices(
        u32,
        &[_]u32{ 0x41, 0x42 },
        fake.acks[0..fake.acks_len],
    );
}

test "an unknown opcode leaves the write data channel in step with the records" {
    // The record pops and the channel does not, so the write record behind
    // the unknown one still gets the first block of the channel.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    const unknown = (Request{ .op = 0x7E, .blocks = 1, .lba = 0, .seq = 0x50 }).words();
    const write = (Request{ .op = 0x02, .blocks = 1, .lba = 7, .seq = 0x51 }).words();
    const script = [_]u32{ unknown[0], unknown[1], write[0], write[1] };
    const channel = channelBlock(0x4433_2211, 0x8877_6655, 0xA5A5_A5A5);

    var fake: FakeDevice = .{ .req = &script, .req_count = 2, .data_out = &channel };
    var server: Server = .{ .device = fake.device(), .image = image };

    try std.testing.expectEqual(@as(u32, 2), try server.servePending());

    const head = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    try expectImageBlock(tmp.dir, "card.img", 7, &head, 0xA5);
    try std.testing.expectEqual(BLOCK_WORDS, fake.data_out_pops);
    // The unknown record is not a write, so it retires no tag.
    try std.testing.expectEqual(@as(usize, 1), fake.acks_len);
    try std.testing.expectEqual(@as(u32, 0x51), fake.acks[0]);
}

test "writeBlock refuses a read only image and a block above the reported capacity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 16);
    const read_only = try openTestImage(tmp.dir, "card.img", 10, true);
    defer read_only.file.close(std.testing.io);
    const writable = try openTestImage(tmp.dir, "card.img", 10, false);
    defer writable.file.close(std.testing.io);

    var block: [sd.BLOCK_SIZE]u8 = @splat(0xEE);
    try std.testing.expectError(Error.ImageReadOnly, read_only.writeBlock(0, &block));
    // The file holds 16 blocks and the card reports 10, so block 10 is
    // real on disk and unreachable through the card.
    try std.testing.expectError(Error.BlockOutOfRange, writable.writeBlock(10, &block));
    try expectImageUntouched(tmp.dir, "card.img", 0);
    try expectImageUntouched(tmp.dir, "card.img", 10);

    try writable.writeBlock(9, &block);
    var got: [sd.BLOCK_SIZE]u8 = undefined;
    try std.testing.expectEqual(got.len, try writable.file.readPositionalAll(
        std.testing.io,
        &got,
        9 * sd.BLOCK_SIZE,
    ));
    try std.testing.expectEqualSlices(u8, &block, &got);
}

// The wait for a whole block. An empty channel reads 0, so a pull that does
// not wait writes 512 zero bytes over a block of the image and reports
// nothing wrong.

test "a write waits for the whole block instead of reading an empty channel" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    const channel = channelBlock(0x4433_2211, 0x8877_6655, 0xA5A5_A5A5);
    const request: Request = .{ .op = 0x02, .blocks = 1, .lba = 3, .seq = 0x22 };
    var fake: FakeDevice = .{
        .req = &request.words(),
        .req_count = 1,
        .data_out = &channel,
        // The block is still arriving on DAT for the first three polls.
        .data_out_late_polls = 3,
    };
    var server: Server = .{ .device = fake.device(), .image = image };

    try std.testing.expectEqual(@as(u32, 1), try server.servePending());

    // Three polls read 0 and the fourth read the whole block.
    try std.testing.expectEqual(@as(usize, 4), fake.data_out_count_reads);
    const head = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    try expectImageBlock(tmp.dir, "card.img", 3, &head, 0xA5);
    try std.testing.expectEqual(@as(u64, 1), server.stats.written);
}

test "a write channel that never fills fails loudly and writes no zeros" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    // The record says a block is there and the channel holds nothing.
    const request: Request = .{ .op = 0x02, .blocks = 1, .lba = 3, .seq = 0x33 };
    var fake: FakeDevice = .{ .req = &request.words(), .req_count = 1 };
    var server: Server = .{
        .device = fake.device(),
        .image = image,
        .options = .{ .block_poll_limit = 8 },
    };

    try std.testing.expectError(Error.DataOutShort, server.servePending());
    try std.testing.expectEqual(@as(usize, 8), fake.data_out_count_reads);
    // No word was read, no acknowledgement went out, and the block of the
    // image still holds what it held.
    try std.testing.expectEqual(@as(usize, 0), fake.data_out_reads);
    try std.testing.expectEqual(@as(usize, 0), fake.acks_len);
    try expectImageUntouched(tmp.dir, "card.img", 3);
    try std.testing.expectEqual(@as(u64, 0), server.stats.written);
}

// The checks of a write record. A write record comes from the device the
// same way a read record does, so every field of it is checked.

test "a write record that ends past the image takes the block and fails the acknowledgement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 4, false);
    defer image.file.close(std.testing.io);

    const channel = channelBlock(0xDEAD_BEEF, 0xFEED_FACE, 0x5A5A_5A5A);
    // Block 4 is real on disk and outside what the card reports.
    const request: Request = .{ .op = 0x02, .blocks = 1, .lba = 4, .seq = 0x44 };
    var fake: FakeDevice = .{
        .req = &request.words(),
        .req_count = 1,
        .data_out = &channel,
    };
    var log_buf: [256]u8 = undefined;
    var log: Io.Writer = .fixed(&log_buf);
    var server: Server = .{ .device = fake.device(), .image = image, .log = &log };

    _ = try server.servePending();

    // The channel is empty even though nothing was written. A record that
    // left its words behind would put every later write on the wrong block.
    try std.testing.expectEqual(BLOCK_WORDS, fake.data_out_pops);
    try expectImageUntouched(tmp.dir, "card.img", 4);
    try std.testing.expectEqual(@as(u64, 1), server.stats.refused);
    try std.testing.expectEqual(@as(u64, 1), server.stats.dropped);
    try std.testing.expectEqual(@as(u64, 0), server.stats.written);
    try std.testing.expectEqual(@as(usize, 1), fake.acks_len);
    try std.testing.expectEqual(@as(u32, 0x44), fake.acks[0] & sd.WRITE_ACK_TAG_MASK);
    try std.testing.expect(fake.acks[0] & sd.WRITE_ACK_FAIL != 0);
    try std.testing.expect(std.mem.indexOf(u8, log.buffered(), "ends past block 4") != null);
}

test "a write record of 0 blocks is refused and still empties the channel" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    const channel = channelBlock(1, 2, 3);
    const request: Request = .{ .op = 0x02, .blocks = 0, .lba = 2, .seq = 0x55 };
    var fake: FakeDevice = .{
        .req = &request.words(),
        .req_count = 1,
        .data_out = &channel,
    };
    var log_buf: [256]u8 = undefined;
    var log: Io.Writer = .fixed(&log_buf);
    var server: Server = .{ .device = fake.device(), .image = image, .log = &log };

    _ = try server.servePending();

    try std.testing.expectEqual(BLOCK_WORDS, fake.data_out_pops);
    try expectImageUntouched(tmp.dir, "card.img", 2);
    try std.testing.expectEqual(@as(u64, 1), server.stats.refused);
    try std.testing.expectEqual(@as(usize, 1), fake.acks_len);
    try std.testing.expect(fake.acks[0] & sd.WRITE_ACK_FAIL != 0);
    try std.testing.expect(std.mem.indexOf(u8, log.buffered(), "write of 0 blocks") != null);
}

test "a write record above the block limit is refused and still empties the channel" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    const channel = channelBlock(1, 2, 3);
    const request: Request = .{ .op = 0x02, .blocks = 4, .lba = 0, .seq = 0x66 };
    var fake: FakeDevice = .{
        .req = &request.words(),
        .req_count = 1,
        .data_out = &channel,
    };
    var log_buf: [256]u8 = undefined;
    var log: Io.Writer = .fixed(&log_buf);
    var server: Server = .{
        .device = fake.device(),
        .image = image,
        .options = .{ .max_blocks_per_request = 1 },
        .log = &log,
    };

    _ = try server.servePending();

    try std.testing.expectEqual(BLOCK_WORDS, fake.data_out_pops);
    try expectImageUntouched(tmp.dir, "card.img", 0);
    try std.testing.expectEqual(@as(u64, 1), server.stats.refused);
    try std.testing.expect(fake.acks[0] & sd.WRITE_ACK_FAIL != 0);
    try std.testing.expect(std.mem.indexOf(u8, log.buffered(), "above the limit of 1") != null);
}

// The startup resync. An earlier run that stopped between the block and the
// acknowledgement leaves both the block and the count of it behind, and the
// card refuses every write until somebody clears them.

test "resyncWriteChannel drops what an earlier run left and retires one block" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    const channel = channelBlock(0x1111_1111, 0x2222_2222, 0x3333_3333);
    var fake: FakeDevice = .{ .data_out = &channel };
    var server: Server = .{ .device = fake.device(), .image = image };

    try std.testing.expectEqual(@as(u32, BLOCK_WORDS), try server.resyncWriteChannel());
    try std.testing.expectEqual(BLOCK_WORDS, fake.data_out_pops);
    try std.testing.expectEqual(channel.len, fake.data_out_head);

    // ONE acknowledgement, with a tag that is not 0 and with the fail bit.
    // A tag of 0 names no record, and the card ignores a write of it.
    try std.testing.expectEqual(@as(usize, 1), fake.acks_len);
    try std.testing.expect(fake.acks[0] & sd.WRITE_ACK_TAG_MASK != 0);
    try std.testing.expect(fake.acks[0] & sd.WRITE_ACK_FAIL != 0);
}

test "resyncWriteChannel on an empty channel writes nothing at all" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    var fake: FakeDevice = .{};
    var server: Server = .{ .device = fake.device(), .image = image };

    try std.testing.expectEqual(@as(u32, 0), try server.resyncWriteChannel());
    try std.testing.expectEqual(@as(usize, 0), fake.data_out_pops);
    try std.testing.expectEqual(@as(usize, 0), fake.acks_len);
}

test "the host model of the card cache follows the direct mapped rule" {
    var model: CacheModel = .{};
    model.configure(128);
    try std.testing.expectEqual(@as(usize, 128), model.lines);
    try std.testing.expect(!model.holds(37));

    model.insert(37);
    try std.testing.expect(model.holds(37));
    // 37 and 37 + 128 share one line, so the second takes it and the
    // first is gone. The card does the same.
    try std.testing.expect(!model.holds(37 + 128));
    model.insert(37 + 128);
    try std.testing.expect(model.holds(37 + 128));
    try std.testing.expect(!model.holds(37));

    // A write drops the line it names and no other.
    model.insert(5);
    model.remove(37 + 128);
    try std.testing.expect(!model.holds(37 + 128));
    try std.testing.expect(model.holds(5));
    // A write to a block that maps to a line holding ANOTHER block leaves
    // that line alone.
    model.remove(5 + 128);
    try std.testing.expect(model.holds(5));

    model.clear();
    try std.testing.expect(!model.holds(5));
}

test "a line count the model cannot hold turns the model off" {
    var model: CacheModel = .{};
    // Not a power of two. The card guarantees one, so a count like this
    // says the card is not what this code thinks it is.
    model.configure(216);
    try std.testing.expectEqual(@as(usize, 0), model.lines);
    model.insert(1);
    try std.testing.expect(!model.holds(1));

    // Above what the array holds.
    model.configure(MODEL_LINES * 2);
    try std.testing.expectEqual(@as(usize, 0), model.lines);

    // Zero lines, which is a card with no cache at all.
    model.configure(0);
    try std.testing.expectEqual(@as(usize, 0), model.lines);

    model.configure(MODEL_LINES);
    try std.testing.expectEqual(MODEL_LINES, model.lines);
}

test "learnCache sizes the model from what CACHE_LINES reports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    var fake: FakeDevice = .{};
    var server: Server = .{ .device = fake.device(), .image = image };
    try std.testing.expectEqual(@as(usize, 0), server.cache.lines);
    try server.learnCache();
    try std.testing.expectEqual(@as(usize, 128), server.cache.lines);
}

test "a read ahead fills the blocks after the record and tags them as fills" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 64);
    const image = try openTestImage(tmp.dir, "card.img", 64, false);
    defer image.file.close(std.testing.io);

    const request: Request = .{ .op = 0x01, .blocks = 1, .lba = 10, .seq = 4 };
    var fake: FakeDevice = .{ .req = &request.words(), .req_count = 1 };
    var server: Server = .{
        .device = fake.device(),
        .image = image,
        .options = .{ .read_ahead = 2 },
    };
    try server.learnCache();
    server.last_read_end = request.lba;
    server.sequential_reads = READ_AHEAD_SEQUENCE - 1;

    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try server.continueReadAhead();

    // One block for the record and two fills after it.
    try std.testing.expectEqual(@as(usize, 3), fake.tags_len);
    try std.testing.expectEqual(@as(usize, 3 * BLOCK_WORDS), fake.pushed_len);
    try std.testing.expectEqual(@as(u8, 4), fake.tags[0]);
    try std.testing.expectEqual(@as(?u32, null), fake.fills[0]);
    // A fill carries the tag that names NO record, and its own address.
    try std.testing.expectEqual(@as(u8, 0), fake.tags[1]);
    try std.testing.expectEqual(@as(?u32, 11), fake.fills[1]);
    try std.testing.expectEqual(@as(u8, 0), fake.tags[2]);
    try std.testing.expectEqual(@as(?u32, 12), fake.fills[2]);

    // The bytes of each fill are the bytes of the block it names.
    var got: [3 * sd.BLOCK_SIZE]u8 = undefined;
    const pushed = fake.pushedBytes(&got);
    var want: [sd.BLOCK_SIZE]u8 = undefined;
    patternBlock(10, &want);
    try std.testing.expectEqualSlices(u8, &want, pushed[0..sd.BLOCK_SIZE]);
    patternBlock(11, &want);
    try std.testing.expectEqualSlices(
        u8,
        &want,
        pushed[sd.BLOCK_SIZE .. 2 * sd.BLOCK_SIZE],
    );
    patternBlock(12, &want);
    try std.testing.expectEqualSlices(u8, &want, pushed[2 * sd.BLOCK_SIZE ..]);

    try std.testing.expectEqual(@as(u64, 1), server.stats.blocks);
    try std.testing.expectEqual(@as(u64, 2), server.stats.fills);
    // The model now holds all three, so nothing is left to fill.
    try std.testing.expect(server.cache.holds(10));
    try std.testing.expect(server.cache.holds(11));
    try std.testing.expect(server.cache.holds(12));
}

test "a read ahead pushes nothing for a block the card already holds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 64);
    const image = try openTestImage(tmp.dir, "card.img", 64, false);
    defer image.file.close(std.testing.io);

    const request: Request = .{ .op = 0x01, .blocks = 1, .lba = 10, .seq = 4 };
    var fake: FakeDevice = .{ .req = &request.words(), .req_count = 1 };
    var server: Server = .{
        .device = fake.device(),
        .image = image,
        .options = .{ .read_ahead = 2 },
    };
    try server.learnCache();
    // The card is told to hold block 11 already.
    server.cache.insert(11);
    server.last_read_end = request.lba;
    server.sequential_reads = READ_AHEAD_SEQUENCE - 1;

    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try server.continueReadAhead();

    // The record and ONE fill: block 11 cost nothing at all.
    try std.testing.expectEqual(@as(usize, 2), fake.tags_len);
    try std.testing.expectEqual(@as(?u32, 12), fake.fills[1]);
    try std.testing.expectEqual(@as(u64, 1), server.stats.fills);
    try std.testing.expectEqual(@as(u64, 1), server.stats.fills_skipped);
}

test "a read ahead waits while the card still has a record" {
    // A fill pushed in front of a record the card is already waiting for
    // takes the room the answer needs and delays the block the host is
    // really reading.
    //
    // The card reports TWO records and the pass takes one, so one record
    // is still known to be waiting when the read ahead would run.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 64);
    const image = try openTestImage(tmp.dir, "card.img", 64, false);
    defer image.file.close(std.testing.io);

    const request: Request = .{ .op = 0x01, .blocks = 1, .lba = 10, .seq = 4 };
    var fake: FakeDevice = .{
        .req = &request.words(),
        .req_count = 2,
        .req_count_later = 2,
    };
    var server: Server = .{
        .device = fake.device(),
        .image = image,
        .options = .{ .read_ahead = 2, .max_requests_per_poll = 1 },
    };
    try server.learnCache();
    server.last_read_end = request.lba;
    server.sequential_reads = READ_AHEAD_SEQUENCE - 1;

    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try std.testing.expectEqual(@as(usize, 1), fake.tags_len);
    try std.testing.expectEqual(@as(u64, 0), server.stats.fills);
    try std.testing.expectEqual(@as(u64, 1), server.stats.ahead_deferred_busy);
    try std.testing.expectEqual(@as(u64, 0), server.stats.ahead_deferred_space);
}

test "a read ahead of zero blocks pushes nothing beyond the record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 64);
    const image = try openTestImage(tmp.dir, "card.img", 64, false);
    defer image.file.close(std.testing.io);

    const request: Request = .{ .op = 0x01, .blocks = 1, .lba = 10, .seq = 4 };
    var fake: FakeDevice = .{ .req = &request.words(), .req_count = 1 };
    var server: Server = .{ .device = fake.device(), .image = image };
    try server.learnCache();

    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try std.testing.expectEqual(@as(usize, 1), fake.tags_len);
    try std.testing.expectEqual(@as(u64, 0), server.stats.fills);
}

test "a read ahead stops at the last block of the image" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 8);
    const image = try openTestImage(tmp.dir, "card.img", 8, false);
    defer image.file.close(std.testing.io);

    // The last block. There is nothing after it to fill, and a fill of a
    // block past the end would read past the image.
    const request: Request = .{ .op = 0x01, .blocks = 1, .lba = 7, .seq = 1 };
    var fake: FakeDevice = .{ .req = &request.words(), .req_count = 1 };
    var server: Server = .{
        .device = fake.device(),
        .image = image,
        .options = .{ .read_ahead = 4 },
    };
    try server.learnCache();

    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try std.testing.expectEqual(@as(usize, 1), fake.tags_len);
    try std.testing.expectEqual(@as(u64, 0), server.stats.fills);
}

test "a write drops the block it names from the host model" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 16);
    const image = try openTestImage(tmp.dir, "card.img", 16, false);
    defer image.file.close(std.testing.io);

    const request: Request = .{ .op = 0x02, .blocks = 1, .lba = 3, .seq = 9 };
    const words = channelBlock(0xAA, 0xBB, 0xCC);
    var fake: FakeDevice = .{
        .req = &request.words(),
        .req_count = 1,
        .data_out = &words,
    };
    var server: Server = .{ .device = fake.device(), .image = image };
    try server.learnCache();
    server.cache.insert(3);
    server.cache.insert(4);

    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    // The card invalidates the line that CMD24 names, so the model must
    // drop the same one and no other.
    try std.testing.expect(!server.cache.holds(3));
    try std.testing.expect(server.cache.holds(4));
}

test "a record for a block the model claims clears the whole model" {
    // The card throws its whole store away on a CMD0 and no command of the
    // SD bus reaches this side, so a record for a block the model claims
    // is the only news of it. A model that went on claiming blocks the
    // card lost would skip the fills that would put them back.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 64);
    const image = try openTestImage(tmp.dir, "card.img", 64, false);
    defer image.file.close(std.testing.io);

    const request: Request = .{ .op = 0x01, .blocks = 1, .lba = 10, .seq = 4 };
    var fake: FakeDevice = .{ .req = &request.words(), .req_count = 1 };
    var server: Server = .{
        .device = fake.device(),
        .image = image,
        .options = .{ .read_ahead = 2 },
    };
    try server.learnCache();
    server.cache.insert(10);
    server.cache.insert(11);
    server.cache.insert(50);

    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try server.continueReadAhead();
    try std.testing.expectEqual(@as(u64, 1), server.stats.model_resets);
    // The clear happened before the record was served, so block 50 is
    // forgotten. It also clears the sequence predictor, so no speculative
    // block goes out until another request proves a sequential walk.
    try std.testing.expect(!server.cache.holds(50));
    try std.testing.expectEqual(@as(u64, 0), server.stats.fills);
    try std.testing.expectEqual(@as(u64, 0), server.stats.fills_skipped);
}

test "a new card generation clears pending fills before serving a request" {
    // CMD0 invalidates the FPGA cache. A pending host-model entry from the
    // prior generation must not suppress the first request after that CMD0.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 64);
    const image = try openTestImage(tmp.dir, "card.img", 64, false);
    defer image.file.close(std.testing.io);

    const request: Request = .{
        .op = 0x01,
        .blocks = 1,
        .lba = 10,
        .seq = 4,
        .epoch = 2,
    };
    var fake: FakeDevice = .{};
    var server: Server = .{
        .device = fake.device(),
        .image = image,
        .card_epoch = 1,
    };
    try server.learnCache();
    server.cache.insertPending(10);
    server.cache.insertPending(11);

    try std.testing.expect(try server.serveRequest(request, 0));
    try std.testing.expectEqual(@as(usize, 1), fake.tags_len);
    try std.testing.expectEqual(@as(u8, request.seq), fake.tags[0]);
    try std.testing.expectEqual(@as(u64, 1), server.stats.model_resets);
    try std.testing.expect(!server.cache.holds(11));
}

test "a read ahead pushes nothing when the data channel has no room" {
    // The card drains the data channel on the SD clock, which the host
    // owns and can stop. A read ahead that waited for room there could
    // burn the whole poll limit and then fail a serve loop that had
    // nothing wrong with it.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 64);
    const image = try openTestImage(tmp.dir, "card.img", 64, false);
    defer image.file.close(std.testing.io);

    const request: Request = .{ .op = 0x01, .blocks = 1, .lba = 10, .seq = 4 };
    var fake: FakeDevice = .{
        .req = &request.words(),
        .req_count = 1,
        // Room for the block of the record and nothing after it.
        .space_words = BLOCK_WORDS,
        .space_words_later = 0,
    };
    var server: Server = .{
        .device = fake.device(),
        .image = image,
        .options = .{ .read_ahead = 2 },
    };
    try server.learnCache();
    server.last_read_end = request.lba;
    server.sequential_reads = READ_AHEAD_SEQUENCE - 1;

    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try std.testing.expectEqual(@as(usize, 1), fake.tags_len);
    try std.testing.expectEqual(@as(u64, 0), server.stats.fills);
    try std.testing.expectEqual(@as(u64, 1), server.stats.ahead_deferred_space);
    try std.testing.expectEqual(@as(u64, 0), server.stats.ahead_deferred_busy);
}

test "read ahead runs between the records of a stream and not only after them" {
    // Boot is almost all CMD18. The card posts ONE record for each block
    // of a stream, so a batch is one record long and a read ahead that
    // waited for the end of the batch never ran while a stream was in
    // flight. That is where it is worth the most: the card takes a fill
    // into its cache in the gap between two blocks of a stream, and the
    // lookup of the next block then costs no round trip at all.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 64);
    const image = try openTestImage(tmp.dir, "card.img", 64, false);
    defer image.file.close(std.testing.io);

    // Four records, one block each, at consecutive addresses, which is
    // what a CMD18 stream of four blocks posts.
    const stream = [_]Request{
        .{ .op = 0x01, .blocks = 1, .lba = 10, .seq = 1 },
        .{ .op = 0x01, .blocks = 1, .lba = 11, .seq = 2 },
        .{ .op = 0x01, .blocks = 1, .lba = 12, .seq = 3 },
        .{ .op = 0x01, .blocks = 1, .lba = 13, .seq = 4 },
    };
    var words: [stream.len * REQUEST_WORDS]u32 = undefined;
    for (stream, 0..) |request, i| {
        @memcpy(words[i * REQUEST_WORDS ..][0..REQUEST_WORDS], &request.words());
    }

    var fake: FakeDevice = .{
        .req = &words,
        // One record waiting on every pass, which is what a stream looks
        // like: the card asks for the next block at the end bit of this
        // one.
        .req_count = 1,
        .req_count_later = 1,
        // Four blocks of channel, which is what the gateware holds.
        .space_words = 4 * BLOCK_WORDS,
    };
    var server: Server = .{
        .device = fake.device(),
        .image = image,
        .options = .{ .read_ahead = 2 },
    };
    try server.learnCache();
    server.last_read_end = stream[0].lba;
    server.sequential_reads = READ_AHEAD_SEQUENCE - 2;

    for (stream) |_| {
        try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    }

    // EVERY record is answered with a block of its own, whatever the
    // model says about a fill on its way. A record proves that the card
    // has no answer yet, and a fill that reached the cache and was pushed
    // out of it again answers nothing at all, so a skip here would leave
    // the host waiting out the whole read timeout.
    try std.testing.expectEqual(@as(u64, 4), server.stats.blocks);
    // The walk is not broken by the blocks this side sent ahead. Records
    // three and four name blocks inside the window that record two
    // opened, and the read ahead goes on through both.
    try std.testing.expect(server.stats.fills > 0);
    try std.testing.expectEqual(@as(u64, 0), server.stats.model_resets);
    try std.testing.expectEqual(@as(u64, 0), server.stats.ahead_deferred_busy);
    try std.testing.expectEqual(@as(u64, 0), server.stats.refused);
}

test "a fill carries the fill tag and its own address, never a record tag" {
    // A block that no record asked for must never be read as the answer to
    // one. The tag is what keeps them apart: a fill carries DATA_TAG_FILL,
    // which names NO request, and the address of the block it is.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 64);
    const image = try openTestImage(tmp.dir, "card.img", 64, false);
    defer image.file.close(std.testing.io);

    const request: Request = .{ .op = 0x01, .blocks = 1, .lba = 20, .seq = 7 };
    var fake: FakeDevice = .{
        .req = &request.words(),
        .req_count = 1,
        .req_count_later = 1,
        .space_words = 4 * BLOCK_WORDS,
    };
    var server: Server = .{
        .device = fake.device(),
        .image = image,
        .options = .{ .read_ahead = 3 },
    };
    try server.learnCache();
    server.last_read_end = request.lba;
    server.sequential_reads = READ_AHEAD_SEQUENCE - 1;
    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try server.continueReadAhead();
    try server.continueReadAhead();

    // One block for the record and three fills after it.
    try std.testing.expectEqual(@as(usize, 4), fake.tags_len);
    try std.testing.expectEqual(@as(u8, 7), fake.tags[0]);
    try std.testing.expectEqual(@as(?u32, null), fake.fills[0]);
    for (1..4) |i| {
        try std.testing.expectEqual(@as(u8, sd.DATA_TAG_FILL), fake.tags[i]);
        try std.testing.expectEqual(@as(?u32, @intCast(20 + i)), fake.fills[i]);
    }

    // The bytes of each block are the bytes of the address its tag names,
    // so a fill can never carry the bytes of another block.
    var want: [sd.BLOCK_SIZE]u8 = undefined;
    for (0..4) |i| {
        patternBlock(20 + i, &want);
        const got = fake.pushed[i * BLOCK_WORDS ..][0..BLOCK_WORDS];
        for (0..BLOCK_WORDS) |w| {
            try std.testing.expectEqual(
                std.mem.readInt(u32, want[w * 4 ..][0..4], .little),
                got[w],
            );
        }
    }
}

test "a record combines its tag and block in one USB frame" {
    // The number that decides how fast the link runs. One frame is one
    // transfer on the wire and costs of the order of half a millisecond at
    // full speed, whatever it carries.
    //
    // A record costs TWO transactions and no more: one status read, which
    // brings the record AND the free space of the data channel back
    // together, and one transaction that carries the tag and the block.
    // Nothing polls DATA_IN_COUNT on its own, because the status read of
    // every pass already reports it.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 64);
    const image = try openTestImage(tmp.dir, "card.img", 64, false);
    defer image.file.close(std.testing.io);

    // Two records far apart, so neither is a repeat of the other and the
    // host model is never wrong.
    const records = [_]Request{
        .{ .op = 0x01, .blocks = 1, .lba = 30, .seq = 3 },
        .{ .op = 0x01, .blocks = 1, .lba = 50, .seq = 4 },
    };
    var words: [records.len * REQUEST_WORDS]u32 = undefined;
    for (records, 0..) |request, i| {
        @memcpy(words[i * REQUEST_WORDS ..][0..REQUEST_WORDS], &request.words());
    }
    var fake: FakeDevice = .{
        .req = &words,
        .req_count = 1,
        .req_count_later = 1,
        .space_words = 4 * BLOCK_WORDS,
    };
    var server: Server = .{
        .device = fake.device(),
        .image = image,
        .options = .{ .read_ahead = 0 },
    };
    try server.learnCache();
    fake.frames = 0;
    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try std.testing.expectEqual(@as(usize, 2), fake.frames);

    // The next record costs the same two. Nothing about the first pass
    // was a cost of starting.
    fake.frames = 0;
    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try std.testing.expectEqual(@as(usize, 2), fake.frames);
    try std.testing.expectEqual(@as(u64, 2), server.stats.blocks);
    try std.testing.expectEqual(@as(u64, 0), server.stats.refused);
}

test "a read ahead window rides behind the record in one USB frame" {
    // The block that answers the record and the three fills behind it
    // share ONE transaction, and the status read of the pass is the only
    // other one. Four blocks therefore cost TWO round trips, which is half
    // a round trip per block.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePatternImage(tmp.dir, "card.img", 128);
    const image = try openTestImage(tmp.dir, "card.img", 128, false);
    defer image.file.close(std.testing.io);

    // Two records far enough apart that the read ahead of the first names
    // no block of the second. Nothing here is a repeat, so the host model
    // is never wrong and never cleared.
    const records = [_]Request{
        .{ .op = 0x01, .blocks = 1, .lba = 40, .seq = 5 },
        .{ .op = 0x01, .blocks = 1, .lba = 60, .seq = 6 },
    };
    var words: [records.len * REQUEST_WORDS]u32 = undefined;
    for (records, 0..) |request, i| {
        @memcpy(words[i * REQUEST_WORDS ..][0..REQUEST_WORDS], &request.words());
    }
    var fake: FakeDevice = .{
        .req = &words,
        .req_count = 1,
        .req_count_later = 1,
        .space_words = 4 * BLOCK_WORDS,
    };
    var server: Server = .{
        .device = fake.device(),
        .image = image,
        .options = .{ .read_ahead = 3 },
    };
    try server.learnCache();
    server.last_read_end = records[0].lba;
    server.sequential_reads = READ_AHEAD_SEQUENCE - 1;
    // The first pass spends the one read of DATA_IN_COUNT, so what the
    // second costs is the steady cost and not the cost of starting.
    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try server.continueReadAhead();
    try server.continueReadAhead();

    fake.frames = 0;
    server.last_read_end = records[1].lba;
    server.sequential_reads = READ_AHEAD_SEQUENCE - 1;
    try std.testing.expectEqual(@as(u32, 1), try server.servePending());
    try server.continueReadAhead();
    try server.continueReadAhead();
    // One status read and one transaction that carries the answer and the
    // three fills behind it.
    try std.testing.expectEqual(@as(u64, 6), server.stats.fills);
    try std.testing.expectEqual(@as(u64, 0), server.stats.model_resets);
    try std.testing.expectEqual(@as(usize, 2), fake.frames);
    // The demand block leads the transaction and the fills follow it, so
    // no speculative block can ever sit in front of the one the host is
    // waiting for.
    try std.testing.expectEqual(@as(u8, 6), fake.tags[fake.tags_len - 4]);
    try std.testing.expectEqual(@as(?u32, null), fake.fills[fake.tags_len - 4]);
}
