//! The mimic device interface: a fat pointer (context + vtable) that callers
//! drive without knowing whether it talks to real silicon over USB, a
//! simulator, or a future transport. The runner code depends on this concrete
//! type, not an `anytype` generic, so silicon, sim, and new transports stay
//! interchangeable.
//!
//! An implementation exposes a `device()` method returning one of these,
//! wiring its own methods into the vtable (see transport.zig).

/// One register setup and FIFO stream inside a grouped transport write.
pub const WriteStreamGroup = struct {
    before: []const [2]u32,
    addr: u32,
    values: []const u32,
    after: []const [2]u32 = &.{},
};

/// The CSR and stream operations every mimic backend provides. All are
/// fallible (transport timeouts, sim allocation), hence `anyerror`.
pub const Device = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Write one 32-bit word to a CSR.
        reg_write: *const fn (ptr: *anyopaque, addr: u32, value: u32) anyerror!void,
        /// Read one 32-bit word from a CSR.
        reg_read: *const fn (ptr: *anyopaque, addr: u32) anyerror!u32,
        /// Write many {addr, value} pairs. The backend may coalesce them.
        write_regs: *const fn (ptr: *anyopaque, pairs: []const [2]u32) anyerror!void,
        /// Read `words.len` consecutive words starting at `addr`. This is a
        /// burst.
        read_regs: *const fn (ptr: *anyopaque, addr: u32, words: []u32) anyerror!void,
        /// Read consecutive words and then write bit 0 to `pop_addr`, all in
        /// one transport transaction.
        read_regs_pop: *const fn (
            ptr: *anyopaque,
            addr: u32,
            pop_addr: u32,
            words: []u32,
        ) anyerror!void,
        /// Stream `values` as pushes to the fixed FIFO `addr`.
        write_stream: *const fn (ptr: *anyopaque, addr: u32, values: []const u32) anyerror!void,
        /// Write register pairs and then stream FIFO words in one ordered
        /// transport transaction. This keeps setup writes adjacent to the
        /// data that consumes them.
        write_regs_stream_regs: *const fn (
            ptr: *anyopaque,
            before: []const [2]u32,
            addr: u32,
            values: []const u32,
            after: []const [2]u32,
        ) anyerror!void,
        /// Send multiple ordered setup and stream groups in one transport
        /// transaction.
        write_stream_groups: *const fn (
            ptr: *anyopaque,
            groups: []const WriteStreamGroup,
        ) anyerror!void,
        /// Read `words.len` words from the fixed FIFO `addr`. The address
        /// does not advance, so every word is one pop of the same FIFO.
        /// This is the read counterpart of `write_stream`.
        read_stream: *const fn (ptr: *anyopaque, addr: u32, words: []u32) anyerror!void,
    };

    pub fn regWrite(self: Device, addr: u32, value: u32) anyerror!void {
        return self.vtable.reg_write(self.ptr, addr, value);
    }
    pub fn regRead(self: Device, addr: u32) anyerror!u32 {
        return self.vtable.reg_read(self.ptr, addr);
    }
    pub fn writeRegs(self: Device, pairs: []const [2]u32) anyerror!void {
        return self.vtable.write_regs(self.ptr, pairs);
    }
    pub fn readRegs(self: Device, addr: u32, words: []u32) anyerror!void {
        return self.vtable.read_regs(self.ptr, addr, words);
    }
    pub fn readRegsPop(
        self: Device,
        addr: u32,
        pop_addr: u32,
        words: []u32,
    ) anyerror!void {
        return self.vtable.read_regs_pop(self.ptr, addr, pop_addr, words);
    }
    pub fn writeStream(self: Device, addr: u32, values: []const u32) anyerror!void {
        return self.vtable.write_stream(self.ptr, addr, values);
    }
    pub fn writeRegsStreamRegs(
        self: Device,
        before: []const [2]u32,
        addr: u32,
        values: []const u32,
        after: []const [2]u32,
    ) anyerror!void {
        return self.vtable.write_regs_stream_regs(
            self.ptr,
            before,
            addr,
            values,
            after,
        );
    }
    pub fn writeStreamGroups(
        self: Device,
        groups: []const WriteStreamGroup,
    ) anyerror!void {
        return self.vtable.write_stream_groups(self.ptr, groups);
    }
    pub fn readStream(self: Device, addr: u32, words: []u32) anyerror!void {
        return self.vtable.read_stream(self.ptr, addr, words);
    }
};
