// The bench for the SD block read path tests.
//
// It holds the same modules the SoC holds on that path, wired the same
// way: the CSR slave in the bus clock domain, the card in the SD clock
// domain, and the two FIFOs that carry a request one way and a block the
// other. The two clocks are separate ports, so a test drives the bus clock
// with a generator and the SD clock by hand through the host model.
//
// The tests are split across several files, because dart test runs one
// file at a time inside a file and one block is 4114 SD clocks.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import 'sd_host_model.dart';

/// The argument of CMD8: VHS 1 for 2.7 to 3.6 V and the check pattern 0xAA.
const int sdIfCondArg = 0x000001AA;

/// The argument of ACMD41: the host voltage window and the HCS bit.
const int sdOpCondArg = 0x40FF8000;

/// Largest number of ACMD41 polls the walk sends before it gives up.
const int sdOpCondPollBound = 32;

/// The block address the read tests ask for.
const int sdTestLba = 0x00001234;

/// Word 0 of the record that the [seq] th read of a card must post.
///
/// The block count is 1 in bits 31 to 16, the SEQUENCE TAG is in bits 15
/// to 8, the card generation is in bits 7 to 4 and the opcode is 1,
/// read_blocks, in bits 3 to 0. The tag counts the reads that the card took,
/// and it starts at 1, because the tag 0 names no request at all.
int sdRecordWord0(int seq, {int epoch = 0}) =>
    0x00010001 | (seq << 8) | ((epoch & 0x0F) << 4);

/// Word 0 of the block the tests push.
///
/// The channel is LITTLE ENDIAN, so byte 0 of the block is bits 7 to 0.
/// The pattern below gives bytes 0x0B, 0x0E, 0x11 and 0x14.
const int sdBlockWord0 = 0x14110E0B;

/// The last word of the block the tests push, which holds bytes 508 to
/// 511.
const int sdBlockWord127 = 0x080502FF;

/// SD clocks the read path waits for an answer, in these tests.
///
/// The counter starts when the card posts the record, so it only has to
/// cover the R1 of CMD17 and the few clocks the block toggle needs to
/// cross. That is under 300 clocks, and the bus work costs no SD clock at
/// all because the host stops the clock while the runtime reads and
/// writes. 900 leaves room and is still short enough that a test can drive
/// the whole wait.
const int sdTestTimeoutClocks = 900;

/// SD clocks the write path of a bench waits for an acknowledgement.
///
/// It is longer than a whole block on DAT, which is 4114 clocks, because
/// the wait starts after the block and the test still drives the clock
/// through the bus accesses that answer the record.
const int sdTestWriteTimeoutClocks = 9000;

/// The 512 bytes the tests push into the data channel.
///
/// The pattern is not a constant, so a card that sends a fixed block or
/// the block of another request cannot pass.
List<int> sdTestBlockBytes() => [
  for (var i = 0; i < sdBlockBytes; i++) (i * 3 + 11) & 0xFF,
];

/// The 128 words of [bytes], packed the way the runtime packs them.
///
/// Byte 0 of the block goes in bits 7 to 0 of the first word.
List<int> sdBlockWordsOf(List<int> bytes) => [
  for (var i = 0; i < bytes.length; i += 4)
    bytes[i] |
        (bytes[i + 1] << 8) |
        (bytes[i + 2] << 16) |
        (bytes[i + 3] << 24),
];

/// The read path in the small: the CSR slave, the card, and the two FIFOs
/// that carry a request one way and a block the other.
///
/// It holds the same modules the SoC holds on this path, wired the same
/// way. The two clocks are separate ports, so a test drives the bus clock
/// with a generator and the SD clock by hand through the host model.
///
/// With [breakDataCrossing] the data FIFO is bypassed: the card reads a
/// single register that samples the CSR data bus on the SD clock. That is
/// the crossing a stream must NOT have, and the negative control test uses
/// it to show that the FIFO is what carries the block.
class SdReadBridge extends BridgeModule {
  /// The CSR slave that the runtime drives.
  late final MimicSdCard csr;

  /// The card personality on the SD bus.
  late final MimicSdCardDevice card;

  /// True while the data words bypass the FIFO. See the class doc.
  final bool breakDataCrossing;

  /// True while the WRITE words bypass their FIFO.
  ///
  /// It is the mirror of [breakDataCrossing]: the card pushes the block it
  /// took into one register in the bus clock domain rather than into the
  /// FIFO, so the runtime reads whatever that register held at the last bus
  /// clock edge. The negative control of the write path uses it.
  final bool breakWriteCrossing;

  /// Holds the tag channel full for an admission test.
  final bool forceTagFull;

  /// Number of lines in the block cache of the card under test.
  final int cacheLines;

  SdReadBridge({
    this.breakDataCrossing = false,
    this.breakWriteCrossing = false,
    this.forceTagFull = false,
    int readTimeoutClocks = sdTestTimeoutClocks,
    int writeTimeoutClocks = sdTestWriteTimeoutClocks,
    this.cacheLines = sdCacheDefaultLines,
    String name = 'read_bridge',
  }) : super(
         // The line count changes the shape of the bridge, so two benches
         // of different cache sizes are two definitions. The name is
         // reserved, so one name for both would make ROHD refuse to emit.
         '${breakWriteCrossing ? 'ReadBridgeWriteTorn' : (breakDataCrossing ? 'ReadBridgeTorn' : (forceTagFull ? 'ReadBridgeTagFull' : 'ReadBridge'))}L$cacheLines',
         name: name,
         reserveDefinitionName: true,
       ) {
    createPort('sys_clk', PortDirection.input);
    createPort('sd_clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('wb_cyc', PortDirection.input);
    createPort('wb_stb', PortDirection.input);
    createPort('wb_we', PortDirection.input);
    createPort('wb_adr', PortDirection.input, width: 12);
    createPort('wb_dat', PortDirection.input, width: 32);
    createPort('wb_sel', PortDirection.input, width: 4);
    createPort('sd_cmd_in', PortDirection.input);
    createPort('sd_dat_in', PortDirection.input);
    createPort('num_blocks', PortDirection.input, width: sdCommandArgBits);
    createPort('tag_visible', PortDirection.input);
    addOutput('wb_ack');
    addOutput('wb_miso', width: 32);
    addOutput('sd_cmd_out');
    addOutput('sd_cmd_oe');
    addOutput('sd_dat_out');
    addOutput('sd_dat_oe');
    addOutput('card_state', width: sdCardStateBits);
    // The push into the acknowledge channel, brought out so that a test can
    // see whether a write of WRITE_ACK reached the channel at all. The
    // channel itself gives nothing back: an entry that the card pops leaves
    // no mark that a test can read.
    addOutput('ack_push');

    final sysClk = input('sys_clk');
    final sdClk = input('sd_clk');
    final reset = input('reset');

    csr = MimicSdCard(
      baseAddress: 0,
      name: 'mimic_sd_card',
      cacheLines: cacheLines,
    );
    addSubModule(csr);
    card = MimicSdCardDevice(
      name: 'sd_card_device',
      readTimeoutClocks: readTimeoutClocks,
      writeTimeoutClocks: writeTimeoutClocks,
      cacheLines: cacheLines,
    );
    addSubModule(card);

    csr.input('clk').srcConnection! <= sysClk;
    csr.input('reset').srcConnection! <= reset;
    csr.input('bus_CYC').srcConnection! <= input('wb_cyc');
    csr.input('bus_STB').srcConnection! <= input('wb_stb');
    csr.input('bus_WE').srcConnection! <= input('wb_we');
    csr.input('bus_ADR').srcConnection! <= input('wb_adr');
    csr.input('bus_DAT_MOSI').srcConnection! <= input('wb_dat');
    csr.input('bus_SEL').srcConnection! <= input('wb_sel');
    output('wb_ack') <= csr.output('bus_ACK');
    output('wb_miso') <= csr.output('bus_DAT_MISO');

    // The reset of the SD clock domain, the way the SoC builds it. It goes
    // high with no clock at all and it releases two SD clocks after the
    // SoC reset does, so a card whose clock never ticks holds its reset
    // and publishes the values a reset gives, and never X.
    final sdResetSync = MimicResetSync(name: 'sd_reset_sync');
    addSubModule(sdResetSync);
    sdResetSync.input('clk').srcConnection! <= sdClk;
    sdResetSync.input('async_reset').srcConnection! <= reset;
    final sdReset = sdResetSync.output('reset');

    // The SD domain reset, seen from the bus clock domain, the way the SoC
    // builds it. While it stands, the request channel and the write data
    // channel both read EMPTY, because the card has pushed nothing and a
    // channel that read otherwise would hand the runtime a word that no
    // card ever wrote. A board whose host never starts the SD clock holds
    // this for ever, and the SoC has the same guard.
    final sdHeldSync = HarborCdcSync(name: 'sd_reset_sys_sync');
    addSubModule(sdHeldSync);
    sdHeldSync.input('async_in').srcConnection! <= sdReset;
    sdHeldSync.input('dst_clk').srcConnection! <= sysClk;
    sdHeldSync.input('dst_reset').srcConnection! <= reset;
    final sdHeld = (sdHeldSync.output('sync_out') | reset).named(
      'sd_domain_held',
    );

    card.input('clk').srcConnection! <= sdClk;
    card.input('reset').srcConnection! <= sdReset;
    card.input('sd_cmd_in').srcConnection! <= input('sd_cmd_in');
    card.input('sd_dat_in').srcConnection! <= input('sd_dat_in');
    output('sd_cmd_out') <= card.output('sd_cmd_out');
    output('sd_cmd_oe') <= card.output('sd_cmd_oe');
    output('sd_dat_out') <= card.output('sd_dat_out');
    output('sd_dat_oe') <= card.output('sd_dat_oe');
    output('card_state') <= card.output('card_state');

    // The CSD stays at the default that the card resets to. No test here
    // reads a capacity, and the crossing that carries a written CSD has a
    // test of its own.
    card.input('csd').srcConnection! <=
        Const(sdCardCsdValue, width: sdResponseRegBits);
    card.input('csd_valid').srcConnection! <= Const(0);
    card.input('num_blocks').srcConnection! <= input('num_blocks');
    card.input('num_blocks_valid').srcConnection! <= Const(1);

    // The card state and the four bring-up counters, on the roads the SoC
    // gives them. The CSR slave needs these inputs driven.
    final stateBits = <Logic>[];
    for (var i = 0; i < sdCardStateBits; i++) {
      final sync = HarborCdcSync(name: 'card_state_sync_$i');
      addSubModule(sync);
      sync.input('async_in').srcConnection! <= card.output('card_state')[i];
      sync.input('dst_clk').srcConnection! <= sysClk;
      sync.input('dst_reset').srcConnection! <= reset;
      stateBits.add(sync.output('sync_out'));
    }
    csr.input('card_state').srcConnection! <= stateBits.rswizzle();

    final dbg = <String, ({String cardPort, int width})>{
      'dbg_sd_clk': (cardPort: 'dbg_sd_clk_gray', width: sdDbgClkBits),
      'dbg_sd_cmd': (cardPort: 'dbg_sd_cmd_gray', width: sdDbgEventBits),
      'dbg_sd_crc_err': (
        cardPort: 'dbg_sd_crc_err_gray',
        width: sdDbgEventBits,
      ),
      'dbg_sd_resp': (cardPort: 'dbg_sd_resp_gray', width: sdDbgEventBits),
      'dbg_cache_hit': (cardPort: 'dbg_cache_hit_gray', width: sdDbgEventBits),
      'dbg_cache_miss': (
        cardPort: 'dbg_cache_miss_gray',
        width: sdDbgEventBits,
      ),
      'dbg_cache_fill': (
        cardPort: 'dbg_cache_fill_gray',
        width: sdDbgEventBits,
      ),
    };
    dbg.forEach((csrPort, spec) {
      final sync = MimicSdGraySync(width: spec.width, name: '${csrPort}_sync');
      addSubModule(sync);
      sync.input('gray_in').srcConnection! <= card.output(spec.cardPort);
      sync.input('clk').srcConnection! <= sysClk;
      sync.input('reset').srcConnection! <= reset;
      csr.input(csrPort).srcConnection! <= sync.output('count');
    });

    // The request channel. The card writes a record in the SD clock
    // domain and the runtime reads it in the bus domain.
    final reqFifo = HarborCdcFifo(
      dataWidth: sdRequestBits,
      depth: sdRequestFifoDepth,
      name: 'sd_req_fifo',
    );
    addSubModule(reqFifo);
    reqFifo.input('wr_clk').srcConnection! <= sdClk;
    reqFifo.input('wr_reset').srcConnection! <= sdReset;
    reqFifo.input('wr_data').srcConnection! <= card.output('req_data');
    reqFifo.input('wr_en').srcConnection! <= card.output('req_valid');
    reqFifo.input('rd_clk').srcConnection! <= sysClk;
    reqFifo.input('rd_reset').srcConnection! <= reset;
    reqFifo.input('rd_en').srcConnection! <= csr.output('req_pop');
    csr.input('req_data').srcConnection! <= reqFifo.output('rd_data');
    csr.input('req_empty').srcConnection! <= reqFifo.output('rd_empty');

    // The data channel, four whole blocks deep, the way the SoC sets it.
    // Its almost-full margin is one block, so the flag gates admission of
    // a transaction that must land all 128 words.
    const ecp5Target = HarborFpgaTarget.ecp5(
      device: 'lfe5u-25f',
      package: 'CSFBGA285',
    );
    final dataFifo = MimicByteLaneCdcFifo(
      depth: sdDataInFifoWords,
      almostFullMargin: sdBlockWords,
      target: ecp5Target,
      name: 'sd_data_fifo',
    );
    addSubModule(dataFifo);
    dataFifo.input('wr_clk').srcConnection! <= sysClk;
    dataFifo.input('wr_reset').srcConnection! <= reset;
    dataFifo.input('wr_data').srcConnection! <= csr.output('data_word');
    dataFifo.input('wr_en').srcConnection! <= csr.output('data_push');
    dataFifo.input('rd_clk').srcConnection! <= sdClk;
    dataFifo.input('rd_reset').srcConnection! <= sdReset;
    dataFifo.input('rd_en').srcConnection! <= card.output('data_pop');
    csr.input('data_full').srcConnection! <= dataFifo.output('wr_full');
    csr.input('data_blocked').srcConnection! <=
        dataFifo.output('wr_almost_full');

    // The tag channel, one entry per block.
    final tagFifo = HarborCdcFifo(
      dataWidth: sdTagChannelBits,
      depth: sdTagFifoDepth,
      name: 'sd_tag_fifo',
    );
    addSubModule(tagFifo);
    tagFifo.input('wr_clk').srcConnection! <= sysClk;
    tagFifo.input('wr_reset').srcConnection! <= reset;
    tagFifo.input('wr_data').srcConnection! <= csr.output('tag_word');
    tagFifo.input('wr_en').srcConnection! <= csr.output('tag_push');
    tagFifo.input('rd_clk').srcConnection! <= sdClk;
    tagFifo.input('rd_reset').srcConnection! <= sdReset;
    tagFifo.input('rd_en').srcConnection! <= card.output('data_tag_pop');
    csr.input('tag_full').srcConnection! <=
        (forceTagFull ? Const(1) : tagFifo.output('wr_full'));
    // One entry names one block: the sequence tag in the low bits and the
    // FILL ADDRESS above it, the way the SoC splits it.
    card.input('data_tag').srcConnection! <=
        tagFifo.output('rd_data').getRange(0, sdRequestSeqBits);
    card.input('data_fill_lba').srcConnection! <=
        tagFifo
            .output('rd_data')
            .getRange(
              sdTagChannelLbaLsb,
              sdTagChannelLbaLsb + sdCommandArgBits,
            );
    card.input('data_fill_valid').srcConnection! <=
        tagFifo.output('rd_data')[sdTagChannelValidBit];
    card.input('data_tag_empty').srcConnection! <=
        (tagFifo.output('rd_empty') | ~input('tag_visible'));

    if (breakDataCrossing) {
      // The broken crossing: one register in the SD clock domain that
      // samples the CSR data bus. It has no queue and no pointer, so the
      // card reads whatever the bus held at the last SD clock edge and
      // never the words in the order the runtime wrote them.
      final tornWord = Logic(name: 'torn_word', width: 32);
      Sequential(
        sdClk,
        reset: reset,
        resetValues: {tornWord: Const(0, width: 32)},
        [tornWord < csr.output('data_word')],
      );
      card.input('data_word').srcConnection! <= tornWord;
      card.input('data_empty').srcConnection! <= Const(0);
    } else {
      card.input('data_word').srcConnection! <= dataFifo.output('rd_data');
      card.input('data_empty').srcConnection! <= dataFifo.output('rd_empty');
    }

    card.input('card_enable').srcConnection! <= csr.output('card_enable');
    card.input('data_blocks_pushed_gray').srcConnection! <=
        csr.output('data_blocks_pushed_gray');
    csr.input('sd_read_timeout_toggle').srcConnection! <=
        card.output('read_timeout_toggle');

    // The WORDS the card took off the data channel, on the gray road the
    // SoC gives them. `DATA_IN_COUNT` is built from this count.
    final wordsConsumedSync = MimicSdGraySync(
      width: sdDataWordCountBits,
      name: 'words_consumed_sync',
    );
    addSubModule(wordsConsumedSync);
    wordsConsumedSync.input('gray_in').srcConnection! <=
        card.output('words_consumed_gray');
    wordsConsumedSync.input('clk').srcConnection! <= sysClk;
    wordsConsumedSync.input('reset').srcConnection! <= reset;
    csr.input('words_consumed').srcConnection! <=
        wordsConsumedSync.output('count');

    // The WRITE channel: the block the host wrote, on its way to the
    // runtime. It is the mirror of the data channel above, one whole block
    // deep and in the other direction.
    //
    // The margin is the WHOLE depth, the way the SoC sets it, so
    // `wr_almost_full` reads "the channel holds at least one word". That
    // is what the card gates a new write on.
    final outFifo = HarborCdcFifo(
      dataWidth: 32,
      depth: sdDataFifoWords,
      almostFullMargin: sdDataFifoWords,
      // The SoC puts this channel on block RAM. This bench gives no
      // target, so the FIFO falls back to the flop array and the flag
      // changes nothing here. It is set so that the two stay the same
      // shape if the bench ever gets a target.
      blockRam: true,
      name: 'sd_out_fifo',
    );
    addSubModule(outFifo);
    outFifo.input('wr_clk').srcConnection! <= sdClk;
    outFifo.input('wr_reset').srcConnection! <= sdReset;
    outFifo.input('wr_data').srcConnection! <= card.output('out_word');
    outFifo.input('wr_en').srcConnection! <= card.output('out_push');
    outFifo.input('rd_clk').srcConnection! <= sysClk;
    outFifo.input('rd_reset').srcConnection! <= reset;
    outFifo.input('rd_en').srcConnection! <= csr.output('out_pop');
    // The channel reads EMPTY while the SD domain is in reset, the way the
    // SoC reads it. See [sdHeld]. Without the guard a bench with a parked
    // SD clock reads a word out of a memory that no reset ever loaded.
    csr.input('out_empty').srcConnection! <=
        outFifo.output('rd_empty') | sdHeld;
    // The WRITE side of the same channel, which the card reads. `out_room`
    // says the channel holds no word and is what holds a second write off
    // while a block is still on it. `out_full` is what the card counts its
    // accepted pushes with, because a full channel drops a push.
    card.input('out_room').srcConnection! <= ~outFifo.output('wr_almost_full');
    card.input('out_full').srcConnection! <= outFifo.output('wr_full');

    if (breakWriteCrossing) {
      // The broken crossing, the mirror of the torn read above: one
      // register in the bus clock domain that samples the word the card
      // pushes. It has no queue and no pointer, so the runtime reads
      // whatever the card held at the last bus clock edge and never the
      // words in the order the card pushed them.
      final tornOut = Logic(name: 'torn_out_word', width: 32);
      Sequential(
        sysClk,
        reset: reset,
        resetValues: {tornOut: Const(0, width: 32)},
        [tornOut < card.output('out_word')],
      );
      csr.input('out_data').srcConnection! <= tornOut;
    } else {
      csr.input('out_data').srcConnection! <= outFifo.output('rd_data');
    }

    // The acknowledge channel, which releases the host from busy.
    final ackFifo = HarborCdcFifo(
      dataWidth: sdWriteAckBits,
      depth: sdWriteAckFifoDepth,
      name: 'sd_ack_fifo',
    );
    addSubModule(ackFifo);
    ackFifo.input('wr_clk').srcConnection! <= sysClk;
    ackFifo.input('wr_reset').srcConnection! <= reset;
    ackFifo.input('wr_data').srcConnection! <= csr.output('ack_word');
    ackFifo.input('wr_en').srcConnection! <= csr.output('ack_push');
    output('ack_push') <= csr.output('ack_push');
    ackFifo.input('rd_clk').srcConnection! <= sdClk;
    ackFifo.input('rd_reset').srcConnection! <= sdReset;
    ackFifo.input('rd_en').srcConnection! <= card.output('ack_pop');
    card.input('ack_data').srcConnection! <= ackFifo.output('rd_data');
    card.input('ack_empty').srcConnection! <= ackFifo.output('rd_empty');

    final wordsSync = MimicSdGraySync(
      width: sdDataWordCountBits,
      name: 'words_written_sync',
    );
    addSubModule(wordsSync);
    wordsSync.input('gray_in').srcConnection! <=
        card.output('words_written_gray');
    wordsSync.input('clk').srcConnection! <= sysClk;
    wordsSync.input('reset').srcConnection! <= reset;
    csr.input('words_written').srcConnection! <= wordsSync.output('count');

    card.input('write_back').srcConnection! <= csr.output('write_back');
    csr.input('sd_write_timeout_toggle').srcConnection! <=
        card.output('write_timeout_toggle');
  }
}

/// The bench: the bridge, the two clocks and the bus a test drives.
class SdReadBench {
  /// The design under test.
  final SdReadBridge bridge;

  /// The host that drives the SD bus and the SD clock.
  final SdHost host;

  /// The free-running bus clock. It is asynchronous to the SD clock.
  final Logic sysClk;

  /// The reset of both domains, so a test can assert it again and prove
  /// what a reset throws away.
  final Logic reset;

  /// The Wishbone master signals that a test drives.
  final Logic cyc;
  final Logic stb;
  final Logic we;
  final Logic adr;
  final Logic dat;

  /// Test control for the tag FIFO read-side visibility.
  final Logic tagVisible;

  SdReadBench({
    required this.bridge,
    required this.host,
    required this.sysClk,
    required this.reset,
    required this.cyc,
    required this.stb,
    required this.we,
    required this.adr,
    required this.dat,
    required this.tagVisible,
  });

  /// The card state that the card reports now, on the SD side.
  int get cardState => bridge.output('card_state').value.toInt();

  /// True while the CSR slave pushes an entry into the acknowledge channel.
  bool get ackPush => bridge.output('ack_push').value == LogicValue.one;
}

/// Builds the bridge with both clocks running and reset released.
/// [parkSdClock] holds the SD clock STILL through the reset and after it,
/// which is what a board whose host never starts the clock gives. The bus
/// clock runs, so a test can still read the CSR map. Every register of the
/// SD clock domain then holds the value its reset gives, and a register
/// that no reset ever loaded reads X.
Future<SdReadBench> setUpSdReadBench({
  bool breakDataCrossing = false,
  bool breakWriteCrossing = false,
  bool forceTagFull = false,
  int readTimeoutClocks = sdTestTimeoutClocks,
  int writeTimeoutClocks = sdTestWriteTimeoutClocks,
  int cacheLines = sdCacheDefaultLines,
  bool parkSdClock = false,
  int capacityBlocks = sdCardCapacityBlocks,
}) async {
  final bridge = SdReadBridge(
    breakDataCrossing: breakDataCrossing,
    breakWriteCrossing: breakWriteCrossing,
    forceTagFull: forceTagFull,
    readTimeoutClocks: readTimeoutClocks,
    writeTimeoutClocks: writeTimeoutClocks,
    cacheLines: cacheLines,
  );
  final sdClk = Logic(name: 'sd_clk');
  final reset = Logic(name: 'reset');
  final cmdIn = Logic(name: 'sd_cmd_in');
  final datIn = Logic(name: 'sd_dat_in');
  final cyc = Logic(name: 'wb_cyc');
  final stb = Logic(name: 'wb_stb');
  final we = Logic(name: 'wb_we');
  final adr = Logic(name: 'wb_adr', width: 12);
  final dat = Logic(name: 'wb_dat', width: 32);
  final sel = Logic(name: 'wb_sel', width: 4);
  final tagVisible = Logic(name: 'tag_visible');
  final numBlocks = Logic(name: 'num_blocks', width: sdCommandArgBits);

  // One SD clock period is 10 time units, which is what the host model
  // drives. 6 is not a whole part of it, so the two domains drift against
  // each other the way two real clocks do.
  final sysClk = SimpleClockGenerator(6).clk;

  bridge.input('sys_clk').srcConnection! <= sysClk;
  bridge.input('sd_clk').srcConnection! <= sdClk;
  bridge.input('reset').srcConnection! <= reset;
  bridge.input('sd_cmd_in').srcConnection! <= cmdIn;
  bridge.input('sd_dat_in').srcConnection! <= datIn;
  bridge.input('wb_cyc').srcConnection! <= cyc;
  bridge.input('wb_stb').srcConnection! <= stb;
  bridge.input('wb_we').srcConnection! <= we;
  bridge.input('wb_adr').srcConnection! <= adr;
  bridge.input('wb_dat').srcConnection! <= dat;
  bridge.input('wb_sel').srcConnection! <= sel;
  bridge.input('tag_visible').srcConnection! <= tagVisible;
  bridge.input('num_blocks').srcConnection! <= numBlocks;
  await bridge.build();

  final host = SdHost(
    clk: sdClk,
    cmdOut: cmdIn,
    datOut: datIn,
    cardCmd: bridge.output('sd_cmd_out'),
    cardCmdOe: bridge.output('sd_cmd_oe'),
    cardDat: bridge.output('sd_dat_out'),
    cardDatOe: bridge.output('sd_dat_oe'),
  );

  sdClk.inject(0);
  // A real 0 to 1 EDGE on the reset, and not an X to 1 change. ROHD builds
  // `always_ff @(posedge clk, posedge reset)` for an asynchronous reset,
  // and that fires on the EDGE alone: a reset that starts at X never gives
  // one, so every register with an asynchronous reset holds X for the
  // whole simulation. `read_timeout_toggle` is such a register, and the X
  // reaches EVENT through the synchroniser. Only a bench that gives the
  // edge can see the difference.
  reset.inject(0);
  cmdIn.inject(1);
  datIn.inject(1);
  cyc.inject(0);
  stb.inject(0);
  we.inject(0);
  adr.inject(0);
  dat.inject(0);
  sel.inject(0xF);
  tagVisible.inject(1);
  numBlocks.inject(capacityBlocks);
  Simulator.setMaxSimTime(40000000);
  unawaited(Simulator.run());
  // One tick with the reset low, and then the edge.
  await Simulator.tick();
  reset.inject(1);
  if (parkSdClock) {
    // No SD clock at any time. The bus clock alone runs, so the CSR slave
    // still answers and the SD domain holds the reset that
    // [MimicResetSync] gives it with no clock at all.
    for (var i = 0; i < 8; i++) {
      await Simulator.tick();
    }
    reset.inject(0);
    for (var i = 0; i < 8; i++) {
      await Simulator.tick();
    }
  } else {
    // Both domains need edges under reset, because each holds its own
    // registers.
    await host.idle(4);
    reset.inject(0);
    await host.idle(sdCommandGapClocks);
  }
  return SdReadBench(
    bridge: bridge,
    host: host,
    sysClk: sysClk,
    reset: reset,
    cyc: cyc,
    stb: stb,
    we: we,
    adr: adr,
    dat: dat,
    tagVisible: tagVisible,
  );
}

/// Runs one Wishbone write cycle on the bus clock.
Future<void> wbWrite(SdReadBench b, int addr, int data) async {
  await b.sysClk.nextPosedge;
  b.adr.inject(addr);
  b.dat.inject(data);
  b.we.inject(1);
  b.cyc.inject(1);
  b.stb.inject(1);
  await wbFinish(b);
}

/// Runs one Wishbone read cycle on the bus clock and returns the word.
Future<int> wbRead(SdReadBench b, int addr) async {
  await b.sysClk.nextPosedge;
  b.adr.inject(addr);
  b.we.inject(0);
  b.cyc.inject(1);
  b.stb.inject(1);
  await wbFinish(b);
  return b.bridge.output('wb_miso').value.toInt();
}

/// Waits for ACK and drops the cycle.
Future<void> wbFinish(SdReadBench b) async {
  for (var i = 0; i < 16; i++) {
    await b.sysClk.nextPosedge;
    if (b.bridge.output('wb_ack').value == LogicValue.one) {
      b.cyc.inject(0);
      b.stb.inject(0);
      b.we.inject(0);
      return;
    }
  }
  fail('the CSR slave gave no ACK in 16 bus clocks');
}

/// Drives the identification walk and leaves the card in tran.
///
/// It sends the commands a host sends before it reads a block and checks
/// only that each one is answered, because the answers themselves have a
/// test of their own in sd_card_ident_test.dart.
Future<void> walkToTran(SdReadBench b) async {
  final host = b.host;
  await host.idle(sdCommandGapClocks);
  await host.sendCommand(sdCmdGoIdleState, 0);
  await host.receiveResponse(SdResponseKind.r1, timeoutClocks: 16);

  await host.idle(sdCommandGapClocks);
  await host.sendCommand(sdCmdSendIfCond, sdIfCondArg);
  final ifCond = await host.receiveResponse(SdResponseKind.r1);
  expect(ifCond.timedOut, isFalse, reason: 'CMD8 gave no response.');

  var ready = false;
  for (var poll = 0; poll < sdOpCondPollBound && !ready; poll++) {
    await host.idle(sdCommandGapClocks);
    await host.sendCommand(sdCmdAppCmd, 0);
    final appCmd = await host.receiveResponse(SdResponseKind.r1);
    expect(appCmd.timedOut, isFalse, reason: 'CMD55 gave no response.');

    await host.idle(sdCommandGapClocks);
    await host.sendCommand(sdAcmdSendOpCond, sdOpCondArg);
    final opCond = await host.receiveResponse(SdResponseKind.r3);
    expect(opCond.timedOut, isFalse, reason: 'ACMD41 gave no response.');
    // Bit 31 of the OCR is the power-up status.
    ready = (opCond.payload & 0x80000000) != 0;
  }
  expect(ready, isTrue, reason: 'the card never reported its power-up done.');

  await host.idle(sdCommandGapClocks);
  await host.sendCommand(sdCmdAllSendCid, 0);
  final cid = await host.receiveResponse(SdResponseKind.r2);
  expect(cid.timedOut, isFalse, reason: 'CMD2 gave no response.');

  await host.idle(sdCommandGapClocks);
  await host.sendCommand(sdCmdSendRelativeAddr, 0);
  final rca = await host.receiveResponse(SdResponseKind.r1);
  expect(rca.timedOut, isFalse, reason: 'CMD3 gave no response.');

  await host.idle(sdCommandGapClocks);
  await host.sendCommand(sdCmdSelectCard, sdCardRca << 16);
  final select = await host.receiveResponse(SdResponseKind.r1);
  expect(select.timedOut, isFalse, reason: 'CMD7 gave no response.');

  expect(
    b.cardState,
    sdCardStateTran,
    reason: 'the walk must leave the card in tran.',
  );
}

/// Reads one record off the request channel, the way the runtime does.
///
/// Word 0 comes from REQ and word 1 from REQ_HI. NEITHER read has a side
/// effect, so the record goes away only on the WRITE of REQ_POP that ends
/// this helper. No access between the three changes anything.
Future<({int word0, int lba, int seq, int epoch})> takeRecord(
  SdReadBench b,
) async {
  final word0 = await wbRead(b, MimicReg.req);
  final lba = await wbRead(b, MimicReg.reqHi);
  await wbWrite(b, MimicReg.reqPop, MimicReqPop.pop);
  return (
    word0: word0,
    lba: lba,
    seq: (word0 >> 8) & 0xFF,
    epoch: (word0 >> 4) & 0x0F,
  );
}

/// Pushes one block into the data channel, the way the runtime does.
///
/// The tag goes in first, one write, and then the 128 words of the block.
/// A block that no tag names is thrown away by the card.
Future<void> pushBlock(
  SdReadBench b,
  List<int> words, {
  required int tag,
}) async {
  await wbWrite(b, MimicReg.dataTag, tag);
  for (final word in words) {
    await wbWrite(b, MimicReg.dataIn, word);
  }
}

/// Sends CMD55 and then one application command, and returns the R1 of
/// that application command.
///
/// The card reads an index as an application command only while the CMD55
/// bit is high, so the pair belongs together.
Future<SdResponse> appCommand(SdReadBench b, int index, int argument) async {
  await b.host.idle(sdCommandGapClocks);
  await b.host.sendCommand(sdCmdAppCmd, sdCardRca << 16);
  final appCmd = await b.host.receiveResponse(SdResponseKind.r1);
  expect(appCmd.timedOut, isFalse, reason: 'CMD55 gave no response.');

  await b.host.idle(sdCommandGapClocks);
  await b.host.sendCommand(index, argument);
  final answer = await b.host.receiveResponse(SdResponseKind.r1);
  expect(answer.timedOut, isFalse, reason: 'ACMD$index gave no response.');
  return answer;
}

/// Reads the SCR the way `mmc_sd_setup_card` does: ACMD51 and then the 8
/// bytes on DAT0.
///
/// The frame has the shape of a block read with 8 bytes in it, so the host
/// model decodes it with the same method and its own CRC16.
Future<SdDataBlock> readScr(SdReadBench b) async {
  final answer = await appCommand(b, sdAcmdSendScr, 0);
  expect(
    answer.payload & (1 << 19),
    0,
    reason: 'ACMD51 answered R1 with ERROR, so no SCR follows.',
  );
  return b.host.receiveDataBlock(blockBytes: sdScrBytes, timeoutClocks: 200);
}

/// Answers one record on the request channel with [bytes].
///
/// It reads the record the way the runtime does, checks the address and
/// the opcode, and pushes the block back with the tag of that record.
Future<void> answerRecord(
  SdReadBench b,
  List<int> bytes, {
  required int expectLba,
}) async {
  final record = await takeRecord(b);
  expect(
    record.lba,
    expectLba,
    reason: 'the card asked for another block than the one the host wants.',
  );
  expect(
    record.word0 & 0x0F,
    sdRequestOpReadBlocks,
    reason: 'the record carries an opcode the runtime does not know.',
  );
  expect(
    (record.word0 >> 16) & 0xFFFF,
    1,
    reason: 'a record asks for ONE block, whatever command started it.',
  );
  await pushBlock(b, sdBlockWordsOf(bytes), tag: record.seq);
}

/// The bytes of block [lba] in the image the multi-block tests serve.
///
/// The pattern moves with the address, so a card that sends the same block
/// twice, or the block of another address, cannot pass.
List<int> sdTestBlockBytesFor(int lba) => [
  for (var i = 0; i < sdBlockBytes; i++) (i * 3 + 11 + lba * 7) & 0xFF,
];

/// Takes [count] words off the write data channel.
///
/// Each word costs one read of DATA_OUT and one write of DATA_OUT_POP,
/// because NO ADDRESS OF THE MAP HAS A SIDE EFFECT ON READ. The read
/// leaves the word where it is and the write takes it away.
Future<List<int>> pullWriteWords(SdReadBench b, int count) async {
  final words = <int>[];
  for (var i = 0; i < count; i++) {
    words.add(await wbRead(b, MimicReg.dataOut));
    await wbWrite(b, MimicReg.dataOutPop, MimicDataOutPop.pop);
  }
  return words;
}

/// The bytes of [words], LITTLE ENDIAN, so byte 0 is bits 7 to 0 of word 0.
List<int> sdBytesOfWords(List<int> words) => [
  for (final w in words) ...[
    w & 0xFF,
    (w >> 8) & 0xFF,
    (w >> 16) & 0xFF,
    (w >> 24) & 0xFF,
  ],
];

/// Retires the write that [tag] names and releases the host from busy.
Future<void> ackWrite(SdReadBench b, int tag, {bool fail = false}) async {
  await wbWrite(
    b,
    MimicReg.writeAck,
    (tag & MimicWriteAck.tagMask) | (fail ? MimicWriteAck.fail : 0),
  );
}

/// The opcode field of word 0 of a record.
int sdRecordOp(int word0) => word0 & 0x0F;

/// Pushes one FILL into the data channel, the way a runtime pushes a block
/// that nobody asked for.
///
/// The block address goes in first, then the tag that names NO record, and
/// then the 128 words. The card writes the block into the line the address
/// maps to and sends nothing on the SD bus.
///
/// It then drives the SD clock long enough for the card to take the block
/// off the channel. The card does that one word per SD clock, and the card
/// refuses a read while a block it did not ask for is still on the
/// channel, so a test that read too early would get a refusal and not a
/// hit.
Future<void> pushFill(
  SdReadBench b,
  List<int> bytes, {
  required int lba,
}) async {
  await pushFillNoDrain(b, bytes, lba: lba);
  await b.host.idle(sdBlockWords + 64);
}

/// Pushes one FILL into the data channel and drives NO SD clock after it.
///
/// It is what read ahead really does. The runtime pushes a block that
/// nobody asked for while the host is busy with something else, and the
/// card takes it off the channel whenever its own clock next runs. A test
/// that wants to see the card work with a block still waiting takes this
/// one and chooses how many clocks to give it.
Future<void> pushFillNoDrain(
  SdReadBench b,
  List<int> bytes, {
  required int lba,
}) async {
  await wbWrite(b, MimicReg.dataFillLba, lba);
  await wbWrite(b, MimicReg.dataTag, MimicDataTag.fill);
  for (final word in sdBlockWordsOf(bytes)) {
    await wbWrite(b, MimicReg.dataIn, word);
  }
}

/// The three block cache counters, read the way a runtime reads them.
Future<({int hit, int miss, int fill})> cacheCounters(SdReadBench b) async => (
  hit: await wbRead(b, MimicReg.dbgCacheHit),
  miss: await wbRead(b, MimicReg.dbgCacheMiss),
  fill: await wbRead(b, MimicReg.dbgCacheFill),
);

/// Sends CMD17 for [lba] and checks that the card accepted it.
Future<void> startRead(SdReadBench b, int lba, {String reason = ''}) async {
  await b.host.idle(sdCommandGapClocks);
  await b.host.sendCommand(sdCmdReadSingleBlock, lba);
  final r1 = await b.host.receiveResponse(SdResponseKind.r1);
  expect(r1.timedOut, isFalse, reason: '$reason CMD17 gave no response.');
  expect(
    r1.payload & (1 << 19),
    0,
    reason: '$reason the card answered CMD17 with ERROR.',
  );
}

/// Reads block [lba] and requires a HIT: the card must post NO record.
Future<SdDataBlock> readCachedBlock(
  SdReadBench b,
  int lba, {
  String reason = '',
}) async {
  await startRead(b, lba, reason: reason);
  expect(
    await wbRead(b, MimicReg.reqCount),
    0,
    reason: '$reason a read the cache holds must post NO record.',
  );
  final got = await b.host.receiveDataBlock(timeoutClocks: 400);
  expect(got.timedOut, isFalse, reason: '$reason the card sent no block.');
  expect(got.crcOk, isTrue, reason: '$reason the block has a bad CRC16.');
  // The card leaves the data state one clock after the end bit, so a
  // caller that reads the card state needs these clocks to have run.
  await b.host.idle(4);
  return got;
}

/// Reads block [lba] and requires a MISS: the card must post one record,
/// which this helper answers with [bytes].
Future<SdDataBlock> readMissedBlock(
  SdReadBench b,
  int lba,
  List<int> bytes, {
  String reason = '',
}) async {
  await startRead(b, lba, reason: reason);
  expect(
    await wbRead(b, MimicReg.reqCount),
    1,
    reason: '$reason a read the cache does not hold must post one record.',
  );
  await answerRecord(b, bytes, expectLba: lba);
  final got = await b.host.receiveDataBlock(timeoutClocks: 400);
  expect(got.timedOut, isFalse, reason: '$reason the card sent no block.');
  expect(got.crcOk, isTrue, reason: '$reason the block has a bad CRC16.');
  await b.host.idle(4);
  return got;
}

/// Writes [bytes] to block [lba] the way a host does, and answers the
/// record the way the runtime does.
Future<void> writeBlockThrough(
  SdReadBench b,
  int lba,
  List<int> bytes, {
  String reason = '',
}) async {
  await b.host.idle(sdCommandGapClocks);
  await b.host.sendCommand(sdCmdWriteBlock, lba);
  final r1 = await b.host.receiveResponse(SdResponseKind.r1);
  expect(r1.timedOut, isFalse, reason: '$reason CMD24 gave no response.');
  expect(
    r1.payload & (1 << 19),
    0,
    reason: '$reason the card refused the write.',
  );

  await b.host.idle(4);
  await b.host.sendDataBlock(bytes);
  final token = await b.host.receiveStatusToken();
  expect(
    token.token,
    SdStatusToken.accepted,
    reason: '$reason the card did not accept the block.',
  );

  final record = await takeRecord(b);
  expect(
    sdRecordOp(record.word0),
    sdRequestOpWriteBlocks,
    reason: '$reason the record is not a write.',
  );
  expect(
    record.lba,
    lba,
    reason:
        '$reason the write record names another '
        'block.',
  );
  final words = await pullWriteWords(b, sdBlockWords);
  expect(
    sdBytesOfWords(words),
    bytes,
    reason: '$reason the runtime read other bytes than the host wrote.',
  );
  await ackWrite(b, record.seq);
  final busy = await b.host.waitBusy(timeoutClocks: 256);
  expect(
    busy.timedOut,
    isFalse,
    reason: '$reason the card never released busy.',
  );
  await b.host.idle(8);
}

/// Asserts the reset of both domains and releases it, the way the board
/// does at power up.
///
/// The SD domain takes its reset through [MimicResetSync], so it needs SD
/// clock edges to release. The bus domain needs bus clocks, which run by
/// themselves.
Future<void> pulseReset(SdReadBench b) async {
  b.reset.inject(1);
  await b.host.idle(8);
  b.reset.inject(0);
  await b.host.idle(sdCommandGapClocks);
}
