//! Mimic runtime library. Drives the SD card mimic FPGA over USB (a
//! vendor-class device with bulk endpoints) with a 7-byte framed protocol
//! that reads and writes a CSR space on the device.
//!
//! `runtime/src/main.zig` is the CLI entrypoint and consumes this as
//! `@import("mimic")`. Consumers open a backend (transport), get its `Device`
//! interface, and drive the CSR map in `sd.zig`.

/// The backend-agnostic device interface (fat pointer + vtable) the callers
/// drive. A backend exposes a `device()` returning one of these.
pub const device = @import("mimic/device.zig");
pub const Device = device.Device;

/// Real-silicon backend (USB) + the wire protocol.
pub const transport = @import("mimic/transport.zig");
pub const protocol = @import("mimic/protocol.zig");
pub const usb = @import("mimic/usb.zig");

/// The CSR map, fixed register values, and CTRL bits.
pub const sd = @import("mimic/sd.zig");

/// The block read path: request records in, image blocks out.
pub const serve = @import("mimic/serve.zig");

/// The genip-emitted mimic.json manifest.
pub const manifest = @import("mimic/manifest.zig");
