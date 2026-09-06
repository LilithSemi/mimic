// MimicSdRegTx: the card register sender of the SD card personality.
//
// Some commands answer with a value that the CARD holds and not with a
// block that the runtime supplies. ACMD51 sends the 8 bytes of the SCR and
// CMD6 sends the 64 bytes of the switch status. Each of those goes out on
// DAT0 in the same frame shape a block read uses: a start bit, the payload
// most significant byte first, a CRC16 and an end bit. Only the LENGTH is
// different.
//
// This module is the sender for those frames. It takes the whole value in
// one clock, it waits for the response on CMD to end, and it then feeds
// [MimicSdLink] one byte at a time. It holds no knowledge of any register:
// the state machine gives it the bytes and the length, so a command that a
// later phase adds needs no change here.
//
// The block read path is NOT this module. A block comes from the runtime
// over a clock domain crossing and needs a request, a tag and a timeout,
// and [MimicSdReadPath] owns all of that. A card register is already in
// this clock domain and needs none of it.

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'sd_link.dart' show sdDataTxLenBits;

/// Sender state 0: no frame is in progress.
const int sdRegTxStateIdle = 0;

/// Sender state 1: the value is held and the sender waits for CMD to free.
const int sdRegTxStateWait = 1;

/// Sender state 2: the frame is going out on DAT.
const int sdRegTxStateSend = 2;

/// Number of bits in the sender state register.
final int sdRegTxStateBits = sdRegTxStateSend.bitLength;

/// The card register sender.
///
/// A pulse on `start` with the value on `data` and the length in bytes on
/// `bytes` sends one frame. `data` holds the value with the byte that goes
/// out FIRST in the most significant byte, which is the order
/// `sdScrToBytes` gives. A value shorter than [maxBytes] therefore sits at
/// the TOP of the port and the low bytes are not read.
///
/// `busy` is high from the start pulse until the link reports the end bit.
/// `ready` is the opposite, and a start pulse while `ready` is low does
/// nothing at all.
///
/// The frame waits for `cmd_busy` to fall, because the card answers the
/// command on CMD first and sends the payload on DAT after it.
class MimicSdRegTx extends BridgeModule {
  /// Largest number of payload bytes one frame carries.
  ///
  /// The `data` port is this many bytes wide. ACMD51 needs 8. CMD6 needs
  /// 64 and a build that adds it must widen this, because a value wider
  /// than the port would lose its top bytes with no message.
  final int maxBytes;

  /// Makes the card register sender.
  MimicSdRegTx({required this.maxBytes, String? name})
    : super('MimicSdRegTx', name: name ?? 'sd_reg_tx') {
    if (maxBytes < 1) {
      throw ArgumentError.value(
        maxBytes,
        'maxBytes',
        'must be 1 or more. A frame of 0 bytes is not a frame.',
      );
    }
    if (maxBytes.bitLength > sdDataTxLenBits) {
      // The link holds the length in sdDataTxLenBits bits, and Const
      // truncates a wider value with no message. A truncated length is a
      // frame that stops in the middle and a host that reads a CRC error.
      throw ArgumentError.value(
        maxBytes,
        'maxBytes',
        'needs ${maxBytes.bitLength} bits and the transmit length of the '
            'link is $sdDataTxLenBits bits.',
      );
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('data', PortDirection.input, width: maxBytes * 8);
    createPort('bytes', PortDirection.input, width: sdDataTxLenBits);

    // The link is sending a response on CMD. The payload follows the
    // response, so the frame waits for this to fall.
    createPort('cmd_busy', PortDirection.input);

    createPort('tx_next', PortDirection.input);
    createPort('tx_done', PortDirection.input);

    addOutput('tx_start');
    addOutput('tx_byte', width: 8);
    addOutput('tx_len', width: sdDataTxLenBits);
    addOutput('busy');
    addOutput('ready');

    final clk = input('clk');
    final reset = input('reset');

    final stateIdle = Const(sdRegTxStateIdle, width: sdRegTxStateBits);
    final stateWait = Const(sdRegTxStateWait, width: sdRegTxStateBits);
    final stateSend = Const(sdRegTxStateSend, width: sdRegTxStateBits);

    final state = Logic(name: 'reg_tx_state', width: sdRegTxStateBits);
    final shift = Logic(name: 'reg_tx_shift', width: maxBytes * 8);
    final lenReg = Logic(name: 'reg_tx_len', width: sdDataTxLenBits);

    // The response of this command has been seen on CMD.
    //
    // The wait ends on the FALL of `cmd_busy` and never on a low that no
    // response has raised. A sender that read the low alone could put the
    // payload on DAT before the response went out, and a host that reads
    // CMD first would then miss the start bit of the frame.
    final sawBusy = Logic(name: 'reg_tx_saw_busy');

    final inIdle = state.eq(stateIdle).named('reg_tx_in_idle');
    final inWait = state.eq(stateWait).named('reg_tx_in_wait');
    final inSend = state.eq(stateSend).named('reg_tx_in_send');

    final ready = inIdle.named('reg_tx_ready');
    final take = (ready & input('start')).named('reg_tx_take');

    // The clock the frame opens in. The link reads `tx_byte` in the clock
    // AFTER this one, and the shift register already holds byte 0 here, so
    // no load is needed on this edge.
    final go = (inWait & sawBusy & ~input('cmd_busy')).named('reg_tx_go');

    // The byte that goes out first is the most significant one, which is
    // the order a card sends a register in.
    final shiftNext =
        (maxBytes == 1
                ? Const(0, width: 8)
                : [
                    shift.slice(maxBytes * 8 - 9, 0),
                    Const(0, width: 8),
                  ].swizzle())
            .named('reg_tx_shift_next');

    Sequential(
      clk,
      reset: reset,
      resetValues: {
        state: stateIdle,
        shift: Const(0, width: maxBytes * 8),
        lenReg: Const(maxBytes, width: sdDataTxLenBits),
        sawBusy: Const(0),
      },
      [
        Case(state, [
          CaseItem(stateIdle, [
            If(
              take,
              then: [
                // The whole value in one clock. The caller holds it for
                // the start pulse alone and is free after it.
                shift < input('data'),
                lenReg < input('bytes'),
                state < stateWait,
                sawBusy < Const(0),
              ],
            ),
          ]),
          CaseItem(stateWait, [
            // WRAPPED, and that is the point. A flat write would clear the
            // flag on every clock the response is not on the line, which
            // is every clock of the wait after the response ends, and the
            // frame would never start.
            //
            // The sender reaches this state while its OWN response is
            // already on CMD, because the state machine asks for the frame
            // in the clock after it queues the answer. The flag is
            // therefore set in the first clock of the wait in every case
            // the card can reach, and it is here for the case where the
            // link holds the answer back.
            If(input('cmd_busy'), then: [sawBusy < Const(1)]),
            If(go, then: [state < stateSend]),
          ]),
          CaseItem(stateSend, [
            // The link cannot stop in the middle of a frame, so the send
            // runs to its end bit whatever else happens.
            If(input('tx_next'), then: [shift < shiftNext]),
            If(input('tx_done'), then: [state < stateIdle]),
          ]),
        ]),
      ],
    );

    output('tx_start') <= go;
    output('tx_byte') <= shift.slice(maxBytes * 8 - 1, maxBytes * 8 - 8);
    output('tx_len') <= lenReg;
    output('busy') <= inWait | inSend;
    output('ready') <= ready;
  }
}
