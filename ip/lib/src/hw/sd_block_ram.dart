// MimicBlockRam: one synchronous write port and one registered read port.
//
// The block cache holds 64 KiB of data and a tag for each line. That is far
// too much storage for flip-flops, so it must map onto the block RAM of the
// part: a DP16KD on the ECP5, a RAMB on a Xilinx part. This module is the
// primitive that makes that happen.
//
// Why NOT `HarborBram`
// Harbor has a primitive of the same shape, and it models the array with one
// [Logic] for each entry plus a mux tree that selects one of them. That model
// is correct, and it does not scale: the data store of a 128-line cache is
// 16384 entries, which becomes more than 16000 ROHD modules and a mux tree
// of the same size. Elaboration of the SoC would take minutes and a
// simulation would crawl.
//
// This module keeps the memory in a Dart list instead, so the cost of the
// model is the cost of one list index. The emitted SystemVerilog is the same
// inference template that Harbor emits, so the SILICON is the same block RAM.
//
// How the two halves agree
//   * `definitionVerilog` gives synthesis a plain inferrable memory: one
//     synchronous write and one registered read. Yosys maps that template
//     onto a DP16KD on the ECP5 and onto a RAMB on a Xilinx part, so the
//     module is not tied to one vendor.
//   * The ROHD body drives `rd_data` through a real [Sequential], so the
//     read has the SAME one cycle of latency the block RAM has and the
//     simulator schedules it the way it schedules every other flop. Only the
//     array itself is Dart.
//
// The Dart array is read through `mem_read`, which is a combinational value
// that this module writes with `put`. Two rules keep that value in step with
// the simulator, and both are load bearing:
//   * The WRITE runs on the clock GLITCH, which the simulator raises before
//     it moves any flip-flop. Every input therefore still holds the value it
//     had at the clock edge, which is the value the memory must store.
//   * The READ value is refreshed AFTER the tick. `mem_read` then changes
//     only between edges, so the register that samples it takes the value
//     from before the edge. A write and a read of one address in one clock
//     therefore gives the OLD value, which is what the emitted `always_ff`
//     with its non-blocking assignments gives as well.
//
// The cells start at ZERO and not at X. A DP16KD holds the value its INITVAL
// gives, and the default INITVAL of an inferred memory is 0, so zero is what
// the silicon really holds. It is also the safe value for a card whose clock
// the host can stop: an X that left this module would cross into the CSR bus
// through the cache and there is a long history of that fault in this design.

import 'package:rohd/rohd.dart';

/// A block RAM with one write port and one registered read port.
///
/// Both ports run on [clk]. A write of `wr_data` to `wr_addr` lands while
/// `wr_en` is high. A read of `rd_addr` lands in `rd_data` ONE clock later
/// while `rd_en` is high, and `rd_data` holds its value while `rd_en` is
/// low, so a reader that has to wait leaves `rd_en` low and the word stays.
///
/// `rd_data` resets to 0. The cells take no reset, the way the cells of a
/// block RAM take none, and they start at 0 because that is the value an
/// inferred memory powers up with.
///
/// The two ports must not hit the same address in one clock in a design
/// that reads the result: a real block RAM gives UNDEFINED data for that
/// collision, and this model gives the old value instead. The block cache
/// never does it, because a line that is being filled is marked invalid and
/// nothing reads it.
class MimicBlockRam extends Module with SystemVerilog {
  /// Number of bits in one entry.
  final int width;

  /// Number of entries.
  final int depth;

  /// Number of address bits, derived from [depth].
  final int addrWidth;

  /// The registered read data, one clock behind `rd_addr`.
  Logic get rdData => output('rd_data');

  /// Makes the memory.
  ///
  /// [depth] must be 2 or more, because a memory of one entry needs no
  /// address and the address port would be zero bits wide.
  MimicBlockRam(
    Logic clk, {
    required Logic reset,
    required this.width,
    required this.depth,
    required Logic wrEn,
    required Logic wrAddr,
    required Logic wrData,
    required Logic rdEn,
    required Logic rdAddr,
    String? name,
  }) : addrWidth = (depth - 1).bitLength,
       super(
         name: name ?? 'mimic_block_ram',
         // One stable definition name for each shape, so the emitted file
         // name and the instantiation agree and two memories of one shape
         // become one definition.
         definitionName: 'MimicBlockRam_${width}x$depth',
         reserveDefinitionName: true,
       ) {
    if (depth < 2) {
      throw ArgumentError.value(
        depth,
        'depth',
        'must be 2 or more. A memory of one entry has no address bits.',
      );
    }
    if (width < 1) {
      throw ArgumentError.value(width, 'width', 'must be 1 or more.');
    }
    final aw = addrWidth;
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    wrEn = addInput('wr_en', wrEn);
    wrAddr = addInput('wr_addr', wrAddr, width: aw);
    wrData = addInput('wr_data', wrData, width: width);
    rdEn = addInput('rd_en', rdEn);
    rdAddr = addInput('rd_addr', rdAddr, width: aw);
    final rd = addOutput('rd_data', width: width);

    // The array. It never reaches the netlist: `definitionVerilog` replaces
    // the whole body with the inference template below.
    final zero = LogicValue.filled(width, LogicValue.zero);
    final cells = List<LogicValue>.filled(depth, zero);

    // The combinational read of the array. This module drives it by hand,
    // because a list index is what keeps the model small.
    final memRead = Logic(name: 'mem_read', width: width);

    void refreshRead() {
      final a = rdAddr.value;
      memRead.put(
        a.isValid && a.toInt() < depth
            ? cells[a.toInt()]
            : LogicValue.filled(width, LogicValue.x),
      );
    }

    // The write. It runs on the GLITCH of the clock and not on `posedge`,
    // because the simulator raises the glitch BEFORE it moves any
    // flip-flop and it delivers `posedge` after the whole tick. Every
    // input therefore still holds the value it had at the clock edge here,
    // which is the value a real memory stores. A `posedge` listener would
    // read the values the flops have ALREADY taken and would store the
    // word of the next clock.
    clk.glitch.listen((event) {
      if (event.newValue != LogicValue.one) return;
      if (wrEn.value == LogicValue.one) {
        final a = wrAddr.value;
        if (a.isValid && a.toInt() < depth) {
          cells[a.toInt()] = wrData.value;
        }
      }
    });

    // The read value, refreshed AFTER the tick. `mem_read` therefore
    // changes only between clock edges, so the register below takes the
    // value it held BEFORE the edge, the way a non-blocking assignment
    // does. A refresh inside the tick would let the register take the word
    // of this clock and the read would have no latency at all.
    Simulator.postTick.listen((_) => refreshRead());
    refreshRead();

    final rdReg = Logic(name: 'rd_reg', width: width);
    Sequential(
      clk,
      reset: reset,
      resetValues: {rdReg: Const(0, width: width)},
      [
        If(rdEn, then: [rdReg < memRead]),
      ],
    );
    rd <= rdReg;
  }

  @override
  String? definitionVerilog(String definitionType) =>
      '''
module $definitionType (
  input logic clk,
  input logic reset,
  input logic wr_en,
  input logic [${addrWidth - 1}:0] wr_addr,
  input logic [${width - 1}:0] wr_data,
  input logic rd_en,
  input logic [${addrWidth - 1}:0] rd_addr,
  output logic [${width - 1}:0] rd_data
);
  // Simple dual-port RAM: one synchronous write and one registered read
  // with a clock enable. This is the block RAM inference template, which
  // yosys maps onto a Lattice DP16KD on the ECP5 and onto a RAMB on a
  // Xilinx part.
  logic [${width - 1}:0] mem [0:${depth - 1}];
  always_ff @(posedge clk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
    if (reset) rd_data <= $width'd0;
    else if (rd_en) rd_data <= mem[rd_addr];
  end
endmodule''';
}
