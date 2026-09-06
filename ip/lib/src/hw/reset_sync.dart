// MimicResetSync: the reset of a clock domain that the SoC does not clock.
//
// A domain whose clock comes from outside the chip cannot take the SoC
// reset directly. ROHD builds a synchronous reset, which is
// `always_ff @(posedge clk) if (reset) ...`, so every register of that
// domain needs a clock edge WHILE the reset is high before it holds its
// reset value. A host that powers the board up and starts the SD clock
// after the SoC releases its reset gives no such edge, and the card then
// runs with registers that no reset ever loaded.
//
// This module makes the reset of that domain. The reset goes high with no
// clock at all, because the flops of this module take the SoC reset as an
// ASYNCHRONOUS reset. The reset goes low again only two clock edges after
// the SoC releases it, because a 0 must shift through the two flops. The
// domain therefore always sees its reset high on its first clock edges,
// and it releases the reset in step with its own clock, which keeps the
// recovery time of the registers that follow.

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Reset of a clock domain, asserted asynchronously and released in step
/// with [clk].
///
/// `async_reset` is the reset of the domain that owns the reset, which is
/// the SoC domain. `reset` is the reset that the target domain uses.
class MimicResetSync extends BridgeModule {
  /// Number of flops the release shifts through. Minimum 2.
  ///
  /// Two flops is the usual number: the first one can go metastable when
  /// the release lands near a clock edge, and the second one gives the
  /// first one a whole clock period to settle.
  final int stages;

  MimicResetSync({this.stages = 2, String? name})
    : super('MimicResetSync', name: name ?? 'reset_sync') {
    if (stages < 2) {
      throw ArgumentError.value(
        stages,
        'stages',
        'must be at least 2. One flop gives the release no time to settle.',
      );
    }
    createPort('clk', PortDirection.input);
    createPort('async_reset', PortDirection.input);
    addOutput('reset');

    final regs = <Logic>[
      for (var i = 0; i < stages; i++) Logic(name: 'reset_stage_$i'),
    ];

    // `asyncReset` is what makes this module work. It emits
    // `always_ff @(posedge clk, posedge async_reset)`, so the flops take
    // the reset value with no clock edge. Every flop resets to 1, which is
    // the reset of the target domain held.
    Sequential(
      input('clk'),
      reset: input('async_reset'),
      asyncReset: true,
      resetValues: {for (final r in regs) r: Const(1)},
      [
        regs[0] < Const(0),
        for (var i = 1; i < stages; i++) regs[i] < regs[i - 1],
      ],
    );

    output('reset') <= regs.last;
  }
}
