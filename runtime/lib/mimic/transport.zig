//! Transport-level mimic device access over USB. The register and stream
//! protocol logic lives here once, behind the burst discipline the device
//! expects; usb.zig only moves bytes.

const std = @import("std");
const Io = std.Io;
const proto = @import("protocol.zig");
const usb = @import("usb.zig");
const sd = @import("sd.zig");
const Iface = @import("device.zig").Device;
const WriteStreamGroup = @import("device.zig").WriteStreamGroup;

pub const Device = struct {
    io: Io,
    usb: usb.Device,

    pub fn openUsb(io: Io) !Device {
        return .{ .io = io, .usb = try usb.Device.open(io) };
    }

    pub fn close(self: Device) void {
        self.usb.close(self.io);
    }

    fn writeFrame(self: Device, bytes: []u8) !void {
        try self.usb.writeFrame(bytes);
    }

    fn readResponse(self: Device, buf: []u8) !void {
        try self.usb.readResponse(buf);
    }

    pub fn regWrite(self: Device, addr: u32, value: u32) !void {
        var frame: [proto.HEADER_LEN + 4]u8 = undefined;
        _ = proto.encodeWriteHeader(frame[0..proto.HEADER_LEN], addr, 4);
        std.mem.writeInt(u32, frame[proto.HEADER_LEN..][0..4], value, .little);
        try self.writeFrame(&frame);
    }

    /// Frames per write burst. 92 * 11 = 1012 bytes, roughly 1KB, sized to
    /// stay inside one USB bulk transfer with room to drain.
    const BURST_FRAMES = 92;

    /// Coalesces many single-word writes `{addr, value}` into few USB
    /// transactions. Each `regWrite` alone is a USB round trip, so a long
    /// setup sequence costs one round trip per register. Packing the frames
    /// into ~1KB bursts and syncing with one barrier read between bursts
    /// collapses that. The device sees the identical byte stream either way.
    /// Same-address writes (FIFO pushes) keep their order.
    pub fn writeRegs(self: Device, pairs: []const [2]u32) !void {
        const FRAME = proto.HEADER_LEN + 4;
        var buf: [BURST_FRAMES * FRAME]u8 = undefined;
        var i: usize = 0;
        while (i < pairs.len) {
            const n = @min(BURST_FRAMES, pairs.len - i);
            var off: usize = 0;
            for (pairs[i .. i + n]) |p| {
                _ = proto.encodeWriteHeader(buf[off..][0..proto.HEADER_LEN], p[0], 4);
                std.mem.writeInt(u32, buf[off + proto.HEADER_LEN ..][0..4], p[1], .little);
                off += FRAME;
            }
            try self.writeFrame(buf[0..off]);
            i += n;
            // Barrier between bursts: a pure read returns only once the
            // device has drained everything sent so far, so the next burst
            // cannot outrun it. The last burst needs none.
            if (i < pairs.len) _ = try self.regRead(sd.REG_ID);
        }
    }

    pub fn regRead(self: Device, addr: u32) !u32 {
        var hdr: [proto.HEADER_LEN]u8 = undefined;
        _ = proto.encodeRead(&hdr, addr, 4);
        try self.writeFrame(&hdr);
        var resp: [4]u8 = undefined;
        try self.readResponse(&resp);
        return std.mem.readInt(u32, &resp, .little);
    }

    /// Words per streaming burst. Four SD blocks fit in one USB transaction,
    /// which matches the whole DATA_IN channel.
    const STREAM_WORDS: usize = 512;
    const MAX_STREAM_GROUPS: usize = 4;

    /// Streams `values` as FIFO pushes to the fixed `addr` (opcode 0x03):
    /// one 7-byte header, then the values as 32-bit LE words, so N pushes
    /// cost one header instead of N. Chunked into ~1KB bursts with a barrier
    /// read between them. The device keeps pushing across chunks; the FIFO
    /// accumulates them.
    pub fn writeStream(self: Device, addr: u32, values: []const u32) !void {
        var buf: [proto.HEADER_LEN + STREAM_WORDS * 4]u8 = undefined;
        var i: usize = 0;
        while (i < values.len) {
            const n: usize = @min(STREAM_WORDS, values.len - i);
            const nbytes: usize = n * 4; // compute in usize, then narrow to the u16 len
            _ = proto.encodeStreamHeader(buf[0..proto.HEADER_LEN], addr, @intCast(nbytes));
            var off: usize = proto.HEADER_LEN;
            for (values[i .. i + n]) |v| {
                std.mem.writeInt(u32, buf[off..][0..4], v, .little);
                off += 4;
            }
            try self.writeFrame(buf[0..off]);
            i += n;
            if (i < values.len) _ = try self.regRead(sd.REG_ID); // barrier
        }
    }

    /// Writes setup registers and one FIFO stream in one bulk transfer.
    /// The USB command parser consumes concatenated frames in order, so the
    /// register values are visible before the first streamed word arrives.
    /// This is the cold read path: keeping the tag and its block in one
    /// transfer removes one host scheduling round trip per SD block.
    pub fn writeRegsStreamRegs(
        self: Device,
        before: []const [2]u32,
        addr: u32,
        values: []const u32,
        after: []const [2]u32,
    ) !void {
        if (before.len + after.len > BURST_FRAMES or values.len > STREAM_WORDS) {
            return error.TransactionTooLarge;
        }

        const WRITE_FRAME = proto.HEADER_LEN + 4;
        var buf: [BURST_FRAMES * WRITE_FRAME + proto.HEADER_LEN + STREAM_WORDS * 4]u8 = undefined;
        var off: usize = 0;
        for (before) |pair| {
            _ = proto.encodeWriteHeader(buf[off..][0..proto.HEADER_LEN], pair[0], 4);
            std.mem.writeInt(u32, buf[off + proto.HEADER_LEN ..][0..4], pair[1], .little);
            off += WRITE_FRAME;
        }

        const stream_bytes = values.len * 4;
        _ = proto.encodeStreamHeader(buf[off..][0..proto.HEADER_LEN], addr, @intCast(stream_bytes));
        off += proto.HEADER_LEN;
        for (values) |value| {
            std.mem.writeInt(u32, buf[off..][0..4], value, .little);
            off += 4;
        }
        for (after) |pair| {
            _ = proto.encodeWriteHeader(buf[off..][0..proto.HEADER_LEN], pair[0], 4);
            std.mem.writeInt(u32, buf[off + proto.HEADER_LEN ..][0..4], pair[1], .little);
            off += WRITE_FRAME;
        }
        try self.writeFrame(buf[0..off]);
    }

    /// Sends a bounded group of register setup and FIFO streams as one USB
    /// transfer. The command parser keeps frame order while the endpoint
    /// applies backpressure, so the host pays one scheduling round trip for
    /// the complete group.
    pub fn writeStreamGroups(
        self: Device,
        groups: []const WriteStreamGroup,
    ) !void {
        if (groups.len == 0) return;
        if (groups.len > MAX_STREAM_GROUPS) return error.TransactionTooLarge;

        const WRITE_FRAME = proto.HEADER_LEN + 4;
        var buf: [
            BURST_FRAMES * WRITE_FRAME +
                MAX_STREAM_GROUPS * proto.HEADER_LEN + STREAM_WORDS * 4
        ]u8 = undefined;
        var off: usize = 0;
        var pairs: usize = 0;
        var stream_words: usize = 0;
        for (groups) |group| {
            pairs += group.before.len + group.after.len;
            stream_words += group.values.len;
            if (pairs > BURST_FRAMES or stream_words > STREAM_WORDS) {
                return error.TransactionTooLarge;
            }
            for (group.before) |pair| {
                _ = proto.encodeWriteHeader(buf[off..][0..proto.HEADER_LEN], pair[0], 4);
                std.mem.writeInt(u32, buf[off + proto.HEADER_LEN ..][0..4], pair[1], .little);
                off += WRITE_FRAME;
            }
            const stream_bytes = group.values.len * 4;
            _ = proto.encodeStreamHeader(
                buf[off..][0..proto.HEADER_LEN],
                group.addr,
                @intCast(stream_bytes),
            );
            off += proto.HEADER_LEN;
            for (group.values) |value| {
                std.mem.writeInt(u32, buf[off..][0..4], value, .little);
                off += 4;
            }
            for (group.after) |pair| {
                _ = proto.encodeWriteHeader(buf[off..][0..proto.HEADER_LEN], pair[0], 4);
                std.mem.writeInt(u32, buf[off + proto.HEADER_LEN ..][0..4], pair[1], .little);
                off += WRITE_FRAME;
            }
        }
        try self.writeFrame(buf[0..off]);
    }

    /// Words per READ frame. 32 words = 128 bytes.
    ///
    /// This was 8 words. Reads of 9 or more words corrupted the response
    /// on real hardware, and the cause looked analog, because the full
    /// USB path simulation passed every size. The cause was the device.
    /// The old gateware told the host that its packets were 64 bytes
    /// while the endpoint buffer was smaller, so a longer response
    /// overran the buffer. The ported tinyfpga core declares 32 bytes,
    /// which is the true buffer size, so the host now splits a long
    /// response into correct packets. Reads of 16 and 32 words were
    /// measured on hardware with no errors.
    const MAX_READ_WORDS: usize = 32;

    /// Reads `words.len` consecutive 32-bit words from `addr` in as few READ
    /// round trips as the frame size allows. The device advances the address
    /// per 32-bit word within one frame.
    pub fn readRegs(self: Device, addr: u32, words: []u32) !void {
        var off: usize = 0;
        while (off < words.len) {
            const n: usize = @min(@as(usize, MAX_READ_WORDS), words.len - off);
            const rd_addr: u32 = addr + @as(u32, @intCast(off)) * 4;
            const rd_len: u16 = @as(u16, @intCast(n)) * 4;
            var hdr: [proto.HEADER_LEN]u8 = undefined;
            _ = proto.encodeRead(&hdr, rd_addr, rd_len);
            try self.writeFrame(&hdr);
            var buf: [MAX_READ_WORDS * 4]u8 = undefined;
            try self.readResponse(buf[0 .. n * 4]);
            for (0..n) |i| words[off + i] = std.mem.readInt(u32, buf[i * 4 ..][0..4], .little);
            off += n;
        }
    }

    /// Reads consecutive CSR words and performs one explicit pop after the
    /// final word. The response completes only after the pop is accepted.
    pub fn readRegsPop(
        self: Device,
        addr: u32,
        pop_addr: u32,
        words: []u32,
    ) !void {
        if (words.len == 0 or words.len > MAX_READ_WORDS) {
            return error.TransactionTooLarge;
        }
        const len: u16 = @intCast(words.len * 4);
        var hdr: [proto.HEADER_LEN]u8 = undefined;
        _ = proto.encodeReadThenPop(&hdr, addr, pop_addr, len);
        try self.writeFrame(&hdr);
        var buf: [MAX_READ_WORDS * 4]u8 = undefined;
        try self.readResponse(buf[0 .. words.len * 4]);
        for (words, 0..) |*word, i| {
            word.* = std.mem.readInt(u32, buf[i * 4 ..][0..4], .little);
        }
    }

    /// Reads and explicitly pops `words.len` words from DATA_OUT.
    ///
    /// One command tells the gateware both addresses. For every word, the
    /// gateware reads DATA_OUT and then writes the pop bit to DATA_OUT_POP
    /// before it returns the word. Ordinary READ commands and CSR reads keep
    /// their no-side-effect rule.
    pub fn readStream(self: Device, addr: u32, words: []u32) !void {
        if (addr != sd.REG_DATA_OUT) return error.UnexpectedStreamAddress;
        var off: usize = 0;
        while (off < words.len) {
            const n: usize = @min(@as(usize, MAX_READ_WORDS), words.len - off);
            const len: u16 = @intCast(n * 4);
            var hdr: [proto.HEADER_LEN]u8 = undefined;
            _ = proto.encodeReadPopStream(
                &hdr,
                sd.REG_DATA_OUT,
                sd.REG_DATA_OUT_POP,
                len,
            );
            try self.writeFrame(&hdr);
            var buf: [MAX_READ_WORDS * 4]u8 = undefined;
            try self.readResponse(buf[0 .. n * 4]);
            for (0..n) |i| {
                words[off + i] = std.mem.readInt(u32, buf[i * 4 ..][0..4], .little);
            }
            off += n;
        }
    }

    /// Erases this concrete transport into the caller-facing `Device`
    /// interface.
    pub fn device(self: *Device) Iface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn cast(ptr: *anyopaque) *Device {
        return @ptrCast(@alignCast(ptr));
    }
    const vtable = Iface.VTable{
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
            fn f(p: *anyopaque, pairs: []const [2]u32) anyerror!void {
                return cast(p).writeRegs(pairs);
            }
        }.f,
        .read_regs = struct {
            fn f(p: *anyopaque, a: u32, w: []u32) anyerror!void {
                return cast(p).readRegs(a, w);
            }
        }.f,
        .read_regs_pop = struct {
            fn f(p: *anyopaque, a: u32, pop: u32, w: []u32) anyerror!void {
                return cast(p).readRegsPop(a, pop, w);
            }
        }.f,
        .write_stream = struct {
            fn f(p: *anyopaque, a: u32, vals: []const u32) anyerror!void {
                return cast(p).writeStream(a, vals);
            }
        }.f,
        .write_regs_stream_regs = struct {
            fn f(
                p: *anyopaque,
                before: []const [2]u32,
                a: u32,
                vals: []const u32,
                after: []const [2]u32,
            ) anyerror!void {
                return cast(p).writeRegsStreamRegs(before, a, vals, after);
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
    };
};
