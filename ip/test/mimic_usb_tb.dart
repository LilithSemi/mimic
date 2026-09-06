// A PHY-level testbench for the Mimic SoC: the SoC built with no command
// ports, plus a host that drives real USB packets on the D+/D- pads.
//
// Shared by usb_full_path_test.dart and usb_gap_sweep_test.dart so both
// exercise the same host behaviour: real tokens with a CRC5, real data
// packets with a CRC16, per-endpoint data toggles, NAK retries and multi
// packet transfers.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_host_model.dart';

/// The device address the testbench assigns with SET_ADDRESS.
const int mimicTbDevAddr = 7;

/// The endpoint that carries the vendor command protocol.
const int mimicTbCmdEndp = 1;

/// The maximum packet payload of every endpoint of this device.
const int mimicTbMaxPacket = mimicUsbMaxPacketSize;

/// A WRITE command frame: header then the data bytes.
List<int> mimicWriteFrame(int addr, List<int> data) => [
  0x01,
  addr & 0xFF,
  (addr >> 8) & 0xFF,
  (addr >> 16) & 0xFF,
  (addr >> 24) & 0xFF,
  data.length & 0xFF,
  (data.length >> 8) & 0xFF,
  ...data,
];

/// A WRITE_STREAM command frame: header then the data bytes. The address
/// stays fixed, so every word lands on the same register.
List<int> mimicWriteStreamFrame(int addr, List<int> data) => [
  MimicUsbOpcode.writeStream,
  addr & 0xFF,
  (addr >> 8) & 0xFF,
  (addr >> 16) & 0xFF,
  (addr >> 24) & 0xFF,
  data.length & 0xFF,
  (data.length >> 8) & 0xFF,
  ...data,
];

/// The little-endian bytes of the 32-bit [words].
List<int> mimicWordBytes(List<int> words) => [
  for (final w in words) ...[
    w & 0xFF,
    (w >> 8) & 0xFF,
    (w >> 16) & 0xFF,
    (w >> 24) & 0xFF,
  ],
];

/// A READ command frame: header only.
List<int> mimicReadFrame(int addr, int len) => [
  0x02,
  addr & 0xFF,
  (addr >> 8) & 0xFF,
  (addr >> 16) & 0xFF,
  (addr >> 24) & 0xFF,
  len & 0xFF,
  (len >> 8) & 0xFF,
];

/// The little-endian 32-bit word that the first four bytes of [b] hold.
int mimicWord(List<int> b) => b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);

/// The SoC and the host that drives its pads.
class MimicUsbTb {
  /// The SoC under test.
  final HarborSoC soc;

  /// The host line model.
  final UsbLineHost host;

  /// The data toggle the next EP1 OUT data packet carries.
  bool outToggle = false;

  MimicUsbTb(this.soc, this.host);

  /// Waits [cycles] clock edges while watching the device line.
  Future<void> settle(int cycles) => host.settle(cycles);

  /// Sends the SETUP stage of a control transfer and returns the handshake.
  Future<UsbRxPacket> setupStage(int addr, List<int> setup) async {
    await host.sendToken(usbPidSetup, addr: addr, endp: 0);
    await host.sendData(usbPidData0, setup);
    return host.expectPacket();
  }

  /// Runs one control transfer that has no data stage: SETUP, then the IN
  /// status stage with its zero-length DATA1, then the host ACK.
  Future<void> controlNoData(int addr, List<int> setup, String label) async {
    final ack = await setupStage(addr, setup);
    expect(ack.pid, equals(usbPidAck), reason: '$label data ACK');

    await host.sendToken(usbPidIn, addr: addr, endp: 0);
    final zlp = await host.expectPacket();
    expect(zlp.pid, equals(usbPidData1), reason: '$label status ZLP');
    expect(zlp.bytes, isEmpty, reason: '$label status ZLP has no payload');
    await host.sendHandshake(usbPidAck);
    await settle(40);
  }

  /// Runs one control read: SETUP, the IN data stage over as many packets as
  /// the 32-byte control endpoint needs, then the OUT status stage. Returns
  /// the bytes the device served.
  Future<List<int>> controlRead(
    int addr,
    List<int> setup,
    String label, {
    int maxPackets = 8,
  }) async {
    final ack = await setupStage(addr, setup);
    expect(ack.pid, equals(usbPidAck), reason: '$label setup ACK');

    final wLength = setup[6] | (setup[7] << 8);
    final out = <int>[];
    for (var i = 0; i < maxPackets; i++) {
      await host.sendToken(usbPidIn, addr: addr, endp: 0);
      final data = await host.expectPacket();
      expect(
        data.pid,
        anyOf(equals(usbPidData0), equals(usbPidData1)),
        reason: '$label IN packet $i is data',
      );
      await host.sendHandshake(usbPidAck);
      await settle(20);
      out.addAll(data.bytes);
      // The data stage ends on a packet shorter than the endpoint size, or
      // when the host has the full wLength it asked for.
      if (data.bytes.length < mimicTbMaxPacket || out.length >= wLength) break;
    }

    // The OUT status stage: a zero-length DATA1 that the device ACKs.
    await host.sendToken(usbPidOut, addr: addr, endp: 0);
    await host.sendData(usbPidData1, const []);
    final st = await host.expectPacket();
    expect(st.pid, equals(usbPidAck), reason: '$label status ACK');
    await settle(20);
    return out;
  }

  /// SET_ADDRESS then SET_CONFIGURATION, each with its full status stage.
  Future<void> enumerate() async {
    await controlNoData(0, [
      0x00,
      0x05,
      mimicTbDevAddr,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
    ], 'SET_ADDRESS');
    await controlNoData(mimicTbDevAddr, [
      0x00,
      0x09,
      0x01,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
    ], 'SET_CONFIGURATION');
  }

  /// Sends one command frame on EP1 OUT and waits for the ACK, retrying the
  /// whole transaction while the endpoint NAKs, the way a host controller
  /// does. Advances the data toggle on success. Returns false when every
  /// retry NAKs.
  Future<bool> bulkOut(List<int> payload, {int retries = 20}) async {
    final pid = outToggle ? usbPidData1 : usbPidData0;
    for (var i = 0; i < retries; i++) {
      await host.sendToken(
        usbPidOut,
        addr: mimicTbDevAddr,
        endp: mimicTbCmdEndp,
      );
      await host.sendData(pid, payload);
      final ack = await host.expectPacket(timeout: 2000);
      if (ack.pid == usbPidAck) {
        outToggle = !outToggle;
        return true;
      }
      await settle(50);
    }
    return false;
  }

  /// Sends one command frame on EP1 OUT as a full USB bulk transfer: as many
  /// [mimicTbMaxPacket] packets as the frame needs, and a last packet that is
  /// shorter than [mimicTbMaxPacket] to end the transfer. A frame whose
  /// length is a multiple of the packet size gets a zero-length packet at the
  /// end, as a host controller does. Returns false when the device never ACKs
  /// a packet.
  Future<bool> bulkOutFrame(List<int> frame, {int retries = 20}) async {
    var off = 0;
    var lastFull = true;
    while (off < frame.length || lastFull) {
      final end = off + mimicTbMaxPacket < frame.length
          ? off + mimicTbMaxPacket
          : frame.length;
      if (!await bulkOut(frame.sublist(off, end), retries: retries)) {
        return false;
      }
      lastFull = end - off == mimicTbMaxPacket;
      off = end;
      await settle(30);
    }
    return true;
  }

  /// Polls EP1 IN until the endpoint answers with a data packet, then ACKs
  /// it. Returns an empty packet when every poll NAKs.
  Future<UsbRxPacket> bulkIn({int retries = 60, bool ack = true}) async {
    for (var i = 0; i < retries; i++) {
      await host.sendToken(
        usbPidIn,
        addr: mimicTbDevAddr,
        endp: mimicTbCmdEndp,
      );
      final p = await host.expectPacket(timeout: 3000);
      if (p.pid == usbPidData0 || p.pid == usbPidData1) {
        if (ack) {
          await host.sendHandshake(usbPidAck);
          await settle(20);
        }
        return p;
      }
      await settle(30);
    }
    return const UsbRxPacket(-1, <int>[]);
  }

  /// Reads a response of [len] bytes over as many bulk IN packets as the
  /// 32-byte endpoint needs.
  Future<List<int>> bulkInBytes(int len) async {
    final out = <int>[];
    while (out.length < len) {
      final p = await bulkIn();
      if (p.isEmpty) break;
      out.addAll(p.bytes);
      if (p.bytes.length < mimicTbMaxPacket) break;
    }
    return out;
  }
}

/// Builds the SoC, wires the host line model to its pads, releases reset and
/// returns the testbench ready for traffic.
Future<MimicUsbTb> buildMimicUsbTb(
  String name, {
  int maxSimTime = 400000000,
}) async {
  final soc = buildMimicSoc(name: name, tbCmdPorts: false);

  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final dp = Logic(name: 'host_dp');
  final dm = Logic(name: 'host_dm');

  soc.port('clk').getsLogic(clk);
  soc.port('reset').getsLogic(reset);
  soc.port('usb_dp').getsLogic(dp);
  soc.port('usb_dm').getsLogic(dm);

  // The SD pins. This bench drives USB only, but the SoC holds an SD card
  // and its inputs are ports of the top module. An input with no driver
  // holds X, and the X goes through the clock domain crossing into the SoC
  // domain, where it reaches the CSR read data. A read that covers the CSD
  // registers then returns X and the response stops.
  //
  // The SD clock stays LOW, because this bench has no SD host. That is what
  // a card sees before a host arrives, and it keeps the card in reset. CMD
  // and DAT stay HIGH, which is what the pull-up of an idle line gives.
  final sdClk = Logic(name: 'sd_clk_tb');
  final sdCmdIn = Logic(name: 'sd_cmd_in_tb');
  final sdDatIn = Logic(name: 'sd_dat_in_tb');
  soc.port(mimicSdClkPinName).getsLogic(sdClk);
  soc.port('sd_cmd_in').getsLogic(sdCmdIn);
  soc.port('sd_dat_in').getsLogic(sdDatIn);

  final obs = UsbLineHost.observer(
    clk: clk,
    reset: reset,
    oe: soc.output('usb_oe'),
    dpOut: soc.output('usb_dp_out'),
    dmOut: soc.output('usb_dm_out'),
  );

  await soc.build();
  await obs.build();

  final host = UsbLineHost(clk: clk, dp: dp, dm: dm, obs: obs);

  // The reset starts at 0 and goes to 1 one clock later, so the SD domain
  // sees a real 0 to 1 edge on its reset.
  //
  // [MimicResetSync] takes the SoC reset as an ASYNCHRONOUS reset, which
  // needs that edge. A reset that starts at 1 goes from X to 1, the
  // asynchronous reset never asserts, and the module holds X. The SD clock
  // stays low in this bench, so no clock edge ever clears the X either: the
  // whole SD domain then holds X, the X crosses into the bus domain and
  // CARD_STATE and the DBG_SD_* registers read X. A READ that covers them
  // puts X bytes in a bulk IN packet and the host cannot decode the packet.
  reset.inject(0);
  sdClk.inject(0);
  sdCmdIn.inject(1);
  sdDatIn.inject(1);
  host.idle();
  Simulator.setMaxSimTime(maxSimTime);
  unawaited(Simulator.run().then((_) {}, onError: (Object _) {}));

  await clk.nextPosedge;
  reset.inject(1);
  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);
  await host.settle(40);

  return MimicUsbTb(soc, host);
}
