//! Mimic command protocol framing (pure, no IO).
//!
//! Wire format (little-endian):
//!   header = { opcode:u8, addr:u32, len:u16 }   (7 bytes)
//!   WRITE  (0x01): header then `len` data bytes. The address advances one
//!                   32-bit word per word written.
//!   READ   (0x02): header only. The device returns `len` raw bytes.
//!   STREAM (0x03): header then `len` data bytes. The address stays fixed,
//!                   so every 32-bit word pushes the same FIFO.
//!   READ_POP_STREAM (0x04): header only. The low 16 address bits name the
//!                   data register and the high 16 bits name its explicit
//!                   pop register. The device reads one word, writes 1 to
//!                   the pop register, and returns the word. It repeats for
//!                   `len` bytes.
//!   READ_THEN_POP (0x05): header only, with addresses packed as above. The
//!                   device reads consecutive words and writes 1 to the pop
//!                   register once, after the final word. It then completes
//!                   the response.

const std = @import("std");

pub const OP_WRITE: u8 = 0x01;
pub const OP_READ: u8 = 0x02;
pub const OP_STREAM: u8 = 0x03;
pub const OP_READ_POP_STREAM: u8 = 0x04;
pub const OP_READ_THEN_POP: u8 = 0x05;

pub const HEADER_LEN: usize = 7;

/// One decoded command header. `len` counts payload bytes, not words.
pub const Header = struct {
    opcode: u8,
    addr: u32,
    len: u16,
};

/// Encodes a header into `buf`. The caller appends the payload. Returns the
/// header length. `buf.len` must be at least HEADER_LEN.
pub fn encodeHeader(buf: []u8, opcode: u8, addr: u32, len: u16) usize {
    std.debug.assert(buf.len >= HEADER_LEN);
    buf[0] = opcode;
    std.mem.writeInt(u32, buf[1..5], addr, .little);
    std.mem.writeInt(u16, buf[5..7], len, .little);
    return HEADER_LEN;
}

/// Encodes a WRITE header. The device advances `addr` one 32-bit word per
/// word in the payload.
pub fn encodeWriteHeader(buf: []u8, addr: u32, len: u16) usize {
    return encodeHeader(buf, OP_WRITE, addr, len);
}

/// Encodes a STREAM header. The device holds `addr` fixed, so the payload is
/// a run of pushes to one FIFO register.
pub fn encodeStreamHeader(buf: []u8, addr: u32, len: u16) usize {
    return encodeHeader(buf, OP_STREAM, addr, len);
}

/// Encodes a READ command (header only). The device answers with `len`
/// bytes.
pub fn encodeRead(buf: []u8, addr: u32, len: u16) usize {
    return encodeHeader(buf, OP_READ, addr, len);
}

/// Encodes an explicit FIFO read-and-pop command. Both addresses must fit in
/// 16 bits. The gateware reads `read_addr`, writes 1 to `pop_addr`, and only
/// then returns each word.
pub fn encodeReadPopStream(
    buf: []u8,
    read_addr: u32,
    pop_addr: u32,
    len: u16,
) usize {
    std.debug.assert(read_addr <= std.math.maxInt(u16));
    std.debug.assert(pop_addr <= std.math.maxInt(u16));
    const packed_addr = read_addr | (pop_addr << 16);
    return encodeHeader(buf, OP_READ_POP_STREAM, packed_addr, len);
}

/// Encodes a consecutive register read followed by one explicit pop. Both
/// addresses must fit in 16 bits.
pub fn encodeReadThenPop(
    buf: []u8,
    read_addr: u32,
    pop_addr: u32,
    len: u16,
) usize {
    std.debug.assert(read_addr <= std.math.maxInt(u16));
    std.debug.assert(pop_addr <= std.math.maxInt(u16));
    const packed_addr = read_addr | (pop_addr << 16);
    return encodeHeader(buf, OP_READ_THEN_POP, packed_addr, len);
}

/// Decodes a header. Performs no validation: the caller checks `opcode`
/// against the known set with `knownOpcode`.
pub fn decodeHeader(buf: *const [HEADER_LEN]u8) Header {
    return .{
        .opcode = buf[0],
        .addr = std.mem.readInt(u32, buf[1..5], .little),
        .len = std.mem.readInt(u16, buf[5..7], .little),
    };
}

/// True when `opcode` is one this runtime speaks.
pub fn knownOpcode(opcode: u8) bool {
    return switch (opcode) {
        OP_WRITE, OP_READ, OP_STREAM, OP_READ_POP_STREAM, OP_READ_THEN_POP => true,
        else => false,
    };
}

test "encodeWriteHeader lays out opcode, LE addr, LE len" {
    var buf: [HEADER_LEN]u8 = undefined;
    const n = encodeWriteHeader(&buf, 0x0100, 4);
    try std.testing.expectEqual(HEADER_LEN, n);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x00, 0x01, 0x00, 0x00, 0x04, 0x00 }, &buf);
}

test "encodeStreamHeader keeps the FIFO opcode" {
    var buf: [HEADER_LEN]u8 = undefined;
    _ = encodeStreamHeader(&buf, 0x0020, 8);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x03, 0x20, 0x00, 0x00, 0x00, 0x08, 0x00 }, &buf);
}

test "encodeRead lays out READ opcode for a CSR" {
    var buf: [HEADER_LEN]u8 = undefined;
    const n = encodeRead(&buf, 0x0004, 4);
    try std.testing.expectEqual(HEADER_LEN, n);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00 }, &buf);
}

test "encodeReadPopStream packs the read and pop addresses" {
    var buf: [HEADER_LEN]u8 = undefined;
    _ = encodeReadPopStream(&buf, 0x28, 0x74, 512);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x04, 0x28, 0x00, 0x74, 0x00, 0x00, 0x02 },
        &buf,
    );
}

test "encodeReadThenPop packs the read and final pop addresses" {
    var buf: [HEADER_LEN]u8 = undefined;
    _ = encodeReadThenPop(&buf, 0x90, 0x70, 12);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x05, 0x90, 0x00, 0x70, 0x00, 0x0C, 0x00 },
        &buf,
    );
}

test "encodeHeader splits a wide address across the LE bytes" {
    var buf: [HEADER_LEN]u8 = undefined;
    _ = encodeHeader(&buf, OP_WRITE, 0xDEADBEEF, 0x1234);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0xEF, 0xBE, 0xAD, 0xDE, 0x34, 0x12 }, &buf);
}

test "decode inverts encode for every opcode" {
    const cases = [_]struct { opcode: u8, addr: u32, len: u16 }{
        .{ .opcode = OP_WRITE, .addr = 0x00000000, .len = 4 },
        .{ .opcode = OP_READ, .addr = 0x12345678, .len = 128 },
        .{ .opcode = OP_STREAM, .addr = 0x00000020, .len = 960 },
        .{ .opcode = OP_READ_POP_STREAM, .addr = 0x00740028, .len = 512 },
        .{ .opcode = OP_READ_THEN_POP, .addr = 0x00700090, .len = 12 },
    };
    for (cases) |c| {
        var buf: [HEADER_LEN]u8 = undefined;
        _ = encodeHeader(&buf, c.opcode, c.addr, c.len);
        const h = decodeHeader(&buf);
        try std.testing.expectEqual(c.opcode, h.opcode);
        try std.testing.expectEqual(c.addr, h.addr);
        try std.testing.expectEqual(c.len, h.len);
    }
}

test "knownOpcode accepts the protocol set and rejects the rest" {
    try std.testing.expect(knownOpcode(OP_WRITE));
    try std.testing.expect(knownOpcode(OP_READ));
    try std.testing.expect(knownOpcode(OP_STREAM));
    try std.testing.expect(knownOpcode(OP_READ_POP_STREAM));
    try std.testing.expect(knownOpcode(OP_READ_THEN_POP));
    try std.testing.expect(!knownOpcode(0x00));
    try std.testing.expect(!knownOpcode(0x06));
    try std.testing.expect(!knownOpcode(0xFF));
}
