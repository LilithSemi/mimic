/// Mimic: SD card emulation over USB for SBCs, FPGAs, and DUTs.
library;

export 'src/genip.dart';
export 'src/regs.dart';
export 'src/sd_crc.dart';
export 'src/sd_regs.dart';
export 'src/hw/led_activity.dart';
export 'src/hw/reset_sync.dart';
export 'src/hw/sd_block_cache.dart';
export 'src/hw/byte_lane_cdc_fifo.dart';
export 'src/hw/sd_block_ram.dart';
export 'src/hw/sd_card.dart';
export 'src/hw/sd_card_device.dart';
export 'src/hw/sd_card_fsm.dart';
export 'src/hw/sd_debug.dart';
export 'src/hw/sd_link.dart';
export 'src/hw/sd_read_path.dart';
export 'src/hw/sd_reg_tx.dart';
export 'src/hw/sd_write_path.dart';
export 'src/hw/usb_device.dart';
export 'src/soc.dart';

/// Library version string (used by the smoke test and `--version`).
const String mimicVersion = '0.0.1';
