//! The mimic.json manifest emitted by the Dart genip tool, parsed
//! field-for-field. The snake_case keys are the contract between the
//! generator and this runtime.

const std = @import("std");
const sd = @import("sd.zig");
const usb = @import("usb.zig");

/// How the device serves the SD card. Phase 1 has one mode.
pub const SdMode = enum { served };

/// The transport the bitstream exposes. Phase 1 has USB only.
pub const Transport = enum { usb };

/// The generated manifest (`mimic.json`).
pub const Manifest = struct {
    name: []const u8,
    /// Interface version as a dotted string, e.g. "1.0.0".
    interface_version: []const u8,
    /// The value the VERSION CSR reads: major << 16 | minor << 8 | patch.
    version_reg: u32,
    vid: u16,
    pid: u16,
    cache_blocks: u32,
    sd_mode: SdMode,
    csr_base: u32,
    transport: Transport,
};

/// Parses mimic.json bytes. Strings are copied into the parser arena
/// (`alloc_always`), so the manifest stays valid after the caller frees the
/// source bytes. Call `deinit` on the returned value when done.
pub fn parse(gpa: std.mem.Allocator, json: []const u8) !std.json.Parsed(Manifest) {
    return std.json.parseFromSlice(Manifest, gpa, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

const sample_manifest =
    \\{ "name": "mimic", "interface_version": "1.0.0", "version_reg": 65536,
    \\  "vid": 4617, "pid": 4289, "cache_blocks": 8, "sd_mode": "served",
    \\  "csr_base": 0, "transport": "usb" }
;

test "parse reads every manifest field" {
    var parsed = try parse(std.testing.allocator, sample_manifest);
    defer parsed.deinit();
    const m = parsed.value;
    try std.testing.expectEqualStrings("mimic", m.name);
    try std.testing.expectEqualStrings("1.0.0", m.interface_version);
    try std.testing.expectEqual(@as(u32, 65536), m.version_reg);
    try std.testing.expectEqual(@as(u16, 4617), m.vid);
    try std.testing.expectEqual(@as(u16, 4289), m.pid);
    try std.testing.expectEqual(@as(u32, 8), m.cache_blocks);
    try std.testing.expectEqual(SdMode.served, m.sd_mode);
    try std.testing.expectEqual(@as(u32, 0), m.csr_base);
    try std.testing.expectEqual(Transport.usb, m.transport);
}

test "manifest values match the CSR and USB constants" {
    // The manifest is a contract: version_reg must equal the value the
    // VERSION CSR reads, and vid/pid must equal the device this runtime
    // scans for.
    var parsed = try parse(std.testing.allocator, sample_manifest);
    defer parsed.deinit();
    const m = parsed.value;
    try std.testing.expectEqual(sd.INTERFACE_VERSION, m.version_reg);
    try std.testing.expectEqual(usb.VID, m.vid);
    try std.testing.expectEqual(usb.PID, m.pid);
    try std.testing.expectEqual(sd.CSR_BASE, m.csr_base);
}

test "parse rejects a manifest with an unknown transport" {
    const bad =
        \\{ "name": "mimic", "interface_version": "1.0.0", "version_reg": 65536,
        \\  "vid": 4617, "pid": 4289, "cache_blocks": 8, "sd_mode": "served",
        \\  "csr_base": 0, "transport": "uart" }
    ;
    try std.testing.expectError(error.InvalidEnumTag, parse(std.testing.allocator, bad));
}
