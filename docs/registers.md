# Register and channel interface

The CSR window starts at `0x00000000`. Each register is 32 bits wide and
aligned to four bytes. A register read has no side effect. State changes only
on writes.

## CSR map

| Offset | Name | Access | Function |
| ------ | ---- | ------ | -------- |
| `0x00` | `ID` | RO | `0x4D494D43`, which is `MIMC`. |
| `0x04` | `VERSION` | RO | Packed interface version. Current value is `0x00010000`. |
| `0x08` | `CTRL` | RW | Card control bits. |
| `0x0C` | `STATUS` | RO | Reserved. Reads zero. |
| `0x10` | `NUM_BLOCKS` | RW | Published capacity in blocks. |
| `0x14` | `SCRATCH` | RW | Transport test register. |
| `0x18` | `REQ` | RO | Word 0 of the head request. No pop. |
| `0x1C` | `REQ_COUNT` | RO | Whole requests waiting. |
| `0x20` | `DATA_IN` | WO | Read-data word stream into the card. |
| `0x24` | `DATA_IN_COUNT` | RO | Free `DATA_IN` space in words. |
| `0x28` | `DATA_OUT` | RO | Head write-data word. No pop. |
| `0x2C` | `DATA_OUT_COUNT` | RO | Write-data words waiting. |
| `0x30` | `EVENT` | RW1C | Latched card faults. |
| `0x34` | `IRQ_ENABLE` | RW | Event interrupt mask. |
| `0x38` | `DBG_CMD_COUNT` | RO | USB commands received. |
| `0x3C` | `DBG_IN_COUNT` | RO | USB responses sent. |
| `0x40` | `DBG_RESET_COUNT` | RO | USB bus resets. |
| `0x44` | `CARD_STATE` | RO | SD state in bits 3 through 0. |
| `0x48` | `CSD_0` | RW | CSD bits 31 through 0. |
| `0x4C` | `CSD_1` | RW | CSD bits 63 through 32. |
| `0x50` | `CSD_2` | RW | CSD bits 95 through 64. |
| `0x54` | `CSD_3` | RW | CSD bits 127 through 96. |
| `0x58` | `DBG_SD_CLK` | RO | SD clock ticks. |
| `0x5C` | `DBG_SD_CMD` | RO | Framed SD commands. |
| `0x60` | `DBG_SD_CRC_ERR` | RO | Commands with bad CRC7. |
| `0x64` | `DBG_SD_RESP` | RO | SD responses started. |
| `0x68` | `REQ_HI` | RO | Word 1 of the head request. No pop. |
| `0x6C` | `DATA_TAG` | WO | Tag for the next `DATA_IN` block. |
| `0x70` | `REQ_POP` | WO | Bit 0 removes one request. |
| `0x74` | `DATA_OUT_POP` | WO | Bit 0 removes one output word. |
| `0x78` | `WRITE_ACK` | WO | Retire a write and release SD busy. |
| `0x7C` | `DATA_FILL_LBA` | WO | Block address for the next fill. |
| `0x80` | `DBG_CACHE_HIT` | RO | Reads completed from cache. |
| `0x84` | `DBG_CACHE_MISS` | RO | Reads that posted a request. |
| `0x88` | `DBG_CACHE_FILL` | RO | Completed cache fills. |
| `0x8C` | `CACHE_LINES` | RO | Cache lines in this bitstream. |

`mimic-cli info` prints the main register set through `DBG_SD_RESP`. The serve
statistics read the cache counters separately.

## CTRL bits

| Bit | Name | Meaning when set |
| --- | ---- | ---------------- |
| 0 | `ENABLE` | Enable the card. |
| 1 | `TEST_PATTERN` | Drive test-pattern data. |
| 2 | `READ_ONLY` | Refuse writes and report write protection. |
| 3 | `CACHE_BYPASS` | Do not answer reads from the block cache. |
| 4 | `WRITE_BACK` | Keep a write in the card before runtime acknowledgement. |

The runtime uses write-through operation, so `WRITE_BACK` stays clear.

## EVENT bits

| Bit | Meaning |
| --- | ------- |
| 0 | The runtime did not answer a read before the card timeout. |
| 1 | The runtime did not acknowledge a write before the card timeout. |
| 2 | `DATA_IN` overflowed. The read-data channel is no longer aligned. |

Write a one to clear a set event bit.

## Request records

A request has two words:

```
word 0: operation[7:0], sequence[15:8], blocks[31:16]
word 1: block address[31:0]
```

Operation `0x01` reads blocks. Operation `0x02` writes one block. Operation
`0x03` discards one received block after a bad SD CRC16.

Read `REQ`, read `REQ_HI`, then write bit 0 to `REQ_POP`. The two reads do not
change the request. A block address is an LBA, not a byte address.

## Data channel rules

One block is 128 little-endian 32-bit words. A read response writes its
sequence value to `DATA_TAG` before it streams the block to `DATA_IN`. A fill
writes its LBA to `DATA_FILL_LBA`, writes tag 0, and then streams the block.

For a write, wait until `DATA_OUT_COUNT` reports a complete block. Read one
word from `DATA_OUT`, then write bit 0 to `DATA_OUT_POP`. Repeat this for 128
words. Write the request tag to `WRITE_ACK` after the image write completes.
Bit 8 of `WRITE_ACK` reports that the runtime could not keep the block.
