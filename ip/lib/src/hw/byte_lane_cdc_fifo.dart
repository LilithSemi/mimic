library;

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// A 32-bit asynchronous FIFO built from four lockstep byte lanes.
///
/// ECP5 maps a 512 by 32 inferred memory to one DP16KD in x36 mode. The
/// OrangeCrab has proven runtime writes only in x9 mode, so this wrapper makes
/// four 8-bit [HarborCdcFifo] instances. Each lane maps to one x9 DP16KD.
///
/// All lanes take the same write and read enables. Full and empty are the OR
/// of every lane, so no transfer occurs until every lane can take it. This
/// also covers a one-clock difference between their pointer synchronisers.
class MimicByteLaneCdcFifo extends BridgeModule {
  MimicByteLaneCdcFifo({
    required int depth,
    required int almostFullMargin,
    required HarborDeviceTarget? target,
    super.name = 'byte_lane_cdc_fifo',
  }) : super('MimicByteLaneCdcFifo_32w${depth}d') {
    createPort('wr_clk', PortDirection.input);
    createPort('wr_reset', PortDirection.input);
    createPort('wr_data', PortDirection.input, width: 32);
    createPort('wr_en', PortDirection.input);
    addOutput('wr_full');
    addOutput('wr_almost_full');

    createPort('rd_clk', PortDirection.input);
    createPort('rd_reset', PortDirection.input);
    createPort('rd_en', PortDirection.input);
    addOutput('rd_data', width: 32);
    addOutput('rd_empty');

    final lanes = <HarborCdcFifo>[];
    for (var i = 0; i < 4; i++) {
      final lane = HarborCdcFifo(
        dataWidth: 8,
        depth: depth,
        almostFullMargin: almostFullMargin,
        target: target,
        blockRam: true,
        name: 'lane_$i',
      );
      lanes.add(lane);
      addSubModule(lane);
      lane.input('wr_clk').srcConnection! <= input('wr_clk');
      lane.input('wr_reset').srcConnection! <= input('wr_reset');
      lane.input('wr_data').srcConnection! <=
          input('wr_data').getRange(i * 8, (i + 1) * 8);
      lane.input('wr_en').srcConnection! <= input('wr_en');
      lane.input('rd_clk').srcConnection! <= input('rd_clk');
      lane.input('rd_reset').srcConnection! <= input('rd_reset');
      lane.input('rd_en').srcConnection! <= input('rd_en');
    }

    output('wr_full') <=
        lanes.map((lane) => lane.output('wr_full')).reduce((a, b) => a | b);
    output('wr_almost_full') <=
        lanes
            .map((lane) => lane.output('wr_almost_full'))
            .reduce((a, b) => a | b);
    output('rd_empty') <=
        lanes.map((lane) => lane.output('rd_empty')).reduce((a, b) => a | b);
    output('rd_data') <=
        [for (var i = lanes.length - 1; i >= 0; i--) lanes[i].output('rd_data')]
            .swizzle();
  }
}
