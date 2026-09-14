// MimicSdCardFsm: the card state machine of the SD card personality.
//
// MimicSdLink below this module owns the wire: it frames a command, it
// checks the CRC7 and it sends the response bits back. This module owns
// the meaning: it holds the card state, it captures each command that the
// link accepts, it builds the 32-bit card status out of the state, and it
// starts a response when the link is free.
//
// The default decode holds the identification commands that a host sends
// before it reads or writes a block: CMD0, CMD8, CMD55 and ACMD41 bring
// the card to ready, and CMD2, CMD3, CMD9 and CMD7 then give the card an
// address and select it. The card ends this set in the transfer state.
// CMD17 then reads one block, and CMD12 and CMD13 are the two commands a
// host uses to recover from a read that gave it no data.
//
// All logic here runs in the SD clock domain, the same domain as the link.

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../sd_regs.dart';
import 'sd_link.dart';

/// Number of bits in the CURRENT_STATE field of the card status.
const int sdCardStateBits = 4;

/// Card state 0, idle. The card is on and waits for CMD0 or ACMD41.
const int sdCardStateIdle = 0;

/// Card state 1, ready. The card finished its power-up and waits for CMD2.
const int sdCardStateReady = 1;

/// Card state 2, ident. The card sent its CID and waits for CMD3.
const int sdCardStateIdent = 2;

/// Card state 3, stby. The card has an address and is not selected.
const int sdCardStateStby = 3;

/// Card state 4, tran. The card is selected and takes a transfer command.
const int sdCardStateTran = 4;

/// Card state 5, data. The card is sending data to the host.
const int sdCardStateData = 5;

/// Card state 6, rcv. The card is taking data from the host.
///
/// Nothing enters this state yet. The number is here so that the write
/// path of phase 3 does not renumber the states above it.
const int sdCardStateRcv = 6;

/// Card state 7, prg. The card is writing data that it took.
///
/// Nothing enters this state yet. The number is here so that the write
/// path of phase 3 does not renumber the states above it.
const int sdCardStatePrg = 7;

/// Card state 8, dis. The card is writing and is not selected.
const int sdCardStateDis = 8;

/// Number of bits in the card status, which an R1 response carries.
///
/// The status sits in the 32-bit payload field of a short response, so it
/// is exactly as wide as the argument of a command.
const int sdCardStatusBits = sdCommandArgBits;

/// Bit number of the lowest bit of CURRENT_STATE in the card status.
///
/// CURRENT_STATE is bits 12 to 9 and holds the state that the card was in
/// when the command arrived.
const int sdStatusCurrentStateLsb = 9;

/// Bit number of READY_FOR_DATA in the card status.
///
/// A 1 says that the card has a free data buffer. The card holds the bit
/// low only while it writes what it took, which is the prg state.
const int sdStatusReadyForDataBit = 8;

/// Bit number of APP_CMD in the card status.
///
/// A 1 tells the host that the card takes the next command as an
/// application command. The card raises the bit in the response to CMD55.
const int sdStatusAppCmdBit = 5;

/// Bit number of COM_CRC_ERROR in the card status.
///
/// A 1 says that the CRC7 of the last command was wrong. This card never
/// takes such a command, so the bit is always 0. The number is here
/// because an R6 carries this bit, and the field would move if the bit
/// were not at the top of the three error bits.
const int sdStatusComCrcErrorBit = 23;

/// Bit number of ERROR in the card status.
///
/// A 1 says that the card met an error that no other bit names. This card
/// never sets it, and an R6 carries it below ILLEGAL_COMMAND.
const int sdStatusErrorBit = 19;

/// Bit number of ILLEGAL_COMMAND in the card status.
///
/// A 1 tells the host that the command is not legal in the state that the
/// card was in. The bit reports a state violation only. A command that the
/// card drops because the answer slot is full gets no response at all, and
/// the host recovers from that with a timeout.
const int sdStatusIllegalCommandBit = 22;

/// A 1 tells the host that the block length the command asked for is not
/// a length the card can use.
///
/// The card holds a datapath of [sdBlockBytes] bytes alone, so CMD16 with
/// any other length raises this bit and changes nothing.
const int sdStatusBlockLenErrorBit = 29;

/// Bit number of OUT_OF_RANGE in the card status.
///
/// A 1 says that a data command named a block at or above the configured
/// capacity. The card answers the command but starts no data transfer.
const int sdStatusOutOfRangeBit = 31;

/// Command index 0, GO_IDLE_STATE.
///
/// A broadcast command with no response. It returns the card to idle from
/// every state.
const int sdCmdGoIdleState = 0;

/// Command index 2, ALL_SEND_CID.
///
/// A broadcast command. Every card in the ready state answers R2 with its
/// CID and moves to the ident state.
const int sdCmdAllSendCid = 2;

/// Command index 3, SEND_RELATIVE_ADDR.
///
/// The card in the ident state picks its own address, answers R6 with that
/// address and moves to the stby state. Every command after this one names
/// the card by that address.
const int sdCmdSendRelativeAddr = 3;

/// Command index 7, SELECT/DESELECT_CARD.
///
/// The card whose address the argument holds answers R1 and moves to the
/// tran state. Every other card leaves the tran state and answers nothing,
/// because the answer belongs to the one card that the host selected.
const int sdCmdSelectCard = 7;

/// Command index 8, SEND_IF_COND.
///
/// The card answers R7, which echoes the voltage and the check pattern of
/// the argument. A host that gets no answer takes the card for a card that
/// is older than version 2.0.
const int sdCmdSendIfCond = 8;

/// Command index 9, SEND_CSD.
///
/// The card whose address the argument holds answers R2 with its CSD. The
/// host reads the capacity of the card from that register.
const int sdCmdSendCsd = 9;

/// Command index 12, STOP_TRANSMISSION.
///
/// The card answers R1b and stops a transfer that is running. R1b is an R1
/// with a busy signal on DAT0 after it, and a card that is not busy simply
/// does not pull DAT0 low, so this card sends a plain R1.
///
/// A Linux mmc host that hits its data read timeout starts its recovery
/// with this command and then polls CMD13. A card that answers neither
/// gives the block layer an error for the read and for every retry after
/// it, so both commands are here for the host to recover with.
const int sdCmdStopTransmission = 12;

/// Command index 13, SEND_STATUS.
///
/// The card whose address the argument holds answers R1 with its card
/// status. The command changes nothing, so a host can poll it.
const int sdCmdSendStatus = 13;

/// Application command index 13, SD_STATUS.
///
/// After CMD55, index 13 answers R1 and sends the 64-byte SD Status
/// Register on DAT0. U-Boot reads it while choosing a bus mode.
const int sdAcmdSdStatus = 13;

/// Command index 17, READ_SINGLE_BLOCK.
///
/// The card in the tran state answers R1, moves to the data state and
/// sends one block of [sdBlockBytes] bytes on DAT. The argument is a BLOCK
/// address for a high capacity card, which is what the CSD of this card
/// reports.
const int sdCmdReadSingleBlock = 17;

/// Command index 16, SET_BLOCKLEN.
///
/// The card answers R1. This card reads and writes [sdBlockBytes] bytes at
/// a time and nothing else, so it accepts that length and refuses every
/// other with BLOCK_LEN_ERROR. A high capacity card fixes the block length
/// at 512 bytes, so a host that follows the specification asks for no
/// other.
const int sdCmdSetBlocklen = 16;

/// Command index 24, WRITE_BLOCK.
///
/// The card in the tran state answers R1, moves to the rcv state and takes
/// one block of [sdBlockBytes] bytes on DAT. It then checks the CRC16,
/// sends the CRC status token and holds DAT0 low while it programs. The
/// argument is a BLOCK address for a high capacity card, which is what the
/// CSD of this card reports.
const int sdCmdWriteBlock = 24;

/// Command index 18, READ_MULTIPLE_BLOCK.
///
/// The card in the tran state answers R1, moves to the data state and
/// sends one block after another from the address in the argument until
/// the host sends CMD12. Linux reads multi-block for nearly every request,
/// so this is the path a mounted card spends its time in.
const int sdCmdReadMultipleBlock = 18;

/// Command index 55, APP_CMD.
///
/// The card answers R1 with APP_CMD set, and it reads the next command as
/// an application command.
const int sdCmdAppCmd = 55;

/// Application command index 41, SD_SEND_OP_COND.
///
/// The card answers R3 with the OCR. Index 41 without CMD55 in front of it
/// is a different command, and this card does not answer that one.
const int sdAcmdSendOpCond = 41;

/// Application command index 6, SET_BUS_WIDTH.
///
/// The card answers R1 and takes the bus width from bits 1 and 0 of the
/// argument. Index 6 without CMD55 in front of it is CMD6, SWITCH_FUNC,
/// which is a different command.
const int sdAcmdSetBusWidth = 6;

/// Command index 6, SWITCH_FUNC.
///
/// The card in the tran state answers R1 and then sends the
/// [sdSwitchStatusBytes] bytes of the switch status on DAT0, in the same
/// frame shape a block read uses. Bit 31 of the argument picks the mode: 0
/// asks what the card supports and 1 asks the card to change function.
/// This card offers no function beyond the default of every group, so both
/// modes give the same status and neither changes anything.
///
/// The same index with CMD55 in front of it is ACMD6, SET_BUS_WIDTH, which
/// is a different command.
const int sdCmdSwitchFunc = 6;

/// Application command index 51, SEND_SCR.
///
/// The card answers R1 and then sends the [sdScrBytes] bytes of the SCR on
/// DAT0, in the same frame shape a block read uses. Linux reads the SCR in
/// `mmc_sd_setup_card`, right after it selects the card and BEFORE it
/// reads any block, and it rejects a card that does not answer. This
/// command is therefore on the path of every mount.
const int sdAcmdSendScr = 51;

/// The value of ACMD6 bits 1 and 0 that asks for the 1-bit bus.
const int sdBusWidthArg1Bit = 0;

/// The value of ACMD6 bits 1 and 0 that asks for the 4-bit bus.
///
/// The current datapath refuses this width. Hosts connected to it must
/// limit their controller to one data line until the 4-bit datapath lands.
const int sdBusWidthArg4Bit = 2;

/// Number of argument bits that ACMD6 reads.
const int sdBusWidthArgBits = 2;

/// Number of bits in the card register that ACMD51 and CMD6 send on DAT.
///
/// The switch status of CMD6 is the longest of these values, so the port
/// is as wide as that. A value shorter than the port sits at the TOP of
/// it, because the sender puts the most significant byte on the wire
/// first. See [MimicSdRegTx].
const int sdCardRegTxBits = sdSwitchStatusBits;

/// The SD Status Register is one 64-byte data frame. The fields that U-Boot
/// consumes are optional geometry and erase hints, so a zero value is a
/// valid minimal report for this emulated card. Its DAT_BUS_WIDTH field is
/// also zero, which reports the 1-bit bus currently in use.
const int sdSsrBytes = 64;
const int sdCardSsrValue = 0;

/// The switch status that CMD6 reports, with every group at its default.
///
/// The card offers no function beyond the default of any group, so the
/// support map of every group names function 0 alone. The constructor of
/// [MimicSdCardFsm] checks that, because a status that named the high
/// speed access mode would invite the host to clock the card at 50 MHz
/// and the datapath answers at the default speed alone.
///
/// The selection nibbles of this value are the default function. The
/// decode replaces them with the answer for the groups the host asked
/// about, so the value here is the base and not the whole answer.
final List<int> sdCardSwitchStatusBytes = sdSwitchStatus();

/// The SCR register of this card.
///
/// The SD specification requires both width bits even when a board connects
/// only DAT0. Linux rejects the card during SCR parsing if either bit is
/// absent. The board device tree limits the host to one data line while the
/// current datapath reads and drives DAT0 alone.
final int sdCardScrValue = sdScr();

/// Every command index that the default decode holds.
///
/// The constructor of [MimicSdCardFsm] reads the largest number here, so a
/// command that this list forgets cannot make the width guard pass for the
/// wrong reason.
const List<int> sdCommandIndices = [
  sdCmdGoIdleState,
  sdCmdAllSendCid,
  sdCmdSendRelativeAddr,
  sdCmdSelectCard,
  sdCmdSendIfCond,
  sdCmdSendCsd,
  sdCmdStopTransmission,
  sdCmdSendStatus,
  sdCmdReadSingleBlock,
  sdCmdSetBlocklen,
  sdCmdReadMultipleBlock,
  sdCmdWriteBlock,
  sdAcmdSendOpCond,
  sdAcmdSetBusWidth,
  sdAcmdSendScr,
  sdCmdAppCmd,
  sdCmdSwitchFunc,
];

/// Number of bits in the relative card address, RCA.
///
/// The address sits in the high [sdRcaBits] bits of the argument of every
/// command that names one card.
const int sdRcaBits = 16;

/// The address that the card publishes in its answer to CMD3.
///
/// Any address other than 0 is legal, because 0 is the address that CMD7
/// uses to deselect every card. The card holds one fixed address, so a
/// host that reads the R6 of CMD3 and a test that reads the same word see
/// the same number.
const int sdCardRca = 0x0001;

/// Number of low card status bits that an R6 response carries.
///
/// An R6 holds a 16-bit status: three error bits and then bits 12 to 0 of
/// the card status, which hold CURRENT_STATE and READY_FOR_DATA at the
/// same bit numbers that an R1 gives them.
const int sdR6StatusLowBits = 13;

/// Number of error bits that an R6 response carries above the low bits.
///
/// The three bits are COM_CRC_ERROR, ILLEGAL_COMMAND and ERROR, in that
/// order from the top of the R6 status.
const int sdR6StatusErrorBits = 3;

/// Number of 512-byte blocks that the DEFAULT CSD of this card reports.
///
/// This number is the RESET VALUE of the CSD register block alone. The
/// runtime owns the personality of the card and writes the whole CSD over
/// the CSR block at `MimicReg.csd0`, so the capacity that CMD9 reports
/// after that write is the capacity that the runtime chose and not this
/// one. The default is here because a host can probe the card before the
/// runtime writes anything, and a card that answers CMD9 with an unreset
/// register is a card that no host accepts.
const int sdCardCapacityBlocks = 1024 * 1024;

/// The CID register that CMD2 returns for a card made in
/// [manufactureYear] and [manufactureMonth], as one 128-bit value.
///
/// [sdCid] builds the bytes and the CRC7, so the value that a host reads
/// here and the value that any other part of the design reads cannot drift
/// apart. It also checks both parts of the date, so a year or a month that
/// the MDT field cannot hold throws here and never reaches the hardware.
///
/// The date is the one thing about the CID that a build supplies. The
/// generator resolves it, and the SoC build carries it down to this
/// function, the same way the capacity reaches [sdCardCsdValue].
BigInt sdCardCidValueFor({
  int manufactureYear = sdCidDefaultManufactureYear,
  int manufactureMonth = sdCidDefaultManufactureMonth,
}) => sdRegisterToBigInt(
  sdCid(manufactureYear: manufactureYear, manufactureMonth: manufactureMonth),
);

/// The DEFAULT CID register, as one 128-bit value.
///
/// This is the CID of a card whose build named no date. A build that names
/// one gets [sdCardCidValueFor] instead.
final BigInt sdCardCidValue = sdCardCidValueFor();

/// The DEFAULT CSD register, as one 128-bit value.
///
/// This is the reset value of the CSD register of the card, and of the CSR
/// block that the runtime writes. It is not what CMD9 answers after the
/// runtime writes a CSD of its own.
final BigInt sdCardCsdValue = sdRegisterToBigInt(
  sdCsdV2(capacityBlocks: sdCardCapacityBlocks),
);

/// The default CSD as the four 32-bit words of the CSR block.
///
/// Entry 0 is the reset value of CSD_0 at `MimicReg.csd0`, which holds
/// `csd[31:0]`. [sdRegisterToWords] gives the words in WIRE order, which
/// is the most significant word first, and the CSR block runs the other
/// way, so the list is reversed here. The word order of the helper is not
/// changed, because the wire order is what the link sends.
final List<int> sdCardCsdWords = List<int>.unmodifiable(
  sdRegisterToWords(sdCsdV2(capacityBlocks: sdCardCapacityBlocks)).reversed,
);

/// Number of bits in the check pattern of CMD8, the low field of R7.
const int sdIfCondCheckBits = 8;

/// Number of bits in the voltage field of CMD8, VHS.
const int sdIfCondVhsBits = 4;

/// Number of argument bits that an R7 response echoes.
///
/// The card returns VHS and the check pattern as the host gave them. A
/// host that reads back a pattern of its own knows that the card
/// understood the command, and it rejects a card that echoes anything
/// else.
const int sdIfCondEchoBits = sdIfCondVhsBits + sdIfCondCheckBits;

/// Number of ACMD41 commands that report a card that is still busy.
///
/// The card clears OCR bit 31 for this many polls and then reports that
/// the power-up is done. A real host polls for up to one second, so the
/// count only has to be more than one. A small count lets a test drive the
/// whole loop.
const int sdOpCondBusyPolls = 3;

/// Number of bits in the ACMD41 poll counter.
///
/// The counter holds 0 to [sdOpCondBusyPolls] and it stops at the top, so
/// the width comes from the count itself and cannot fall behind it.
final int sdOpCondPollBits = sdOpCondBusyPolls.bitLength;

/// Everything that a command decode reads.
///
/// The constructor of [MimicSdCardFsm] makes every register that this
/// class carries, and it gives each one a reset value. A decode reads
/// these fields and gives its own writes back through
/// [SdCommandDecision.updates]. A decode therefore never makes a register,
/// and no register can escape the reset list of the module.
///
/// This class is the place for the registered state that the command set
/// needs, such as the RCA register that CMD3 loads in task 4. A new field
/// here does not change the type of [SdCommandDecode], so a decode that
/// ignores the new field still builds.
class SdDecodeInputs {
  /// The index of the command that the link accepted.
  final Logic index;

  /// The argument of that command.
  final Logic arg;

  /// The card state now, before the command moves the card.
  final Logic state;

  /// The card status built from [state], in the shape that an R1 carries.
  final Logic status;

  /// The sticky bit that CMD55 sets, one bit wide.
  ///
  /// A 1 says that CMD55 was the last command that the card took, so the
  /// card reads this command as an application command. A decode that
  /// writes this bit must write it on every command, because the bit must
  /// clear after the one command that follows CMD55.
  final Logic appCmd;

  /// The number of ACMD41 commands that the card answered, and stopped
  /// counting at [sdOpCondBusyPolls].
  ///
  /// The card reports a busy OCR while the count is below the top, and a
  /// ready OCR at the top. The count is [sdOpCondPollBits] bits wide.
  final Logic opCondPoll;

  /// The address of the card, [sdRcaBits] bits wide.
  ///
  /// The register holds 0 until CMD3 publishes an address, and CMD0 takes
  /// the address back. A decode that writes this register must write it
  /// under a condition, because a flat write would give the card an
  /// address on every command that it takes.
  final Logic rca;

  /// The CSD register of the card, [sdResponseRegBits] bits wide.
  ///
  /// This is a value that the card is GIVEN, and not a register that the
  /// module makes. The runtime owns the personality of the card, so it
  /// writes the whole CSD over the CSR block and the SoC brings the value
  /// into the SD clock domain. The card sends these 128 bits for CMD9 with
  /// nothing added, so the CRC7 and the end bit of the low byte come from
  /// the runtime as well.
  final Logic csd;

  /// The number of 512-byte blocks that the card contains.
  ///
  /// A valid block address is smaller than this value. The SoC transfers the
  /// complete value into this clock domain before it enables the card.
  final Logic numBlocks;

  /// High while the block read path can take a new read, one bit wide.
  ///
  /// The read path is a module of its own, and it is low while a read is
  /// running and while the card is still waiting for a block it gave up
  /// on. A decode that starts a read must read this bit, because a read
  /// that the path cannot take would leave the card in the data state with
  /// nothing to send.
  final Logic readReady;

  /// High while the block write path can take a new write, one bit wide.
  ///
  /// The write path is a module of its own, and it is low while a write is
  /// running and while a block that the runtime has not taken is still on
  /// the write channel. A decode that starts a write must read this bit,
  /// because a write that the path cannot take would leave the host
  /// sending 512 bytes that nothing catches.
  final Logic writeReady;

  /// The enable bit of the CSR CTRL register, one bit wide.
  ///
  /// The runtime raises it when it is ready to answer a request. A card
  /// with the bit low answers no read, so clearing the bit releases a host
  /// that is in the middle of a transfer.
  final Logic cardEnable;

  /// High while the card register sender can take a new frame, one bit
  /// wide.
  ///
  /// The sender puts the SCR on DAT for ACMD51. It is low while a frame is
  /// going out, and a decode that starts one must read this bit, because a
  /// start pulse that the sender drops would leave the host waiting for a
  /// start bit that never comes.
  final Logic regReady;

  /// Makes the input set of one decode.
  const SdDecodeInputs({
    required this.index,
    required this.arg,
    required this.state,
    required this.status,
    required this.appCmd,
    required this.opCondPoll,
    required this.rca,
    required this.csd,
    required this.numBlocks,
    required this.readReady,
    required this.writeReady,
    required this.cardEnable,
    required this.regReady,
  });
}

/// The answer that the card gives for one command that the link accepted.
///
/// [respond] high asks the link for a response. [kind] and [data] then give
/// the frame, in the shape that [MimicSdLink] reads for that kind.
/// [nextState] is the card state after the command, and must hold the
/// current state when the command does not move the card.
///
/// [updates] carries every other register write that the command makes.
/// The module puts these writes in the same branch as [nextState], so a
/// command that the card cannot answer changes nothing at all. A write in
/// [updates] must not name the card state register, because [nextState]
/// already owns it.
class SdCommandDecision {
  /// High to ask the link for a response.
  final Logic respond;

  /// The response kind, one of [sdRespKindR1], [sdRespKindR3] or
  /// [sdRespKindR2].
  final Logic kind;

  /// The response payload, of [sdResponseRegBits] bits.
  final Logic data;

  /// The card state after the command, of [sdCardStateBits] bits.
  final Logic nextState;

  /// Writes to the other registers that the decode reads.
  final List<Conditional> updates;

  /// High to start one block read, one bit wide, or null for a decode that
  /// starts none.
  ///
  /// The module turns this into a pulse of one clock on `read_start`. A
  /// decode that raises it must also give [readLba] and must move the card
  /// to [sdCardStateData] through [nextState], because the read path and
  /// the card state have to agree on what the card is doing.
  final Logic? readStart;

  /// The block address of that read, of [sdCommandArgBits] bits, or null.
  final Logic? readLba;

  /// High while that read is a MULTIPLE block read, one bit wide, or null
  /// for a decode that starts none.
  ///
  /// The read path streams block after block while this is high and stops
  /// on the abort that CMD12 makes. A decode that leaves it null starts
  /// single block reads alone.
  final Logic? readMulti;

  /// High to start one block write, one bit wide, or null for a decode
  /// that starts none.
  ///
  /// The module turns this into a pulse of one clock on `write_start`. A
  /// decode that raises it must also give [writeLba] and must move the card
  /// to [sdCardStateRcv] through [nextState], because the write path and
  /// the card state have to agree on what the card is doing.
  final Logic? writeStart;

  /// The block address of that write, of [sdCommandArgBits] bits, or null.
  final Logic? writeLba;

  /// High to send one CARD REGISTER on DAT, one bit wide, or null for a
  /// decode that sends none.
  ///
  /// The module turns this into a pulse of one clock on `reg_send`. A
  /// decode that raises it must also give [regData] and [regBytes], and
  /// must read [SdDecodeInputs.regReady] first.
  final Logic? regSend;

  /// The register to send, of [sdCardRegTxBits] bits, or null.
  ///
  /// The byte that goes out FIRST is the most significant one, which is
  /// the order a card sends a register in.
  final Logic? regData;

  /// The length of that register in bytes, of [sdDataTxLenBits] bits, or
  /// null.
  final Logic? regBytes;

  /// High to return the card to the idle state, one bit wide, or null for
  /// a decode that never does.
  ///
  /// The module turns this into a pulse of one clock on `go_idle`. It is
  /// what CMD0 raises, and the BLOCK CACHE reads it: a card that has been
  /// re-identified must not serve a line that the host before it filled,
  /// so the whole store is invalidated on that pulse.
  ///
  /// A decode that raises it must also move the card to [sdCardStateIdle]
  /// through [nextState], because the pulse and the card state have to
  /// agree on what the card is doing.
  final Logic? goIdle;

  /// Makes the answer for one command.
  const SdCommandDecision({
    required this.respond,
    required this.kind,
    required this.data,
    required this.nextState,
    this.updates = const [],
    this.readStart,
    this.readLba,
    this.readMulti,
    this.writeStart,
    this.writeLba,
    this.regSend,
    this.regData,
    this.regBytes,
    this.goIdle,
  });
}

/// Builds the answer for one command that the link accepted.
///
/// [MimicSdCardFsm] calls a decode one time, while it elaborates, and the
/// result becomes one combinational block. A decode is therefore a pure
/// function of the signals in [SdDecodeInputs]: it must not keep state of
/// its own between calls, and it must not make a register.
typedef SdCommandDecode = SdCommandDecision Function(SdDecodeInputs inputs);

/// SD card state machine: card state, card status and the response start.
///
/// The link side of this module is the other half of the [MimicSdLink]
/// contract. `cmd_valid` is a pulse of one clock, and `cmd_index`,
/// `cmd_arg` and `cmd_crc_ok` all hold the result of that frame while the
/// pulse is high. The card takes a command only when `cmd_crc_ok` is high
/// in that clock, so a frame that the host damaged goes nowhere.
///
/// The card answers through `resp_start`, `resp_data` and `resp_kind`. The
/// link drops a pulse on `resp_start` that comes while `resp_busy` is
/// high, so this module holds the answer in a register and starts it only
/// in a clock where `resp_busy` is low. An R2 holds the link busy for 136
/// clocks, which is nearly three times an R1, so the wait is real.
///
/// A command that asks for a response while the answer slot is full does
/// nothing at all: no answer, no state move and no register write. The
/// card and the host must agree on the card state, and a command that the
/// card acts on but never answers breaks that agreement with no way back.
/// A command whose decode asks for no response always moves the card,
/// because a broadcast command such as CMD0 changes the state and gives no
/// answer.
///
/// `resp_start` is high in one clock for each answer, but this module does
/// not make that width alone. It clears `resp_pending` on the same edge
/// that raises `resp_start`, which is enough only while no new answer
/// takes the slot on that edge. When a second command queues its answer on
/// that same edge, `resp_pending` stays high and `resp_start` holds until
/// `resp_busy` rises. The link raises `resp_busy` on the edge that samples
/// `resp_start`, so the pulse is one clock. The one clock width is a
/// property of the pair, not of this module alone.
///
/// The path from a command to a response is two clocks. The first clock
/// captures the command, the second clock decodes it and queues the
/// answer, and `resp_start` follows in the clock after that. The gap is
/// welcome: the specification asks for at least two clocks (Ncr) between
/// the end bit of a command and the start bit of its response.
///
/// `card_state` reports the state register. The card status that a
/// response carries is built from the same register, so the two cannot
/// drift apart.
///
/// `csd` gives the 128-bit CSD that CMD9 answers with. This module holds no
/// CSD of its own and knows nothing of the field layout: the runtime owns
/// the personality of the card and writes the whole register, and the SoC
/// brings the value into this clock domain and holds it still. A card whose
/// CSD nothing has written yet still answers CMD9, because the register
/// that feeds this port resets to a default CSD.
class MimicSdCardFsm extends BridgeModule {
  /// The 128-bit CID register that CMD2 answers with.
  ///
  /// The card identity is fixed in the hardware, so this is a build-time
  /// value and not a port. Only the MDT date inside it changes from build
  /// to build. See [sdCardCidValueFor].
  final BigInt cid;

  /// Makes the card state machine.
  ///
  /// [decode] replaces the command set. It defaults to the command set of
  /// this module. A test gives a decode of its own to drive the response
  /// handshake with a rule that it picks.
  ///
  /// [cid] is the CID register that CMD2 answers with. It defaults to
  /// [sdCardCidValue], the CID of a build that named no manufacture date.
  MimicSdCardFsm({String? name, SdCommandDecode? decode, BigInt? cid})
    : cid = cid ?? sdCardCidValue,
      super('MimicSdCardFsm', name: name ?? 'sd_card_fsm') {
    if (this.cid.bitLength > sdResponseRegBits) {
      // Const truncates a value that is too wide with no message, and a
      // truncated CID is a card that gives an identity nobody built.
      throw StateError(
        'The CID needs ${this.cid.bitLength} bits and the response register '
        'is $sdResponseRegBits bits.',
      );
    }
    if (sdStatusCurrentStateLsb != sdStatusReadyForDataBit + 1) {
      throw StateError(
        'CURRENT_STATE starts at bit $sdStatusCurrentStateLsb and '
        'READY_FOR_DATA is bit $sdStatusReadyForDataBit. The status builder '
        'puts the two fields side by side, so CURRENT_STATE must start one '
        'bit above READY_FOR_DATA.',
      );
    }
    if (sdStatusCurrentStateLsb + sdCardStateBits > sdCardStatusBits) {
      throw StateError(
        'CURRENT_STATE is $sdCardStateBits bits at bit '
        '$sdStatusCurrentStateLsb, which does not fit in a card status of '
        '$sdCardStatusBits bits.',
      );
    }
    if (sdCardStatusBits + sdCommandIndexBits > sdResponseRegBits) {
      throw StateError(
        'A short response holds a $sdCommandIndexBits bit index and a '
        '$sdCardStatusBits bit payload, which does not fit in a resp_data '
        'port of $sdResponseRegBits bits.',
      );
    }
    if (sdCardStateDis >= (1 << sdCardStateBits)) {
      throw StateError(
        'The largest card state is $sdCardStateDis, which does not fit in '
        'the $sdCardStateBits bits of CURRENT_STATE.',
      );
    }
    if (sdStatusIllegalCommandBit >= sdCardStatusBits ||
        sdStatusAppCmdBit >= sdCardStatusBits) {
      throw StateError(
        'APP_CMD is bit $sdStatusAppCmdBit and ILLEGAL_COMMAND is bit '
        '$sdStatusIllegalCommandBit, and a card status is only '
        '$sdCardStatusBits bits.',
      );
    }
    if (sdIfCondEchoBits > sdCardStatusBits) {
      throw StateError(
        'An R7 echoes $sdIfCondEchoBits argument bits, which does not fit '
        'in the $sdCardStatusBits bit payload of a short response.',
      );
    }
    if (sdOpCondBusyPolls < 1) {
      throw StateError(
        'The ACMD41 poll count is $sdOpCondBusyPolls. The count must be 1 '
        'or more, because the counter is as wide as the count and a width '
        'of 0 is not a signal.',
      );
    }
    if (sdCardScrValue.bitLength > sdCardRegTxBits) {
      throw StateError(
        'The SCR needs ${sdCardScrValue.bitLength} bits and the card '
        'register port is $sdCardRegTxBits bits.',
      );
    }
    if (sdScrBytes.bitLength > sdDataTxLenBits) {
      throw StateError(
        'The SCR is $sdScrBytes bytes, which does not fit in the '
        '$sdDataTxLenBits bits of a transmit length.',
      );
    }
    if (sdScrBytes * 8 > sdCardRegTxBits) {
      throw StateError(
        'The SCR is $sdScrBytes bytes and the card register port is '
        '$sdCardRegTxBits bits. The decode puts the SCR at the top of that '
        'port, so a register that is wider than the port would lose the '
        'bytes that go out first.',
      );
    }
    if (sdCardSwitchStatusBytes.length != sdSwitchStatusBytes) {
      throw StateError(
        'The switch status is ${sdCardSwitchStatusBytes.length} bytes and '
        'the specification gives it $sdSwitchStatusBytes bytes.',
      );
    }
    if (sdSwitchStatusBits != sdCardRegTxBits) {
      throw StateError(
        'The switch status is $sdSwitchStatusBits bits and the card '
        'register port is $sdCardRegTxBits bits. The status is the longest '
        'value the port carries, so the two must be equal.',
      );
    }
    if (sdSwitchStatusBytes.bitLength > sdDataTxLenBits) {
      throw StateError(
        'The switch status is $sdSwitchStatusBytes bytes, which does not '
        'fit in the $sdDataTxLenBits bits of a transmit length.',
      );
    }
    for (var group = 1; group <= sdSwitchGroups; group++) {
      final support = sdSwitchStatusSupport(sdCardSwitchStatusBytes, group);
      if (support != sdSwitchSupportDefaultOnly) {
        // The decode answers every CMD6 with the default function of every
        // group and changes nothing at all. A status that advertised
        // another function would be a contradiction the card makes itself:
        // the host would ask for that function, read the default back, and
        // have no way to tell that from a card that is broken. Group 1 is
        // the worst of them. Its function 1 is the high speed access mode,
        // and a host that reads it clocks the card at 50 MHz, which this
        // datapath cannot answer.
        throw StateError(
          'The switch status advertises 0x${support.toRadixString(16)} for '
          'function group $group and the card grants function '
          '$sdSwitchFunctionDefault alone. Function '
          '$sdSwitchFunctionHighSpeed of group 1 is the high speed access '
          'mode, and this datapath answers at the default speed. Build the '
          'status with the default function alone, or make the card do '
          'what it advertises.',
        );
      }
    }
    if (sdSwitchSelectionLsb + sdSwitchSelectionBits > sdSwitchStatusBits) {
      throw StateError(
        'The selection field of the switch status ends at bit '
        '${sdSwitchSelectionLsb + sdSwitchSelectionBits - 1} and the status '
        'is only $sdSwitchStatusBits bits.',
      );
    }
    if (sdSwitchModeBit >= sdCommandArgBits ||
        sdSwitchGroups * sdSwitchGroupBits > sdCommandArgBits) {
      throw StateError(
        'CMD6 reads the mode from bit $sdSwitchModeBit and one nibble for '
        'each of the $sdSwitchGroups groups, which does not fit in the '
        '$sdCommandArgBits bits of a command argument.',
      );
    }
    if (sdStatusBlockLenErrorBit >= sdCardStatusBits) {
      throw StateError(
        'BLOCK_LEN_ERROR is bit $sdStatusBlockLenErrorBit and a card status '
        'is only $sdCardStatusBits bits.',
      );
    }
    if (sdBlockBytes.bitLength > sdCommandArgBits) {
      throw StateError(
        'A block is $sdBlockBytes bytes, which does not fit in the '
        '$sdCommandArgBits bits of a command argument.',
      );
    }
    final maxCommandIndex = sdCommandIndices.reduce((a, b) => a > b ? a : b);
    if (maxCommandIndex >= (1 << sdCommandIndexBits)) {
      throw StateError(
        'The largest command index is $maxCommandIndex, which does not fit '
        'in the $sdCommandIndexBits bits of a command index.',
      );
    }
    if (sdRegisterBytes * 8 != sdResponseRegBits) {
      throw StateError(
        'An R2 sends a register of ${sdRegisterBytes * 8} bits without a '
        'change, and a resp_data port holds $sdResponseRegBits bits. The '
        'two must be equal, because a register that is too wide would lose '
        'its top bits and one that is too narrow would move every field.',
      );
    }
    if (sdRcaBits > sdCommandArgBits) {
      throw StateError(
        'An address is $sdRcaBits bits and a command argument is only '
        '$sdCommandArgBits bits, so the address does not fit in the '
        'argument that names the card.',
      );
    }
    if (sdCardRca == 0 || sdCardRca >= (1 << sdRcaBits)) {
      throw StateError(
        'The card address is $sdCardRca. The address must be 1 or more, '
        'because CMD7 uses 0 to deselect every card, and it must fit in '
        'the $sdRcaBits bits of an address.',
      );
    }
    if (sdR6StatusErrorBits + sdR6StatusLowBits !=
        sdCardStatusBits - sdRcaBits) {
      throw StateError(
        'An R6 holds a $sdRcaBits bit address and then '
        '$sdR6StatusErrorBits error bits over $sdR6StatusLowBits status '
        'bits, which is not the $sdCardStatusBits bit payload of a short '
        'response.',
      );
    }
    if (sdStatusComCrcErrorBit >= sdCardStatusBits ||
        sdStatusIllegalCommandBit >= sdCardStatusBits ||
        sdStatusErrorBit >= sdCardStatusBits ||
        sdStatusComCrcErrorBit < sdR6StatusLowBits ||
        sdStatusIllegalCommandBit < sdR6StatusLowBits ||
        sdStatusErrorBit < sdR6StatusLowBits) {
      throw StateError(
        'An R6 takes COM_CRC_ERROR from bit $sdStatusComCrcErrorBit, '
        'ILLEGAL_COMMAND from bit $sdStatusIllegalCommandBit and ERROR '
        'from bit $sdStatusErrorBit of a $sdCardStatusBits bit card '
        'status, and all three must sit above the low $sdR6StatusLowBits '
        'bits that the R6 carries as well.',
      );
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('cmd_index', PortDirection.input, width: sdCommandIndexBits);
    createPort('cmd_arg', PortDirection.input, width: sdCommandArgBits);
    createPort('cmd_valid', PortDirection.input);
    createPort('cmd_crc_ok', PortDirection.input);
    createPort('resp_busy', PortDirection.input);

    // The CSD that CMD9 answers with. The card holds no CSD of its own: the
    // runtime writes the whole register and the SoC brings it here, already
    // settled in this clock domain. The width comes from the response port,
    // because the link sends an R2 register with nothing added.
    createPort('csd', PortDirection.input, width: sdResponseRegBits);
    createPort('num_blocks', PortDirection.input, width: sdCommandArgBits);

    // The block read path. `read_ready` says the path can take a new read
    // and `card_enable` is CTRL bit 0 of the CSR block, already brought
    // into this clock domain. `read_done` and `read_failed` are pulses of
    // one clock that end a read, and both return the card to tran.
    createPort('read_ready', PortDirection.input);
    createPort('card_enable', PortDirection.input);
    createPort('read_done', PortDirection.input);
    createPort('read_failed', PortDirection.input);
    createPort('reg_ready', PortDirection.input);

    // The block write path. `write_ready` says the path can take a new
    // write, `write_prg` says the card is programming a block it took, and
    // the two pulses end the write and return the card to the transfer
    // state.
    createPort('write_ready', PortDirection.input);
    createPort('write_done', PortDirection.input);
    createPort('write_failed', PortDirection.input);
    createPort('write_prg', PortDirection.input);

    addOutput('resp_start');
    addOutput('resp_data', width: sdResponseRegBits);
    addOutput('resp_kind', width: sdRespKindBits);
    addOutput('card_state', width: sdCardStateBits);
    addOutput('read_start');
    addOutput('read_lba', width: sdCommandArgBits);
    addOutput('read_abort');
    addOutput('read_multi');
    addOutput('write_start');
    addOutput('write_lba', width: sdCommandArgBits);
    addOutput('write_abort');
    addOutput('reg_send');
    addOutput('reg_data', width: sdCardRegTxBits);
    addOutput('reg_bytes', width: sdDataTxLenBits);

    // A pulse of one clock for each CMD0 the card takes. The block cache
    // reads it and throws every line away, so a card that a new host
    // re-identifies never answers a read out of the store the last host
    // filled.
    addOutput('go_idle');

    final clk = input('clk');
    final reset = input('reset');

    // The card state, and the command that the link last accepted. The
    // command registers let the decode read the index and the argument in
    // the clock after the pulse, which the link holds for one clock only.
    final state = Logic(name: 'card_state_reg', width: sdCardStateBits);
    final cmdIndexReg = Logic(name: 'cmd_index_reg', width: sdCommandIndexBits);
    final cmdArgReg = Logic(name: 'cmd_arg_reg', width: sdCommandArgBits);
    final cmdPending = Logic(name: 'cmd_pending');

    // The answer that waits for the link. resp_data and resp_kind come
    // from these registers, so they stand still from the clock that queues
    // them to the clock that starts them.
    final respPending = Logic(name: 'resp_pending');
    final respDataReg = Logic(name: 'resp_data_reg', width: sdResponseRegBits);
    final respKindReg = Logic(name: 'resp_kind_reg', width: sdRespKindBits);

    // The registered state that the command set owns. The module makes
    // both, so both are in the reset list below and neither can start as
    // X. A decode reads them through SdDecodeInputs and writes them back
    // through SdCommandDecision.updates.
    final appCmd = Logic(name: 'app_cmd_reg');
    final opCondPoll = Logic(name: 'op_cond_poll_reg', width: sdOpCondPollBits);
    final rca = Logic(name: 'rca_reg', width: sdRcaBits);

    // The start of a block read. The module owns both, because the pulse
    // has to be one clock wide and a decode holds no state of its own.
    final readStartReg = Logic(name: 'read_start_reg');
    final readLbaReg = Logic(name: 'read_lba_reg', width: sdCommandArgBits);
    final readMultiReg = Logic(name: 'read_multi_reg');
    final writeStartReg = Logic(name: 'write_start_reg');
    final writeLbaReg = Logic(name: 'write_lba_reg', width: sdCommandArgBits);
    final regSendReg = Logic(name: 'reg_send_reg');
    final regDataReg = Logic(name: 'reg_data_reg', width: sdCardRegTxBits);
    final regBytesReg = Logic(name: 'reg_bytes_reg', width: sdDataTxLenBits);
    final goIdleReg = Logic(name: 'go_idle_reg');

    // The card status. Every bit outside the two fields below is 0 in this
    // phase. The widths come from the field constants, so a field that
    // moves cannot push another field off the end without notice.
    final statusTopBits =
        sdCardStatusBits - sdStatusCurrentStateLsb - sdCardStateBits;
    final inPrg = state
        .eq(Const(sdCardStatePrg, width: sdCardStateBits))
        .named('in_prg');
    final readyForData = (~inPrg).named('ready_for_data');
    final status = [
      Const(0, width: statusTopBits),
      state,
      readyForData,
      Const(0, width: sdStatusReadyForDataBit),
    ].swizzle().named('card_status');

    // The link raises both in the same clock for a frame that it framed and
    // whose CRC7 it accepted. cmd_crc_ok is a register that reads 0 in
    // every other clock, so a stale verdict cannot reach this term.
    final cmdAccept = (input('cmd_valid') & input('cmd_crc_ok')).named(
      'cmd_accept',
    );

    // The command set. The status goes in before the state moves, because
    // CURRENT_STATE reports the state that the card was in when the command
    // arrived.
    final decision = (decode ?? _decodeCommand)(
      SdDecodeInputs(
        index: cmdIndexReg,
        arg: cmdArgReg,
        state: state,
        status: status,
        appCmd: appCmd,
        opCondPoll: opCondPoll,
        rca: rca,
        csd: input('csd'),
        numBlocks: input('num_blocks'),
        readReady: input('read_ready'),
        writeReady: input('write_ready'),
        cardEnable: input('card_enable'),
        regReady: input('reg_ready'),
      ),
    );

    // A decode that starts no read gives null, so the module supplies a
    // constant 0 and the branch below folds away. A width that comes from
    // the port and not from a bare number keeps a truncated address out of
    // the read path.
    final decodeReadStart = decision.readStart ?? Const(0);
    final decodeReadLba = decision.readLba ?? Const(0, width: sdCommandArgBits);
    final decodeReadMulti = decision.readMulti ?? Const(0);
    final decodeWriteStart = decision.writeStart ?? Const(0);
    final decodeWriteLba =
        decision.writeLba ?? Const(0, width: sdCommandArgBits);
    if (decodeWriteLba.width != sdCommandArgBits) {
      throw StateError(
        'The decode gives a write block address of ${decodeWriteLba.width} '
        'bits and a command argument is $sdCommandArgBits bits.',
      );
    }
    final decodeRegSend = decision.regSend ?? Const(0);
    final decodeRegData = decision.regData ?? Const(0, width: sdCardRegTxBits);
    final decodeRegBytes =
        decision.regBytes ?? Const(1, width: sdDataTxLenBits);
    final decodeGoIdle = decision.goIdle ?? Const(0);
    if (decodeReadLba.width != sdCommandArgBits) {
      throw StateError(
        'The decode gives a block address of ${decodeReadLba.width} bits '
        'and a command argument is $sdCommandArgBits bits.',
      );
    }
    if (decodeRegData.width != sdCardRegTxBits) {
      throw StateError(
        'The decode gives a card register of ${decodeRegData.width} bits '
        'and the register sender port is $sdCardRegTxBits bits.',
      );
    }
    if (decodeRegBytes.width != sdDataTxLenBits) {
      throw StateError(
        'The decode gives a register length of ${decodeRegBytes.width} bits '
        'and a transmit length is $sdDataTxLenBits bits.',
      );
    }

    // The link takes the answer in the first clock where it is free.
    final respGo = (respPending & ~input('resp_busy')).named('resp_go');

    // A queue of one. respGo means that the link took the answer on this
    // same edge, so the slot is free again. Without the term a second
    // command could write over an answer that never went out. A host that
    // follows the specification waits for the response before it sends the
    // next command, so this holds only for traffic that no host sends.
    final respSlotFree = (~respPending | respGo).named('resp_slot_free');

    // The card acts on a command only when it can also answer it. A
    // command that asks for no answer always acts, because a broadcast
    // command moves the card and gives nothing back.
    final decodeCommit = (~decision.respond | respSlotFree).named(
      'decode_commit',
    );

    // The card is sending a block now. The read path owns the transfer and
    // the card status reports the state, so both read this register.
    final dataState = Const(sdCardStateData, width: sdCardStateBits);
    final inDataState = state.eq(dataState).named('in_data_state');

    // The two states of a write. The card is in rcv while it takes the
    // block and in prg while it programs it, and both belong to the write
    // path.
    final rcvState = Const(sdCardStateRcv, width: sdCardStateBits);
    final prgState = Const(sdCardStatePrg, width: sdCardStateBits);
    final inWriteState = (state.eq(rcvState) | state.eq(prgState)).named(
      'in_write_state',
    );

    // The card leaves the data state for a reason of its own, which is a
    // command that moves it somewhere other than data. CMD0 is the one
    // such command today. The read path has to hear about it, because the
    // record it posted still stands and the answer to it is now late.
    final leaveData =
        (cmdPending &
                decodeCommit &
                inDataState &
                decision.nextState.neq(dataState))
            .named('leave_data_state');

    // The same rule for a write. A command that takes the card out of rcv
    // or prg aborts the write, because the record the card posted still
    // stands and the host is no longer waiting for the card to program.
    final leaveWrite =
        (cmdPending &
                decodeCommit &
                inWriteState &
                decision.nextState.neq(rcvState) &
                decision.nextState.neq(prgState))
            .named('leave_write_state');

    // A decode that MOVES the card. It is the only thing that may beat the
    // end of a transfer, and the two branches below the decode read it.
    //
    // A command that moves the card, such as CMD0, must win: a CMD0 that
    // lands as a block finishes takes the card to idle and not to tran.
    // A command that moves it NOWHERE must not win. CMD13 is such a
    // command: it reports the card and leaves `nextState` at the state the
    // card is already in. A card that let it win wrote prg back over the
    // tran that the completion had just written, and the one clock pulse
    // of `write_done` was gone. A Linux host without
    // MMC_CAP_WAIT_WHILE_BUSY polls CMD13 through the whole busy window,
    // so that collision is routine, and CMD12 is not accepted in prg, so
    // only CMD0 recovered the card.
    final decodeMovesState =
        (cmdPending & decodeCommit & decision.nextState.neq(state)).named(
          'decode_moves_state',
        );

    // The branches below are ordered, and a later one wins.
    //
    // respGo comes first, so an answer that the decode queues in that same
    // clock is not cleared. The rcv to prg branch comes next, so the end of
    // a write below beats it. The decode follows. The two ends of a
    // transfer come AFTER the decode and read [decodeMovesState], which is
    // what lets a command that moves the card win while a command that
    // moves it nowhere does not. cmdAccept is last, so a command that
    // arrives in the same clock where a decode ends keeps its capture.
    Sequential(
      clk,
      reset: reset,
      resetValues: {
        state: Const(sdCardStateIdle, width: sdCardStateBits),
        cmdIndexReg: Const(0, width: sdCommandIndexBits),
        cmdArgReg: Const(0, width: sdCommandArgBits),
        cmdPending: Const(0),
        respPending: Const(0),
        respDataReg: Const(0, width: sdResponseRegBits),
        respKindReg: Const(sdRespKindR1, width: sdRespKindBits),
        appCmd: Const(0),
        opCondPoll: Const(0, width: sdOpCondPollBits),
        rca: Const(0, width: sdRcaBits),
        readStartReg: Const(0),
        readLbaReg: Const(0, width: sdCommandArgBits),
        readMultiReg: Const(0),
        writeStartReg: Const(0),
        writeLbaReg: Const(0, width: sdCommandArgBits),
        regSendReg: Const(0),
        regDataReg: Const(0, width: sdCardRegTxBits),
        regBytesReg: Const(1, width: sdDataTxLenBits),
        goIdleReg: Const(0),
      },
      [
        // The start of a read is a pulse of one clock. The default is here
        // so that the register clears on the clock after the decode raised
        // it, and the decode branch below beats the default.
        readStartReg < Const(0),
        // The start of a write is a pulse of one clock, for the same
        // reason and with the same shape.
        writeStartReg < Const(0),
        // The start of a register frame is a pulse of one clock as well,
        // for the same reason and with the same shape.
        regSendReg < Const(0),
        // The return to idle is a pulse of one clock as well.
        goIdleReg < Const(0),
        If(respGo, then: [respPending < Const(0)]),
        // The write moved from taking the block to programming it. This
        // branch comes FIRST so that the end of a write below beats it: a
        // write that ends on the same clock takes the card to tran and not
        // to prg.
        If(state.eq(rcvState) & input('write_prg'), then: [state < prgState]),
        If(
          cmdPending,
          then: [
            cmdPending < Const(0),
            If(
              decodeCommit,
              then: [
                state < decision.nextState,
                ...decision.updates,
                If(
                  decodeReadStart,
                  then: [
                    readStartReg < Const(1),
                    readLbaReg < decodeReadLba,
                    readMultiReg < decodeReadMulti,
                  ],
                ),
                If(
                  decodeWriteStart,
                  then: [
                    writeStartReg < Const(1),
                    writeLbaReg < decodeWriteLba,
                  ],
                ),
                If(
                  decodeRegSend,
                  then: [
                    regSendReg < Const(1),
                    regDataReg < decodeRegData,
                    regBytesReg < decodeRegBytes,
                  ],
                ),
                // WRAPPED, and that is the point. A flat write here would
                // pulse `go_idle` on EVERY command the card takes and the
                // block cache would throw every line away on each one.
                If(decodeGoIdle, then: [goIdleReg < Const(1)]),
                If(
                  decision.respond,
                  then: [
                    respPending < Const(1),
                    respDataReg < decision.data,
                    respKindReg < decision.kind,
                  ],
                ),
              ],
            ),
          ],
        ),
        // The read ended. The card goes back to tran, which is where a
        // block read starts and ends.
        //
        // This branch is AFTER the decode, and it is held off only by a
        // decode that MOVES the card. A command that moves the card wins,
        // so a CMD0 that lands as a block finishes still takes the card to
        // idle. A command that moves it nowhere, such as CMD13, does not
        // win, so the end of the transfer is never written over. See
        // [decodeMovesState].
        If(
          ~decodeMovesState &
              inDataState &
              (input('read_done') | input('read_failed')),
          then: [state < Const(sdCardStateTran, width: sdCardStateBits)],
        ),
        // The write ended, well or badly. The card goes back to tran,
        // which is where a block write starts and ends. It has the same
        // shape as the read above and for the same reason.
        If(
          ~decodeMovesState &
              inWriteState &
              (input('write_done') | input('write_failed')),
          then: [state < Const(sdCardStateTran, width: sdCardStateBits)],
        ),
        If(
          cmdAccept,
          then: [
            cmdIndexReg < input('cmd_index'),
            cmdArgReg < input('cmd_arg'),
            cmdPending < Const(1),
          ],
        ),
      ],
    );

    // The published state is held at idle while the domain is in reset, and
    // it is the REGISTER that drives it at every other time.
    //
    // The gate is not a repeat of the reset above. The state register takes
    // a SYNCHRONOUS reset, so it needs one clock edge while the reset is
    // high before it holds idle. The SD clock comes from the host and it
    // does not run before the host arrives, so a card that never got one
    // edge would publish whatever its flop powered up with. That value
    // crosses into the bus domain and reaches CARD_STATE, which a runtime
    // reads over USB to learn whether the card is alive. The gate makes
    // that read say idle, which is what a card that no host has clocked
    // is. [MimicSdGrayCounter] gates its published count for the same
    // reason.
    //
    // The gate adds no transition of its own. The register already holds
    // idle on the first edge after the reset, so the state does not move at
    // the release.
    output('card_state') <=
        mux(reset, Const(sdCardStateIdle, width: sdCardStateBits), state);
    output('resp_start') <= respGo;
    output('resp_data') <= respDataReg;
    output('resp_kind') <= respKindReg;
    output('read_start') <= readStartReg;
    output('read_lba') <= readLbaReg;
    output('read_abort') <= leaveData;
    output('read_multi') <= readMultiReg;
    output('write_start') <= writeStartReg;
    output('write_lba') <= writeLbaReg;
    output('write_abort') <= leaveWrite;
    output('reg_send') <= regSendReg;
    output('reg_data') <= regDataReg;
    output('reg_bytes') <= regBytesReg;
    output('go_idle') <= goIdleReg;
  }

  /// The command set of the card.
  ///
  /// This decode holds the identification commands. A Linux mmc driver
  /// sends all of them before it reads one block, so a card that answers
  /// none of them is a card that no host ever reaches.
  ///
  /// CMD0 gives no answer, returns the card to idle from every state and
  /// takes the address of the card back. CMD8 answers R7, which echoes the
  /// low [sdIfCondEchoBits] bits of the argument. CMD55 answers R1 with
  /// APP_CMD set and marks the next command as an application command.
  /// ACMD41 answers R3 with the OCR, and it moves the card to ready on the
  /// answer that reports the power-up done. CMD2 answers R2 with the CID
  /// and moves the card to ident. CMD3 answers R6 with the address of the
  /// card and moves the card to stby. CMD9 answers R2 with the CSD that the
  /// `csd` port gives. CMD7 answers R1 and moves the card to tran.
  ///
  /// CMD17 reads one block. CMD12 answers R1 and takes the card out of the
  /// data state, and CMD13 answers R1 with the card status. Those two are
  /// the recovery path of a host whose read gave it no data, so the card
  /// answers CMD12 in the transfer state as well as in the data state. See
  /// where they are built below.
  ///
  /// CMD9 and CMD7 name one card by its address, and this card answers
  /// them for the address that CMD3 published alone. CMD7 that names
  /// another card leaves the tran state and gives no answer at all,
  /// because the answer belongs to the card that the host selected.
  ///
  /// Every other index, and every command that reaches the card in a state
  /// that does not hold it, gives no answer. The host reads that as a
  /// timeout and sends the command again, which is what a real card gives.
  /// CMD8 is the one command that answers out of its state, because a host
  /// that sends CMD8 is asking what the card is and reads
  /// ILLEGAL_COMMAND as an answer to that question.
  SdCommandDecision _decodeCommand(SdDecodeInputs inputs) {
    final index = inputs.index;
    final idleState = Const(sdCardStateIdle, width: sdCardStateBits);
    final readyState = Const(sdCardStateReady, width: sdCardStateBits);
    final identState = Const(sdCardStateIdent, width: sdCardStateBits);
    final stbyState = Const(sdCardStateStby, width: sdCardStateBits);
    final tranState = Const(sdCardStateTran, width: sdCardStateBits);
    final inIdle = inputs.state.eq(idleState).named('in_idle');
    final inReady = inputs.state.eq(readyState).named('in_ready');
    final inIdent = inputs.state.eq(identState).named('in_ident');
    final inStby = inputs.state.eq(stbyState).named('in_stby');
    final inTran = inputs.state.eq(tranState).named('in_tran');

    final isCmd0 = _isCommand(index, sdCmdGoIdleState, 'is_cmd0');
    final isCmd2 = _isCommand(index, sdCmdAllSendCid, 'is_cmd2');
    final isCmd3 = _isCommand(index, sdCmdSendRelativeAddr, 'is_cmd3');
    final isCmd7 = _isCommand(index, sdCmdSelectCard, 'is_cmd7');
    final isCmd8 = _isCommand(index, sdCmdSendIfCond, 'is_cmd8');
    final isCmd9 = _isCommand(index, sdCmdSendCsd, 'is_cmd9');
    final isCmd12 = _isCommand(index, sdCmdStopTransmission, 'is_cmd12');
    final isIndex13 = _isCommand(index, sdCmdSendStatus, 'is_index13');
    final isCmd17 = _isCommand(index, sdCmdReadSingleBlock, 'is_cmd17');
    final isCmd16 = _isCommand(index, sdCmdSetBlocklen, 'is_cmd16');
    final isCmd18 = _isCommand(index, sdCmdReadMultipleBlock, 'is_cmd18');
    final isCmd24 = _isCommand(index, sdCmdWriteBlock, 'is_cmd24');
    final isCmd55 = _isCommand(index, sdCmdAppCmd, 'is_cmd55');

    // Index 41 is ACMD41 only while the CMD55 bit is high. The same index
    // with the bit low is a different command, and this card holds no
    // command at that index.
    final isAcmd41 =
        (inputs.appCmd & _isCommand(index, sdAcmdSendOpCond, 'is_index41'))
            .named('is_acmd41');

    // The same rule for the other two application commands. Index 6 with
    // the bit low is CMD6, SWITCH_FUNC, which is a different command with
    // a different answer, and index 51 with the bit low is not a command
    // at all.
    final isIndex6 = _isCommand(index, sdAcmdSetBusWidth, 'is_index6');
    final isAcmd6 = (inputs.appCmd & isIndex6).named('is_acmd6');
    final isCmd6 = (~inputs.appCmd & isIndex6).named('is_cmd6');
    final isAcmd13 = (inputs.appCmd & isIndex13).named('is_acmd13');
    final isCmd13 = (~inputs.appCmd & isIndex13).named('is_cmd13');
    final isAcmd51 =
        (inputs.appCmd & _isCommand(index, sdAcmdSendScr, 'is_index51')).named(
          'is_acmd51',
        );

    // The address that the command names, and the address of the card.
    //
    // The address register is the guard here. It holds 0 until CMD3
    // publishes an address, so a card that never answered CMD3 matches no
    // address at all, whatever the host asks for. CMD7 also uses the
    // address 0 to deselect every card, and that address matches nothing
    // for the same reason.
    final noRca = Const(0, width: sdRcaBits);
    final cardRca = Const(sdCardRca, width: sdRcaBits);
    final argRca = inputs.arg
        .slice(sdCommandArgBits - 1, sdCommandArgBits - sdRcaBits)
        .named('arg_rca');
    final hasRca = inputs.rca.neq(noRca).named('has_rca');
    final rcaMatch = (hasRca & argRca.eq(inputs.rca)).named('rca_match');

    // Each command belongs to one state: CMD8 and ACMD41 to idle, CMD2 to
    // ready, CMD3 to ident and CMD9 to stby. The card answers CMD8 in
    // another state with ILLEGAL_COMMAND, because an R1 has a field that
    // reports a state violation. An R3 and an R2 have no such field, so a
    // command that carries one of those answers nothing at all out of its
    // state: a frame of another shape tells the host less than a timeout
    // does, and the host recovers from a timeout by itself.
    final illegal = (isCmd8 & ~inIdle).named('illegal_command');
    final sendIfCond = (isCmd8 & inIdle).named('send_if_cond');
    final sendOpCond = (isAcmd41 & inIdle).named('send_op_cond');
    final sendCid = (isCmd2 & inReady).named('send_cid');
    final sendRca = (isCmd3 & inIdent).named('send_rca');
    final sendCsd = (isCmd9 & inStby & rcaMatch).named('send_csd');

    // CMD7 selects the card whose address it names, and every other card
    // leaves the tran state without an answer. The state term guards the
    // move on its own, so the move does not lean on the module-wide rule
    // that a card with an address sits in stby or tran alone.
    final selectCard = (isCmd7 & rcaMatch & (inStby | inTran)).named(
      'select_card',
    );
    final deselectCard = (isCmd7 & ~rcaMatch & inTran).named('deselect_card');

    // CMD17, READ_SINGLE_BLOCK. It belongs to the tran state, the same way
    // CMD2 belongs to ready.
    //
    // The card takes the read only while the runtime holds it enabled and
    // while the read path can take one. In every other case in tran the
    // card answers R1 with ERROR and stays where it is: a host that reads
    // an error retries or gives up, and a host that gets no answer at all
    // waits out its own timeout first. The card never leaves the host
    // waiting for a block it will not send.
    //
    // CMD17 out of the tran state gives no answer and posts no request,
    // which is the rule every other addressed command of this decode
    // holds.
    final dataState = Const(sdCardStateData, width: sdCardStateBits);
    final readAllowed = (inputs.cardEnable & inputs.readReady).named(
      'read_allowed',
    );

    // CMD18, READ_MULTIPLE_BLOCK, takes the same path. The one difference
    // is `readMulti`, which tells the read path to go on to the block after
    // this one until CMD12 stops it. Linux reads multi-block for nearly
    // every request, so the two commands must be equal in every other way.
    final isRead = (isCmd17 | isCmd18).named('is_read_command');
    final addressInRange = inputs.arg
        .lt(inputs.numBlocks)
        .named('address_in_range');
    final readAddressBad = (isRead & inTran & ~addressInRange).named(
      'read_address_bad',
    );
    final readBlock = (isRead & inTran & readAllowed & addressInRange).named(
      'read_block',
    );
    final readRefused = (isRead & inTran & ~readAllowed & addressInRange).named(
      'read_refused',
    );
    final readMulti = (readBlock & isCmd18).named('read_multi');

    // CMD24, WRITE_BLOCK. It belongs to the tran state, the same way CMD17
    // does, and it takes the same two guards.
    //
    // The card takes the write only while the runtime holds it enabled and
    // while the write path can take one. In every other case in tran the
    // card answers R1 with ERROR and stays where it is, and the host
    // retries. A card that answered R1 with no error and then took no
    // block would leave the host sending 512 bytes that nothing catches,
    // and the host would only find out when its own write timeout ran out.
    //
    // CMD24 out of the tran state gives no answer and posts no record,
    // which is the rule every other addressed command of this decode
    // holds. That covers a CMD24 in idle, in stby and in the middle of a
    // read.
    final rcvState = Const(sdCardStateRcv, width: sdCardStateBits);
    final prgState = Const(sdCardStatePrg, width: sdCardStateBits);
    final writeAllowed = (inputs.cardEnable & inputs.writeReady).named(
      'write_allowed',
    );
    final writeAddressBad = (isCmd24 & inTran & ~addressInRange).named(
      'write_address_bad',
    );
    final writeBlock = (isCmd24 & inTran & writeAllowed & addressInRange).named(
      'write_block',
    );
    final writeRefused = (isCmd24 & inTran & ~writeAllowed & addressInRange)
        .named('write_refused');

    // CMD16, SET_BLOCKLEN. The card holds a datapath of sdBlockBytes bytes
    // and nothing else, so it accepts that length and refuses every other
    // with BLOCK_LEN_ERROR. A high capacity card fixes the block length at
    // 512 bytes, so a host that follows the specification asks for no
    // other, and a host that does gets a clear refusal and not a card that
    // silently reads the wrong number of bytes.
    final setBlockLen = (isCmd16 & inTran).named('set_block_len');
    final blockLenOk = inputs.arg
        .eq(Const(sdBlockBytes, width: sdCommandArgBits))
        .named('block_len_ok');
    final blockLenBad = (setBlockLen & ~blockLenOk).named('block_len_bad');

    // ACMD6, SET_BUS_WIDTH. The card drives DAT0 alone, so it accepts the
    // 1-bit bus and refuses every other width with ERROR.
    //
    // The SD specification requires the SCR to include the 4-bit support
    // bit. The board device tree must limit the host to one data line until
    // the datapath implements all four lines.
    final setBusWidth = (isAcmd6 & inTran).named('set_bus_width');
    final busWidthOk = inputs.arg
        .slice(sdBusWidthArgBits - 1, 0)
        .eq(Const(sdBusWidthArg1Bit, width: sdBusWidthArgBits))
        .named('bus_width_ok');
    final busWidthBad = (setBusWidth & ~busWidthOk).named('bus_width_bad');

    // ACMD51, SEND_SCR. The card answers R1 and then puts the 8 bytes of
    // the SCR on DAT0 with a CRC16, in the same frame shape a block read
    // uses. Linux reads the SCR in `mmc_sd_setup_card`, right after CMD7
    // and BEFORE any read, and it rejects a card that does not answer.
    //
    // The card stays in the TRAN state through the frame. A real card
    // passes through data and back, and no host reads the state in
    // between, so the card reports the state it is in when the frame ends
    // either way. Staying in tran also keeps the frame off the read path,
    // which owns the moves in and out of the data state.
    final scrCommand = (isAcmd51 & inTran).named('scr_command');
    final sendScr = (scrCommand & inputs.regReady).named('send_scr');
    final scrRefused = (scrCommand & ~inputs.regReady).named('scr_refused');

    // CMD6, SWITCH_FUNC. The card answers R1 and then puts the 64 bytes of
    // the switch status on DAT0 with a CRC16, through the same sender the
    // SCR uses. It is the last command a host sends before it mounts the
    // card.
    //
    // Bit 31 of the argument picks the mode: 0 is CHECK, which asks what
    // the card supports, and 1 is SWITCH, which asks the card to change
    // function. THIS DECODE READS NEITHER MODE, and that is correct here.
    // The card supports the default function of every group and nothing
    // else, so a SWITCH can only ever grant the function that is already
    // in force. The answer and the behaviour of the card are therefore the
    // same in both modes, and there is nothing for a mode bit to change.
    //
    // The card stays in TRAN through the frame, for the reason ACMD51
    // gives above.
    final switchCommand = (isCmd6 & inTran).named('switch_command');
    final sendSwitch = (switchCommand & inputs.regReady).named('send_switch');
    final switchRefused = (switchCommand & ~inputs.regReady).named(
      'switch_refused',
    );

    // ACMD13, SD_STATUS. U-Boot reads this 64-byte register after each bus
    // mode attempt. Index 13 without CMD55 remains CMD13, SEND_STATUS, and
    // answers on CMD alone.
    final sdStatusCommand = (isAcmd13 & inTran).named('sd_status_command');
    final sendSdStatus = (sdStatusCommand & inputs.regReady).named(
      'send_sd_status',
    );
    final sdStatusRefused = (sdStatusCommand & ~inputs.regReady).named(
      'sd_status_refused',
    );

    // The selection nibble that each group gets in the answer.
    //
    // The host names one function for each group in the low
    // sdSwitchGroups nibbles of the argument, group 1 lowest. This card
    // grants function 0 of every group and refuses every other, so the
    // answer for a group is 0 when the host asked for function 0 or for
    // the no-change value 0xF, and 0xF when the host asked for anything
    // else. A host reads that 0xF as the card telling it that the function
    // is not there.
    //
    // The nibbles go into the value from group 6 down to group 1, which is
    // the order of the status: group 1 sits at the BOTTOM of the selection
    // field and therefore last in the swizzle.
    final selectDefault = Const(
      sdSwitchFunctionDefault,
      width: sdSwitchGroupBits,
    );
    final selectMissing = Const(
      sdSwitchSelectNotSupported,
      width: sdSwitchGroupBits,
    );
    final noChange = Const(sdSwitchArgNoChange, width: sdSwitchGroupBits);
    final selections = <Logic>[
      for (var group = sdSwitchGroups; group >= 1; group--)
        () {
          final asked = inputs.arg
              .slice(
                group * sdSwitchGroupBits - 1,
                (group - 1) * sdSwitchGroupBits,
              )
              .named('switch_arg_group$group');
          final granted = (asked.eq(selectDefault) | asked.eq(noChange)).named(
            'switch_granted_group$group',
          );
          return mux(
            granted,
            selectDefault,
            selectMissing,
          ).named('switch_sel_group$group');
        }(),
    ];

    // The base status, with the selection field cut out of it and the
    // nibbles above put in its place. The two constant parts come from the
    // bit numbers of the specification, so a field that moves takes both
    // slices with it.
    final switchBase = Const(
      sdRegisterToBigInt(sdCardSwitchStatusBytes),
      width: sdSwitchStatusBits,
    );
    final switchStatus = [
      switchBase.slice(
        sdSwitchStatusBits - 1,
        sdSwitchSelectionLsb + sdSwitchSelectionBits,
      ),
      ...selections,
      switchBase.slice(sdSwitchSelectionLsb - 1, 0),
    ].swizzle().named('switch_status');

    // The SCR is shorter than the register port, and the sender puts the
    // byte that goes out FIRST in the most significant byte. The value
    // therefore sits at the top of the port and the low bytes are never
    // read.
    final scrValue = [
      Const(sdCardScrValue, width: sdScrBytes * 8),
      Const(0, width: sdCardRegTxBits - sdScrBytes * 8),
    ].swizzle().named('scr_value');
    final ssrValue = Const(
      sdCardSsrValue,
      width: sdCardRegTxBits,
    ).named('sd_status_value');

    // CMD12, STOP_TRANSMISSION, and CMD13, SEND_STATUS. The two commands
    // that a Linux host sends to recover from a data read timeout.
    //
    // CMD12 belongs to the data state, and this card answers it in the
    // transfer state as well. That is a deliberate difference from a real
    // card, which reports ILLEGAL_COMMAND there. The card gives up on a
    // read BEFORE the host does, so it is already back in the transfer
    // state when the recovery of the host arrives, and an error in the
    // answer to CMD12 makes `__mmc_blk_err_check` fail the request that the
    // recovery was meant to save.
    //
    // CMD12 from the data state moves the card back to the transfer state,
    // which the read path reads as an abort. A block that is already going
    // out on DAT still runs to its end bit, because the SD bus has no way
    // to stop in the middle of one.
    //
    // CMD13 names one card by its address and reads its status. It changes
    // nothing, so a host can poll it.
    final stopTransmission = (isCmd12 & (inTran | inputs.state.eq(dataState)))
        .named('stop_transmission');
    // CMD13 also belongs in the rcv and prg states, and that is the whole
    // point of it for a write: a host polls CMD13 until the card leaves
    // prg, which is how it learns that the card finished the block. A card
    // that refused CMD13 there would leave the host with nothing to poll.
    final sendStatus =
        (isCmd13 &
                rcaMatch &
                (inStby |
                    inTran |
                    inputs.state.eq(dataState) |
                    inputs.state.eq(rcvState) |
                    inputs.state.eq(prgState)))
            .named('send_status');

    // The power-up poll. The counter stops at the top, so the card reports
    // busy for the first sdOpCondBusyPolls answers and ready after that.
    final pollLimit = Const(sdOpCondBusyPolls, width: sdOpCondPollBits);
    final powerUpDone = inputs.opCondPoll.gte(pollLimit).named('power_up_done');
    final nextPoll = mux(
      powerUpDone,
      inputs.opCondPoll,
      inputs.opCondPoll + Const(1, width: sdOpCondPollBits),
    ).named('op_cond_poll_next');

    // The OCR that an R3 carries. sd_regs.dart builds both words, so the
    // voltage window and the capacity bit cannot drift from the register
    // that the host reads anywhere else.
    final ocr = mux(
      powerUpDone,
      Const(sdOcr(), width: sdCardStatusBits),
      Const(sdOcr(ready: false), width: sdCardStatusBits),
    ).named('ocr_value');

    // The R7 payload: zeros, then the voltage and the check pattern as the
    // host gave them.
    final ifCond = [
      Const(0, width: sdCardStatusBits - sdIfCondEchoBits),
      inputs.arg.slice(sdIfCondEchoBits - 1, 0),
    ].swizzle().named('if_cond_echo');

    // The card status that an R1 carries, with the two flag bits of this
    // command on top of the state fields.
    final status = _statusWithBit(
      _statusWithBit(
        _statusWithBit(
          _statusWithBit(
            _statusWithBit(inputs.status, sdStatusAppCmdBit, isCmd55),
            sdStatusIllegalCommandBit,
            illegal,
          ),
          sdStatusOutOfRangeBit,
          readAddressBad | writeAddressBad,
        ),
        sdStatusErrorBit,
        (readRefused |
                writeRefused |
                busWidthBad |
                scrRefused |
                switchRefused |
                sdStatusRefused)
            .named('error_bit_set'),
      ),
      sdStatusBlockLenErrorBit,
      blockLenBad,
    ).named('status_out');

    // The R6 payload: the address of the card, and then the 16-bit status
    // of an R6. That status holds COM_CRC_ERROR, ILLEGAL_COMMAND and ERROR
    // over bits 12 to 0 of the card status, so CURRENT_STATE and
    // READY_FOR_DATA keep the bit numbers that an R1 gives them.
    //
    // This card never sets any of the three error bits in the ident state,
    // so this field pack and a plain status.slice(15, 0) give the same
    // bits today. The constructor guard above proves the field order, not
    // a test. A test can tell the two apart only once a command can raise
    // one of the three bits before the card answers an R6.
    final r6Status = [
      status[sdStatusComCrcErrorBit],
      status[sdStatusIllegalCommandBit],
      status[sdStatusErrorBit],
      status.slice(sdR6StatusLowBits - 1, 0),
    ].swizzle().named('r6_status');
    final publishedRca = [cardRca, r6Status].swizzle().named('published_rca');

    // The register that an R2 carries. The link sends these 128 bits with
    // nothing added, because the CRC7 and the end bit are already in the
    // last byte of each register.
    //
    // The CID is a constant, because the card identity is fixed. The build
    // chooses the MDT date inside it, and nothing else. The CSD comes in on
    // a port, because the runtime owns the capacity and the timing of the
    // card and writes the whole register.
    final sendLong = (sendCid | sendCsd).named('send_long');
    final longData = mux(
      sendCsd,
      inputs.csd,
      Const(cid, width: sdResponseRegBits),
    ).named('resp_long_data');

    // An illegal CMD8 answers R1 and not R7, because the echo of an R7
    // carries no field that can hold ILLEGAL_COMMAND.
    final payload = mux(
      sendOpCond,
      ocr,
      mux(sendIfCond, ifCond, mux(sendRca, publishedRca, status)),
    ).named('resp_payload');
    final kind = mux(
      sendLong,
      Const(sdRespKindR2, width: sdRespKindBits),
      mux(
        sendOpCond,
        Const(sdRespKindR3, width: sdRespKindBits),
        Const(sdRespKindR1, width: sdRespKindBits),
      ),
    ).named('resp_kind_sel');

    // The card reaches ready on the ACMD41 that reports the power-up done,
    // which is the move that the state diagram of the specification gives.
    final goReady = (sendOpCond & powerUpDone).named('go_ready');
    final nextState = mux(
      isCmd0,
      idleState,
      mux(
        goReady,
        readyState,
        mux(
          sendCid,
          identState,
          mux(
            sendRca,
            stbyState,
            mux(
              selectCard,
              tranState,
              mux(
                deselectCard,
                stbyState,
                mux(
                  readBlock,
                  dataState,
                  mux(
                    writeBlock,
                    rcvState,
                    mux(stopTransmission, tranState, inputs.state),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ).named('next_card_state');

    return SdCommandDecision(
      respond:
          (isCmd8 |
                  isCmd55 |
                  sendOpCond |
                  sendCid |
                  sendRca |
                  sendCsd |
                  selectCard |
                  readBlock |
                  readAddressBad |
                  readRefused |
                  writeBlock |
                  writeAddressBad |
                  writeRefused |
                  setBlockLen |
                  setBusWidth |
                  scrCommand |
                  switchCommand |
                  sdStatusCommand |
                  stopTransmission |
                  sendStatus)
              .named('decode_respond'),
      kind: kind,
      data: mux(
        sendLong,
        longData,
        _shortResponse(index, payload),
      ).named('resp_data_sel'),
      nextState: nextState,
      readStart: readBlock,
      readLba: inputs.arg,
      readMulti: readMulti,
      writeStart: writeBlock,
      writeLba: inputs.arg,
      regSend: (sendScr | sendSwitch | sendSdStatus).named('reg_send_any'),
      regData: mux(
        sendSwitch,
        switchStatus,
        mux(sendSdStatus, ssrValue, scrValue),
      ).named('reg_data_sel'),
      regBytes: mux(
        sendScr,
        Const(sdScrBytes, width: sdDataTxLenBits),
        Const(sdSsrBytes, width: sdDataTxLenBits),
      ).named('reg_bytes_sel'),
      // CMD0 returns the card to idle from every state, so it is also what
      // tells the block cache to throw every line away.
      goIdle: isCmd0,
      updates: [
        // Flat, and that is the point. The module elaborates this decode
        // one time, so the write runs on every command that the card
        // takes. CMD55 sets the bit and the one command after it clears
        // the bit, which is what the specification asks for.
        inputs.appCmd < isCmd55,
        // Wrapped, and that is also the point. The same unconditional
        // write would count every command, not the ACMD41 commands alone,
        // and the card would report ready to the first host poll.
        If(sendOpCond, then: [inputs.opCondPoll < nextPoll]),
        // Wrapped for the same reason. A flat write would give the card
        // its address on every command, so the card would answer CMD7 and
        // CMD9 for an address that it never published, and a host that
        // reads the R6 of CMD3 could no longer tell which card answered.
        // CMD0 takes the address back, because a card in idle has none.
        If(
          sendRca,
          then: [inputs.rca < cardRca],
          orElse: [
            If(isCmd0, then: [inputs.rca < noRca]),
          ],
        ),
      ],
    );
  }
}

/// True while [index] holds command number [value].
///
/// The width comes from [sdCommandIndexBits], so a command number that
/// does not fit cannot silently lose its top bits. The constructor of
/// [MimicSdCardFsm] checks the largest number that this file uses.
Logic _isCommand(Logic index, int value, String name) =>
    index.eq(Const(value, width: sdCommandIndexBits)).named(name);

/// [status] with the bit at [bit] raised while [set] is high.
///
/// The two parts around the bit come from the width of [status], so a bit
/// number that moves cannot push the fields around it off the end.
Logic _statusWithBit(Logic status, int bit, Logic set) {
  final above = status.width - bit - 1;
  final mask = [
    if (above > 0) Const(0, width: above),
    set,
    if (bit > 0) Const(0, width: bit),
  ].swizzle();
  return status | mask;
}

/// The `resp_data` word of a short response.
///
/// [MimicSdLink] reads the 6-bit index field in bits 37 to 32 and the
/// 32-bit payload in bits 31 to 0. Every short response of this card
/// echoes the command index, which is what R1, R6 and R7 all carry. An R3
/// has no index field on the wire, so the link puts six ones there itself
/// and the field below never reaches the host.
Logic _shortResponse(Logic index, Logic payload) {
  final pad = sdResponseRegBits - sdCommandIndexBits - sdCardStatusBits;
  return [
    if (pad > 0) Const(0, width: pad),
    index,
    payload,
  ].swizzle().named('resp_data_word');
}
