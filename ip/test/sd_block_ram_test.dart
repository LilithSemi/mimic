// The block RAM primitive that the block cache is built on.
//
// The tests here prove the two properties the cache leans on: a read has
// exactly ONE clock of latency, and a read port whose enable is low holds
// the word it already gave. Both are properties of a real block RAM, and a
// model that got either one wrong would let a cache pass in simulation and
// send the wrong bytes on hardware.
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// The memory under test, with every port driven from the test.
class RamBench {
  final MimicBlockRam ram;
  final Logic clk;
  final Logic reset;
  final Logic wrEn;
  final Logic wrAddr;
  final Logic wrData;
  final Logic rdEn;
  final Logic rdAddr;

  RamBench({
    required this.ram,
    required this.clk,
    required this.reset,
    required this.wrEn,
    required this.wrAddr,
    required this.wrData,
    required this.rdEn,
    required this.rdAddr,
  });

  /// The word the read port gives now.
  int get rdData => ram.rdData.value.toInt();
}

Future<RamBench> setUpRam({int width = 32, int depth = 16}) async {
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final wrEn = Logic(name: 'wr_en');
  final wrAddr = Logic(name: 'wr_addr', width: (depth - 1).bitLength);
  final wrData = Logic(name: 'wr_data', width: width);
  final rdEn = Logic(name: 'rd_en');
  final rdAddr = Logic(name: 'rd_addr', width: (depth - 1).bitLength);
  final ram = MimicBlockRam(
    clk,
    reset: reset,
    width: width,
    depth: depth,
    wrEn: wrEn,
    wrAddr: wrAddr,
    wrData: wrData,
    rdEn: rdEn,
    rdAddr: rdAddr,
  );
  reset.put(1);
  wrEn.put(0);
  wrAddr.put(0);
  wrData.put(0);
  rdEn.put(0);
  rdAddr.put(0);
  await ram.build();
  Simulator.setMaxSimTime(100000);
  unawaited(Simulator.run());
  await clk.nextNegedge;
  await clk.nextNegedge;
  reset.inject(0);
  await clk.nextNegedge;
  return RamBench(
    ram: ram,
    clk: clk,
    reset: reset,
    wrEn: wrEn,
    wrAddr: wrAddr,
    wrData: wrData,
    rdEn: rdEn,
    rdAddr: rdAddr,
  );
}

/// Writes [data] at [addr] in one clock.
Future<void> ramWrite(RamBench b, int addr, int data) async {
  b.wrEn.inject(1);
  b.wrAddr.inject(addr);
  b.wrData.inject(data);
  await b.clk.nextNegedge;
  b.wrEn.inject(0);
}

void main() {
  tearDown(Simulator.reset);

  test('a read gives the word one clock after the address', () async {
    final b = await setUpRam();
    await ramWrite(b, 3, 0xDEADBEEF);
    await ramWrite(b, 4, 0x0BADF00D);

    // The address goes on the port. The word is NOT there yet: a block RAM
    // read port is a register, so the word lands on the next clock.
    b.rdEn.inject(1);
    b.rdAddr.inject(3);
    expect(
      b.rdData,
      0,
      reason: 'the read port answered before the clock that reads it.',
    );
    await b.clk.nextNegedge;
    expect(b.rdData, 0xDEADBEEF, reason: 'the word is one clock late.');

    b.rdAddr.inject(4);
    expect(
      b.rdData,
      0xDEADBEEF,
      reason: 'the port must hold the last word until the next clock.',
    );
    await b.clk.nextNegedge;
    expect(b.rdData, 0x0BADF00D);
    await Simulator.endSimulation();
  });

  test('a read port whose enable is low holds the word it gave', () async {
    final b = await setUpRam();
    await ramWrite(b, 1, 0x11111111);
    await ramWrite(b, 2, 0x22222222);

    b.rdEn.inject(1);
    b.rdAddr.inject(1);
    await b.clk.nextNegedge;
    expect(b.rdData, 0x11111111);

    // The address moves and the enable falls. A held read port keeps the
    // word, which is what lets the cache wait for the link with the first
    // word of a line already on the port.
    b.rdEn.inject(0);
    b.rdAddr.inject(2);
    for (var i = 0; i < 4; i++) {
      await b.clk.nextNegedge;
      expect(
        b.rdData,
        0x11111111,
        reason: 'a read port with no enable must not move.',
      );
    }
    b.rdEn.inject(1);
    await b.clk.nextNegedge;
    expect(b.rdData, 0x22222222);
    await Simulator.endSimulation();
  });

  test('a cell that no write filled reads 0, and never X', () async {
    // A DP16KD powers up at the value its INITVAL gives, and the default of
    // an inferred memory is 0. An X here would cross the whole card and
    // reach the CSR bus.
    final b = await setUpRam();
    b.rdEn.inject(1);
    b.rdAddr.inject(9);
    await b.clk.nextNegedge;
    expect(b.ram.rdData.value.isValid, isTrue, reason: 'the read gave X.');
    expect(b.rdData, 0);
    await Simulator.endSimulation();
  });

  test(
    'a write and a read of one address in one clock gives the OLD word',
    () async {
      // The emitted always_ff assigns both with non-blocking assignments, so
      // the read takes the cell as it was before the write. The model must
      // agree, or a test would pass on behaviour the silicon does not have.
      final b = await setUpRam();
      await ramWrite(b, 5, 0xAAAAAAAA);
      b.rdEn.inject(1);
      b.rdAddr.inject(5);
      await b.clk.nextNegedge;
      expect(b.rdData, 0xAAAAAAAA);

      b.wrEn.inject(1);
      b.wrAddr.inject(5);
      b.wrData.inject(0x55555555);
      await b.clk.nextNegedge;
      b.wrEn.inject(0);
      expect(
        b.rdData,
        0xAAAAAAAA,
        reason: 'the read took the word the write put in on the same clock.',
      );
      await b.clk.nextNegedge;
      expect(b.rdData, 0x55555555);
      await Simulator.endSimulation();
    },
  );

  test('the definition name states the shape of the memory', () {
    // Two memories of one shape are one module definition, and two of
    // different shapes are two. A name that did not carry the shape would
    // make the emitted file and the instantiation disagree.
    final clk = Logic(name: 'clk');
    final sig = Logic(name: 'sig');
    final ram = MimicBlockRam(
      clk,
      reset: sig,
      width: 8,
      depth: 16,
      wrEn: sig,
      wrAddr: Logic(width: 4),
      wrData: Logic(width: 8),
      rdEn: sig,
      rdAddr: Logic(width: 4),
      name: 'ram_one',
    );
    expect(ram.definitionName, 'MimicBlockRam_8x16');
    expect(ram.addrWidth, 4);
  });

  test('a memory of one entry is refused', () {
    final clk = Logic(name: 'clk');
    final sig = Logic(name: 'sig');
    expect(
      () => MimicBlockRam(
        clk,
        reset: sig,
        width: 8,
        depth: 1,
        wrEn: sig,
        wrAddr: sig,
        wrData: Logic(width: 8),
        rdEn: sig,
        rdAddr: sig,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });
}
