const std = @import("std");
const Io = std.Io;
const mimic = @import("mimic");
const sd = mimic.sd;
const serve = mimic.serve;
const transport = mimic.transport;

const Device = transport.Device;

/// Blocks the serve loop fills into the card cache after each read when
/// nobody names a number.
///
/// THREE, which is what the data channel holds beside the block that
/// answers the record. The channel holds four whole blocks, the runtime
/// pushes the answer and then the fills, and a fill that finds no room is
/// dropped, so a larger number here only counts drops.
///
/// It is not free. A large read ahead on a RANDOM workload spends the link
/// on blocks nobody reads. Boot is not random: it is one CMD18 stream
/// after another, and a stream costs one record for every read ahead depth
/// plus one blocks instead of one record per block.
const DEFAULT_READ_AHEAD: u16 = 3;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip(); // argv[0]

    var cmd: ?[]const u8 = null;
    var operand: ?[]const u8 = null;
    var grow = false;
    var read_only = false;
    var stats = false;
    var read_ahead: u16 = DEFAULT_READ_AHEAD;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            return usage(io, null);
        } else if (std.mem.eql(u8, a, "--grow")) {
            grow = true;
        } else if (std.mem.eql(u8, a, "--ro")) {
            read_only = true;
        } else if (std.mem.eql(u8, a, "--stats")) {
            stats = true;
        } else if (std.mem.startsWith(u8, a, "--read-ahead=")) {
            const text = a["--read-ahead=".len..];
            read_ahead = std.fmt.parseInt(u16, text, 10) catch
                return usage(io, "--read-ahead takes a whole number of blocks");
        } else if (cmd == null) {
            cmd = a;
        } else if (operand == null) {
            operand = a;
        } else {
            return usage(io, "unexpected argument");
        }
    }
    const command = cmd orelse "help";
    if (std.mem.eql(u8, command, "help")) return usage(io, null);

    // One buffered stdout writer for the whole run; flushed on exit. The
    // failure paths below std.process.exit (which skips defers), so they
    // flush by hand.
    const out_file = Io.File.stdout();
    var out_buf: [512]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);
    const out = &out_writer.interface;
    defer out.flush() catch {};

    // Reject an unknown command before the device open, so a typo does not
    // report a missing device.
    const is_capacity = std.mem.eql(u8, command, "capacity");
    const is_serve = std.mem.eql(u8, command, "serve");
    const takes_image = is_capacity or is_serve;
    const known = std.mem.eql(u8, command, "version") or
        std.mem.eql(u8, command, "probe") or
        std.mem.eql(u8, command, "info") or
        takes_image;
    if (!known) {
        try out.print("unknown command: {s}\n", .{command});
        return usage(io, null);
    }
    if (!takes_image and operand != null) return usage(io, "this command takes no argument");
    if (!takes_image and grow) return usage(io, "--grow belongs to the capacity and serve commands");
    if (!is_serve and (read_only or stats)) {
        return usage(io, "--ro and --stats belong to the serve command");
    }
    if (!is_serve and read_ahead != DEFAULT_READ_AHEAD) {
        return usage(io, "--read-ahead belongs to the serve command");
    }
    if (grow and read_only) {
        return usage(io, "--grow appends zeros to the image, so it cannot go with --ro");
    }
    if (is_serve) {
        // A block count builds a CSD out of nothing, and `serve` has to read
        // real blocks, so it takes a path only.
        const path = operand orelse return usage(io, "serve needs an image path");
        if (std.fmt.parseInt(u64, path, 10)) |_| {
            return usage(io, "serve needs an image path and not a block count");
        } else |_| {}
    }

    // The capacity plan is built before the device opens. A bad path or a
    // bad block count must never reach the hardware, and the grow step
    // changes a file of the operator, so its report comes first.
    const plan: ?CapacityPlan = if (takes_image)
        capacityPlan(io, .cwd(), out, operand orelse
            return usage(io, "capacity needs an image path or a block count"), grow) catch |e| fail(out, e)
    else
        null;

    const device = Device.openUsb(io) catch |e| fail(out, e);
    defer device.close();

    if (std.mem.eql(u8, command, "version")) {
        cmdVersion(device, out) catch |e| fail(out, e);
    } else if (std.mem.eql(u8, command, "probe")) {
        cmdProbe(io, device, out) catch |e| fail(out, e);
    } else if (is_capacity) {
        // The optional holds a plan whenever the command is `capacity`,
        // which the branch above already decided.
        cmdCapacity(device, out, plan.?) catch |e| fail(out, e);
    } else if (is_serve) {
        cmdServe(io, device, out, plan.?, operand.?, .{
            .read_only = read_only,
            .stats = stats,
            .read_ahead = read_ahead,
        }) catch |e| fail(out, e);
    } else {
        cmdInfo(device, out) catch |e| fail(out, e);
    }
}

/// Reads ID and VERSION, verifies the MIMC magic, and prints the interface
/// version decoded from major << 16 | minor << 8 | patch.
fn cmdVersion(device: Device, out: *Io.Writer) !void {
    const id = try device.regRead(sd.REG_ID);
    if (id != sd.ID_MAGIC) {
        try out.print("ID = 0x{X:0>8}, expected 0x{X:0>8}\n", .{ id, sd.ID_MAGIC });
        return error.BadIdMagic;
    }
    const raw = try device.regRead(sd.REG_VERSION);
    const v = sd.decodeInterfaceVersion(raw);
    try out.print("ID      = 0x{X:0>8} (MIMC)\n", .{id});
    try out.print("VERSION = 0x{X:0>8} (interface {d}.{d}.{d})\n", .{ raw, v.major, v.minor, v.patch });
}

/// Transport reliability probe. SCRATCH write-readback across five patterns,
/// then repeated 32-word burst reads from ID: word[0] of every burst must be
/// the magic. Counts every op and every failure, prints stats, then PASS or
/// FAIL. A failed op counts and the probe continues, so a flaky link shows a
/// full picture instead of a dead run.
fn cmdProbe(io: Io, device: Device, out: *Io.Writer) !void {
    const id = try device.regRead(sd.REG_ID);
    if (id != sd.ID_MAGIC) return error.BadIdMagic;
    const ver = try device.regRead(sd.REG_VERSION);
    if (ver != sd.INTERFACE_VERSION) return error.BadVersion;

    var ops: usize = 0;
    var errors: usize = 0;
    const start = Io.Clock.Timestamp.now(io, .awake);

    // Write-readback: a mismatch means the write path corrupts.
    const patterns = [_]u32{ 0x00000000, 0xFFFFFFFF, 0xA5A5A5A5, 0x5A5A5A5A, 0x12345678 };
    for (patterns) |p| {
        ops += 1;
        device.regWrite(sd.REG_SCRATCH, p) catch {
            errors += 1;
            continue;
        };
        ops += 1;
        const rb = device.regRead(sd.REG_SCRATCH) catch {
            errors += 1;
            continue;
        };
        if (rb != p) errors += 1;
    }

    // Burst reads: a desynced or corrupt burst shows up as word[0] != magic.
    const W: usize = 32;
    const BURSTS: usize = 1024;
    var words: [W]u32 = undefined;
    for (0..BURSTS) |_| {
        ops += 1;
        device.readRegs(sd.REG_ID, &words) catch {
            errors += 1;
            continue;
        };
        if (words[0] != sd.ID_MAGIC) errors += 1;
    }

    const elapsed_ns: u64 = @intCast(start.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds);
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    const ops_per_s = @as(f64, @floatFromInt(ops)) / elapsed_s;
    try out.print("ops: {d}  errors: {d}  elapsed: {d:.3}s  ops/s: {d:.0}\n", .{ ops, errors, elapsed_s, ops_per_s });

    if (errors != 0) {
        try out.print("FAIL\n", .{});
        out.flush() catch {};
        std.process.exit(1);
    }
    try out.print("PASS\n", .{});
}

/// Reads the whole CSR map and prints a name = value table, with the CTRL
/// bits decoded.
fn cmdInfo(device: Device, out: *Io.Writer) !void {
    const names = [_][]const u8{
        "ID",         "VERSION",       "CTRL",        "STATUS",
        "NUM_BLOCKS", "SCRATCH",       "REQ",         "REQ_COUNT",
        "DATA_IN",    "DATA_IN_COUNT", "DATA_OUT",    "DATA_OUT_COUNT",
        "EVENT",      "IRQ_ENABLE",    "DBG_CMD",     "DBG_IN",
        "DBG_RESET",  "CARD_STATE",    "CSD_0",       "CSD_1",
        "CSD_2",      "CSD_3",         "SD_CLK",      "SD_CMD",
        "SD_CRC_ERR", "SD_RESP",       "REQ_HI",      "DATA_TAG",
        "REQ_POP",    "DATA_OUT_POP",  "WRITE_ACK",   "DATA_FILL_LBA",
        "CACHE_HIT",  "CACHE_MISS",    "CACHE_FILL",  "CACHE_LINES",
        "REQ_SNAP_N", "REQ_SNAP",      "REQ_SNAP_HI", "READ_START",
        "READ_DONE",  "READ_DROP",     "READ_ABORT",
    };
    // One burst over the whole block, REQ included. NO address of the map
    // has a side effect on read, so this walk cannot take a request away
    // from a `serve` loop that runs at the same time, whatever it covers.
    // The pop is a WRITE of REG_REQ_POP and this command writes nothing.
    comptime std.debug.assert(names.len * 4 == sd.REG_DBG_READ_ABORT + 4);
    var words: [names.len]u32 = undefined;
    try device.readRegs(sd.REG_ID, &words);
    for (names, 0..) |name, i| {
        try out.print("0x{X:0>2} {s:<15} = 0x{X:0>8}\n", .{ i * 4, name, words[i] });
    }
    const ctrl = words[sd.REG_CTRL / 4];
    try out.print("CTRL: enable={d} test-pattern={d} read-only={d} cache-bypass={d}\n", .{
        @as(u1, @intFromBool(ctrl & sd.CTRL_ENABLE != 0)),
        @as(u1, @intFromBool(ctrl & sd.CTRL_TEST_PATTERN != 0)),
        @as(u1, @intFromBool(ctrl & sd.CTRL_READ_ONLY != 0)),
        @as(u1, @intFromBool(ctrl & sd.CTRL_CACHE_BYPASS != 0)),
    });
    const card: sd.CardState = @enumFromInt(
        words[sd.REG_CARD_STATE / 4] & sd.CARD_STATE_MASK,
    );
    try out.print("CARD_STATE: {s}\n", .{card.name()});

    // The CSD carries the size that the card reports to the host, so the
    // operator sees it beside the card state.
    const csd = sd.csdFromWords(.{
        words[sd.REG_CSD_0 / 4],
        words[sd.REG_CSD_1 / 4],
        words[sd.REG_CSD_2 / 4],
        words[sd.REG_CSD_3 / 4],
    });
    if (sd.csdCapacityBlocks(&csd)) |blocks| {
        try printCapacity(out, "CAPACITY", blocks);
    } else {
        try out.print("CAPACITY: the CSD is not version 2.0, write one with `capacity`\n", .{});
    }
}

/// What the `capacity` command will write, and what it cost to get there.
const CapacityPlan = struct {
    /// The register bytes, most significant byte first.
    csd: [sd.CSD_BYTES]u8,
    /// The blocks that the source holds, after any grow.
    source_blocks: u64,
    /// The blocks that the card will report.
    advertised_blocks: u64,
    /// The blocks that the source holds and the card cannot address.
    lost_blocks: u64,
    /// The bytes of a part block at the end of the image. The card
    /// addresses whole blocks, so these bytes are unreachable too.
    partial_bytes: u64,
    /// The zero bytes that `--grow` appended to the image.
    appended_bytes: u64,
};

/// Builds the plan from an image path or from a 512-byte block count.
///
/// A pure decimal argument is a block count, and anything else is a path.
/// The path is the real use case: the operator points at the image that
/// the card serves, so the card cannot report a size that the image does
/// not have.
///
/// With `grow`, the image file grows to the next size that the CSD holds
/// exactly. Without it, the reported capacity rounds down and the operator
/// gets a warning.
///
/// `dir` is the directory that a relative path starts from. The CLI gives
/// the working directory and a test gives a temporary directory.
fn capacityPlan(io: Io, dir: Io.Dir, out: *Io.Writer, arg: []const u8, grow: bool) !CapacityPlan {
    if (std.fmt.parseInt(u64, arg, 10)) |blocks| {
        // A block count has no file behind it, so there is nothing to
        // grow. Growing the count alone would make the card report space
        // that no image holds.
        if (grow) return error.GrowNeedsImage;
        const fit = try sd.fitCapacityBlocks(blocks);
        return .{
            .csd = try sd.csdV2(fit.advertised_blocks, .{}),
            .source_blocks = blocks,
            .advertised_blocks = fit.advertised_blocks,
            .lost_blocks = fit.lost_blocks,
            .partial_bytes = 0,
            .appended_bytes = 0,
        };
    } else |_| {}

    const mode: Io.File.OpenFlags.Mode = if (grow) .read_write else .read_only;
    const file = try dir.openFile(io, arg, .{ .mode = mode });
    defer file.close(io);
    var size = (try file.stat(io)).size;

    var appended: u64 = 0;
    if (grow) {
        const target = try sd.growTargetBytes(size);
        if (target > size) {
            try appendZeros(io, file, size, target - size);
            appended = target - size;
            size = target;
            try out.print("grow: appended {d} bytes ({d} blocks) to {s}\n", .{
                appended,
                appended / sd.BLOCK_SIZE,
                arg,
            });
        } else {
            try out.print("grow: {s} already fits a whole CSD capacity, nothing to do\n", .{arg});
        }
    }

    const blocks = sd.blocksInBytes(size);
    const partial_bytes = size % sd.BLOCK_SIZE;
    const fit = try sd.fitCapacityBlocks(blocks);
    if (fit.lost_blocks != 0 or partial_bytes != 0) {
        try warnRoundedDown(out, arg, blocks, partial_bytes, fit);
    }
    return .{
        .csd = try sd.csdV2(fit.advertised_blocks, .{}),
        .source_blocks = blocks,
        .advertised_blocks = fit.advertised_blocks,
        .lost_blocks = fit.lost_blocks,
        .partial_bytes = partial_bytes,
        .appended_bytes = appended,
    };
}

/// Appends `count` zero bytes to the end of `file`.
///
/// The write starts at the current end of the file, so the data that the
/// image already holds does not move. This grows a file and never shortens
/// one.
fn appendZeros(io: Io, file: Io.File, from: u64, count: u64) !void {
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.seekTo(from);
    try writer.interface.splatByteAll(0, @intCast(count));
    try writer.interface.flush();
}

/// Tells the operator that the card reports less space than the image
/// holds, and what to do about it.
fn warnRoundedDown(
    out: *Io.Writer,
    arg: []const u8,
    blocks: u64,
    partial_bytes: u64,
    fit: sd.CapacityFit,
) !void {
    const unreachable_bytes = fit.lost_blocks * sd.BLOCK_SIZE + partial_bytes;
    try out.print("WARNING: {s} holds {d} whole blocks", .{ arg, blocks });
    if (partial_bytes != 0) {
        try out.print(" and {d} bytes of a part block", .{partial_bytes});
    }
    try out.print("\n", .{});
    try out.print("WARNING: the card will report {d} blocks\n", .{fit.advertised_blocks});
    try out.print("WARNING: {d} blocks ({d} bytes) at the end are unreachable\n", .{
        fit.lost_blocks,
        unreachable_bytes,
    });
    try out.print(
        "WARNING: the CSD holds capacity in steps of {d} blocks, so this size has no exact CSD\n",
        .{sd.CSD_CAPACITY_UNIT_BLOCKS},
    );
    try out.print("WARNING: the capacity rounds down, because a card must never claim more space than the image holds\n", .{});
    try out.print("WARNING: run `capacity {s} --grow` to append zeros and report the exact size instead\n", .{arg});
}

/// Writes the four CSD registers and reads them back. Returns the words
/// that were written.
///
/// The read back is not a formality: the card serves this register to the
/// host once, and a write that the link dropped would give the host a
/// wrong size with no other sign. `capacity` and `serve` both go through
/// here, so the card reports one size and one only.
fn applyCapacity(device: Device, out: *Io.Writer, plan: CapacityPlan) ![4]u32 {
    const words = sd.csdToWords(&plan.csd);
    try device.writeRegs(&.{
        .{ sd.REG_CSD_0, words[0] },
        .{ sd.REG_CSD_1, words[1] },
        .{ sd.REG_CSD_2, words[2] },
        .{ sd.REG_CSD_3, words[3] },
    });

    var read_back: [4]u32 = undefined;
    try device.readRegs(sd.REG_CSD_0, &read_back);
    if (!std.mem.eql(u32, &words, &read_back)) {
        for (read_back, 0..) |w, i| {
            try out.print("CSD_{d} wrote 0x{X:0>8}, read 0x{X:0>8}\n", .{ i, words[i], w });
        }
        return error.CsdReadBackMismatch;
    }
    return words;
}

/// Writes the four CSD registers, reads them back, and prints the capacity
/// that the card now reports.
fn cmdCapacity(device: Device, out: *Io.Writer, plan: CapacityPlan) !void {
    const id = try device.regRead(sd.REG_ID);
    if (id != sd.ID_MAGIC) return error.BadIdMagic;

    const words = try applyCapacity(device, out, plan);

    try out.print("CSD = ", .{});
    for (plan.csd) |b| try out.print("{X:0>2}", .{b});
    try out.print("\n", .{});
    for (words, 0..) |w, i| {
        try out.print("0x{X:0>2} CSD_{d}{s:<10} = 0x{X:0>8}\n", .{ sd.REG_CSD_0 + 4 * i, i, "", w });
    }
    try printCapacity(out, "capacity", plan.advertised_blocks);
}

/// Prints a block count as blocks, bytes, and GiB.
fn printCapacity(out: *Io.Writer, label: []const u8, blocks: u64) !void {
    const bytes = blocks * sd.BLOCK_SIZE;
    const gib = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
    try out.print("{s}: {d} blocks, {d} bytes ({d:.2} GiB)\n", .{ label, blocks, bytes, gib });
}

/// What `serve` was asked to do beyond the image path.
const ServeOptions = struct {
    /// Open the image read only and set the read-only bit of the card.
    read_only: bool,
    /// Print the counters and the rate when the loop stops.
    stats: bool,
    /// Blocks to fill into the card cache after each read.
    read_ahead: u16 = DEFAULT_READ_AHEAD,
};

/// Set by the stop signal handler.
///
/// A signal handler is dispatched by the kernel and cannot take a context
/// parameter, so this state is global. IronStyle allows exactly this shape:
/// minimal state, written by the handler, read by the main loop. It is the
/// only global in the CLI.
var stop_requested = std.atomic.Value(bool).init(false);

fn onStopSignal(_: std.posix.SIG) callconv(.c) void {
    stop_requested.store(true, .monotonic);
}

/// Catches SIGINT and SIGTERM, so the loop stops between passes.
///
/// SA_RESTART is set on purpose. Without it the signal would break the USB
/// transfer that is in flight, and the operator would see a transport
/// failure instead of a clean stop.
fn installStopHandler() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = onStopSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

/// Opens the disk image that the card serves.
///
/// Read-write is the default, because the write path of the card will put
/// the blocks of the host back into this file. `--ro` opens it read only,
/// which also makes the open fail on an image that the operator cannot
/// read, instead of failing later on the first block.
fn openImage(io: Io, dir: Io.Dir, path: []const u8, read_only: bool) !Io.File {
    const mode: Io.File.OpenFlags.Mode = if (read_only) .read_only else .read_write;
    return dir.openFile(io, path, .{ .mode = mode });
}

/// Backs the emulated card with a disk image until a signal stops the loop.
///
/// The order matters. The size of the card is published before the card
/// turns on, so a host that enumerates at once never reads a stale CSD. The
/// card turns off before this returns, so a host that is in the middle of a
/// transfer sees the card go away instead of waiting for a block that
/// nothing will send.
fn cmdServe(
    io: Io,
    device: Device,
    out: *Io.Writer,
    plan: CapacityPlan,
    path: []const u8,
    options: ServeOptions,
) !void {
    const id = try device.regRead(sd.REG_ID);
    if (id != sd.ID_MAGIC) return error.BadIdMagic;

    const file = try openImage(io, .cwd(), path, options.read_only);
    defer file.close(io);

    _ = try applyCapacity(device, out, plan);

    // The interface wants a mutable transport, and a copy of the transport
    // holds the same io and the same USB handle.
    var owned = device;
    var server: serve.Server = .{
        .device = owned.device(),
        .image = .{
            .io = io,
            .file = file,
            .blocks = plan.advertised_blocks,
            .read_only = options.read_only,
        },
        .log = out,
        .options = .{
            .read_ahead = options.read_ahead,
            // The CLI drives real silicon, where a read of DATA_IN_COUNT
            // is a USB round trip and the channel drains on the SD clock.
            // See `serve.CLI_SPACE_POLL_WAIT_US`.
            .space_poll_wait_us = serve.CLI_SPACE_POLL_WAIT_US,
        },
    };
    try server.publishCapacity();

    // The line count of the card cache is a build parameter of the
    // gateware, so it is READ and never assumed. The host model of what
    // the card holds is sized from it, and a card that reports a count the
    // model cannot hold turns the model off rather than model it wrong.
    try server.learnCache();

    // Learn the full input credit while the card is still off. The first
    // SD read then spends known-safe space instead of waiting for another
    // USB register round trip on its critical path.
    try server.learnDataInCredit();

    // An earlier run that stopped between the block and the acknowledgement
    // left the 512 bytes of that block on the write channel, and the card
    // still counts one block that nobody took. Nothing clears that by
    // itself, so the card would refuse every write of this run. The drain
    // comes BEFORE the card turns on, so no block of this run can be in
    // flight while it happens.
    const dropped = try server.resyncWriteChannel();
    if (dropped != 0) {
        try out.print(
            "WARNING: dropped {d} words that an earlier run left on the write channel\n",
            .{dropped},
        );
    }

    try server.enable();
    errdefer server.disable() catch {};

    installStopHandler();
    try printCapacity(out, "serving", plan.advertised_blocks);
    try out.print("image: {s}{s}\n", .{ path, if (options.read_only) " (read only)" else "" });
    try out.print("cache: {d} lines on the card, read ahead {d} blocks\n", .{
        server.cache.lines,
        options.read_ahead,
    });
    try out.print("press ctrl-c to stop\n", .{});
    try out.flush();

    const start = Io.Clock.Timestamp.now(io, .awake);
    while (!stop_requested.load(.monotonic)) {
        // The poll is a USB round trip of its own, so an idle loop paces
        // itself on the link and does not spin on the CPU.
        const taken = try server.servePending();
        if (taken == 0) {
            try server.continueReadAhead();
            io.sleep(Io.Duration.fromMicroseconds(serve.CLI_IDLE_POLL_WAIT_US), .awake) catch {};
        }
        if (taken != 0) try out.flush();
    }

    server.disable() catch |e| {
        try out.print("WARNING: the card did not turn off: {s}\n", .{@errorName(e)});
    };
    try out.print("\nstopped\n", .{});
    if (options.stats) {
        try printServeStats(io, out, server.stats, start);
        // The card counts its own hits and misses in the SD clock domain,
        // so the hit rate comes from the card and not from a guess on this
        // side. A read of these addresses has no side effect.
        printCacheStats(out, device) catch |e| {
            try out.print("WARNING: the cache counters could not be read: {s}\n", .{@errorName(e)});
        };
    }

    // A refusal means the card asked for a block that this image does not
    // have, which is a fault of the gateware and not of the operator.
    if (server.stats.refused != 0) {
        try out.print("WARNING: {d} requests were refused, see the lines above\n", .{server.stats.refused});
    }

    // EVENT carries the error bits of the card. No bit of it drives this
    // loop, so it is reported raw and the operator decodes it against the
    // gateware.
    const event = try device.regRead(sd.REG_EVENT);
    if (event != 0) try out.print("EVENT = 0x{X:0>8}\n", .{event});
}

/// Prints what the serve loop moved and how fast it moved it.
fn printServeStats(io: Io, out: *Io.Writer, stats: serve.Stats, start: Io.Clock.Timestamp) !void {
    const elapsed_ns: u64 = @intCast(start.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds);
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    const bytes = stats.bytes();
    try out.print("stats: {d} requests, {d} blocks, {d} bytes, {d} refused, {d} polls\n", .{
        stats.requests,
        stats.blocks,
        bytes,
        stats.refused,
        stats.polls,
    });
    try out.print("stats: {d} blocks written, {d} blocks dropped\n", .{
        stats.written,
        stats.dropped,
    });
    try out.print("stats: {d} fills, {d} fills skipped, {d} model resets\n", .{
        stats.fills,
        stats.fills_skipped,
        stats.model_resets,
    });
    // The two reasons a read ahead was dropped say different things. A
    // card that was BUSY was already holding a record, so the fill would
    // have delayed the block the host was reading. NO ROOM says the data
    // channel is too shallow for the read ahead depth that is set.
    try out.print("stats: read ahead dropped: {d} card busy, {d} no room\n", .{
        stats.ahead_deferred_busy,
        stats.ahead_deferred_space,
    });
    // A run that served nothing has no rate to report, and dividing by a
    // zero elapsed time would print an infinity.
    if (elapsed_s <= 0) return;
    const kib_per_s = @as(f64, @floatFromInt(bytes)) / elapsed_s / 1024.0;
    const blocks_per_s = @as(f64, @floatFromInt(stats.blocks)) / elapsed_s;
    try out.print("stats: {d:.3}s, {d:.1} KiB/s, {d:.0} blocks/s\n", .{
        elapsed_s,
        kib_per_s,
        blocks_per_s,
    });
}

/// Prints the hit, miss and fill counters of the card cache.
///
/// The counters live on the CARD, because only the card can see a read
/// that it answered by itself: a hit posts no record, so nothing of it
/// reaches this side. They wrap at 16 bits, so a long run reports a
/// remainder and not a total, and the RATIO is what a reader wants.
fn printCacheStats(out: *Io.Writer, device: Device) !void {
    const hits = try device.regRead(sd.REG_DBG_CACHE_HIT);
    const misses = try device.regRead(sd.REG_DBG_CACHE_MISS);
    const fills = try device.regRead(sd.REG_DBG_CACHE_FILL);
    try out.print("cache: {d} hits, {d} misses, {d} lines filled\n", .{
        hits,
        misses,
        fills,
    });
    const reads = hits + misses;
    if (reads == 0) return;
    const rate = @as(f64, @floatFromInt(hits)) * 100.0 /
        @as(f64, @floatFromInt(reads));
    try out.print("cache: {d:.1}% of reads cost no round trip\n", .{rate});
}

/// Prints `error: <name>` plus a human hint, then exits 1. Flushes by hand:
/// std.process.exit skips the writer defer. The print failures are ignored
/// because there is no recovery left on this path; exit code 1 still signals
/// the failure.
fn fail(out: *Io.Writer, err: anyerror) noreturn {
    out.print("error: {s}\n", .{@errorName(err)}) catch {};
    out.print("hint: {s}\n", .{hint(err)}) catch {};
    out.flush() catch {};
    std.process.exit(1);
}

fn hint(err: anyerror) []const u8 {
    return switch (err) {
        error.DeviceNotFound => "no mimic device on USB (VID 1209, PID 10C1); is the FPGA attached and programmed?",
        error.NoBulkEndpoints => "the device enumerated without bulk endpoints; an enumeration-only bitstream is flashed, flash the full build instead",
        error.InterfaceBusy => "another process holds the USB claim on interface 0, or a kernel driver is bound; close it and retry",
        error.AccessDenied => "the USB node or the claim was denied; check udev permissions on /dev/bus/usb",
        error.ClaimFailed => "could not claim USB interface 0",
        error.Timeout => "a bulk transfer timed out; the device stopped responding",
        error.EndpointStalled => "the device stalled a bulk endpoint; the bitstream hit a protocol error, power cycle and reflash",
        error.NoEndpoint => "usbfs rejected the bulk endpoint; the flashed bitstream exposes no bulk endpoints",
        error.DeviceGone => "the device disconnected during a transfer; the USB link dropped",
        error.LinkError => "the USB link reported low level errors; check the wiring and the bitstream",
        error.BulkFailed => "a bulk transfer failed; the USB link is unstable",
        error.BadIdMagic => "the ID register does not report the MIMC magic; wrong bitstream?",
        error.BadVersion => "the VERSION register does not match this runtime; reflash a matching bitstream",
        error.CsdReadBackMismatch => "the CSD registers did not read back what was written; the CSD block is missing from the bitstream, or the link dropped a write",
        error.GrowNeedsImage => "--grow appends zeros to an image file, so give a path and not a block count",
        error.CapacityTooSmall => "the image holds less than one CSD capacity step of 1024 blocks (512 KiB); use a larger image",
        error.CapacityNotAligned => "the block count is not a multiple of 1024, which the CSD cannot express",
        error.CapacityTooLarge => "C_SIZE is 22 bits, so a version 2.0 CSD reports at most 2 TiB",
        error.FileNotFound => "no such image file",
        error.IsDir => "the capacity argument is a directory, give an image file or a block count",
        error.NumBlocksTooLarge => "the image holds more blocks than the 32 bits of NUM_BLOCKS hold, which caps a card at 2 TiB minus 512 bytes",
        error.BlockOutOfRange => "the card asked for a block above the size that it reports; the gateware and the CSD disagree",
        error.ShortImageRead => "the image gave back less than a whole block; it was truncated while the runtime was serving it",
        error.DataInFull => "the DATA_IN FIFO never made room; the device stopped draining it, so the card or the USB engine is stuck",
        error.NotOpenForWriting => "the image is open read only; drop --ro to let the card write to it",
        else => "unexpected failure",
    };
}

fn usage(io: Io, err: ?[]const u8) !void {
    var buf: [512]u8 = undefined;
    var w = Io.File.stderr().writer(io, &buf);
    const out = &w.interface;
    defer out.flush() catch {};
    if (err) |e| try out.print("error: {s}\n\n", .{e});
    try out.print(
        \\mimic-cli: drive the SD card mimic.
        \\
        \\usage: mimic-cli <command> [argument]
        \\
        \\commands:
        \\  help     print this usage
        \\  version  read ID and VERSION, verify the MIMC magic
        \\  probe    SCRATCH round trips + burst reads, print stats
        \\  info     print the CSR map with CTRL bits decoded
        \\  capacity <image|blocks> [--grow]
        \\           build an SD CSD register and write it to CSD_0..CSD_3,
        \\           so the card reports that size. The argument is a path
        \\           to a disk image, or a plain 512-byte block count.
        \\
        \\           The CSD holds capacity in steps of 1024 blocks
        \\           (512 KiB). A size that is not a whole number of steps
        \\           rounds down and prints a warning, so the card never
        \\           claims more space than the image holds. --grow appends
        \\           zero bytes to the image instead, up to a whole block
        \\           and then up to a whole step, and reports the exact
        \\           size. --grow only ever makes an image larger.
        \\
        \\  serve <image> [--ro] [--grow] [--stats] [--read-ahead=N]
        \\           back the emulated card with a disk image. The command
        \\           sets the capacity from the size of the image, turns the
        \\           card on, and then answers every block that the card
        \\           asks for until ctrl-c stops it. The card is turned off
        \\           before the command exits.
        \\
        \\           The image opens read-write. --ro opens it read only and
        \\           sets the read-only bit of the card, so the host sees a
        \\           write protected card. --grow behaves as it does for
        \\           `capacity` and cannot go with --ro. --stats prints the
        \\           blocks served and the rate when the loop stops.
        \\
        \\           The card holds a cache of whole blocks, and a read it
        \\           holds costs no round trip at all. --read-ahead=N also
        \\           puts the N blocks AFTER each read into that cache, so
        \\           a host walking a file pays one round trip for N+1
        \\           blocks. The default is 3 and 0 turns it off.
        \\
        \\
    , .{});
}

/// Makes a test image of `bytes` bytes in `dir` and returns nothing. The
/// content is zeros, which is enough: only the size drives the CSD.
fn writeTestImage(dir: Io.Dir, name: []const u8, bytes: usize) !void {
    const file = try dir.createFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(std.testing.io, &buf);
    try writer.interface.splatByteAll(0, bytes);
    try writer.interface.flush();
}

fn testImageSize(dir: Io.Dir, name: []const u8) !u64 {
    const file = try dir.openFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    return (try file.stat(std.testing.io)).size;
}

test "capacityPlan takes a plain block count and rounds it down" {
    var out_buf: [1024]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    const plan = try capacityPlan(std.testing.io, .cwd(), &out, "5121", false);
    try std.testing.expectEqual(@as(u64, 5121), plan.source_blocks);
    try std.testing.expectEqual(@as(u64, 5120), plan.advertised_blocks);
    try std.testing.expectEqual(@as(u64, 1), plan.lost_blocks);
    try std.testing.expectEqual(@as(?u64, 5120), sd.csdCapacityBlocks(&plan.csd));
}

test "capacityPlan refuses --grow on a block count, because there is no file to grow" {
    var out_buf: [1024]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    try std.testing.expectError(
        error.GrowNeedsImage,
        capacityPlan(std.testing.io, .cwd(), &out, "5121", true),
    );
}

test "capacityPlan warns and never advertises more blocks than the image holds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 5121 blocks and 38 bytes over: one whole block and one part block sit
    // above the 5120 block step.
    const size = 5121 * sd.BLOCK_SIZE + 38;
    try writeTestImage(tmp.dir, "card.img", size);

    var out_buf: [2048]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    const plan = try capacityPlan(std.testing.io, tmp.dir, &out, "card.img", false);
    try std.testing.expectEqual(@as(u64, 5121), plan.source_blocks);
    try std.testing.expectEqual(@as(u64, 5120), plan.advertised_blocks);
    try std.testing.expectEqual(@as(u64, 1), plan.lost_blocks);
    try std.testing.expectEqual(@as(u64, 38), plan.partial_bytes);
    try std.testing.expectEqual(@as(u64, 0), plan.appended_bytes);
    try std.testing.expect(plan.advertised_blocks * sd.BLOCK_SIZE <= size);

    // The operator must see the counts and the way out.
    const text = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "holds 5121 whole blocks") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "38 bytes of a part block") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "report 5120 blocks") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1 blocks (550 bytes) at the end are unreachable") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--grow") != null);

    // The default path never changes the file.
    try std.testing.expectEqual(size, try testImageSize(tmp.dir, "card.img"));
}

test "capacityPlan with --grow pads a part block first and then a part step" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const size = 5121 * sd.BLOCK_SIZE + 38;
    try writeTestImage(tmp.dir, "card.img", size);

    var out_buf: [2048]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    const plan = try capacityPlan(std.testing.io, tmp.dir, &out, "card.img", true);
    // 474 bytes reach the end of block 5122, then 1022 blocks reach step
    // 6144. The image grows and the card reports every block of it.
    try std.testing.expectEqual(@as(u64, 474 + 1022 * sd.BLOCK_SIZE), plan.appended_bytes);
    try std.testing.expectEqual(@as(u64, 6144), plan.source_blocks);
    try std.testing.expectEqual(@as(u64, 6144), plan.advertised_blocks);
    try std.testing.expectEqual(@as(u64, 0), plan.lost_blocks);
    try std.testing.expectEqual(@as(u64, 0), plan.partial_bytes);
    try std.testing.expectEqual(@as(u64, 6144 * sd.BLOCK_SIZE), try testImageSize(tmp.dir, "card.img"));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "WARNING") == null);
}

test "capacityPlan with --grow is safe to run twice and leaves the image alone the second time" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(tmp.dir, "card.img", 5121 * sd.BLOCK_SIZE);

    var out_buf: [2048]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    const first = try capacityPlan(std.testing.io, tmp.dir, &out, "card.img", true);
    try std.testing.expectEqual(@as(u64, 1023 * sd.BLOCK_SIZE), first.appended_bytes);
    const grown_size = try testImageSize(tmp.dir, "card.img");

    var second_buf: [2048]u8 = undefined;
    var second_out: Io.Writer = .fixed(&second_buf);
    const second = try capacityPlan(std.testing.io, tmp.dir, &second_out, "card.img", true);
    try std.testing.expectEqual(@as(u64, 0), second.appended_bytes);
    try std.testing.expectEqual(first.advertised_blocks, second.advertised_blocks);
    try std.testing.expectEqual(grown_size, try testImageSize(tmp.dir, "card.img"));
    try std.testing.expect(std.mem.indexOf(u8, second_out.buffered(), "nothing to do") != null);
}

test "--grow keeps the bytes that the image already holds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A file that ends part way into a block. The pad must go after the
    // last byte and must not overwrite it.
    const size = 1024 * sd.BLOCK_SIZE + 3;
    {
        const file = try tmp.dir.createFile(std.testing.io, "card.img", .{});
        defer file.close(std.testing.io);
        var buf: [4096]u8 = undefined;
        var writer = file.writer(std.testing.io, &buf);
        try writer.interface.splatByteAll(0xA5, size);
        try writer.interface.flush();
    }

    var out_buf: [2048]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    const plan = try capacityPlan(std.testing.io, tmp.dir, &out, "card.img", true);
    try std.testing.expectEqual(@as(u64, 2048), plan.advertised_blocks);

    const file = try tmp.dir.openFile(std.testing.io, "card.img", .{});
    defer file.close(std.testing.io);
    var read_buf: [8]u8 = undefined;
    var reader = file.reader(std.testing.io, &read_buf);
    try reader.seekTo(size - 4);
    var tail: [8]u8 = undefined;
    try reader.interface.readSliceAll(&tail);
    try std.testing.expectEqualSlices(u8, &.{ 0xA5, 0xA5, 0xA5, 0xA5, 0, 0, 0, 0 }, &tail);
}

test "openImage with --ro refuses a path that it cannot read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(
        error.FileNotFound,
        openImage(std.testing.io, tmp.dir, "no-such.img", true),
    );
    // The default mode fails on the same path, so --ro is not what decides
    // whether a missing image is caught.
    try std.testing.expectError(
        error.FileNotFound,
        openImage(std.testing.io, tmp.dir, "no-such.img", false),
    );
}

test "an image opened with --ro cannot be written" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(tmp.dir, "card.img", sd.BLOCK_SIZE);

    const file = try openImage(std.testing.io, tmp.dir, "card.img", true);
    defer file.close(std.testing.io);
    try std.testing.expectError(
        error.NotOpenForWriting,
        file.writePositionalAll(std.testing.io, "spoiled", 0),
    );

    // The file still holds what it held before.
    var got: [sd.BLOCK_SIZE]u8 = undefined;
    try std.testing.expectEqual(got.len, try file.readPositionalAll(std.testing.io, &got, 0));
    for (got) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "openImage without --ro opens the image for writing" {
    // The write path of the card puts the blocks of the host back into this
    // file, so the default mode must allow a write.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(tmp.dir, "card.img", sd.BLOCK_SIZE);

    const file = try openImage(std.testing.io, tmp.dir, "card.img", false);
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, "mimic", 0);
    var got: [5]u8 = undefined;
    try std.testing.expectEqual(got.len, try file.readPositionalAll(std.testing.io, &got, 0));
    try std.testing.expectEqualStrings("mimic", &got);
}
