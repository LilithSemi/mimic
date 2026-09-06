{
  flakever,
  manufactureDate,
  lib,
  buildDartApplication,
  mkShell,
  dart,
  yq,
  openfpgaloader,
  trellis,
  picocom,
  yosys,
  nextpnr,
  icestorm,
}:
# `manufactureDate` is the YYYY-MM the generated card reports in the MDT
# field of its CID. flake.nix takes it from the flake's lastModifiedDate,
# with a fallback for a dirty tree where that attribute does not exist.
assert
  lib.match "[0-9]{4}-(0[1-9]|1[0-2])" manufactureDate != null
  || throw "manufactureDate must be YYYY-MM, got: ${manufactureDate}";
buildDartApplication {
  pname = "mimic-ip";
  inherit (flakever) version;

  src = lib.fileset.toSource {
    root = ../../ip;
    fileset = lib.fileset.unions [
      ../../ip/bin
      ../../ip/lib
      ../../ip/test
      ../../ip/pubspec.yaml
      ../../ip/pubspec.lock
      ../../ip/analysis_options.yaml
    ];
  };

  pubspecLock = lib.importJSON ../../ip/pubspec.lock.json;

  gitHashes = {
    harbor = "sha256-vHkiZgAdh+hTIn2xk+wlNfzq/bldV/ftQ7qJ8guDlx4=";
  };

  dartEntryPoints."bin/mimic-genip" = "bin/mimic_genip.dart";

  extraWrapProgramArgs = "--add-flags '--manufacture-date ${manufactureDate}'";

  doCheck = true;

  checkPhase = ''
    runHook preCheck

    export HOME=$TMPDIR
    export PUB_CACHE=$TMPDIR/.pub-cache

    testPkgRoot=$(jq --raw-output \
      '.packages[] | select(.name == "test") | .rootUri | sub("file://"; "")' \
      .dart_tool/package_config.json)

    dart --packages=.dart_tool/package_config.json \
      "$testPkgRoot/bin/test.dart"

    runHook postCheck
  '';

  passthru.shell = mkShell {
    name = "mimic-ip-dev-shell";
    packages = [
      dart
      yq
      openfpgaloader
      picocom
      yosys
      nextpnr
      trellis
      icestorm
    ];
  };
}
