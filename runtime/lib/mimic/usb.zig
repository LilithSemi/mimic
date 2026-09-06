//! USB transport for the mimic command protocol over the custom vendor
//! device (VID 0x1209, PID 0x10C1, bulk EP1 OUT 0x01 / EP1 IN 0x81, 32-byte
//! max packets).
//!
//! The device is found by scanning /sys/bus/usb/devices with std.Io, then the
//! /dev/bus/usb node is opened with std.Io and driven with usbfs ioctls (the
//! one thing std.Io does not model).
//!
//! Every failure maps to a named error that says what went wrong: a busy
//! claim, a denied claim, a stalled endpoint, a missing endpoint, a gone
//! device, or a timed out transfer. The common case of a wrong bitstream is
//! caught up front: an enumeration-only build reports no bulk endpoints, and
//! bulk traffic to it can only fail, so the scan reports that cause instead.

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;

pub const VID: u16 = 0x1209;
pub const PID: u16 = 0x10C1;
pub const EP_OUT: u8 = 0x01;
pub const EP_IN: u8 = 0x81;
const INTERFACE: u32 = 0;
const TIMEOUT_MS: u32 = 2000;

/// Bulk endpoint maximum packet size, in bytes. This is the wMaxPacketSize
/// the device reports for EP1 OUT and EP1 IN. The ported tinyfpga endpoint
/// buffer sets the ceiling, so the value cannot go above 32.
const MAX_PACKET: usize = 32;
const SYS_DEVICES = "/sys/bus/usb/devices";

pub const Error = error{
    DeviceNotFound,
    NoBulkEndpoints,
    InterfaceBusy,
    AccessDenied,
    ClaimFailed,
    Timeout,
    EndpointStalled,
    NoEndpoint,
    DeviceGone,
    LinkError,
    BulkFailed,
};

// _IOC encoding (asm-generic): (dir<<30)|(size<<16)|(type<<8)|nr.
const IOC_WRITE: u32 = 1;
const IOC_READ: u32 = 2;
fn ioc(dir: u32, ty: u32, nr: u32, size: u32) u32 {
    return (dir << 30) | (size << 16) | (ty << 8) | nr;
}

const BulkTransfer = extern struct {
    ep: c_uint,
    len: c_uint,
    timeout: c_uint, // milliseconds
    data: ?*anyopaque,
};

const USBDEVFS_BULK: u32 = ioc(IOC_READ | IOC_WRITE, 'U', 2, @sizeOf(BulkTransfer));
const USBDEVFS_CLAIMINTERFACE: u32 = ioc(IOC_READ, 'U', 15, 4);
const USBDEVFS_RELEASEINTERFACE: u32 = ioc(IOC_READ, 'U', 16, 4);

/// One ioctl call: the raw result or the errno.
const IoctlResult = union(enum) {
    ok: usize,
    err: std.posix.E,
};

fn ioctl(fd: std.posix.fd_t, request: u32, arg: usize) IoctlResult {
    const rc = linux.ioctl(fd, request, arg);
    const e = std.posix.errno(rc);
    if (e == .SUCCESS) return .{ .ok = @intCast(rc) };
    return .{ .err = e };
}

pub const Device = struct {
    file: Io.File,

    /// Finds and opens the mimic vendor device, claiming its interface.
    pub fn open(io: Io) !Device {
        var path_buf: [64]u8 = undefined;
        const path = try findNode(io, &path_buf);
        const file = try Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write });
        errdefer file.close(io);

        var intf: u32 = INTERFACE;
        switch (ioctl(file.handle, USBDEVFS_CLAIMINTERFACE, @intFromPtr(&intf))) {
            .ok => {},
            .err => |e| return switch (e) {
                .BUSY => Error.InterfaceBusy,
                .ACCES, .PERM => Error.AccessDenied,
                else => Error.ClaimFailed,
            },
        }
        return .{ .file = file };
    }

    pub fn close(self: Device, io: Io) void {
        // Release only fails when the claim is already gone (bad fd, no
        // claim), which is the state close wants. The close below drops the
        // claim at the kernel side regardless, so the result is ignored.
        var intf: u32 = INTERFACE;
        _ = switch (ioctl(self.file.handle, USBDEVFS_RELEASEINTERFACE, @intFromPtr(&intf))) {
            .ok, .err => {},
        };
        self.file.close(io);
    }

    fn bulk(self: Device, ep: u8, data: []u8) !usize {
        var bt = BulkTransfer{
            .ep = ep,
            .len = @intCast(data.len),
            .timeout = TIMEOUT_MS,
            .data = if (data.len == 0) null else @ptrCast(data.ptr),
        };
        switch (ioctl(self.file.handle, USBDEVFS_BULK, @intFromPtr(&bt))) {
            .ok => |n| return n,
            .err => |e| return switch (e) {
                .TIMEDOUT => Error.Timeout,
                .PIPE => Error.EndpointStalled,
                .INVAL => Error.NoEndpoint,
                .NODEV, .NXIO, .SHUTDOWN => Error.DeviceGone,
                .IO, .OVERFLOW, .ILSEQ => Error.LinkError,
                else => Error.BulkFailed,
            },
        }
    }

    /// Sends a whole command frame in one bulk-OUT transfer. The buffer must
    /// be mutable: usbfs takes a plain pointer for the transfer data.
    ///
    /// A transfer that ends on a packet boundary gets a zero-length packet
    /// to close it. See [needsZeroPacket]. USBDEVFS_BULK has no flags
    /// field, so the URB_ZERO_PACKET flag is not available here and the
    /// packet goes out by hand.
    pub fn writeFrame(self: Device, bytes: []u8) !void {
        _ = try self.bulk(EP_OUT, bytes);
        if (needsZeroPacket(bytes.len)) {
            var empty: [0]u8 = .{};
            _ = try self.bulk(EP_OUT, &empty);
        }
    }

    /// Reads exactly `buf.len` response bytes from a single bulk-IN transfer.
    /// A short transfer is a failure, not a partial result.
    pub fn readResponse(self: Device, buf: []u8) !void {
        const n = try self.bulk(EP_IN, buf);
        if (n != buf.len) return Error.BulkFailed;
    }
};

/// Scans /sys/bus/usb/devices for VID:PID and builds the /dev/bus/usb path.
/// A device that enumerates without bulk endpoints is an enumeration-only
/// bitstream, and bulk traffic to it can only fail, so it is reported here
/// as its own error.
fn findNode(io: Io, out: []u8) ![]const u8 {
    var sys = Io.Dir.openDirAbsolute(io, SYS_DEVICES, .{ .iterate = true }) catch
        return Error.DeviceNotFound;
    defer sys.close(io);

    var it = sys.iterate();
    while (it.next(io) catch return Error.DeviceNotFound) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const vid = readAttrInt(io, sys, u16, entry.name, "idVendor", 16) orelse continue;
        const pid = readAttrInt(io, sys, u16, entry.name, "idProduct", 16) orelse continue;
        if (vid != VID or pid != PID) continue;
        try checkBulkEndpoints(io, sys, entry.name);
        const bus = readAttrInt(io, sys, u32, entry.name, "busnum", 10) orelse continue;
        const num = readAttrInt(io, sys, u32, entry.name, "devnum", 10) orelse continue;
        return std.fmt.bufPrint(out, "/dev/bus/usb/{d:0>3}/{d:0>3}", .{ bus, num });
    }
    return Error.DeviceNotFound;
}

/// Reads bNumEndpoints of interface 0. A count below two means no bulk pair:
/// an enumeration-only build. The check is skipped when sysfs does not expose
/// the attribute, so odd layouts still open.
fn checkBulkEndpoints(io: Io, sys: Io.Dir, name: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    const rel = std.fmt.bufPrint(&path_buf, "{s}/{s}:1.0/bNumEndpoints", .{ name, name }) catch return;
    var buf: [32]u8 = undefined;
    const contents = sys.readFile(io, rel, &buf) catch return;
    const s = std.mem.trim(u8, contents, " \r\n\t");
    const n = std.fmt.parseInt(u16, s, 10) catch return;
    if (n < 2) return Error.NoBulkEndpoints;
}

/// Reads <name>/<attr> under the sysfs dir and parses an integer.
fn readAttrInt(io: Io, sys: Io.Dir, comptime T: type, name: []const u8, attr: []const u8, base: u8) ?T {
    var path_buf: [256]u8 = undefined;
    const rel = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ name, attr }) catch return null;
    var buf: [32]u8 = undefined;
    const contents = sys.readFile(io, rel, &buf) catch return null;
    const s = std.mem.trim(u8, contents, " \r\n\t");
    return std.fmt.parseInt(T, s, base) catch null;
}

/// True when a bulk-OUT transfer of `len` bytes ends exactly on a packet
/// boundary. Such a transfer has no short last packet, so the device sees
/// only full packets and cannot tell where the transfer stops. The caller
/// must then send a zero-length packet to close it.
///
/// The device reads a command as a stream that ends at a short packet. It
/// keeps its parse state across a full packet, because a full packet means
/// more data follows.
fn needsZeroPacket(len: usize) bool {
    return len != 0 and len % MAX_PACKET == 0;
}

test "needsZeroPacket closes only transfers that end on a packet boundary" {
    // An empty transfer is already a zero-length packet.
    try std.testing.expect(!needsZeroPacket(0));
    // Short last packet: the device sees the end.
    try std.testing.expect(!needsZeroPacket(1));
    try std.testing.expect(!needsZeroPacket(7));
    try std.testing.expect(!needsZeroPacket(MAX_PACKET - 1));
    try std.testing.expect(!needsZeroPacket(MAX_PACKET + 1));
    // Exact multiples need the closing packet. 352 and 704 are writeRegs
    // with 32 and 64 pairs, the sizes the runtime really sends.
    try std.testing.expect(needsZeroPacket(MAX_PACKET));
    try std.testing.expect(needsZeroPacket(MAX_PACKET * 2));
    try std.testing.expect(needsZeroPacket(352));
    try std.testing.expect(needsZeroPacket(704));
}

test "ioctl encodings match the kernel usbdevice_fs.h values" {
    try std.testing.expectEqual(@as(u32, 24), @sizeOf(BulkTransfer));
    try std.testing.expectEqual(@as(u32, 0xC0185502), USBDEVFS_BULK);
    try std.testing.expectEqual(@as(u32, 0x8004550F), USBDEVFS_CLAIMINTERFACE);
    try std.testing.expectEqual(@as(u32, 0x80045510), USBDEVFS_RELEASEINTERFACE);
}
