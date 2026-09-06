//! Mimic command protocol framing (pure, no IO).
//!
//! Wire format (little-endian):
//!   header = { opcode:u8, addr:u32, len:u16 }   (7 bytes)
//!   WRITE  (0x01): header then `len` data bytes. The address advances one
//!                   32-bit word per word written.
//!   READ   (0x02): header only. The device returns `len` raw bytes.
//!   STREAM (0x03): header then `len` data bytes. The address stays fixed,
//!                   so every 32-bit word pushes the same FIFO.

const std = @import("std");

pub const OP_WRITE: u8 = 0x01;
pub const OP_READ: u8 = 0x02;
pub const OP_STREAM: u8 = 0x03;

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
        OP_WRITE, OP_READ, OP_STREAM => true,
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
    try std.testing.expect(!knownOpcode(0x00));
    try std.testing.expect(!knownOpcode(0x04));
    try std.testing.expect(!knownOpcode(0xFF));
}
