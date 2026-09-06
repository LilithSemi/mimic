// MimicSdActivityLed: the board LED as an SD activity light.
//
// This is the LED of a hard disk of the 1980s to the early 2000s. It is
// dark while nothing happens, and it FLICKERS while the host reads and
// writes. It never sits on. A light that goes solid under load says
// nothing more than a light that is always on, and the whole value of the
// light is the difference between "no traffic" and "traffic".
//
// The flicker comes from a forced dark time. A plain retriggerable
// one-shot goes solid: each event pushes the end of the flash further out,
// so under a steady stream of commands the LED never gets to go off. This
// state machine lights the LED for a fixed time, then holds it DARK for a
// fixed time whatever arrives, and only then looks at whether more
// activity waited. The result is about 20 flashes a second under a steady
// stream, and one flash for one command.
//
// The timing lives in the SoC clock domain, at 48 MHz. It cannot live in
// the SD clock domain: the SD clock belongs to the host and STOPS when the
// host stops clocking the card, so a counter there would freeze part way
// through a flash and hold the LED lit for as long as the host was quiet.
// The activity event therefore crosses as a level that inverts once per
// event, and this module turns each edge of it back into one event.

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Number of SoC clock cycles the activity light stays lit, and then dark.
///
/// 1200000 cycles is 25 ms at the 48 MHz SoC clock. A flash and the dark
/// time after it are 50 ms together, so a host that never stops gives about
/// 20 flashes a second. That reads as a flicker. A shorter flash starts to
/// look like a dim steady light, and a much longer one loses the flicker
/// the other way.
const int mimicLedActivityCycles = 1200000;

/// The board LED, driven as an SD activity light.
///
/// `activity_toggle` is an input from the SD clock domain. It is a LEVEL
/// that inverts once per SD activity event, and NOT a pulse: a pulse of one
/// SD clock is narrower than one SoC clock at any SD rate above 48 MHz and,
/// more to the point, the two clocks have no fixed ratio at all, so a
/// synchroniser can miss a pulse and can never miss an edge of a level.
/// This module holds the destination side of that crossing: a two-flop
/// [HarborCdcSync] settles the level, and one more flop makes each change
/// of it one event in this clock domain.
///
/// The flash itself is three phases:
///   * dark, waiting. A pending event starts a flash.
///   * lit, for [onCycles].
///   * dark and FORCED, for [offCycles]. Activity in this phase is held as
///     pending and starts the next flash as soon as the phase ends.
/// The forced dark phase is what keeps the light a flicker under a steady
/// stream of commands.
///
/// [activeLow] inverts the pin. The OrangeCrab RGB LED is common anode: the
/// pin must go LOW to light the channel.
class MimicSdActivityLed extends BridgeModule {
  /// Number of clock cycles one flash stays lit.
  final int onCycles;

  /// Number of clock cycles the light is held dark after a flash, whatever
  /// arrives in that time.
  final int offCycles;

  /// Whether the LED pin lights the LED when it is low.
  final bool activeLow;

  /// Number of bits in the phase register.
  static const int phaseBits = 2;

  /// Phase value: dark, and waiting for an event.
  static const int phaseIdle = 0;

  /// Phase value: lit.
  static const int phaseLit = 1;

  /// Phase value: dark, and holding that way whatever arrives.
  static const int phaseBlank = 2;

  MimicSdActivityLed({
    this.onCycles = mimicLedActivityCycles,
    this.offCycles = mimicLedActivityCycles,
    this.activeLow = true,
    String? name,
  }) : super('MimicSdActivityLed', name: name ?? 'mimic_led') {
    if (onCycles < 2) {
      throw ArgumentError.value(
        onCycles,
        'onCycles',
        'A flash that no one can see is not a flash. Give at least 2.',
      );
    }
    if (offCycles < 2) {
      throw ArgumentError.value(
        offCycles,
        'offCycles',
        'The forced dark time is what stops the light going solid, so it '
            'cannot be shorter than 2 cycles.',
      );
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('activity_toggle', PortDirection.input);
    addOutput('led');

    final clk = input('clk');
    final reset = input('reset');

    // The counter has to hold the LONGER of the two phases, less one,
    // because it counts from 0. The width comes from the numbers and is
    // never written down: `Const` truncates a value too wide for its width
    // with no message, and a truncated compare would end a phase early.
    final timerWidth = (longerPhaseCycles - 1).bitLength;
    final zeroTimer = Const(0, width: timerWidth);

    // The source side of this crossing lives in the SD clock domain, which
    // stops. A two-flop synchroniser needs no clock on the source side, so
    // the level arrives whenever the host does something and stands still
    // in between.
    final sync = HarborCdcSync(name: 'activity_sync');
    addSubModule(sync);
    sync.input('async_in').srcConnection! <= input('activity_toggle');
    sync.input('dst_clk').srcConnection! <= clk;
    sync.input('dst_reset').srcConnection! <= reset;
    final settled = sync.output('sync_out');

    final previous = Logic(name: 'activity_previous');
    final pending = Logic(name: 'activity_pending');
    final phase = Logic(name: 'flash_phase', width: phaseBits);
    final timer = Logic(name: 'flash_timer', width: timerWidth);

    // One event per CHANGE of the settled level. The level is already
    // through the synchroniser, so this exclusive OR reads two flops of the
    // same domain and can never go metastable.
    final event = (settled ^ previous).named('activity_event');

    final litPhase = phase
        .eq(Const(phaseLit, width: phaseBits))
        .named('in_lit_phase');
    final blankPhase = phase
        .eq(Const(phaseBlank, width: phaseBits))
        .named('in_blank_phase');
    final idlePhase = phase
        .eq(Const(phaseIdle, width: phaseBits))
        .named('in_idle_phase');

    final litDone = timer
        .eq(Const(onCycles - 1, width: timerWidth))
        .named('lit_done');
    final blankDone = timer
        .eq(Const(offCycles - 1, width: timerWidth))
        .named('blank_done');

    // Every register here has a reset value. An unreset ROHD register holds
    // X and carries it on with no message, and an X in `phase` would light
    // the LED of a board that has done nothing.
    Sequential(
      clk,
      reset: reset,
      resetValues: {
        previous: Const(0),
        pending: Const(0),
        phase: Const(phaseIdle, width: phaseBits),
        timer: zeroTimer,
      },
      [
        previous < settled,
        If.block([
          // Dark and waiting. A pending event starts a flash and takes the
          // flag down in the same clock.
          Iff(idlePhase, [
            If(
              pending,
              then: [
                phase < Const(phaseLit, width: phaseBits),
                timer < zeroTimer,
                pending < Const(0),
              ],
            ),
          ]),
          // Lit. The phase ends on its own count and nothing extends it,
          // which is the difference between this and a retriggerable
          // one-shot.
          ElseIf(litPhase, [
            If(
              litDone,
              then: [
                phase < Const(phaseBlank, width: phaseBits),
                timer < zeroTimer,
              ],
              orElse: [timer < timer + 1],
            ),
          ]),
          // Dark and FORCED. Activity in this phase only sets the pending
          // flag, so the light is off for the whole of it however much the
          // host asks for.
          ElseIf(blankPhase, [
            If(
              blankDone,
              then: [
                timer < zeroTimer,
                If(
                  pending,
                  then: [
                    phase < Const(phaseLit, width: phaseBits),
                    pending < Const(0),
                  ],
                  orElse: [phase < Const(phaseIdle, width: phaseBits)],
                ),
              ],
              orElse: [timer < timer + 1],
            ),
          ]),
          // The phase register is two bits and holds three phases, so one
          // encoding is spare. A design that reaches it goes back to dark
          // rather than stay in a phase with no exit.
          Else([phase < Const(phaseIdle, width: phaseBits), timer < zeroTimer]),
        ]),
        // This comes LAST on purpose, so it wins over the clear above. An
        // event that lands in the same clock where a flash starts is a
        // SECOND event, and dropping it would lose a flash exactly when the
        // host is busiest.
        If(event, then: [pending < Const(1)]),
      ],
    );

    // The light is off while the domain is in reset, whatever the registers
    // hold. On the board build the domain reset is gated on the PLL lock,
    // so the LED is dark until the clock is good.
    final lit = mux(reset, Const(0), litPhase).named('activity_lit');
    output('led') <= (activeLow ? ~lit : lit);
  }

  /// The longer of the two phases, in clock cycles. The flash timer counts
  /// both phases, so it is sized on this.
  int get longerPhaseCycles => onCycles > offCycles ? onCycles : offCycles;

  /// Number of clock cycles of one full flash, lit plus the forced dark
  /// time after it. The shortest gap between the START of two flashes.
  int get flashPeriodCycles => onCycles + offCycles;
}
