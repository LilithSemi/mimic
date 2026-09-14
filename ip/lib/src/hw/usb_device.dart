// MimicUsbDevice: a CUSTOM vendor-class full-speed USB device (NOT DFU) with
// two bulk endpoints and a command protocol that performs Wishbone READS and
// WRITES. This is the USB transport for the Mimic SD card: a host can write
// the card's CSRs, push data, and read results back over USB, at arbitrary
// word addresses.
//
// Spec grounding (read first, per reference-driven-rohd):
//   - USB 2.0 ch9 (device/config/interface/endpoint descriptors, control
//     transfers) + the bulk-transfer model (DATA0/DATA1 toggle, ACK/NAK).
//   - The full-speed (12 Mbps) line layer, the packet framing layer and the
//     endpoint protocol engine are harbor's, and are REUSED, not reinvented.
//     They come from HarborUsbFsDevice (usb_fs_device.dart), the ROHD port of
//     the TinyFPGA `tinyfpga_bx_usbserial` core:
//       * HarborUsbFsRx / HarborUsbFsTx: raw D+/D- at 48 MHz, NRZI +
//         bit-stuff + clock-recovery + EOP.
//       * HarborUsbFsPe (with HarborUsbFsInPe / HarborUsbFsOutPe): USB packet
//         framing (PID, endpoint buffers, CRC16) and the per-endpoint
//         protocol.
//       * HarborUsbFsResetDet: SE0 bus-reset detection.
//     HarborUsbFsDevice also runs the EP0 chapter-9 control transfers. The
//     vendor descriptors this device advertises live in
//     MimicUsbDescriptorRom, injected into that engine so the single proven
//     FSM serves them.
//   The NET-NEW parts here are: the vendor descriptor set, the command
//   framing parser, and the READ/WRITE Wishbone MASTER (MimicUsbCmdEngine).
//
// Endpoints / max packet size
//   EP0       : control (enumeration), bMaxPacketSize0 = 32.
//   EP1 OUT   : bulk, host -> device, wMaxPacketSize = 32. Carries the COMMAND
//               STREAM.
//   EP1 IN    : bulk, device -> host, wMaxPacketSize = 32 (endpoint address
//               0x81). Carries READ responses.
//   32 is a HARD limit, not a tuning knob. The TinyFPGA endpoint buffer uses
//   a 5-bit byte address with a 6th bit as the full flag, in the original
//   Verilog and in the port, so the buffer holds 32 bytes and no more. A
//   larger declared size passes simulation and then loses data on real
//   hardware, because the host is then free to send a packet the buffer
//   cannot hold.
//
// Command framing (host -> device on EP1 OUT. Little-endian)
//   header = { opcode:u8, addr:u32, len:u16 }   (7 bytes)
//   WRITE (opcode 0x01): header then `len` data bytes. The bytes accumulate
//                        into 32-bit words. Each full word is written to
//                        Wishbone with full SEL, and the address advances one
//                        word per write.
//   READ  (opcode 0x02): header only. The device fetches `len` bytes from
//                        Wishbone starting at addr (one bus read per word it
//                        needs) and emits them, in order, on EP1 IN.
//   WRITE_STREAM (opcode 0x03): like WRITE, but the address stays fixed, so
//                        every full word writes the same register (a FIFO
//                        push).
//   READ_POP_STREAM (opcode 0x04): reads repeatedly from the low 16-bit
//                        address and writes bit 0 to the high 16-bit address
//                        after each word.
//   READ_THEN_POP (opcode 0x05): reads consecutive words from the low 16-bit
//                        address and writes bit 0 to the high 16-bit address
//                        once, after the final word.
//
// Clocking
// Single clock domain (the SoC keeps the USB-rate 48 MHz clock single, the
// way HarborSoC.addMaster expects). The command engine, the Wishbone master,
// the EP0 engine and the PHY all run on `clk`.

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../regs.dart';

/// The maximum packet payload of every endpoint of this device, in bytes.
///
/// The ported TinyFPGA endpoint buffer addresses its bytes with 5 bits and
/// uses a 6th bit as the full flag, so it holds 32 bytes and no more. Every
/// descriptor in [MimicUsbDescriptorRom] declares this value, and
/// [MimicUsbDevice] passes it to the ported core, so the advertised size and
/// the buffer always agree.
const int mimicUsbMaxPacketSize = 32;

// Configuration

/// Immutable configuration for [MimicUsbDevice] / [MimicUsbCmdEngine].
class MimicUsbDeviceConfig {
  /// Wishbone master address bus width.
  final int busAddressWidth;

  /// Wishbone master data bus width (8, 16, 32 or 64).
  final int busDataWidth;

  /// USB idVendor (16-bit). Defaults to the pid.codes open VID 0x1209.
  final int idVendor;

  /// USB idProduct (16-bit). A Mimic-specific product id under that VID.
  final int idProduct;

  /// Whether this device DECLARES the EP1 bulk command interface. When true
  /// the CONFIGURATION descriptor advertises the interface's two bulk
  /// endpoints (bNumEndpoints=2 + the two endpoint descriptors) AND harbor's
  /// EP0 engine is built with its EP1 bulk states. When false the device is
  /// a CONTROL-ONLY vendor device: the config descriptor advertises
  /// bNumEndpoints=0 with NO endpoint descriptors and the engine generates
  /// no EP1 logic.
  ///
  /// This is the SINGLE source of truth that the descriptor set and the
  /// engine both READ, so the advertised endpoints and the generated
  /// endpoint logic can never disagree. The bulk-LESS configuration is an
  /// ENUMERATION-ISOLATION build: the command engine / bus master is present
  /// but undriveable (no bulk endpoints reach it), which is acceptable
  /// because the only purpose of the control-only variant is to test whether
  /// EP0 enumeration succeeds without the bulk additions in the path.
  final bool bulkEndpoints;

  /// USB serial number string, or null for no serial. When non-null it is
  /// served as STRING index 4 and the DEVICE descriptor's iSerialNumber
  /// points at it.
  final String? serialNumber;

  const MimicUsbDeviceConfig({
    this.busAddressWidth = 12,
    this.busDataWidth = 32,
    this.idVendor = 0x1209,
    this.idProduct = 0x10C1,
    this.bulkEndpoints = true,
    this.serialNumber,
  });

  /// Parses a USB idVendor / idProduct string. Accepts '0x1209', '1209' and
  /// '0X1209': the bare form is the convenience, because a VID is always read
  /// and written as hex. [what] names the source in the error message.
  ///
  /// Throws [FormatException] when the text is not hex, or when the value does
  /// not fit the 16 bits [idVendor] and [idProduct] hold.
  static int parseUsbId(String s, String what) {
    var t = s.trim();
    if (t.length >= 2 && (t.startsWith('0x') || t.startsWith('0X'))) {
      t = t.substring(2);
    }
    final v = int.tryParse(t, radix: 16);
    if (v == null || v < 0 || v > 0xFFFF) {
      throw FormatException('$what must be a 16-bit hex value, got: $s');
    }
    return v;
  }

  /// Number of byte lanes on the Wishbone data bus.
  int get bytesPerWord => busDataWidth ~/ 8;

  /// Validates the configuration. Throws [ArgumentError] on failure.
  void validate() {
    if (![8, 16, 32, 64].contains(busDataWidth)) {
      throw ArgumentError(
        'MimicUsbDeviceConfig.busDataWidth must be one of [8,16,32,64], got '
        '$busDataWidth',
      );
    }
    if (busAddressWidth < 1 || busAddressWidth > 64) {
      throw ArgumentError(
        'MimicUsbDeviceConfig.busAddressWidth out of range (1..64), got '
        '$busAddressWidth',
      );
    }
    if (idVendor < 0 || idVendor > 0xFFFF) {
      throw ArgumentError(
        'MimicUsbDeviceConfig.idVendor must be a u16, got $idVendor',
      );
    }
    if (idProduct < 0 || idProduct > 0xFFFF) {
      throw ArgumentError(
        'MimicUsbDeviceConfig.idProduct must be a u16, got $idProduct',
      );
    }
    // The string descriptor is 2 header bytes + 2 bytes per character, and
    // the ROM offset ceiling is 255, so the serial is capped at 126 chars.
    if (serialNumber != null &&
        (serialNumber!.isEmpty || serialNumber!.length > 126)) {
      throw ArgumentError(
        'MimicUsbDeviceConfig.serialNumber must be 1..126 characters, got '
        '${serialNumber!.length}',
      );
    }
  }
}

// Vendor-class descriptor ROM

/// A single descriptor entry: the (type, index) key + its bytes.
class _Desc {
  final int type;
  final int index;
  final List<int> bytes;
  const _Desc(this.type, this.index, this.bytes);
}

/// Combinational ROM of the vendor-class device's standard descriptors.
///
/// Pure data: no clock, no state. Modeled on harbor's [UsbDescriptorRom] (same
/// (desc_type, desc_index, offset) -> (present, length, data) contract) but
/// carries a VENDOR-CLASS device with one interface exposing TWO bulk
/// endpoints (EP1 OUT + EP1 IN), instead of the DFU descriptor set.
class MimicUsbDescriptorRom extends BridgeModule {
  /// Device descriptor (18 bytes). bDeviceClass = 0xFF (vendor-specific) so
  /// the host loads a generic/vendor driver rather than a class driver.
  /// Byte 16 (iSerialNumber) is patched per-instance when a serial number is
  /// supplied.
  static const List<int> deviceDescriptor = [
    18, // bLength
    0x01, // bDescriptorType = DEVICE
    0x00, 0x02, // bcdUSB = 0x0200
    0xFF, // bDeviceClass = vendor-specific
    0x00, // bDeviceSubClass
    0x00, // bDeviceProtocol
    32, // bMaxPacketSize0
    0x09, 0x12, // idVendor = 0x1209 (overridden per-instance below)
    0xC1, 0x10, // idProduct = 0x10C1
    0x00, 0x01, // bcdDevice = 0x0100
    1, // iManufacturer
    2, // iProduct
    0, // iSerialNumber
    1, // bNumConfigurations
  ];

  /// CONFIGURATION tree WITH bulk endpoints (32 bytes): config(9) +
  /// interface(9) + EP1-OUT(7) + EP1-IN(7). The interface is vendor-class
  /// (0xFF) with two bulk endpoints. This is the descriptor served when
  /// [bulkEndpoints] is true.
  static const List<int> configDescriptorBulk = [
    // Configuration header (9 bytes).
    9, // bLength
    0x02, // CONFIGURATION
    32, 0x00, // wTotalLength = 32 (LE) = 9 + 9 + 7 + 7
    1, // bNumInterfaces
    1, // bConfigurationValue
    0, // iConfiguration
    0x80, // bmAttributes (bus powered)
    50, // bMaxPower (100 mA)
    // Interface descriptor (9 bytes).
    9, // bLength
    0x04, // INTERFACE
    0, // bInterfaceNumber
    0, // bAlternateSetting
    2, // bNumEndpoints = 2
    0xFF, // bInterfaceClass = vendor-specific
    0x00, // bInterfaceSubClass
    0x00, // bInterfaceProtocol
    3, // iInterface
    // EP1 OUT endpoint (7 bytes).
    7, // bLength
    0x05, // ENDPOINT
    0x01, // bEndpointAddress = EP1 OUT (dir bit 7 = 0)
    0x02, // bmAttributes = bulk
    0x20, 0x00, // wMaxPacketSize = 32 (LE)
    0, // bInterval (ignored for bulk)
    // EP1 IN endpoint (7 bytes).
    7, // bLength
    0x05, // ENDPOINT
    0x81, // bEndpointAddress = EP1 IN (dir bit 7 = 1)
    0x02, // bmAttributes = bulk
    0x20, 0x00, // wMaxPacketSize = 32 (LE)
    0, // bInterval
  ];

  /// CONTROL-ONLY CONFIGURATION tree (18 bytes): config(9) + interface(9), NO
  /// endpoint descriptors. The interface is still vendor-class (0xFF) but
  /// advertises bNumEndpoints=0. This is the descriptor served when
  /// [bulkEndpoints] is false: the ENUMERATION-ISOLATION variant.
  /// wTotalLength = 9 + 9 = 18.
  static const List<int> configDescriptorNoBulk = [
    // Configuration header (9 bytes).
    9, // bLength
    0x02, // CONFIGURATION
    18, 0x00, // wTotalLength = 18 (LE) = 9 + 9
    1, // bNumInterfaces
    1, // bConfigurationValue
    0, // iConfiguration
    0x80, // bmAttributes (bus powered)
    50, // bMaxPower (100 mA)
    // Interface descriptor (9 bytes).
    9, // bLength
    0x04, // INTERFACE
    0, // bInterfaceNumber
    0, // bAlternateSetting
    0, // bNumEndpoints = 0 (control-only)
    0xFF, // bInterfaceClass = vendor-specific
    0x00, // bInterfaceSubClass
    0x00, // bInterfaceProtocol
    3, // iInterface
  ];

  /// The CONFIGURATION descriptor for the selected endpoint mode.
  static List<int> configDescriptorFor({required bool bulkEndpoints}) =>
      bulkEndpoints ? configDescriptorBulk : configDescriptorNoBulk;

  static const List<int> stringLangId = usbStringLangIdEnUs;

  static List<int> _stringDescriptor(String s) => usbStringDescriptor(s);

  /// Build the vendor descriptor set as a list of harbor [UsbDescriptorEntry]s,
  /// with VID/PID patched into the DEVICE descriptor. Same data this ROM
  /// serves. Injected into harbor's [HarborUsbFsDevice] (descriptors param) so
  /// the ch9 control FSM, including string-descriptor indexing, is reused
  /// as-is.
  ///
  /// String indexes: 1 = manufacturer ('Lilith Semiconductor'), 2 = product ('Mimic'),
  /// 3 = interface ('Mimic Command Interface'). A non-null [serialNumber]
  /// adds string index 4 and points the DEVICE descriptor's iSerialNumber at
  /// it. A null [serialNumber] leaves iSerialNumber 0 (no serial).
  static List<UsbDescriptorEntry> descriptorEntries({
    int idVendor = 0x1209,
    int idProduct = 0x10C1,
    bool bulkEndpoints = true,
    String? serialNumber,
  }) {
    final dev = List<int>.from(deviceDescriptor);
    dev[8] = idVendor & 0xFF;
    dev[9] = (idVendor >> 8) & 0xFF;
    dev[10] = idProduct & 0xFF;
    dev[11] = (idProduct >> 8) & 0xFF;
    if (serialNumber != null) {
      dev[16] = 4; // iSerialNumber = string index 4
    }
    return <UsbDescriptorEntry>[
      UsbDescriptorEntry(0x01, 0, dev),
      UsbDescriptorEntry(
        0x02,
        0,
        configDescriptorFor(bulkEndpoints: bulkEndpoints),
      ),
      const UsbDescriptorEntry(0x03, 0, stringLangId),
      UsbDescriptorEntry(0x03, 1, _stringDescriptor('Lilith Semiconductor')),
      UsbDescriptorEntry(0x03, 2, _stringDescriptor('Mimic')),
      UsbDescriptorEntry(0x03, 3, _stringDescriptor('Mimic Command Interface')),
      if (serialNumber != null)
        UsbDescriptorEntry(0x03, 4, _stringDescriptor(serialNumber)),
    ];
  }

  /// idVendor / idProduct used to patch the device descriptor bytes 8..11.
  final int idVendor;

  /// idProduct used to patch the device descriptor bytes 8..11.
  final int idProduct;

  /// Whether the served CONFIGURATION descriptor advertises the bulk
  /// endpoints.
  final bool bulkEndpoints;

  /// USB serial number string, or null for no serial. When non-null it is
  /// served as STRING index 4 and the DEVICE descriptor's iSerialNumber
  /// points at it.
  final String? serialNumber;

  MimicUsbDescriptorRom({
    String? name,
    this.idVendor = 0x1209,
    this.idProduct = 0x10C1,
    this.bulkEndpoints = true,
    this.serialNumber,
  }) : super('MimicUsbDescriptorRom', name: name ?? 'mimic_usb_desc_rom') {
    if (idVendor < 0 || idVendor > 0xFFFF) {
      throw ArgumentError('idVendor must be a u16, got $idVendor');
    }
    if (idProduct < 0 || idProduct > 0xFFFF) {
      throw ArgumentError('idProduct must be a u16, got $idProduct');
    }

    createPort('desc_type', PortDirection.input, width: 8);
    createPort('desc_index', PortDirection.input, width: 8);
    createPort('offset', PortDirection.input, width: 8);
    addOutput('data', width: 8);
    addOutput('length', width: 16);
    addOutput('present');

    // Patch VID/PID into a per-instance device descriptor copy. Add the
    // serial string (index 4) and point iSerialNumber at it when one is given.
    final dev = List<int>.from(deviceDescriptor);
    dev[8] = idVendor & 0xFF;
    dev[9] = (idVendor >> 8) & 0xFF;
    dev[10] = idProduct & 0xFF;
    dev[11] = (idProduct >> 8) & 0xFF;
    if (serialNumber != null) {
      dev[16] = 4; // iSerialNumber = string index 4
    }

    final descriptors = <_Desc>[
      _Desc(0x01, 0, dev),
      _Desc(0x02, 0, configDescriptorFor(bulkEndpoints: bulkEndpoints)),
      const _Desc(0x03, 0, stringLangId),
      _Desc(0x03, 1, _stringDescriptor('Lilith Semiconductor')),
      _Desc(0x03, 2, _stringDescriptor('Mimic')),
      _Desc(0x03, 3, _stringDescriptor('Mimic Command Interface')),
      if (serialNumber != null)
        _Desc(0x03, 4, _stringDescriptor(serialNumber!)),
    ];

    // Build-time integrity checks (each byte in range. Declared length agrees
    // with the real byte count; <= 255-byte ROM offset ceiling).
    for (final d in descriptors) {
      if (d.bytes.length > 255) {
        throw ArgumentError(
          'descriptor (type=${d.type}, index=${d.index}) exceeds 255 bytes',
        );
      }
      if (d.bytes.isEmpty) {
        throw ArgumentError(
          'descriptor (type=${d.type}, index=${d.index}) is empty',
        );
      }
      for (final b in d.bytes) {
        if (b < 0 || b > 0xFF) {
          throw ArgumentError(
            'descriptor (type=${d.type}, index=${d.index}) byte $b out of '
            'range',
          );
        }
      }
      if (d.type == 0x02) {
        final wTotal = d.bytes[2] | (d.bytes[3] << 8);
        if (wTotal != d.bytes.length) {
          throw ArgumentError(
            'CONFIGURATION wTotalLength=$wTotal != real byte count '
            '${d.bytes.length}',
          );
        }
      } else {
        if (d.bytes[0] != d.bytes.length) {
          throw ArgumentError(
            'descriptor (type=${d.type}, index=${d.index}) bLength='
            '${d.bytes[0]} != real byte count ${d.bytes.length}',
          );
        }
      }
    }

    final descType = input('desc_type');
    final descIndex = input('desc_index');
    final offset = input('offset');

    final matches = <Logic>[
      for (final d in descriptors)
        (descType.eq(Const(d.type, width: 8)) &
                descIndex.eq(Const(d.index, width: 8)))
            .named('match_t${d.type}_i${d.index}'),
    ];

    Logic presentLocal = Const(0);
    for (final m in matches) {
      presentLocal = presentLocal | m;
    }
    output('present') <= presentLocal;

    Logic lengthLocal = Const(0, width: 16);
    for (var i = 0; i < descriptors.length; i++) {
      lengthLocal = mux(
        matches[i],
        Const(descriptors[i].bytes.length, width: 16),
        lengthLocal,
      );
    }
    output('length') <= lengthLocal;

    Logic dataLocal = Const(0, width: 8);
    for (var i = 0; i < descriptors.length; i++) {
      final bytes = descriptors[i].bytes;
      Logic byteSel = Const(0, width: 8);
      for (var off = 0; off < bytes.length; off++) {
        byteSel = mux(
          offset.eq(Const(off, width: 8)),
          Const(bytes[off], width: 8),
          byteSel,
        );
      }
      dataLocal = mux(matches[i], byteSel, dataLocal);
    }
    output('data') <= dataLocal;
  }
}

// Bulk command engine + Wishbone master (the NET-NEW core)

/// Bulk command engine: parses the EP1-OUT command byte stream, drives a
/// Wishbone MASTER for READS and WRITES, and emits READ responses on the
/// EP1-IN byte stream.
///
/// Byte-stream ports (the bulk OUT / IN endpoints connect to these):
///   in:  cmd_data[8], cmd_valid     - a command byte is offered when cmd_valid.
///   out: cmd_ready                  - high when the engine can accept a byte.
///   out: resp_data[8], resp_valid   - a response byte is offered when
///                                     resp_valid (READ replies).
///   in:  resp_ready                 - the IN endpoint can take a byte.
///   out: busy                       - high while a command is in flight.
///   out: out_toggle                 - the expected bulk-OUT data toggle
///                                     (DATA0/DATA1) for the next OUT DATA
///                                     packet, advanced on each accepted packet.
///   out: in_toggle                   - the bulk-IN data toggle for the next IN
///                                     DATA packet.
///
/// The cmd_ready / resp_valid handshake IS the bulk-endpoint ACK/NAK at the
/// byte granularity: when cmd_ready is low the OUT endpoint NAKs (host retries);
/// when resp_valid is low with the host polling IN, the IN endpoint NAKs.
///
/// FSM
///   OP        : read opcode byte.
///   A0..A3    : read 4 address bytes (LE).
///   L0..L1    : read 2 length bytes (LE).
///   DISPATCH  : WRITE -> WR_DATA (or DONE if len==0). READ -> RD_ISSUE.
///   WR_DATA   : read one data byte, accumulate it into the word register;
///               when the word is full, issue a full-word Wishbone write and
///               wait ack. Advance addr/count. Loop until count==len.
///   RD_ISSUE  : issue a Wishbone read of the word holding the next byte. Wait
///               ack. Latch the word.
///   RD_EMIT   : emit the addressed byte of the latched word on resp_*; advance;
///               when the word's remaining bytes are drained (or len reached),
///               go back to RD_ISSUE for the next word, else DONE.
///   DONE      : return to OP.
class MimicUsbCmdEngine extends BridgeModule {
  final MimicUsbDeviceConfig config;

  // Opcodes (shared with the host runtime, see regs.dart).
  static const int _opWrite = MimicUsbOpcode.write;
  static const int _opRead = MimicUsbOpcode.read;
  // Like WRITE, but the destination address does NOT increment: every word
  // lands on the same bus address. This is a FIFO push burst (e.g. streaming
  // block data into DATA_IN with one 7-byte header instead of one per word).
  static const int _opWriteStream = MimicUsbOpcode.writeStream;
  // Read one word repeatedly from the low 16 bits of the command address.
  // After each word, write 1 to the address in the high 16 bits. This keeps
  // FIFO removal explicit without one USB transaction per word.
  static const int _opReadPopStream = MimicUsbOpcode.readPopStream;
  // Read consecutive words, then write bit 0 to the packed pop address once.
  static const int _opReadThenPop = MimicUsbOpcode.readThenPop;

  // FSM states.
  static const int _stOp = 0;
  static const int _stA0 = 1;
  static const int _stA1 = 2;
  static const int _stA2 = 3;
  static const int _stA3 = 4;
  static const int _stL0 = 5;
  static const int _stL1 = 6;
  static const int _stDispatch = 7;
  static const int _stWrData = 8;
  static const int _stWrAck = 9;
  static const int _stRdIssue = 10;
  static const int _stRdAck = 11;
  static const int _stRdEmit = 12;
  static const int _stDone = 13;
  static const int _stRdPopIssue = 14;
  static const int _stRdPopAck = 15;

  MimicUsbCmdEngine({required this.config, String? name})
    : super('MimicUsbCmdEngine', name: name ?? 'mimic_usb_cmd_engine') {
    config.validate();

    final aw = config.busAddressWidth;
    final dw = config.busDataWidth;
    final bytesPerWord = config.bytesPerWord;
    // log2(bytesPerWord): low address bits that index the byte within a word.
    var wordShift = 0;
    for (var v = bytesPerWord; v > 1; v >>= 1) {
      wordShift++;
    }
    final selWidth = bytesPerWord;

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    createPort('cmd_data', PortDirection.input, width: 8);
    createPort('cmd_valid', PortDirection.input);
    // cmd_start: a one-cycle pulse from the EP1 bulk OUT endpoint the instant
    // a NEW command is accepted. It marks the start of a bulk TRANSFER, so a
    // command that spans several OUT packets gets ONE pulse, on its first
    // packet. (A pulse per packet would clear the parse state below in the
    // middle of a command and lose every byte after the first packet.) It
    // PREEMPTS any response still in flight: a host may issue a new command
    // after draining only part of a multi-byte READ response. Without a
    // preempt the engine would still be in RD_EMIT (cmd_ready low) when the
    // EP1 OUT drain needs to push the new command, and the EP1 engine's
    // _stEp1OutDrain would block on cmd_ready forever while RD_EMIT blocks on
    // resp_ready the (now-draining) EP1 engine can no longer pulse: a hard
    // DEADLOCK (OUT ACKs, every following IN times out). On cmd_start the FSM
    // snaps back to _stOp (cmd_ready high, response abandoned, bus cycle
    // dropped) so the new command is parsed cleanly. A new command
    // superseding a half-read response is the correct USB-bulk behaviour. Tie
    // to 0 when unused (backward compatible: the command-level sim tests
    // never pulse it).
    createPort('cmd_start', PortDirection.input);
    addOutput('cmd_ready');

    addOutput('resp_data', width: 8);
    addOutput('resp_valid');
    // resp_last: asserted (together with resp_valid) on the FINAL response
    // byte of the current READ - i.e. the byte whose acceptance completes the
    // requested `len`. A consumer that PACKS the response stream into one USB
    // bulk IN DATA packet (harbor's EP1-IN packet assembler) uses this to
    // know the response is exhausted: it drains bytes while resp_valid, and
    // stops after the byte on which resp_last was high (or at the
    // [mimicUsbMaxPacketSize] max-packet ceiling). Across a multi-WORD read resp_valid drops
    // transiently while the engine fetches the next word
    // (RD_ISSUE/RD_ACK), so resp_valid==0 alone is NOT a reliable "done"
    // signal. Resp_last is.
    addOutput('resp_last');
    createPort('resp_ready', PortDirection.input);

    addOutput('busy');
    addOutput('out_toggle');
    addOutput('in_toggle');

    // Wishbone MASTER interface.
    final busRef = addInterface(
      WishboneInterface(WishboneConfig(addressWidth: aw, dataWidth: dw)),
      name: 'bus',
      role: PairRole.provider, // master
    );
    final bus = busRef.internalInterface!;

    final clk = input('clk');
    final reset = input('reset');
    final cmdData = input('cmd_data');
    final cmdValid = input('cmd_valid');
    final cmdStart = input('cmd_start');
    final respReady = input('resp_ready');

    final state = Logic(name: 'state', width: 4);
    final opcode = Logic(name: 'opcode', width: 8);
    // Full byte address (32-bit working register. The bus address is the low
    // `aw` bits). 32 bits comfortably covers the u32 command address field.
    final addr = Logic(name: 'addr', width: 32);
    final len = Logic(name: 'len', width: 16); // bytes requested
    final count = Logic(name: 'count', width: 16); // bytes done so far

    // Master drive registers.
    final cycReg = Logic(name: 'cyc_reg');
    final stbReg = Logic(name: 'stb_reg');
    final weReg = Logic(name: 'we_reg');
    final adrReg = Logic(name: 'adr_reg', width: aw);
    final datReg = Logic(name: 'dat_reg', width: dw);
    final selReg = Logic(name: 'sel_reg', width: selWidth);

    // Write word accumulator (bytes packed LSB-first into a word, flushed as
    // a full-word Wishbone write).
    final wrAcc = Logic(name: 'wr_acc', width: dw);
    // Latched read word (for RD_EMIT).
    final rdWord = Logic(name: 'rd_word', width: dw);

    // Response stream registers.
    final respDataReg = Logic(name: 'resp_data_reg', width: 8);
    final respValidReg = Logic(name: 'resp_valid_reg');
    // High (with resp_valid) on the FINAL response byte of a READ. Registered
    // in lockstep with respDataReg so a packing consumer (harbor EP1-IN) sees
    // the last-byte marker aligned with the data byte it terminates.
    final respLastReg = Logic(name: 'resp_last_reg');

    // Bulk data-toggle bits (USB 2.0 bulk transfers alternate DATA0/DATA1 per
    // ACKed packet on each endpoint). Surfaced for the device top + sanity
    // test.
    final outToggle = Logic(name: 'out_toggle_reg');
    final inToggle = Logic(name: 'in_toggle_reg');

    //
    // WORD-ORIENTED transfers. The Mimic SD card's Wishbone slave does
    // FULL-WORD register writes (it ignores SEL: a CSR write stores all 32
    // bits). So the command engine accumulates the byte stream into 32-bit
    // words and issues ONE word write per word, and reads a whole word per
    // word the response needs. The command protocol is therefore
    // word-oriented for this slave: WRITE/READ addresses should be
    // word-aligned and lengths a multiple of bytesPerWord. A partial final
    // word writes its untouched high lanes as 0 (documented).
    //
    // Lane (byte within the current word) = (count) mod bytesPerWord. The
    // first byte of a command always lands in lane 0 because addr is
    // word-aligned by contract. The lane therefore tracks count, not addr.
    final laneSel = bytesPerWord == 1
        ? Const(0, width: 1)
        : count.slice(wordShift - 1, 0);
    final laneShiftBits = (laneSel.zeroExtend(32) * Const(8, width: 32)).named(
      'lane_shift_bits',
    );
    // The current command byte ORed into its byte lane of the accumulator.
    final byteInLane = bytesPerWord == 1
        ? cmdData
        : (cmdData.zeroExtend(dw) << laneShiftBits.slice(dw.bitLength - 1, 0))
              .named('byte_in_lane');
    final accNext = (wrAcc | byteInLane).named('acc_next');
    // Word-aligned bus address for the current byte (low wordShift bits
    // zeroed).
    final Logic wordAddr;
    if (bytesPerWord == 1) {
      wordAddr = addr.slice(aw - 1, 0);
    } else {
      wordAddr = [
        addr.slice(aw - 1, wordShift),
        Const(0, width: wordShift),
      ].swizzle();
    }
    // READ_POP_STREAM packs its explicit pop register in the high 16 bits.
    // The bus address width is at most 16 for this encoding.
    if (aw > 16) {
      throw ArgumentError.value(
        aw,
        'busAddressWidth',
        'READ_POP_STREAM requires a bus address width of 16 bits or less.',
      );
    }
    final popAddr = addr.slice(16 + aw - 1, 16).named('read_pop_addr');
    // This accepted byte is the last lane of its word (lane ==
    // bytesPerWord-1) OR the last byte of the whole transfer -> time to
    // flush a word write.
    final lastLane = bytesPerWord == 1
        ? Const(1)
        : laneSel.eq(Const(bytesPerWord - 1, width: laneSel.width));
    final lastByte = (count + Const(1, width: 16)).eq(len);
    final flushWord = (lastLane | lastByte).named('flush_word');
    // Streaming write (opcode 0x03): same byte-accumulate/word-flush path as
    // a normal WRITE, but the address is held fixed so every flushed word
    // writes the same register (a FIFO push). `isWrite` gates the data stage
    // for both.
    final isStream = opcode
        .eq(Const(_opWriteStream, width: 8))
        .named('is_stream');
    final isWrite = (opcode.eq(Const(_opWrite, width: 8)) | isStream).named(
      'is_write',
    );
    final isReadPop = opcode
        .eq(Const(_opReadPopStream, width: 8))
        .named('is_read_pop');
    final isReadThenPop = opcode
        .eq(Const(_opReadThenPop, width: 8))
        .named('is_read_then_pop');
    final finalReadWord = (count + Const(bytesPerWord, width: 16))
        .gte(len)
        .named('final_read_word');
    // The byte of the latched read word selected by the current lane.
    Logic rdByte = rdWord.slice(7, 0);
    for (var lane = 0; lane < bytesPerWord; lane++) {
      rdByte = mux(
        laneSel.eq(Const(lane, width: laneSel.width)),
        rdWord.slice(lane * 8 + 7, lane * 8),
        rdByte,
      );
    }
    // The byte at lane (count mod bpw) is the last in its word for READ when
    // the next byte starts a new word, mirroring the write side.
    final rdLastLane = bytesPerWord == 1
        ? Const(1)
        : laneSel.eq(Const(bytesPerWord - 1, width: laneSel.width));

    // cmd_ready: the engine accepts a command byte only in the header-collect
    // states and in WR_DATA (where it consumes the next data byte). It is the
    // OUT-endpoint NAK gate: low elsewhere so the host holds the stream.
    final inHeader =
        state.eq(Const(_stOp, width: 4)) |
        state.eq(Const(_stA0, width: 4)) |
        state.eq(Const(_stA1, width: 4)) |
        state.eq(Const(_stA2, width: 4)) |
        state.eq(Const(_stA3, width: 4)) |
        state.eq(Const(_stL0, width: 4)) |
        state.eq(Const(_stL1, width: 4));
    final cmdReadyLocal = (inHeader | state.eq(Const(_stWrData, width: 4)))
        .named('cmd_ready');

    // The byte that just arrived (consumed when cmd_ready & cmd_valid).
    final byteTaken = (cmdReadyLocal & cmdValid).named('byte_taken');

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(_stOp, width: 4),
          opcode < Const(0, width: 8),
          addr < Const(0, width: 32),
          len < Const(0, width: 16),
          count < Const(0, width: 16),
          cycReg < Const(0),
          stbReg < Const(0),
          weReg < Const(0),
          adrReg < Const(0, width: aw),
          datReg < Const(0, width: dw),
          selReg < Const(0, width: selWidth),
          wrAcc < Const(0, width: dw),
          rdWord < Const(0, width: dw),
          respDataReg < Const(0, width: 8),
          respValidReg < Const(0),
          respLastReg < Const(0),
          outToggle < Const(0),
          inToggle < Const(0),
        ],
        orElse: [
          // resp_valid is a single-cycle pulse unless held. Default clear and
          // let RD_EMIT re-assert. (A held byte that the host has not taken is
          // kept by re-asserting below while respReady is low.)
          respValidReg < Const(0),
          // resp_last tracks resp_valid: default clear, re-asserted in RD_EMIT.
          respLastReg < Const(0),

          // PREEMPT on a new command. cmd_start pulses the cycle the EP1 bulk
          // OUT endpoint accepts the FIRST packet of a new command transfer.
          // A command longer than the endpoint packet size arrives as more
          // than one packet, and the packets after the first carry no pulse,
          // so the parse state below survives a packet boundary. Whatever
          // this engine was doing (mid-READ in RD_ISSUE/RD_ACK/RD_EMIT,
          // mid-WRITE, header collect), abandon it and snap back to _stOp so
          // cmd_ready is high and the new command's bytes drain in cleanly.
          // This breaks the OUT-after-partial-read deadlock: a host that
          // walked away from a multi-byte READ response would otherwise leave
          // this engine in RD_EMIT (cmd_ready low) while the EP1 engine
          // blocks in _stEp1OutDrain waiting for cmd_ready - a hard wedge
          // (OUT ACKs, every following IN times out). Dropping the stale
          // response is the correct USB-bulk behaviour (a new command
          // supersedes a half-drained response). Also drop any live bus cycle
          // so we never leave cyc/stb asserted into the next command.
          If(
            cmdStart,
            then: [
              state < Const(_stOp, width: 4),
              count < Const(0, width: 16),
              wrAcc < Const(0, width: dw),
              cycReg < Const(0),
              stbReg < Const(0),
              weReg < Const(0),
              respValidReg < Const(0),
              respLastReg < Const(0),
            ],
            orElse: [
              Case(state, [
                CaseItem(Const(_stOp, width: 4), [
                  If(
                    byteTaken,
                    then: [
                      opcode < cmdData,
                      count < Const(0, width: 16),
                      state < Const(_stA0, width: 4),
                    ],
                  ),
                ]),
                CaseItem(Const(_stA0, width: 4), [
                  If(
                    byteTaken,
                    then: [
                      addr < cmdData.zeroExtend(32),
                      state < Const(_stA1, width: 4),
                    ],
                  ),
                ]),
                CaseItem(Const(_stA1, width: 4), [
                  If(
                    byteTaken,
                    then: [
                      addr <
                          (addr |
                              (cmdData.zeroExtend(32) << Const(8, width: 32))),
                      state < Const(_stA2, width: 4),
                    ],
                  ),
                ]),
                CaseItem(Const(_stA2, width: 4), [
                  If(
                    byteTaken,
                    then: [
                      addr <
                          (addr |
                              (cmdData.zeroExtend(32) << Const(16, width: 32))),
                      state < Const(_stA3, width: 4),
                    ],
                  ),
                ]),
                CaseItem(Const(_stA3, width: 4), [
                  If(
                    byteTaken,
                    then: [
                      addr <
                          (addr |
                              (cmdData.zeroExtend(32) << Const(24, width: 32))),
                      state < Const(_stL0, width: 4),
                    ],
                  ),
                ]),
                CaseItem(Const(_stL0, width: 4), [
                  If(
                    byteTaken,
                    then: [
                      len < cmdData.zeroExtend(16),
                      state < Const(_stL1, width: 4),
                    ],
                  ),
                ]),
                CaseItem(Const(_stL1, width: 4), [
                  If(
                    byteTaken,
                    then: [
                      len <
                          (len |
                              (cmdData.zeroExtend(16) << Const(8, width: 16))),
                      state < Const(_stDispatch, width: 4),
                    ],
                  ),
                ]),

                CaseItem(Const(_stDispatch, width: 4), [
                  // A completed OUT DATA packet (the command) was accepted:
                  // advance the OUT data toggle (USB bulk DATA0/DATA1
                  // alternation).
                  outToggle < ~outToggle,
                  count < Const(0, width: 16),
                  wrAcc < Const(0, width: dw),
                  If(
                    isWrite,
                    then: [
                      If(
                        len.eq(Const(0, width: 16)),
                        then: [state < Const(_stDone, width: 4)],
                        orElse: [state < Const(_stWrData, width: 4)],
                      ),
                    ],
                    orElse: [
                      If(
                        opcode.eq(Const(_opRead, width: 8)) |
                            isReadPop |
                            isReadThenPop,
                        then: [
                          If(
                            len.eq(Const(0, width: 16)),
                            then: [state < Const(_stDone, width: 4)],
                            orElse: [state < Const(_stRdIssue, width: 4)],
                          ),
                        ],
                        orElse: [
                          // Unknown opcode: drop the command (no data stage
                          // assumed).
                          state < Const(_stDone, width: 4),
                        ],
                      ),
                    ],
                  ),
                ]),

                CaseItem(Const(_stWrData, width: 4), [
                  If(
                    byteTaken,
                    then: [
                      wrAcc < accNext,
                      If(
                        flushWord,
                        then: [
                          // Issue a full-word write of the accumulated word at
                          // the word-aligned address, full SEL.
                          datReg < accNext,
                          selReg < Const((1 << selWidth) - 1, width: selWidth),
                          adrReg < wordAddr,
                          cycReg < Const(1),
                          stbReg < Const(1),
                          weReg < Const(1),
                          state < Const(_stWrAck, width: 4),
                        ],
                        orElse: [
                          // More bytes still fill this word: just advance the
                          // count.
                          count < count + Const(1, width: 16),
                        ],
                      ),
                    ],
                  ),
                ]),
                CaseItem(Const(_stWrAck, width: 4), [
                  If(
                    bus.ack,
                    then: [
                      cycReg < Const(0),
                      stbReg < Const(0),
                      weReg < Const(0),
                      wrAcc < Const(0, width: dw),
                      // Advance the byte address by one word (normal WRITE),
                      // or hold it fixed for a streaming FIFO push so the
                      // next word writes the same register. Count still
                      // advances so `len` bytes terminate.
                      addr <
                          mux(
                            isStream,
                            addr,
                            (addr + Const(bytesPerWord, width: 32)) &
                                ~Const(bytesPerWord - 1, width: 32),
                          ),
                      count < count + Const(1, width: 16),
                      If(
                        (count + Const(1, width: 16)).gte(len),
                        then: [state < Const(_stDone, width: 4)],
                        orElse: [state < Const(_stWrData, width: 4)],
                      ),
                    ],
                  ),
                ]),

                CaseItem(Const(_stRdIssue, width: 4), [
                  adrReg < wordAddr,
                  selReg < Const((1 << selWidth) - 1, width: selWidth),
                  cycReg < Const(1),
                  stbReg < Const(1),
                  weReg < Const(0),
                  state < Const(_stRdAck, width: 4),
                ]),
                CaseItem(Const(_stRdAck, width: 4), [
                  If(
                    bus.ack,
                    then: [
                      cycReg < Const(0),
                      stbReg < Const(0),
                      rdWord < bus.datMiso,
                      state <
                          mux(
                            isReadPop | (isReadThenPop & finalReadWord),
                            Const(_stRdPopIssue, width: 4),
                            Const(_stRdEmit, width: 4),
                          ),
                    ],
                  ),
                ]),

                CaseItem(Const(_stRdPopIssue, width: 4), [
                  // The word is already safe in rdWord. Pop it explicitly
                  // before exposing the response byte stream to the host.
                  // A command that is interrupted after this point has still
                  // performed the operation it requested.
                  adrReg < popAddr,
                  datReg < Const(1, width: dw),
                  selReg < Const((1 << selWidth) - 1, width: selWidth),
                  cycReg < Const(1),
                  stbReg < Const(1),
                  weReg < Const(1),
                  state < Const(_stRdPopAck, width: 4),
                ]),
                CaseItem(Const(_stRdPopAck, width: 4), [
                  If(
                    bus.ack,
                    then: [
                      cycReg < Const(0),
                      stbReg < Const(0),
                      weReg < Const(0),
                      state < Const(_stRdEmit, width: 4),
                    ],
                  ),
                ]),

                CaseItem(Const(_stRdEmit, width: 4), [
                  // Assert valid for the byte currently selected by `count`.
                  // resp_data and resp_last are driven COMBINATIONALLY (at
                  // the output wiring) from `count`/rdByte, NOT registered
                  // here: registering resp_data from rdByte(count) (itself a
                  // function of the registered count) lags the data ~2 cycles
                  // behind count, so a streaming consumer that drains every
                  // byte (the EP1-IN packet assembler) reads each byte stale
                  // and duplicates it, and the last-byte marker mis-aligns.
                  // Combinational resp_data = byte[count] is stable for the
                  // whole held cycle and advances exactly when `count` does.
                  // valid stays registered (held high across the emit. Only
                  // the byte index moves).
                  respValidReg < Const(1),
                  If(
                    respReady,
                    then: [
                      inToggle < ~inToggle,
                      count < count + Const(1, width: 16),
                      If(
                        (count + Const(1, width: 16)).eq(len),
                        then: [state < Const(_stDone, width: 4)],
                        orElse: [
                          If(
                            rdLastLane,
                            then: [
                              // Crossed a word boundary -> fetch the next
                              // word. A read-and-pop stream holds the data
                              // address fixed. A normal read advances it.
                              If(
                                ~isReadPop,
                                then: [
                                  addr <
                                      (addr + Const(bytesPerWord, width: 32)) &
                                          ~Const(bytesPerWord - 1, width: 32),
                                ],
                              ),
                              state < Const(_stRdIssue, width: 4),
                            ],
                            orElse: [
                              // Same word -> emit the next byte directly.
                              state < Const(_stRdEmit, width: 4),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ]),

                CaseItem(Const(_stDone, width: 4), [
                  state < Const(_stOp, width: 4),
                ]),
              ]),
            ],
          ),
        ],
      ),
    ]);

    output('cmd_ready') <= cmdReadyLocal;
    // resp_valid is REGISTERED (held high across the emit). resp_data and
    // resp_last are COMBINATIONAL in RD_EMIT so they track `count` with no
    // lag:
    //   resp_data = rdByte = byte[count] of the latched read word.
    //   resp_last = (count == len-1), the final byte of the response.
    // resp_valid is only ever high in RD_EMIT, so a consumer only samples
    // these there. Outside RD_EMIT we present the (idle) registered/zero
    // values.
    //
    // resp_valid is COMBINATIONAL on the state, exactly like resp_data: a
    // byte is offered for every RD_EMIT cycle and only those. A registered
    // valid (asserted inside RD_EMIT, cleared only by the default) stays
    // high one cycle PAST the state, into RD_ISSUE at a word boundary and
    // into DONE at the end, while resp_data has already muxed away to the
    // idle register: a consumer sampling that stale cycle (the EP1 IN
    // gather) captures a garbage byte per word boundary and the response
    // grows by one byte per word. With the valid tracking the state, the
    // offer and the byte can never disagree.
    output('resp_data') <=
        mux(state.eq(Const(_stRdEmit, width: 4)), rdByte, respDataReg);
    output('resp_valid') <= state.eq(Const(_stRdEmit, width: 4));
    output('resp_last') <=
        (state.eq(Const(_stRdEmit, width: 4)) &
                count.eq(len - Const(1, width: 16)))
            .named('resp_last');
    output('busy') <= ~state.eq(Const(_stOp, width: 4));
    output('out_toggle') <= outToggle;
    output('in_toggle') <= inToggle;

    bus.cyc <= cycReg;
    bus.stb <= stbReg;
    bus.we <= weReg;
    bus.adr <= adrReg;
    bus.datMosi <= datReg;
    bus.sel <= selReg;
  }

  @override
  Future<void> build() async {
    // Tie cmd_start to 0 when unconnected, so the engine never preempts
    // unless a caller wires the preempt input (command-level tests that
    // drive cmd_*/resp_* directly and never pulse cmd_start are unaffected).
    // Same idiom as harbor's sink_ready tie-off: input('cmd_start')
    // .srcConnection is the engine-internal receiver, and its own
    // srcConnection is null when nothing external drives the port.
    final portLogic = input('cmd_start').srcConnection;
    if (portLogic == null || portLogic.srcConnection == null) {
      port('cmd_start').tieOff(value: 0);
    }
    await super.build();
  }
}

// Top: MimicUsbDevice

/// A custom vendor-class full-speed USB device exposing two bulk endpoints +
/// a Wishbone-master command bridge. Composes harbor's PROVEN
/// [HarborUsbFsDevice] (the ch9 EP0 control FSM + the EP1 bulk endpoints on
/// the ported TinyFPGA line, packet and protocol layers) with the net-new
/// bulk [MimicUsbCmdEngine] (the Wishbone master).
///
/// The EP0 engine is harbor's, configured with mimic's VENDOR descriptors
/// (injected via [HarborUsbFsDevice.descriptors]) and with
/// [HarborUsbFsDevice.bulkEndpoints] enabled. The descriptor data lives in
/// [MimicUsbDescriptorRom] and is handed to harbor's engine as injected
/// descriptors. Every endpoint declares [mimicUsbMaxPacketSize] bytes, the
/// ceiling of the ported endpoint buffer.
///
/// Ports:
///   in:  clk, reset                  (48 MHz USB domain)
///   the D+/D- line, in one of two shapes (see [MimicUsbDevice.ownPads]):
///     in:  dp, dm / out: dp_out, dm_out, oe   (split, the default)
///     inout: usb_dp, usb_dm                   (one bidirectional ball each)
///   out: usb_pullup                  (1k5 full-speed pull-up enable on D+)
///   out: Wishbone MASTER 'bus'       (to the SD card's Wishbone slave)
///   out: configured / dev_addr       (EP0 enumeration observability)
///   out: busy / out_toggle / in_toggle (command-engine observability)
///
/// Bulk endpoint wiring
/// The EP0 engine decodes incoming USB tokens and, for EP1, routes the bulk
/// OUT DATA payload bytes into the command engine's `cmd_*` stream (NAK via
/// cmd_ready) and serializes the command engine's `resp_*` response stream
/// back as EP1 IN DATA packets (NAK when no response byte is ready), with
/// per-endpoint DATA0/DATA1 toggles. So a host GET_DESCRIPTOR returns the
/// VENDOR device (class 0xFF, VID/PID, two bulk endpoints) and bulk traffic
/// on EP1 drives Wishbone reads/writes.
///
/// Testbench command ports
/// When [tbCmdPorts] is true (default, for the existing command-level sim
/// tests) the command engine's byte streams are ALSO exposed at the top as
/// `cmd_*` / `resp_*` so a testbench can drive commands without a full raw
/// dp/dm bulk exchange. In the synthesizable SoC build [tbCmdPorts] is false:
/// the only path to the command engine is the real EP1 bulk endpoints
/// through the PHY.
class MimicUsbDevice extends BridgeModule {
  final MimicUsbDeviceConfig config;

  /// When true, expose the command-engine byte streams (`cmd_*`/`resp_*`) as
  /// top-level ports for command-level sim. When false, the command engine is
  /// driven ONLY by the EP1 bulk endpoints (the synthesizable path).
  final bool tbCmdPorts;

  /// Collapse the split D+/D- `dp`/`dm` in + `dp_out`/`dm_out`/`oe` out ports
  /// into single bidirectional `usb_dp` / `usb_dm` pads (a `TriStateBuffer`
  /// per line), the shape an FPGA IOBUF wants. Off by default so the
  /// verification tests drive the split ports; genip turns it on to bind one
  /// inout pad per line to a board pin.
  final bool ownPads;

  MimicUsbDevice({
    required this.config,
    String? name,
    this.tbCmdPorts = true,
    this.ownPads = false,
  }) : super('MimicUsbDevice', name: name ?? 'mimic_usb_device') {
    config.validate();

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    // USB line pads. With [ownPads] D+ and D- are single inout pads (tristate
    // driven below); otherwise they are the split in + out + oe set the sim
    // tests exercise. The split set is not a workaround: it lets a host model
    // drive the line and watch the device answer without a shared
    // bidirectional net, which ROHD does not co-simulate between siblings.
    if (ownPads) {
      createPort('usb_dp', PortDirection.inOut);
      createPort('usb_dm', PortDirection.inOut);
    } else {
      createPort('dp', PortDirection.input);
      createPort('dm', PortDirection.input);
      addOutput('dp_out');
      addOutput('dm_out');
      addOutput('oe');
    }
    addOutput('usb_pullup');

    if (tbCmdPorts) {
      // Testbench command/response byte streams (command-level sim only).
      createPort('cmd_data', PortDirection.input, width: 8);
      createPort('cmd_valid', PortDirection.input);
      addOutput('cmd_ready');
      addOutput('resp_data', width: 8);
      addOutput('resp_valid');
      addOutput('resp_last');
      createPort('resp_ready', PortDirection.input);
    }

    // Observability.
    addOutput('configured');
    addOutput('dev_addr', width: 7);
    addOutput('busy');
    addOutput('out_toggle');
    addOutput('in_toggle');

    final clk = input('clk');
    final reset = input('reset');

    // Harbor's full-speed USB device on the ported tinyfpga protocol
    // engine: chapter-9 control on endpoint 0 from
    // the injected VENDOR descriptors plus the EP1 bulk streams. The
    // line PHY, packet framing and endpoint protocol engines all live
    // inside the ported core. The token decode filters by device
    // address, so shared-bus contention is impossible by construction.
    final ep0 = HarborUsbFsDevice(
      name: 'dev_ep0',
      descriptors: MimicUsbDescriptorRom.descriptorEntries(
        idVendor: config.idVendor,
        idProduct: config.idProduct,
        bulkEndpoints: config.bulkEndpoints,
        serialNumber: config.serialNumber,
      ),
      bulkEndpoints: config.bulkEndpoints,
      maxPacketSize: mimicUsbMaxPacketSize,
    );
    addSubModule(ep0);
    ep0.input('clk').srcConnection! <= clk;
    ep0.input('reset').srcConnection! <= reset;

    if (ownPads) {
      // One IOBUF per line: drive the pad while the engine asserts its output
      // enable, otherwise release the pad and read it back in. The engine
      // squelches its own transmission internally, so the readback is safe
      // while the device drives.
      final dpPad = inOut('usb_dp');
      final dmPad = inOut('usb_dm');
      final oe = ep0.output('oe');
      dpPad <= TriStateBuffer(ep0.output('dp_out'), enable: oe).out;
      dmPad <= TriStateBuffer(ep0.output('dm_out'), enable: oe).out;
      ep0.input('dp').srcConnection! <= dpPad;
      ep0.input('dm').srcConnection! <= dmPad;
    } else {
      ep0.input('dp').srcConnection! <= input('dp');
      ep0.input('dm').srcConnection! <= input('dm');
      output('dp_out') <= ep0.output('dp_out');
      output('dm_out') <= ep0.output('dm_out');
      output('oe') <= ep0.output('oe');
    }
    output('usb_pullup') <= ep0.output('usb_pullup');
    output('configured') <= ep0.output('configured');
    output('dev_addr') <= ep0.output('dev_addr');

    // The net-new bulk command engine + Wishbone master.
    final engine = MimicUsbCmdEngine(config: config, name: 'dev_cmd_engine');
    addSubModule(engine);
    engine.input('clk').srcConnection! <= clk;
    // Reset the command engine on FPGA reset OR a USB bus reset. A host
    // re-enumerates (drives SE0) on every plug / driver attach. The EP0
    // engine snaps to its Default state, and the command engine MUST too.
    // Otherwise a command left mid-FSM from a prior session (e.g. waiting on
    // a Wishbone ack that never returned) would hold cmd_ready low across
    // the re-enumeration, and the host's first bulk OUT would find the engine
    // unable to accept the command - the OUT endpoint would never drain and
    // the host would HALT it (the EPIPE/STALL). Folding bus_reset into the
    // engine reset guarantees the engine is in _stOp (cmd_ready high) for
    // the host's first OUT.
    final cmdReset = (reset | ep0.output('bus_reset')).named('cmd_reset');
    engine.input('reset').srcConnection! <= cmdReset;
    output('busy') <= engine.output('busy');
    output('out_toggle') <= engine.output('out_toggle');
    output('in_toggle') <= engine.output('in_toggle');

    // EP1 OUT: the command byte stream into the engine.
    //
    // The EP0 engine holds the drained byte in an endpoint buffer register
    // that has no reset, so cmd_data reads as X in simulation until the
    // first packet arrives. The command engine samples cmd_data only while
    // cmd_valid is high, but an OR with the testbench port would still carry
    // that X into the engine. The mask keeps the OR clean.
    final devCmdData = mux(
      ep0.output('cmd_valid'),
      ep0.output('cmd_data'),
      Const(0, width: 8),
    ).named('dev_cmd_data_masked');

    // The EP1 bulk command/response streams exist only when the device
    // DECLARES bulk endpoints. In the control-only ENUMERATION-ISOLATION
    // build (config.bulkEndpoints == false) the EP0 engine has no EP1 ports,
    // so the command engine is fed by the testbench ports (if any) or tied
    // off and is intentionally undriveable through USB.
    if (config.bulkEndpoints) {
      if (tbCmdPorts) {
        // Command stream: the testbench port and the EP1 OUT endpoint are
        // OR-ed, because a test drives one or the other, never both at once.
        engine.input('cmd_data').srcConnection! <=
            (input('cmd_data') | devCmdData);
        engine.input('cmd_valid').srcConnection! <=
            (input('cmd_valid') | ep0.output('cmd_valid'));
        // Response stream: the testbench port is the ONLY consumer. The EP1
        // IN endpoint reports room the whole time it is armed, not only
        // while a host IN token is being answered, so an OR here would let
        // the endpoint swallow the bytes the testbench wants to read. A
        // tbCmdPorts build is for command-level sim, so the testbench owns
        // the response path and the EP0 engine gets an idle EP1 IN stream.
        engine.input('resp_ready').srcConnection! <= input('resp_ready');
        // The EP1 new-command preempt (the testbench command ports never
        // pulse it. OR-with-0 keeps them unaffected).
        engine.input('cmd_start').srcConnection! <= ep0.output('cmd_start');
        output('cmd_ready') <= engine.output('cmd_ready');
        output('resp_data') <= engine.output('resp_data');
        output('resp_valid') <= engine.output('resp_valid');
        output('resp_last') <= engine.output('resp_last');

        ep0.input('cmd_ready').srcConnection! <= engine.output('cmd_ready');
        ep0.input('resp_data').srcConnection! <= Const(0, width: 8);
        ep0.input('resp_valid').srcConnection! <= Const(0);
        ep0.input('resp_last').srcConnection! <= Const(0);
      } else {
        // Synthesizable path: the EP1 endpoints are the only path in and
        // the only path out.
        engine.input('cmd_data').srcConnection! <= devCmdData;
        engine.input('cmd_valid').srcConnection! <= ep0.output('cmd_valid');
        engine.input('resp_ready').srcConnection! <= ep0.output('resp_ready');
        engine.input('cmd_start').srcConnection! <= ep0.output('cmd_start');

        // EP1 IN response stream back from the command engine to the EP0
        // engine. resp_last marks the final byte, which lets the EP1-IN
        // assembler pack the whole response into one bulk IN DATA packet (no
        // 1-byte short packets).
        ep0.input('cmd_ready').srcConnection! <= engine.output('cmd_ready');
        ep0.input('resp_data').srcConnection! <= engine.output('resp_data');
        ep0.input('resp_valid').srcConnection! <= engine.output('resp_valid');
        ep0.input('resp_last').srcConnection! <= engine.output('resp_last');
      }
    } else {
      // Control-only variant: no EP1 path. Feed the command engine from the
      // testbench ports when present, else tie its stream inputs inert (the
      // engine simply never advances. The bus master is dormant).
      if (tbCmdPorts) {
        engine.input('cmd_data').srcConnection! <= input('cmd_data');
        engine.input('cmd_valid').srcConnection! <= input('cmd_valid');
        engine.input('resp_ready').srcConnection! <= input('resp_ready');
        engine.input('cmd_start').srcConnection! <= Const(0);
        output('cmd_ready') <= engine.output('cmd_ready');
        output('resp_data') <= engine.output('resp_data');
        output('resp_valid') <= engine.output('resp_valid');
        output('resp_last') <= engine.output('resp_last');
      } else {
        engine.input('cmd_data').srcConnection! <= Const(0, width: 8);
        engine.input('cmd_valid').srcConnection! <= Const(0);
        engine.input('resp_ready').srcConnection! <= Const(0);
        engine.input('cmd_start').srcConnection! <= Const(0);
      }
      // The EP0 engine keeps its EP1 stream inputs in every build, so tie
      // them off. The control-only device generates no EP1 logic behind
      // them.
      ep0.input('cmd_ready').srcConnection! <= Const(0);
      ep0.input('resp_data').srcConnection! <= Const(0, width: 8);
      ep0.input('resp_valid').srcConnection! <= Const(0);
      ep0.input('resp_last').srcConnection! <= Const(0);
    }

    // Expose the Wishbone MASTER interface 'bus' at the top.
    pullUpInterface(engine.interface('bus'), newIntfName: 'bus');
  }

  /// Build-time config validation.
  void validate() => config.validate();
}
