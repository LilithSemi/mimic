// The CONTRACT of `ready` on the block read path.
//
// The state machine reads `read_ready` in one clock and drives
// `read_start` in the NEXT one: the decode sets a register and the output
// is that register. `ready` therefore promises something about the clock
// AFTER the one it is read in, and a path that opens the window in one
// clock and shuts it in the next loses the read.
//
// A lost read is not a slow read. The state machine has already moved the
// card to the data state and answered the host with no error, so the card
// then waits in the data state for a block that nothing will ever ask the
// runtime for. No timer runs there. Every command after it needs the tran
// state and gets no answer at all.
//
// This test drives the read path alone, with the same one clock of skew
// the state machine has, and sweeps the start across a block that the card
// is taking off the channel.
@Timeout(Duration(minutes: 10))
library;

import 'dart:async';

import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// SD clocks the read path waits for the answer to one record here.
///
/// Short, so that a phase which ends in a wait returns to idle quickly.
const int _timeoutClocks = 64;

/// The block address the fills on the channel carry.
const int _fillLba = 0x5000;

/// The block address the reads name.
const int _readLba = 0x1000;

/// The read path with every port on a signal a test can drive.
class _Bench {
  final MimicSdReadPath path;
  final Logic clk;
  final Logic reset;
  final Logic enable;
  final Logic start;
  final Logic lba;
  final Logic numBlocks;
  final Logic epoch;
  final Logic multi;
  final Logic abort;
  final Logic cmdBusy;
  final Logic dataWord;
  final Logic dataEmpty;
  final Logic tagEmpty;
  final Logic blocksPushed;
  final Logic blockTag;
  final Logic fillLba;
  final Logic fillValid;
  final Logic cacheHit;
  final Logic cacheHitValid;
  final Logic cacheWord;
  final Logic txNext;
  final Logic txDone;

  _Bench({
    required this.path,
    required this.clk,
    required this.reset,
    required this.enable,
    required this.start,
    required this.lba,
    required this.numBlocks,
    required this.epoch,
    required this.multi,
    required this.abort,
    required this.cmdBusy,
    required this.dataWord,
    required this.dataEmpty,
    required this.tagEmpty,
    required this.blocksPushed,
    required this.blockTag,
    required this.fillLba,
    required this.fillValid,
    required this.cacheHit,
    required this.cacheHitValid,
    required this.cacheWord,
    required this.txNext,
    required this.txDone,
  });

  bool _high(String name) => path.output(name).value == LogicValue.one;

  bool get ready => _high('ready');
  bool get busy => _high('busy');
  bool get failed => _high('failed');
  bool get timeoutEvent => _high('timeout_event');

  /// True while the path is in the cache lookup state, which is where a
  /// read the path accepted always goes.
  bool get inLookup => _sig('read_state') == sdReadStateLookup;

  int _sig(String name) {
    final v = path.internalSignals.firstWhere((s) => s.name == name).value;
    return v.isValid ? v.toInt() : -1;
  }

  /// Moves to the next clock. Every value injected before it is what the
  /// path sees in the clock this ends.
  Future<void> tick() => clk.nextPosedge;
}

Future<_Bench> _setUp() async {
  final path = MimicSdReadPath(timeoutClocks: _timeoutClocks);
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final enable = Logic(name: 'enable');
  final start = Logic(name: 'start');
  final lba = Logic(name: 'lba', width: sdCommandArgBits);
  final numBlocks = Logic(name: 'num_blocks', width: sdCommandArgBits);
  final epoch = Logic(name: 'epoch', width: sdRequestEpochBits);
  final multi = Logic(name: 'multi');
  final abort = Logic(name: 'abort');
  final cmdBusy = Logic(name: 'cmd_busy');
  final dataWord = Logic(name: 'data_word', width: 32);
  final dataEmpty = Logic(name: 'data_empty');
  final tagEmpty = Logic(name: 'tag_empty');
  final blocksPushed = Logic(name: 'blocks_pushed', width: sdBlockCountBits);
  final blockTag = Logic(name: 'block_tag', width: sdRequestSeqBits);
  final fillLba = Logic(name: 'fill_lba', width: sdCommandArgBits);
  final fillValid = Logic(name: 'fill_valid');
  final cacheHit = Logic(name: 'cache_hit');
  final cacheHitValid = Logic(name: 'cache_hit_valid');
  final cacheWord = Logic(name: 'cache_word', width: 32);
  final txNext = Logic(name: 'tx_next');
  final txDone = Logic(name: 'tx_done');

  path.input('clk').srcConnection! <= clk;
  path.input('reset').srcConnection! <= reset;
  path.input('enable').srcConnection! <= enable;
  path.input('start').srcConnection! <= start;
  path.input('lba').srcConnection! <= lba;
  path.input('num_blocks').srcConnection! <= numBlocks;
  path.input('epoch').srcConnection! <= epoch;
  path.input('multi').srcConnection! <= multi;
  path.input('abort').srcConnection! <= abort;
  path.input('cmd_busy').srcConnection! <= cmdBusy;
  path.input('data_word').srcConnection! <= dataWord;
  path.input('data_empty').srcConnection! <= dataEmpty;
  path.input('block_tag_empty').srcConnection! <= tagEmpty;
  path.input('blocks_pushed').srcConnection! <= blocksPushed;
  path.input('block_tag').srcConnection! <= blockTag;
  path.input('block_fill_lba').srcConnection! <= fillLba;
  path.input('block_fill_valid').srcConnection! <= fillValid;
  path.input('cache_hit').srcConnection! <= cacheHit;
  path.input('cache_hit_valid').srcConnection! <= cacheHitValid;
  path.input('cache_word').srcConnection! <= cacheWord;
  path.input('tx_next').srcConnection! <= txNext;
  path.input('tx_done').srcConnection! <= txDone;
  await path.build();

  reset.inject(0);
  enable.inject(0);
  start.inject(0);
  lba.inject(0);
  numBlocks.inject(0x10000);
  epoch.inject(0);
  multi.inject(0);
  abort.inject(0);
  cmdBusy.inject(0);
  dataWord.inject(0);
  dataEmpty.inject(1);
  tagEmpty.inject(1);
  blocksPushed.inject(0);
  blockTag.inject(0);
  fillLba.inject(_fillLba);
  fillValid.inject(0);
  cacheHit.inject(0);
  cacheHitValid.inject(0);
  cacheWord.inject(0);
  txNext.inject(0);
  txDone.inject(0);

  Simulator.setMaxSimTime(20000000);
  unawaited(Simulator.run());
  // A real 0 to 1 edge on the reset. See the bench in sd_read_bench.dart.
  await clk.nextPosedge;
  reset.inject(1);
  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);
  await clk.nextPosedge;
  enable.inject(1);
  await clk.nextPosedge;

  return _Bench(
    path: path,
    clk: clk,
    reset: reset,
    enable: enable,
    start: start,
    lba: lba,
    numBlocks: numBlocks,
    epoch: epoch,
    multi: multi,
    abort: abort,
    cmdBusy: cmdBusy,
    dataWord: dataWord,
    dataEmpty: dataEmpty,
    tagEmpty: tagEmpty,
    blocksPushed: blocksPushed,
    blockTag: blockTag,
    fillLba: fillLba,
    fillValid: fillValid,
    cacheHit: cacheHit,
    cacheHitValid: cacheHitValid,
    cacheWord: cacheWord,
    txNext: txNext,
    txDone: txDone,
  );
}

void main() {
  tearDown(Simulator.reset);

  test('a start one clock after ready is always taken', () async {
    final b = await _setUp();

    // A fill waits on the channel, the way read ahead leaves one there.
    b.dataEmpty.inject(0);
    b.tagEmpty.inject(0);
    b.blockTag.inject(sdRequestSeqNone);
    b.fillValid.inject(1);

    // The phases where the path threw the start away. They are collected
    // and reported together, so one lost phase does not hide the rest and
    // the simulation still ends in order.
    final lost = <int>[];
    // The phases where the path refused the read outright. A refusal is
    // an I/O error on the host and not a retry.
    final refused = <int>[];
    var pushed = 0;
    // The sweep walks the start across every clock of the drop and a
    // little past its end.
    for (var phase = 0; phase < sdBlockWords + 8; phase++) {
      // One more whole block waits on the channel. The path is idle, so it
      // starts to take it off on the next clock.
      pushed = (pushed + 1) & ((1 << sdBlockCountBits) - 1);
      b.blocksPushed.inject(pushed);
      await b.tick();

      // Wait for the drop to open.
      var guard = 0;
      while (!b.busy) {
        await b.tick();
        expect(++guard, lessThan(8), reason: 'phase $phase: no drop opened.');
      }

      for (var i = 0; i < phase; i++) {
        await b.tick();
      }

      // The state machine reads `ready` HERE and drives `start` in the
      // clock after it.
      final sawReady = b.ready;
      await b.tick();
      if (!sawReady) {
        // The path said no. The state machine answers R1 with ERROR, and a
        // Linux host reports that as an I/O error on the request. The path
        // must therefore be ready on EVERY clock of a block it is merely
        // absorbing.
        refused.add(phase);
        while (b.busy) {
          await b.tick();
        }
        continue;
      }

      b.start.inject(1);
      b.lba.inject(_readLba + phase);
      await b.tick();
      b.start.inject(0);

      // The read must reach the LOOKUP state. That is where the card asks
      // the cache and then the runtime. A read the path dropped reaches
      // nothing at all: no lookup, no record, and no way for the state
      // machine to learn that the read it announced is gone.
      var sawLookup = b.inLookup;
      for (var i = 0; i < sdBlockWords + 32 && !sawLookup; i++) {
        await b.tick();
        if (b.inLookup) sawLookup = true;
      }
      if (!sawLookup) lost.add(phase);

      // Answer the lookup with a miss and then abort, so the path is back
      // in idle for the next phase.
      b.cacheHit.inject(0);
      b.cacheHitValid.inject(1);
      await b.tick();
      await b.tick();
      b.cacheHitValid.inject(0);
      b.abort.inject(1);
      await b.tick();
      b.abort.inject(0);
      var idleGuard = 0;
      while (b.busy) {
        await b.tick();
        expect(
          ++idleGuard,
          lessThan(sdBlockWords + 64),
          reason: 'phase $phase: the path never returned to idle.',
        );
      }
    }

    await Simulator.endSimulation();
    expect(
      lost,
      isEmpty,
      reason:
          '`ready` was high one clock before the start on these phases of '
          'the drop and the path took none of them. The state machine has '
          'already moved the card to the data state, so the card holds that '
          'state for ever and answers no command after it.',
    );
    expect(
      refused,
      isEmpty,
      reason:
          'the path refused a read on these phases of a block it was only '
          'absorbing. The state machine answers R1 with ERROR there, which '
          'a Linux host reports as an I/O error on the request.',
    );
  });

  test('a lookup the cache never answers gives up', () async {
    final b = await _setUp();

    // A read from idle with nothing on the channel. The path goes to the
    // lookup state on the next clock and waits there for the cache.
    b.start.inject(1);
    b.lba.inject(_readLba);
    await b.tick();
    b.start.inject(0);

    // The cache answers nothing at all. The path must still leave the
    // lookup state, because the card holds the DATA state through it and a
    // card that never leaves it answers no further command.
    var failed = false;
    var timedOut = false;
    for (var i = 0; i < _timeoutClocks + 64 && !failed; i++) {
      await b.tick();
      if (b.failed) failed = true;
      if (b.timeoutEvent) timedOut = true;
    }
    final busyAtEnd = b.busy;
    await Simulator.endSimulation();

    expect(
      failed,
      isTrue,
      reason:
          'the path stayed in the lookup state with no bound. The state '
          'machine holds the card in the data state until `failed` pulses.',
    );
    expect(
      timedOut,
      isTrue,
      reason: 'a lookup that ran out of time must raise the timeout event.',
    );
    expect(busyAtEnd, isFalse, reason: 'the path must be idle again.');
  });
}
