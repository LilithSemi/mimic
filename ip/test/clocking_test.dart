// Clocking and reset tests for the Mimic SoC board build.
//
// The FPGA build runs on one harbor clock domain that a real ECP5 PLL drives.
// These tests hold the three properties the hardware depends on: the PLL is
// really instantiated, the domain reset is gated on the PLL lock, and the
// bench LED really toggles.

@TestOn('vm')
library;

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// The default target a `mimic_genip` build resolves.
HarborFpgaTarget _orangeCrabTarget() =>
    resolveMimicTarget(board: 'orangecrab-25f');

/// Resets the simulator between tests, safely for an ASYNCHRONOUS reset.
///
/// A `Sequential` with an asynchronous reset watches its reset signal the
/// same way it watches its clock. Elaboration alone makes that signal
/// move, and ROHD then waits for the next clock-stable event of the
/// simulator. `Simulator.reset()` closes that event stream, and the wait
/// fails with "Bad state: No element" in a test that had already passed.
/// One tick of the simulator retires the wait before the reset lands.
Future<void> _resetSimulator() async {
  if (!Simulator.simulationHasEnded) {
    Simulator.setMaxSimTime(1);
    await Simulator.run();
  }
  await Simulator.reset();
}

/// Waits [amount] simulated time units with no clock generator running.
Future<void> _wait(int amount) {
  final done = Completer<void>();
  Simulator.registerAction(Simulator.time + amount, done.complete);
  return done.future;
}

/// The argument list of one module instance in emitted SystemVerilog.
String _instanceArgs(String sv, String head) {
  final at = sv.indexOf(head);
  if (at < 0) throw StateError('no instance $head in the netlist');
  final rest = sv.substring(at);
  return rest.substring(0, rest.indexOf(');'));
}

/// Whether the activity light is LIT, whatever the polarity of the pin.
///
/// The board LED is active low, so a lit light reads 0 on the pin. The test
/// asks about the light and never about the pin level, so a change of
/// polarity cannot make a test pass for the wrong reason.
bool _isLit(MimicSdActivityLed led) =>
    led.output('led').value.toInt() == (led.activeLow ? 0 : 1);

/// Holds the reset of [led] high for a few clocks and then releases it.
Future<void> _releaseLedReset(MimicSdActivityLed led, Logic clk) async {
  led.input('activity_toggle').inject(0);
  led.input('reset').inject(1);
  for (var i = 0; i < 3; i++) {
    await clk.nextNegedge;
  }
  led.input('reset').inject(0);
  await clk.nextNegedge;
}

/// Samples the light of [led] once per clock for [cycles] clocks.
Future<List<bool>> _traceLed(
  MimicSdActivityLed led,
  Logic clk,
  int cycles,
) async {
  final trace = <bool>[];
  for (var i = 0; i < cycles; i++) {
    await clk.nextNegedge;
    trace.add(_isLit(led));
  }
  return trace;
}

/// Every run of a lit light in [trace], as a start index and a length.
///
/// The test asks about the FLASHES and the gaps between them, not about
/// single samples, because a light that toggles every clock also "changes
/// state" and is not a flash.
List<({int start, int length})> _litRuns(List<bool> trace) {
  final runs = <({int start, int length})>[];
  var start = -1;
  for (var i = 0; i < trace.length; i++) {
    if (trace[i] && start < 0) {
      start = i;
    } else if (!trace[i] && start >= 0) {
      runs.add((start: start, length: i - start));
      start = -1;
    }
  }
  // A run that is still open at the end of the trace is dropped: its length
  // is not known, so counting it would test the length of the trace.
  return runs;
}

/// The net bound to port [port] in an instance argument list.
String _argNet(String args, String port) {
  final at = args.indexOf('.$port(');
  if (at < 0) throw StateError('no port $port in $args');
  final rest = args.substring(at + port.length + 2);
  return rest.substring(0, rest.indexOf(')'));
}

void main() {
  tearDown(_resetSimulator);

  group('clock domain', () {
    test('an FPGA target gets one PLL domain and nothing else', () {
      final clocks = mimicClockConfigs(_orangeCrabTarget(), mimicClockHz);
      expect(clocks.length, 1);
      final sys = clocks.single;
      expect(sys.name, mimicSysDomain);
      expect(sys.frequency, mimicClockHz);
      expect(sys.sourceFrequency, mimicClockHz);
      // The ratio is 1:1, so only forcePll keeps the PLL that gives the LOCK.
      expect(sys.forcePll, isTrue);
      expect(sys.isPrimary, isFalse);
      // ONE PLL. A second EHXPLLL may not lock on ECP5 silicon, so a later
      // SDIO clock must be a CLKOS secondary of THIS domain.
      expect(sys.coClkosSecondary, isNull);
    });

    test('a simulation target gets no domain, because it has no PLL', () {
      expect(
        mimicClockConfigs(
          const HarborSimTarget(topCell: 'x', frequency: mimicClockHz),
          mimicClockHz,
        ),
        isEmpty,
      );
      expect(mimicClockConfigs(null, mimicClockHz), isEmpty);
    });

    test('the ECP5 dividers put the VCO inside the 400-800 MHz band', () {
      // 48 MHz in, 48 MHz out: CLKI_DIV 1, CLKFB_DIV 1, CLKOP_DIV 12, so the
      // VCO runs at 48 * 12 = 576 MHz. Outside the band the PLL never locks.
      final d = HarborClockGenerator.ecp5PllDividers(
        mimicClockHz,
        mimicClockHz,
      );
      expect(d.clkiDiv, 1);
      expect(d.clkfbDiv, 1);
      final vco = mimicClockHz * d.clkopDiv;
      expect(vco, greaterThanOrEqualTo(400000000));
      expect(vco, lessThanOrEqualTo(800000000));
    });

    test('the emitted SV instantiates a real EHXPLLL', () async {
      final soc = buildMimicSoc(
        name: 'mimic_pll_elab',
        target: _orangeCrabTarget(),
      );
      await soc.build();
      final sv = soc.generateSynth();
      expect(sv, contains('EHXPLLL'));
      // Self-feedback off CLKOP, and a used CLKOP needs its own enable and
      // coarse phase or the output waveform is degenerate.
      expect(sv, contains('.FEEDBK_PATH("CLKOP")'));
      expect(sv, contains('.CLKOP_ENABLE("ENABLED")'));
      expect(sv, contains('.CLKI(clk)'));
      // Exactly one PLL: a second one may not lock on ECP5 silicon.
      expect('EHXPLLL '.allMatches(sv).length, 1);
    });

    test('the domain reset is gated on the PLL lock', () async {
      final soc = buildMimicSoc(
        name: 'mimic_lock_elab',
        target: _orangeCrabTarget(),
      );
      await soc.build();
      final sv = soc.generateSynth();
      // The PLL LOCK output is really connected, and the reset asserts while
      // it is low.
      expect(sv, contains('.LOCK(LOCK)'));
      expect(sv, contains(RegExp(r'assign \w+ = \w+ \| \(~LOCK\);')));
      // Release is re-timed by a two-flop synchroniser on the PLL clock, so
      // there is no recovery hazard when LOCK rises.
      expect(sv, contains('sysRstSync'));
      expect(sv, contains('sysReset'));
      // Everything on the bus runs on the PLL output, not on the raw pad.
      expect(sv, contains('MimicUsbDevice  mimic_usb_device(.clk(sys_pll_fb)'));
      expect(sv, contains('MimicSdCard  mimic_sd_card(.clk(sys_pll_fb)'));
    });

    test('the FPGA build takes the active-low board reset button', () async {
      final soc = buildMimicSoc(
        name: 'mimic_rstn_elab',
        target: _orangeCrabTarget(),
      );
      await soc.build();
      expect(soc.inputs.keys, contains(mimicResetPortName));
      // harbor builds its own power-on reset, so there is no active-high
      // reset input left for a board shim to drive.
      expect(soc.inputs.keys, isNot(contains('reset')));
      final sv = soc.generateSynth();
      expect(sv, contains('porCount'));
      expect(sv, contains(RegExp(r'assign \w+ = porReset \| \(~reset_n\);')));
    });

    test('the reset button site comes from the board catalog', () {
      // harbor names the port reset_n; the catalog calls the button rst_n.
      final target = _orangeCrabTarget();
      expect(target.pinMap[mimicResetPortName], 'V17 LVCMOS33');
      expect(target.pinMap['rst_n'], 'V17 LVCMOS33');
      // A --pin of the port name still wins over the alias.
      final overridden = resolveMimicTarget(
        board: 'orangecrab-25f',
        pinSpecs: const ['reset_n=T17'],
      );
      expect(overridden.pinMap[mimicResetPortName], 'T17');
    });
  });

  group('MimicSdActivityLed', () {
    test('rejects a flash or a dark time no one can see', () {
      expect(
        () => MimicSdActivityLed(onCycles: 1),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => MimicSdActivityLed(offCycles: 1),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('the default flash is 25 ms of the 48 MHz SoC clock', () {
      final led = MimicSdActivityLed();
      // 1200000 cycles at 48 MHz is 25 ms, and lit plus forced dark is
      // 50 ms, which is 20 flashes a second under a steady stream.
      expect(led.onCycles, mimicClockHz * 25 ~/ 1000);
      expect(led.onCycles, led.offCycles);
      expect(led.flashPeriodCycles, mimicClockHz ~/ 20);
      // 25 ms needs 21 bits of counter at this clock: 2^20 is 1048576,
      // which is fewer cycles than one flash.
      expect((led.longerPhaseCycles - 1).bitLength, 21);
    });

    test(
      'no activity leaves the light off and the reset holds it dark',
      () async {
        final led = MimicSdActivityLed(onCycles: 4, offCycles: 4);
        final clk = SimpleClockGenerator(10).clk;
        led.port('clk').getsLogic(clk);
        await led.build();

        Simulator.setMaxSimTime(100000);
        unawaited(Simulator.run());

        led.input('activity_toggle').inject(0);
        led.input('reset').inject(1);
        for (var i = 0; i < 4; i++) {
          await clk.nextNegedge;
          // Active low: the pin is high, so the LED is dark.
          expect(led.output('led').value.toInt(), 1);
        }
        led.input('reset').inject(0);

        // Nothing ever touches the card, so nothing ever lights.
        for (var i = 0; i < 8 * led.flashPeriodCycles; i++) {
          await clk.nextNegedge;
          expect(
            led.output('led').value.toInt(),
            1,
            reason: 'the light is an ACTIVITY light and there is no activity',
          );
        }
        await Simulator.endSimulation();
      },
    );

    test('one event gives exactly one flash of the lit time', () async {
      final led = MimicSdActivityLed(onCycles: 4, offCycles: 4);
      final clk = SimpleClockGenerator(10).clk;
      led.port('clk').getsLogic(clk);
      await led.build();

      Simulator.setMaxSimTime(100000);
      unawaited(Simulator.run());
      await _releaseLedReset(led, clk);

      // One activity event: the level inverts ONCE.
      led.input('activity_toggle').inject(1);

      final trace = await _traceLed(led, clk, 8 * led.flashPeriodCycles);
      await Simulator.endSimulation();

      final flashes = _litRuns(trace);
      expect(flashes.length, 1, reason: 'one event, one flash');
      expect(flashes.single.length, led.onCycles);
    });

    test('an event in each direction of the level counts once each', () async {
      // The crossing carries a TOGGLE, so a second event is the level going
      // back the other way. A design that watched for a rising edge alone
      // would light on every other command.
      final led = MimicSdActivityLed(onCycles: 4, offCycles: 4);
      final clk = SimpleClockGenerator(10).clk;
      led.port('clk').getsLogic(clk);
      await led.build();

      Simulator.setMaxSimTime(100000);
      unawaited(Simulator.run());
      await _releaseLedReset(led, clk);

      final toggle = led.input('activity_toggle');
      toggle.inject(1);
      final first = await _traceLed(led, clk, 3 * led.flashPeriodCycles);
      toggle.inject(0);
      final second = await _traceLed(led, clk, 3 * led.flashPeriodCycles);
      await Simulator.endSimulation();

      expect(_litRuns(first).length, 1);
      expect(_litRuns(second).length, 1);
    });

    test('a steady stream flickers and never goes solid', () async {
      final led = MimicSdActivityLed(onCycles: 4, offCycles: 4);
      final clk = SimpleClockGenerator(10).clk;
      led.port('clk').getsLogic(clk);
      await led.build();

      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());
      await _releaseLedReset(led, clk);

      // Activity in EVERY cycle, which is the load a retriggerable one-shot
      // turns into a solid light.
      final toggle = led.input('activity_toggle');
      final trace = <bool>[];
      var level = 0;
      for (var i = 0; i < 12 * led.flashPeriodCycles; i++) {
        level ^= 1;
        toggle.inject(level);
        await clk.nextNegedge;
        trace.add(_isLit(led));
      }
      await Simulator.endSimulation();

      final flashes = _litRuns(trace);
      expect(
        flashes.length,
        greaterThanOrEqualTo(4),
        reason: 'a steady stream must keep flashing',
      );
      for (final flash in flashes) {
        expect(
          flash.length,
          led.onCycles,
          reason: 'no event may make a flash longer',
        );
      }
      // The gap between two flashes is the whole forced dark time. This is
      // the assertion that fails on a solid light: a retriggerable one-shot
      // gives one run and no gap at all.
      for (var i = 1; i < flashes.length; i++) {
        final gap = flashes[i].start - (flashes[i - 1].start + led.onCycles);
        expect(
          gap,
          greaterThanOrEqualTo(led.offCycles),
          reason: 'the light must be dark between flashes',
        );
      }
    });

    test('a stopped SD clock does not freeze or stretch a flash', () async {
      // The SD clock belongs to the host and it stops. The flash is timed
      // in the SoC domain, so a level that stops moving part way through a
      // flash must change nothing about that flash.
      final led = MimicSdActivityLed(onCycles: 8, offCycles: 8);
      final clk = SimpleClockGenerator(10).clk;
      led.port('clk').getsLogic(clk);
      await led.build();

      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());
      await _releaseLedReset(led, clk);

      // One event, then the host stops clocking the card: the level stands
      // still from here to the end of the test.
      led.input('activity_toggle').inject(1);
      final trace = await _traceLed(led, clk, 6 * led.flashPeriodCycles);
      await Simulator.endSimulation();

      final flashes = _litRuns(trace);
      expect(flashes.length, 1);
      expect(
        flashes.single.length,
        led.onCycles,
        reason: 'the flash is timed on the SoC clock, which keeps running',
      );
      // And the light really goes out again, rather than hold.
      expect(trace.last, isFalse);
    });

    test('activeLow false drives the pin high to light the LED', () async {
      final led = MimicSdActivityLed(
        onCycles: 4,
        offCycles: 4,
        activeLow: false,
      );
      final clk = SimpleClockGenerator(10).clk;
      led.port('clk').getsLogic(clk);
      await led.build();

      Simulator.setMaxSimTime(100000);
      unawaited(Simulator.run());

      led.input('activity_toggle').inject(0);
      led.input('reset').inject(1);
      await clk.nextNegedge;
      expect(led.output('led').value.toInt(), 0);
      led.input('reset').inject(0);
      await clk.nextNegedge;
      led.input('activity_toggle').inject(1);

      final seen = <int>[];
      for (var i = 0; i < 3 * led.flashPeriodCycles; i++) {
        await clk.nextNegedge;
        seen.add(led.output('led').value.toInt());
      }
      await Simulator.endSimulation();
      expect(seen, contains(1), reason: 'the pin goes HIGH to light');
    });
  });

  group('the SoC LED', () {
    test(
      'activityLed puts the activity light on the catalog LED pin',
      () async {
        final soc = buildMimicSoc(
          name: 'mimic_led_elab',
          target: _orangeCrabTarget(),
          activityLed: true,
        );
        await soc.build();
        expect(soc.outputs.keys, contains(mimicLedPinName));
        final sv = soc.generateSynth();
        expect(sv, contains('module MimicSdActivityLed'));
        // The light runs on the PLL domain, so its timing does not depend on
        // the SD clock, which the host stops.
        expect(sv, contains('MimicSdActivityLed  mimic_led(.clk(sys_pll_fb)'));
      },
    );

    test(
      'the light is driven by the card, through a toggle crossing',
      () async {
        final soc = buildMimicSoc(
          name: 'mimic_led_cdc_elab',
          target: _orangeCrabTarget(),
          activityLed: true,
        );
        await soc.build();
        final sv = soc.generateSynth();

        // The card publishes the level, and the light takes exactly that net.
        final cardArgs = _instanceArgs(
          sv,
          'MimicSdCardDevice  sd_card_device(',
        );
        final ledArgs = _instanceArgs(sv, 'MimicSdActivityLed  mimic_led(');
        final published = _argNet(cardArgs, 'sd_activity_toggle');
        expect(_argNet(ledArgs, 'activity_toggle'), published);

        // The destination side is a two-flop synchroniser inside the light,
        // and NOT a handshake: the SD side cannot acknowledge anything while
        // the host holds its clock still.
        expect(sv, contains('HarborCdcSync  activity_sync('));

        // The toggle register is clocked by the SD clock, so the event is
        // captured in the domain that framed the command.
        expect(sv, contains('module MimicSdCardDevice'));
      },
    );

    test(
      'the declared pin list is exactly the board build top ports',
      () async {
        // mimicExposedPins states the contract the board catalog and the
        // pre-place script are read against, so it must not drift from the
        // real port list.
        final soc = buildMimicSoc(
          name: 'mimic_pins_elab',
          target: _orangeCrabTarget(),
          ownPads: true,
          activityLed: true,
        );
        await soc.build();
        final ports = {
          ...soc.inputs.keys,
          ...soc.outputs.keys,
          ...soc.inOuts.keys,
        };
        expect(ports, mimicExposedPins.toSet());
        expect(mimicUsbPadPins.every(ports.contains), isTrue);
      },
    );

    test(
      'the activity light is off by default, so simulation does not pay',
      () async {
        final soc = buildMimicSoc(
          name: 'mimic_noled_elab',
          target: _orangeCrabTarget(),
        );
        await soc.build();
        expect(soc.outputs.keys, isNot(contains(mimicLedPinName)));
      },
    );
  });

  group('the SD domain reset', () {
    test('MimicResetSync refuses one stage, which cannot settle', () {
      expect(() => MimicResetSync(stages: 1), throwsArgumentError);
    });

    test(
      'the card resets even when no SD clock ran under the SoC reset',
      () async {
        // The failure this holds: the registers of the card are clocked by
        // the SD clock and ROHD builds a SYNCHRONOUS reset, so a card that
        // saw no SD clock edge while the SoC reset was high comes up with no
        // reset value at all. CMD9 would then answer a CSD that no one
        // loaded. [MimicResetSync] holds the reset of the SD domain high
        // over the first clock edges the host gives, however late they come.
        final card = MimicSdCardDevice(name: 'sd_card_device');
        final sdClk = Logic(name: 'sd_clk');
        final sysReset = Logic(name: 'sys_reset');
        final cmdIn = Logic(name: 'sd_cmd_in');
        final datIn = Logic(name: 'sd_dat_in');
        final csd = Logic(name: 'csd', width: sdResponseRegBits);
        final csdValid = Logic(name: 'csd_valid');

        final resetSync = MimicResetSync(name: 'sd_reset_sync');
        resetSync.input('clk').srcConnection! <= sdClk;
        resetSync.input('async_reset').srcConnection! <= sysReset;

        card.input('clk').srcConnection! <= sdClk;
        card.input('reset').srcConnection! <= resetSync.output('reset');
        card.input('sd_cmd_in').srcConnection! <= cmdIn;
        card.input('sd_dat_in').srcConnection! <= datIn;
        card.input('csd').srcConnection! <= csd;
        card.input('csd_valid').srcConnection! <= csdValid;
        // The block read path is off here. An input that nothing
        // drives holds X.
        card.input('card_enable').srcConnection! <= Const(0);
        card.input('data_word').srcConnection! <= Const(0, width: 32);
        card.input('data_empty').srcConnection! <= Const(1);
        card.input('data_blocks_pushed_gray').srcConnection! <=
            Const(0, width: sdBlockCountBits);
        card.input('data_tag').srcConnection! <=
            Const(0, width: sdRequestSeqBits);
        card.input('data_tag_empty').srcConnection! <= Const(1);
        await card.build();
        await resetSync.build();

        sdClk.inject(0);
        sysReset.inject(0);
        cmdIn.inject(1);
        datIn.inject(1);
        csd.inject(BigInt.zero);
        csdValid.inject(0);
        Simulator.setMaxSimTime(100000);
        unawaited(Simulator.run());
        // Let the injected values settle. ROHD drives X when two triggers of
        // one Sequential move in the same time step.
        await _wait(20);

        // The SoC reset runs its whole length with the SD clock STOPPED,
        // which is what a host does before it powers the card up.
        sysReset.inject(1);
        await _wait(10);
        expect(
          resetSync.output('reset').value,
          LogicValue.one,
          reason: 'the SD domain reset must go high with no clock at all',
        );
        await _wait(490);
        sysReset.inject(0);
        await _wait(100);
        expect(
          resetSync.output('reset').value,
          LogicValue.one,
          reason: 'the release waits for SD clock edges, and none came',
        );

        // Only now does the host start the clock.
        for (var i = 0; i < 8; i++) {
          sdClk.inject(1);
          await _wait(5);
          sdClk.inject(0);
          await _wait(5);
        }
        expect(
          resetSync.output('reset').value,
          LogicValue.zero,
          reason: 'the reset must release once the clock runs',
        );

        final fsm = card.subModules.whereType<MimicSdCardFsm>().single;
        expect(
          fsm.input('csd').value.toBigInt(),
          equals(sdCardCsdValue),
          reason: 'the CSD register must hold the default CSD, not junk',
        );
        expect(
          card.output('card_state').value.toInt(),
          equals(sdCardStateIdle),
          reason: 'the card must come up in idle',
        );
        expect(
          card.output('sd_cmd_oe').value,
          LogicValue.zero,
          reason: 'a card fresh from reset must not drive CMD',
        );
        await Simulator.endSimulation();
      },
    );

    test('the SoC gives the card and the CSD crossing that reset', () async {
      final soc = buildMimicSoc(
        name: 'mimic_sd_reset_elab',
        target: _orangeCrabTarget(),
        board: HarborBoard.get('orangecrab-25f'),
      );
      await soc.build();
      final sv = soc.generateSynth();

      // The reset synchroniser is a real module, clocked by the SD clock
      // and reset asynchronously.
      expect(sv, contains('module MimicResetSync'));
      expect(
        sv,
        contains('always_ff @(posedge clk or posedge async_reset)'),
        reason: 'the assertion of the SD domain reset must need no clock',
      );

      final syncArgs = _instanceArgs(sv, 'MimicResetSync  sd_reset_sync(');
      final cardArgs = _instanceArgs(sv, 'MimicSdCardDevice  sd_card_device(');
      final cdcArgs = _instanceArgs(sv, 'HarborCdcHandshake  csd_cdc(');
      final syncReset = _argNet(syncArgs, 'reset');
      expect(
        _argNet(syncArgs, 'clk'),
        equals(_argNet(cardArgs, 'clk')),
        reason: 'the synchroniser releases on the clock of the card',
      );
      expect(
        _argNet(cardArgs, 'reset'),
        equals(syncReset),
        reason: 'the card takes the SD domain reset',
      );
      expect(
        _argNet(cdcArgs, 'dst_reset'),
        equals(syncReset),
        reason: 'the SD side of the CSD crossing takes the same reset',
      );
      expect(
        _argNet(cdcArgs, 'src_reset'),
        isNot(equals(syncReset)),
        reason: 'the bus side keeps the SoC reset',
      );
    });
  });
}
