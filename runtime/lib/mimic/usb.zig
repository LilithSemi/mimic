//! USB transport for the mimic command protocol over the custom vendor
//! device (VID 0x1209, PID 0x10C1, bulk EP1 OUT 0x01 / EP1 IN 0x81, 32-byte
//! max packets).
//!
//! The device is found by scanning /sys/bus/usb/devices with std.Io, then the
//! /dev/bus/usb node is opened with std.Io and driven with usbfs ioctls (the
//! one thing std.Io does not model).
//!
//! Transfers go out as SUBMITTED URBs and come back with REAPURB, not as
//! blocking bulk ioctls. A blocking ioctl puts ONE transfer on the schedule
//! and then sleeps, so the next transfer reaches the host controller only
//! after the completion interrupt has woken this process. A queue lets the
//! controller start the next transfer as soon as the one in front of it
//! ends. Measured on the OrangeCrab, one register read fell from 130 us to
//! 88 us. See [transact].
//!
//! It does NOT make a long bulk write faster. This device is full speed
//! behind a high-speed hub, so every 32-byte packet costs one 125 us
//! microframe of split-transaction scheduling, whatever the host queues.
//! That is 3.9 us per byte, which `mimic-cli pushtest` measures the same
//! at 541 bytes and at 8656 bytes.
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

/// URBs that ONE transaction can hold on the queue at the same time.
///
/// This is the depth of the pipeline. Two is what the common shape needs:
/// a command and the answer to it, which removes the turn around between
/// them and measured a third off a register read. Deeper transactions are
/// commands grouped ahead of the answers they ask for, never a command
/// behind an answer, which wedges the device. See [Device.transact].
///
/// Raising it buys nothing while the link is packet limited: the queue is
/// already deeper than the bus can start. The cost of a slot is one
/// 56-byte URB, so the value keeps room for the widest caller and is tuned
/// here if the link ever stops being the limit.
pub const MAX_IN_FLIGHT: usize = 16;

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
    TooManyTransfers,
};

// _IOC encoding (asm-generic): (dir<<30)|(size<<16)|(type<<8)|nr.
const IOC_NONE: u32 = 0;
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

/// One asynchronous transfer, laid out as the kernel `struct usbdevfs_urb`.
///
/// `usercontext` carries the slot index plus one, so a reaped URB names
/// the step it belongs to. Zero is not used, because a null context cannot
/// be told from a missing one.
const Urb = extern struct {
    type: u8,
    endpoint: u8,
    status: c_int,
    flags: c_uint,
    buffer: ?*anyopaque,
    buffer_length: c_int,
    actual_length: c_int,
    start_frame: c_int,
    number_of_packets: c_int,
    error_count: c_int,
    signr: c_uint,
    usercontext: ?*anyopaque,
};

const URB_TYPE_BULK: u8 = 3;
/// Tells the kernel to close a bulk OUT with a zero length packet when the
/// data ends exactly on a packet boundary. It rides inside the same URB, so
/// the closing packet costs no transfer of its own. See [needsZeroPacket].
const URB_ZERO_PACKET: c_uint = 0x40;

const USBDEVFS_BULK: u32 = ioc(IOC_READ | IOC_WRITE, 'U', 2, @sizeOf(BulkTransfer));
const USBDEVFS_CLAIMINTERFACE: u32 = ioc(IOC_READ, 'U', 15, 4);
const USBDEVFS_RELEASEINTERFACE: u32 = ioc(IOC_READ, 'U', 16, 4);
const USBDEVFS_SUBMITURB: u32 = ioc(IOC_READ, 'U', 10, @sizeOf(Urb));
const USBDEVFS_DISCARDURB: u32 = ioc(IOC_NONE, 'U', 11, 0);
const USBDEVFS_REAPURBNDELAY: u32 = ioc(IOC_WRITE, 'U', 13, @sizeOf(usize));

comptime {
    // The layout comes from the kernel header and is not negotiable. A
    // mismatch would send the driver a different structure than it reads,
    // so it is checked where a bad build fails instead of a device.
    if (@sizeOf(Urb) != 56) @compileError("usbdevfs_urb must be 56 bytes");
    if (@offsetOf(Urb, "status") != 4) @compileError("urb.status must be at 4");
    if (@offsetOf(Urb, "buffer") != 16) @compileError("urb.buffer must be at 16");
    if (@offsetOf(Urb, "actual_length") != 28)
        @compileError("urb.actual_length must be at 28");
    if (@offsetOf(Urb, "usercontext") != 48)
        @compileError("urb.usercontext must be at 48");
}

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

/// Maps a transfer errno onto the named transport errors.
fn transferError(e: std.posix.E) Error {
    return switch (e) {
        .TIMEDOUT => Error.Timeout,
        .PIPE => Error.EndpointStalled,
        .INVAL => Error.NoEndpoint,
        .NODEV, .NXIO, .SHUTDOWN => Error.DeviceGone,
        .IO, .OVERFLOW, .ILSEQ => Error.LinkError,
        else => Error.BulkFailed,
    };
}

/// Maps the completion status the kernel writes into a URB. The status is a
/// negative errno, and 0 means the transfer finished.
fn urbError(status: c_int) Error {
    const code: u32 = @intCast(-status);
    const e = std.enums.fromInt(std.posix.E, code) orelse return Error.BulkFailed;
    return transferError(e);
}

/// One transfer of a pipelined transaction.
pub const Step = struct {
    /// True for a bulk IN, false for a bulk OUT.
    in: bool,
    /// The buffer of this transfer. It must stay alive and unread until
    /// [Device.transact] returns.
    data: []u8,
};

/// A bulk OUT step that carries `data` to the device.
pub fn out(data: []u8) Step {
    return .{ .in = false, .data = data };
}

/// A bulk IN step that takes exactly `data.len` bytes from the device.
pub fn in(data: []u8) Step {
    return .{ .in = true, .data = data };
}

pub const Device = struct {
    file: Io.File,
    /// The URBs of the transaction that runs now. They live in this struct
    /// and not on a stack frame, so a queue that fails to drain cannot
    /// leave the kernel with a pointer into a frame that has gone.
    urbs: [MAX_IN_FLIGHT]Urb = undefined,
    /// True for a slot the kernel still holds.
    live: [MAX_IN_FLIGHT]bool = @splat(false),
    /// Slots the kernel still holds. The queue must be empty between
    /// transactions.
    in_flight: usize = 0,
    /// Set when a queue could not be drained. A device in that state could
    /// answer a later command with a URB of an earlier transaction, which
    /// would match a response to the wrong command, so it takes no more
    /// work at all.
    broken: bool = false,

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

    pub fn close(self: *Device, io: Io) void {
        // A transaction that failed can leave the queue loaded. The kernel
        // keeps pointers into this struct until it gives those URBs back,
        // so they are cancelled before the handle goes.
        if (self.in_flight != 0) self.abort();
        // Release only fails when the claim is already gone (bad fd, no
        // claim), which is the state close wants. The close below drops the
        // claim at the kernel side regardless, so the result is ignored.
        var intf: u32 = INTERFACE;
        _ = switch (ioctl(self.file.handle, USBDEVFS_RELEASEINTERFACE, @intFromPtr(&intf))) {
            .ok, .err => {},
        };
        self.file.close(io);
    }

    /// Runs `steps` as ONE pipelined transaction.
    ///
    /// EVERY URB goes on the queue before ANY of them is reaped. The host
    /// controller then holds the whole list and can start the next
    /// transfer in the frame that the one in front of it ends in. A
    /// blocking ioctl per transfer instead gives the controller one
    /// transfer at a time, and the frames between the completion and the
    /// next submission carry nothing.
    ///
    /// ORDER. The kernel keeps one queue per endpoint and starts the URBs
    /// of a queue in the order they were submitted. The device therefore
    /// reads the OUT frames in the order this list gives them and answers
    /// them in the same order. A command that MUST follow another one only
    /// has to come later in `steps`.
    ///
    /// A failed step cancels every URB that is still in flight, waits for
    /// the kernel to give them all back, and clears the IN pipe before it
    /// returns. Nothing of a failed transaction is therefore left for the
    /// NEXT one to reap, which is what would let a response be matched to
    /// the wrong command.
    ///
    /// A short transfer is a failure, not a partial result: every step
    /// names a whole frame or a whole response.
    pub fn transact(self: *Device, steps: []const Step) !void {
        std.debug.assert(steps.len > 0);
        if (steps.len > MAX_IN_FLIGHT) return Error.TooManyTransfers;
        if (self.broken) return Error.DeviceGone;
        // A transaction reaps everything it submits, so the queue is empty
        // here. A loaded queue is a logic error of this file.
        std.debug.assert(self.in_flight == 0);

        for (steps, 0..) |step, i| {
            self.urbs[i] = .{
                .type = URB_TYPE_BULK,
                .endpoint = if (step.in) EP_IN else EP_OUT,
                .status = 0,
                .flags = if (!step.in and needsZeroPacket(step.data.len))
                    URB_ZERO_PACKET
                else
                    0,
                .buffer = if (step.data.len == 0) null else @ptrCast(step.data.ptr),
                .buffer_length = @intCast(step.data.len),
                .actual_length = 0,
                .start_frame = 0,
                .number_of_packets = 0,
                .error_count = 0,
                .signr = 0,
                .usercontext = @ptrFromInt(i + 1),
            };
            switch (ioctl(self.file.handle, USBDEVFS_SUBMITURB, @intFromPtr(&self.urbs[i]))) {
                .ok => {
                    self.live[i] = true;
                    self.in_flight += 1;
                },
                .err => |e| {
                    self.abort();
                    self.drainIn();
                    return transferError(e);
                },
            }
        }

        // Every URB is reaped even after one has failed. Leaving one on the
        // queue would hand it to the next transaction.
        var fault: ?Error = null;
        while (self.in_flight != 0) {
            const urb = self.reap() catch |e| {
                self.abort();
                self.drainIn();
                return e;
            };
            const index = self.retire(urb);
            if (urb.status != 0) {
                if (fault == null) fault = urbError(urb.status);
                continue;
            }
            if (urb.actual_length != steps[index].data.len and fault == null) {
                fault = Error.BulkFailed;
            }
        }
        if (fault) |e| {
            // The device can still hold an answer that this transaction
            // never took. Left there, it would come back as the answer to
            // the NEXT read. The pipe is cleared before the error goes up.
            self.drainIn();
            return e;
        }
    }

    /// Sends a whole command frame in one bulk-OUT transfer. The buffer must
    /// be mutable: usbfs takes a plain pointer for the transfer data.
    pub fn writeFrame(self: *Device, bytes: []u8) !void {
        try self.transact(&.{out(bytes)});
    }

    /// Sends a command and takes its answer in ONE pipelined transaction.
    ///
    /// The IN URB is on the queue BEFORE the command has even left, so the
    /// controller asks for the answer in the frame the device is ready in.
    /// Sent apart, the IN reaches the schedule a frame or more after the
    /// device already had the bytes waiting.
    pub fn writeThenRead(self: *Device, cmd: []u8, resp: []u8) !void {
        try self.transact(&.{ out(cmd), in(resp) });
    }

    /// Takes one URB back from the kernel.
    ///
    /// usbfs reports a ready completion as WRITABLE, so the wait is a poll
    /// and costs no spinning. The non-blocking reap comes first, because a
    /// completion that is already there needs no wait at all.
    fn reap(self: *Device) !*Urb {
        // The poll can wake for a completion that another reap took. The
        // bound keeps a lying poll from spinning forever; one wake per
        // outstanding URB is more than the queue can produce.
        var tries: usize = 0;
        while (tries <= MAX_IN_FLIGHT) : (tries += 1) {
            var done: ?*Urb = null;
            switch (ioctl(self.file.handle, USBDEVFS_REAPURBNDELAY, @intFromPtr(&done))) {
                .ok => return done orelse Error.BulkFailed,
                .err => |e| switch (e) {
                    .AGAIN, .INTR => {},
                    else => return transferError(e),
                },
            }
            if (!try pollCompletion(self.file.handle, TIMEOUT_MS)) return Error.Timeout;
        }
        return Error.BulkFailed;
    }

    /// Takes a reaped URB off the queue and returns the step index it
    /// carries.
    fn retire(self: *Device, urb: *Urb) usize {
        const index = @intFromPtr(urb.usercontext) - 1;
        std.debug.assert(index < MAX_IN_FLIGHT);
        std.debug.assert(self.live[index]);
        self.live[index] = false;
        self.in_flight -= 1;
        return index;
    }

    /// Cancels every URB still in flight and waits for the kernel to give
    /// them all back.
    ///
    /// A cancelled URB completes at once with its own status, so the drain
    /// is bounded. A queue that will NOT drain marks the device broken: a
    /// later transaction could otherwise reap a URB of this one and read
    /// an answer that belongs to a command nobody asked any more.
    fn abort(self: *Device) void {
        for (self.live, 0..) |is_live, i| {
            if (!is_live) continue;
            _ = ioctl(self.file.handle, USBDEVFS_DISCARDURB, @intFromPtr(&self.urbs[i]));
        }
        var guard: usize = 0;
        while (self.in_flight != 0 and guard <= MAX_IN_FLIGHT) : (guard += 1) {
            const urb = self.reap() catch break;
            _ = self.retire(urb);
        }
        if (self.in_flight != 0) self.broken = true;
    }

    /// Reads and throws away whatever the device still holds on the IN
    /// endpoint.
    ///
    /// It runs only on a failed transaction. The answer to the command that
    /// failed can still be in the device, and the next read would then take
    /// those bytes as ITS answer. A blocking bulk read with a short timeout
    /// is used here on purpose: this path wants a timeout per transfer, and
    /// nothing waits on it.
    fn drainIn(self: *Device) void {
        if (self.broken) return;
        var scratch: [MAX_PACKET * 8]u8 = undefined;
        var rounds: usize = 0;
        while (rounds < 8) : (rounds += 1) {
            var bt = BulkTransfer{
                .ep = EP_IN,
                .len = scratch.len,
                .timeout = DRAIN_TIMEOUT_MS,
                .data = @ptrCast(&scratch),
            };
            switch (ioctl(self.file.handle, USBDEVFS_BULK, @intFromPtr(&bt))) {
                .ok => |n| if (n == 0) return,
                .err => return,
            }
        }
    }
};

/// Milliseconds one drain read waits. It is short: the bytes are either
/// already in the device or there are none.
const DRAIN_TIMEOUT_MS: c_uint = 20;

/// Waits until usbfs has a completion ready on `fd`. Returns false when the
/// wait ran out of time.
fn pollCompletion(fd: std.posix.fd_t, timeout_ms: u32) !bool {
    var fds = [1]linux.pollfd{.{
        .fd = fd,
        .events = linux.POLL.OUT,
        .revents = 0,
    }};
    while (true) {
        const rc = linux.poll(&fds, 1, @intCast(timeout_ms));
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => |e| return transferError(e),
        }
        if (rc == 0) return false;
        if (fds[0].revents & (linux.POLL.ERR | linux.POLL.HUP) != 0) {
            return Error.DeviceGone;
        }
        return true;
    }
}

/// Scans /sys/bus/usb/devices for VID:PID and builds the /dev/bus/usb path.
/// A device that enumerates without bulk endpoints is an enumeration-only
/// bitstream, and bulk traffic to it can only fail, so it is reported here
/// as its own error.
fn findNode(io: Io, out_buf: []u8) ![]const u8 {
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
        return std.fmt.bufPrint(out_buf, "/dev/bus/usb/{d:0>3}/{d:0>3}", .{ bus, num });
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
/// only full packets and cannot tell where the transfer stops. The kernel
/// must then close it with a zero-length packet.
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
    // The async trio. SUBMITURB carries the 56-byte urb, REAPURBNDELAY
    // carries a pointer to where the kernel writes the finished one, and
    // DISCARDURB carries the urb address as the plain argument.
    try std.testing.expectEqual(@as(u32, 0x8038550A), USBDEVFS_SUBMITURB);
    try std.testing.expectEqual(@as(u32, 0x0000550B), USBDEVFS_DISCARDURB);
    try std.testing.expectEqual(@as(u32, 0x4008550D), USBDEVFS_REAPURBNDELAY);
}

test "urbError maps the completion statuses the kernel reports" {
    // The kernel writes a NEGATIVE errno into urb.status.
    try std.testing.expectEqual(Error.EndpointStalled, urbError(-32)); // EPIPE
    try std.testing.expectEqual(Error.DeviceGone, urbError(-19)); // ENODEV
    try std.testing.expectEqual(Error.LinkError, urbError(-5)); // EIO
    try std.testing.expectEqual(Error.Timeout, urbError(-110)); // ETIMEDOUT
    // A cancelled URB is not a link fault of its own; it is the wreckage
    // of the failure that cancelled it.
    try std.testing.expectEqual(Error.BulkFailed, urbError(-2)); // ENOENT
}

test "a step names its direction and keeps its buffer" {
    var bytes: [4]u8 = .{ 1, 2, 3, 4 };
    const cmd = out(&bytes);
    try std.testing.expect(!cmd.in);
    try std.testing.expectEqual(@as(usize, 4), cmd.data.len);
    const resp = in(&bytes);
    try std.testing.expect(resp.in);
    try std.testing.expectEqual(bytes[0..].ptr, resp.data.ptr);
}
