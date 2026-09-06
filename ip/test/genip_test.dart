// Unit tests for the mimic_genip value objects: the manifest contract with
// the Zig runtime, the board/pin merge, the oscillator rate and the
// configuration checks. `bin/mimic_genip.dart` only reads the command line
// into MimicGenIpConfig, so everything the generator decides is tested here.

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:mimic/mimic.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// The card state machine inside an elaborated SoC, or null when there is
/// none. It sits several levels down, so the search walks the hierarchy.
MimicSdCardFsm? _findCardFsm(Module root) {
  for (final sub in root.subModules) {
    if (sub is MimicSdCardFsm) return sub;
    final found = _findCardFsm(sub);
    if (found != null) return found;
  }
  return null;
}

void main() {
  group('MimicManifest', () {
    // The literal from runtime/lib/mimic/manifest.zig `sample_manifest`. The
    // Zig round-trip tests parse exactly these bytes, so a manifest built
    // here with the same inputs must produce the same map.
    const sampleJson = '''
{ "name": "mimic", "interface_version": "1.0.0", "version_reg": 65536,
  "vid": 4617, "pid": 4289, "cache_blocks": 8, "sd_mode": "served",
  "csr_base": 0, "transport": "usb" }
''';

    test('toJson matches the runtime manifest.zig sample field for field', () {
      const manifest = MimicManifest(
        name: 'mimic',
        interfaceVersion: '1.0.0',
        versionReg: 65536,
        idVendor: 4617,
        idProduct: 4289,
        cacheBlocks: 8,
        sdMode: 'served',
        csrBase: 0,
        transport: 'usb',
      );
      expect(manifest.toJson(), jsonDecode(sampleJson));
    });

    test('the Zig struct fields are exactly the emitted keys', () {
      // Every field of runtime/lib/mimic/manifest.zig `Manifest`, in order.
      // The Zig parser is not tolerant of a missing field, so a key dropped
      // here breaks the runtime.
      const zigFields = [
        'name',
        'interface_version',
        'version_reg',
        'vid',
        'pid',
        'cache_blocks',
        'sd_mode',
        'csr_base',
        'transport',
      ];
      expect(const MimicGenIpConfig().manifest.toJson().keys, zigFields);
    });

    test('the default build agrees with the register and CSR constants', () {
      // manifest.zig "manifest values match the CSR and USB constants" makes
      // the same assertion from the runtime side.
      const config = MimicGenIpConfig(name: 'mimic');
      final json = config.manifest.toJson();
      expect(json['version_reg'], MimicRegValue.version);
      expect(json['interface_version'], MimicRegValue.versionString);
      expect(json['csr_base'], mimicCsrBase);
      expect(json['vid'], 0x1209);
      expect(json['pid'], 0x10C1);
    });

    test('toJsonString round-trips through a JSON parser', () {
      const config = MimicGenIpConfig(
        name: 'MimicSoC',
        cacheBlocks: 0,
        idVendor: 0x1D50,
        idProduct: 0x6130,
      );
      final decoded =
          jsonDecode(config.manifest.toJsonString()) as Map<String, Object?>;
      expect(decoded, config.manifest.toJson());
      expect(decoded['cache_blocks'], 0);
      expect(decoded['vid'], 0x1D50);
    });
  });

  group('pin resolution', () {
    test('the board catalog supplies the clock and every USB pad', () {
      final target = resolveMimicTarget(board: 'orangecrab-25f');
      expect(target.pinMap['clk'], 'A9 LVCMOS33');
      expect(target.pinMap['usb_dp'], 'N1 LVCMOS33');
      expect(target.pinMap['usb_dm'], 'M2 LVCMOS33');
      expect(target.pinMap['usb_pullup'], 'N2 LVCMOS33');
    });

    test('one --pin replaces only that signal, never the rest', () {
      // The bug this covers: an all-or-nothing default map dropped every
      // catalog pin as soon as the caller named one of their own, which
      // silently unconstrained USB and the clock.
      final target = resolveMimicTarget(
        board: 'orangecrab-25f',
        pinSpecs: const ['led_g=T1'],
      );
      expect(target.pinMap['led_g'], 'T1');
      expect(target.pinMap['clk'], 'A9 LVCMOS33');
      expect(target.pinMap['usb_dp'], 'N1 LVCMOS33');
      expect(target.pinMap['usb_dm'], 'M2 LVCMOS33');
      expect(target.pinMap['usb_pullup'], 'N2 LVCMOS33');
    });

    test('--pin overrides a catalog site of the same name', () {
      final target = resolveMimicTarget(
        board: 'orangecrab-25f',
        pinSpecs: const ['usb_dp=P1 LVCMOS33'],
      );
      expect(target.pinMap['usb_dp'], 'P1 LVCMOS33');
      expect(target.pinMap['usb_dm'], 'M2 LVCMOS33');
    });

    test('a --pin value goes through verbatim, with no IO type appended', () {
      // Harbor's grammar is "SITE [IO_TYPE] [ATTR=VAL...]" and it already
      // defaults IO_TYPE to LVCMOS33. Appending one made "K2 SSTL135" become
      // "K2 SSTL135 LVCMOS33", which states two IO types.
      expect(parseMimicPinSpecs(const ['sdram_dq=K2 SSTL135']), {
        'sdram_dq': 'K2 SSTL135',
      });
      expect(parseMimicPinSpecs(const ['clk=A9']), {'clk': 'A9'});
      expect(parseMimicPinSpecs(const ['a=B1 LVCMOS33 DRIVE=4', 'c=D2']), {
        'a': 'B1 LVCMOS33 DRIVE=4',
        'c': 'D2',
      });
    });

    test('a --pin spec with no "=" is rejected', () {
      expect(
        () => parseMimicPinSpecs(const ['clk A9']),
        throwsA(isA<FormatException>()),
      );
    });

    test('a pin the board does not catalog throws instead of vanishing', () {
      // HarborBoard.fpgaTarget is the check. Asking the ULX3S catalog for the
      // OrangeCrab USB pads must fail loudly, not quietly drop them.
      expect(
        () => HarborBoard.get('ulx3s-85f').fpgaTarget(pins: const ['usb_dp']),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('the --target escape hatch takes its pins from --pin alone', () {
      final target = resolveMimicTarget(
        targetSpec: 'ecp5:lfe5u-85f:CABGA381',
        pinSpecs: const ['clk=G2', 'usb_dp=N1'],
        oscHz: 25000000,
      );
      expect(target.device, 'lfe5u-85f');
      expect(target.package, 'CABGA381');
      expect(target.pinMap, {'clk': 'G2', 'usb_dp': 'N1'});
    });

    test('--target wins over --board', () {
      final target = resolveMimicTarget(
        board: 'orangecrab-25f',
        targetSpec: 'ecp5:lfe5u-85f:CABGA381',
        oscHz: 25000000,
      );
      expect(target.device, 'lfe5u-85f');
    });

    test('an unknown target vendor or shape is rejected', () {
      expect(
        () => parseFpgaTarget('ecp5:lfe5u-25f', const {}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => parseFpgaTarget('gowin:gw1n:LQFP144', const {}),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('oscillator frequency', () {
    test('the board catalog rate is the target rate', () {
      // The bug this covers: a hardcoded 48 MHz put a 48 MHz FREQUENCY
      // constraint and a 48 MHz nextpnr --freq on every board.
      expect(resolveMimicTarget(board: 'orangecrab-25f').frequency, 48000000);
      expect(resolveMimicTarget(board: 'ulx3s-85f').frequency, 25000000);
    });

    test('--osc-freq overrides the board rate', () {
      final target = resolveMimicTarget(
        board: 'orangecrab-25f',
        oscHz: 12000000,
      );
      expect(target.frequency, 12000000);
    });

    test('the --target path carries the given rate', () {
      expect(
        resolveMimicTarget(
          targetSpec: 'ice40:up5k:sg48',
          oscHz: 12000000,
        ).frequency,
        12000000,
      );
      // With no rate stated it falls back to the rate the PHY needs.
      expect(
        resolveMimicTarget(targetSpec: 'ice40:up5k:sg48').frequency,
        mimicClockHz,
      );
    });

    test('buildMimicSoc rejects a clock the USB PHY cannot decode', () {
      // oscHz is read, not decoration: the full-speed PHY oversamples at 4x
      // and the SoC has no PLL, so any other rate never enumerates.
      expect(
        () => buildMimicSoc(name: 'mimic_slow', oscHz: 25000000),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => MimicGenIpConfig(boardName: 'ulx3s-85f').buildSoC(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('buildMimicSoc rejects a target that disagrees with oscHz', () {
      expect(
        () => buildMimicSoc(
          name: 'mimic_mismatch',
          target: const HarborSimTarget(
            topCell: 'mimic_mismatch',
            frequency: 12000000,
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('MimicGenIpConfig', () {
    test('targetDescription names the target that is really built', () {
      // --board carries a default, so the summary used to print the board
      // even for a build that --target had overridden.
      expect(
        const MimicGenIpConfig(
          boardName: 'orangecrab-25f',
          targetSpec: 'ecp5:lfe5u-85f:CABGA381',
        ).targetDescription,
        'ecp5:lfe5u-85f:CABGA381',
      );
      expect(
        const MimicGenIpConfig(boardName: 'orangecrab-25f').targetDescription,
        'orangecrab-25f',
      );
    });

    test('validate rejects an unknown transport or sd-mode', () {
      expect(
        () => const MimicGenIpConfig(transport: 'uart').validate(),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => const MimicGenIpConfig(sdMode: 'loopback').validate(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('validate accepts zero cache blocks and rejects a negative count', () {
      expect(const MimicGenIpConfig(cacheBlocks: 0).validate, returnsNormally);
      expect(
        () => const MimicGenIpConfig(cacheBlocks: -1).validate(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('the supported value lists match the runtime enums', () {
      // runtime/lib/mimic/manifest.zig: `SdMode` and `Transport`.
      expect(MimicGenIpConfig.supportedTransports, ['usb']);
      expect(MimicGenIpConfig.supportedSdModes, ['served']);
    });

    test('validate refuses a date the MDT field cannot hold', () {
      // The check goes through sdCid, which owns the limits of every CID
      // field, so a month of 13 is refused where the field is built and not
      // by a second copy of the rule.
      expect(
        () => const MimicGenIpConfig(
          manufactureDate: MimicManufactureDate(2026, 13),
        ).validate(),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => const MimicGenIpConfig(
          manufactureDate: MimicManufactureDate(1999, 1),
        ).validate(),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        const MimicGenIpConfig(manufactureDate: MimicManufactureDate(2026, 9))
            .validate,
        returnsNormally,
      );
    });

    test('the build date reaches the CID of the elaborated card', () async {
      const date = MimicManufactureDate(2031, 7);
      final soc = const MimicGenIpConfig(
        name: 'mimic_date_elab',
        boardName: 'orangecrab-25f',
        manufactureDate: date,
      ).buildSoC();
      await soc.build();

      final fsm = _findCardFsm(soc);
      expect(
        fsm,
        isNotNull,
        reason:
            'the SoC must hold one card state '
            'machine',
      );
      // The bits, read the way a host reads them and not the way the
      // builder wrote them. MDT is the low 12 bits of the 16 bits above the
      // CRC7 byte: the 8-bit year after 2000 and then the 4-bit month.
      final mdt = ((fsm!.cid >> 8) & BigInt.from(0x0FFF)).toInt();
      expect(sdCidMdtFirstYear + (mdt >> 4), date.year);
      expect(mdt & 0x0F, date.month);
    });
  });

  group('MimicManufactureDate', () {
    test('the flag wins over the environment and the clock', () {
      final date = MimicManufactureDate.resolve(
        flag: '2031-07',
        // A different year in both of the levels below, so the test fails
        // if either one of them answers instead.
        environment: const {'SOURCE_DATE_EPOCH': '315532800'},
        now: DateTime.utc(2044, 3, 9),
      );
      expect(date, const MimicManufactureDate(2031, 7));
    });

    test('SOURCE_DATE_EPOCH wins over the clock', () {
      // 1234567890 is 2009-02-13 in UTC.
      final date = MimicManufactureDate.resolve(
        environment: const {'SOURCE_DATE_EPOCH': '1234567890'},
        now: DateTime.utc(2044, 3, 9),
      );
      expect(date, const MimicManufactureDate(2009, 2));
    });

    test('the clock answers when neither of the other two does', () {
      final date = MimicManufactureDate.resolve(
        environment: const {},
        now: DateTime.utc(2044, 3, 9),
      );
      expect(date, const MimicManufactureDate(2044, 3));
      // An empty flag and an empty variable are the same as no flag and no
      // variable. A shell that expands an unset value writes an empty
      // string, and an empty string is not a date.
      expect(
        MimicManufactureDate.resolve(
          flag: '',
          environment: const {'SOURCE_DATE_EPOCH': ''},
          now: DateTime.utc(2044, 3, 9),
        ),
        const MimicManufactureDate(2044, 3),
      );
    });

    test('every level gives a date, so no build makes a card without one', () {
      // The three levels in order, each one with the ones above it removed.
      final levels = <MimicManufactureDate>[
        MimicManufactureDate.resolve(
          flag: '2031-07',
          environment: const {'SOURCE_DATE_EPOCH': '1234567890'},
          now: DateTime.utc(2044, 3, 9),
        ),
        MimicManufactureDate.resolve(
          environment: const {'SOURCE_DATE_EPOCH': '1234567890'},
          now: DateTime.utc(2044, 3, 9),
        ),
        MimicManufactureDate.resolve(
          environment: const {},
          now: DateTime.utc(2044, 3, 9),
        ),
      ];
      expect(levels, [
        const MimicManufactureDate(2031, 7),
        const MimicManufactureDate(2009, 2),
        const MimicManufactureDate(2044, 3),
      ]);
      // And every one of them builds a CID.
      for (final level in levels) {
        expect(level.validate, returnsNormally);
      }
    });

    test('the flag reads YYYY-MM and refuses any other shape', () {
      expect(
        MimicManufactureDate.parse('2026-09'),
        const MimicManufactureDate(2026, 9),
      );
      for (final bad in const [
        '2026',
        '2026-9',
        '26-09',
        '2026-09-08',
        '2026/09',
        'september',
        '',
      ]) {
        expect(
          () => MimicManufactureDate.parse(bad),
          throwsA(isA<FormatException>()),
          reason: '"$bad" is not YYYY-MM',
        );
      }
    });

    test('a date outside the MDT field is refused, by sdCid', () {
      // The SHAPE is right and the VALUE is not, so the format check passes
      // it on and sdCid throws. There is no second copy of the limits.
      expect(
        MimicManufactureDate.parse('2026-13'),
        const MimicManufactureDate(2026, 13),
      );
      expect(
        () => MimicManufactureDate.parse('2026-13').validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            // The message says what the field can express.
            contains('MDT holds the month as 1 to 12'),
          ),
        ),
      );
      expect(
        () => MimicManufactureDate.parse('1999-01').validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            contains('MDT holds the year after 2000 in 8 bits'),
          ),
        ),
      );
      expect(
        () => MimicManufactureDate.parse('2256-01').validate(),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a SOURCE_DATE_EPOCH the MDT field cannot hold stands aside', () {
      // nix stdenv pins SOURCE_DATE_EPOCH to 1980-01-01, which is before the
      // first year MDT can name. Level 2 then STANDS ASIDE and the clock,
      // level 3, answers. The three levels exist so that no build can make a
      // card with no date, so a level that cannot answer must give way
      // rather than stop the build. The generator says so on stderr.
      final clock = DateTime(2026, 9, 9);
      final date = MimicManufactureDate.resolve(
        environment: const {'SOURCE_DATE_EPOCH': '315532800'},
        now: clock,
      );
      expect(date, const MimicManufactureDate(2026, 9));
      expect(date.validate, returnsNormally);
    });

    test('a SOURCE_DATE_EPOCH the MDT field CAN hold still wins over the '
        'clock', () {
      // The level only stands aside when it cannot answer. A date in range
      // must still beat the clock, or level 2 would be dead code.
      final date = MimicManufactureDate.resolve(
        environment: const {'SOURCE_DATE_EPOCH': '1757376000'},
        now: DateTime(2030, 1, 1),
      );
      expect(
        date.year,
        isNot(2030),
        reason: 'the epoch answers, not the clock',
      );
      expect(date.validate, returnsNormally);
    });

    test('an out of range date NAMED by the caller is still refused', () {
      // Only the environment stands aside. A caller who writes the flag
      // means it, so a silent move to another year would be a lie.
      expect(
        () => MimicManufactureDate.resolve(flag: '1980-01').validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            contains('MDT holds the year after 2000 in 8 bits'),
          ),
        ),
      );
    });

    test('a broken SOURCE_DATE_EPOCH is refused and never guessed at', () {
      expect(
        () => MimicManufactureDate.resolve(
          environment: const {'SOURCE_DATE_EPOCH': 'yesterday'},
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('toString gives back what parse reads', () {
      expect(const MimicManufactureDate(2026, 9).toString(), '2026-09');
      expect(
        MimicManufactureDate.parse(
          const MimicManufactureDate(2031, 12).toString(),
        ),
        const MimicManufactureDate(2031, 12),
      );
    });

    test('the fallback is the date sd_regs states, and it is buildable', () {
      expect(
        MimicManufactureDate.fallback,
        const MimicManufactureDate(
          sdCidDefaultManufactureYear,
          sdCidDefaultManufactureMonth,
        ),
      );
      expect(MimicManufactureDate.fallback.validate, returnsNormally);
    });
  });

  group('MimicUsbDeviceConfig.parseUsbId', () {
    test('reads hex with and without the 0x prefix', () {
      expect(MimicUsbDeviceConfig.parseUsbId('0x1209', '--vid'), 0x1209);
      expect(MimicUsbDeviceConfig.parseUsbId('0X10C1', '--pid'), 0x10C1);
      expect(MimicUsbDeviceConfig.parseUsbId('1209', '--vid'), 0x1209);
      expect(MimicUsbDeviceConfig.parseUsbId(' ffff ', '--vid'), 0xFFFF);
    });

    test('rejects a value that is not 16-bit hex', () {
      expect(
        () => MimicUsbDeviceConfig.parseUsbId('0x10000', '--vid'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => MimicUsbDeviceConfig.parseUsbId('nope', '--vid'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('generateAll', () {
    late Directory dir;
    late MimicGenIpConfig config;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('mimic_genip');
      config = const MimicGenIpConfig(
        name: 'mimic_genip_test',
        boardName: 'orangecrab-25f',
        cacheBlocks: 4,
        serialNumber: 'MIMIC0001',
      );
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('the output directory IS the flashable build', () async {
      await config.generateAll(dir);

      final manifest = jsonDecode(
        File('${dir.path}/mimic.json').readAsStringSync(),
      ) as Map<String, Object?>;
      expect(manifest, config.manifest.toJson());
      expect(manifest['name'], 'mimic_genip_test');
      expect(manifest['cache_blocks'], 4);

      // harbor writes the whole flow with the SoC as the synthesis top, so
      // `make` here gives the bitstream. There is no board shim and no
      // second build directory any more.
      expect(File('${dir.path}/synth.tcl').existsSync(), isTrue);
      expect(File('${dir.path}/Makefile').existsSync(), isTrue);
      expect(Directory('${dir.path}/board').existsSync(), isFalse);
      final synth = File('${dir.path}/synth.tcl').readAsStringSync();
      expect(synth, contains('synth_ecp5 -top mimic_genip_test'));

      // The pre-place script sits beside the Makefile, where harbor's
      // `$(wildcard support/nextpnr/constraints.py)` hook finds it.
      final makefile = File('${dir.path}/Makefile').readAsStringSync();
      expect(makefile, contains('support/nextpnr/constraints.py'));

      // It names the USB pads and at least one PHY instance out of the
      // elaborated design, never a hardcoded copy.
      final preplace = File('${dir.path}/support/nextpnr/constraints.py')
          .readAsStringSync();
      expect(preplace, contains('"usb_dp"'));
      expect(preplace, contains('"usb_pullup"'));
      expect(preplace, isNot(contains('PHY_PATTERNS = ()')));
      expect(preplace, isNot(contains('"clk"')));
      expect(preplace, isNot(contains('"led_g"')));
    });

    test('a second pre-place contribution is kept, not clobbered', () async {
      // harbor writes the same file for its own contributors. Appending is
      // what keeps a peripheral fragment alive beside the USB region.
      final target = File('${dir.path}/support/nextpnr/constraints.py')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('# earlier fragment\n');
      final soc = config.buildSoC();
      await soc.build();
      config.writePreplaceScript(soc, dir);
      final text = target.readAsStringSync();
      expect(text, contains('# earlier fragment'));
      expect(text, contains('PHY_PATTERNS'));
    });

    test(
      'the SoC constraints hold every pad and no unused catalog pin',
      () async {
        await config.generateAll(dir);
        final lpf = File('${dir.path}/mimic_genip_test.lpf').readAsStringSync();
        expect(lpf, contains('LOCATE COMP "clk" SITE "A9"'));
        expect(lpf, contains('LOCATE COMP "usb_dp" SITE "N1"'));
        expect(lpf, contains('LOCATE COMP "usb_dm" SITE "M2"'));
        expect(lpf, contains('LOCATE COMP "usb_pullup" SITE "N2"'));
        expect(lpf, contains('FREQUENCY PORT "clk" 48.0 MHz'));
        // The board glue the hand-written shim used to carry: harbor's
        // active-low reset input on the button site, and the bench LED.
        expect(lpf, contains('LOCATE COMP "reset_n" SITE "V17"'));
        expect(lpf, contains('LOCATE COMP "led_g" SITE "M3"'));
        // The microSD socket, 1-bit mode. CMD and DAT0 carry the pull-up the
        // litex table has, so an idle line reads high and a released line is
        // not read as a start bit.
        expect(lpf, contains('LOCATE COMP "sd_clk" SITE "K1"'));
        expect(lpf, contains('LOCATE COMP "sd_cmd" SITE "K2"'));
        expect(lpf, contains('LOCATE COMP "sd_dat0" SITE "J1"'));
        expect(
          lpf,
          contains('IOBUF PORT "sd_cmd" IO_TYPE=LVCMOS33 PULLMODE=UP;'),
        );
        expect(
          lpf,
          contains('IOBUF PORT "sd_dat0" IO_TYPE=LVCMOS33 PULLMODE=UP;'),
        );
        // The bus is 1 bit wide, so DAT1 to DAT3 carry no data. They are
        // still constrained, because the pad pull-up holds each line high
        // the way a real card does. A host that reads DAT[3:0] to decide the
        // card is busy sees a floating line as busy and then sends no
        // command at all.
        expect(lpf, contains('LOCATE COMP "sd_dat1" SITE "K3"'));
        expect(lpf, contains('LOCATE COMP "sd_dat2" SITE "L3"'));
        expect(lpf, contains('LOCATE COMP "sd_dat3" SITE "M1"'));
        expect(
          lpf,
          contains('IOBUF PORT "sd_dat3" IO_TYPE=LVCMOS33 PULLMODE=UP;'),
        );
        // The catalog signal name the alias came from has no port of its own,
        // so it must not be constrained twice.
        expect(lpf, isNot(contains('"rst_n"')));
        // Harbor drops a catalog pin the design has no top-level port for, so
        // the whole catalog can go to the target without breaking nextpnr.
        expect(lpf, isNot(contains('uart_tx')));
        expect(lpf, isNot(contains('spi_cs_n')));
      },
    );
  });
}
