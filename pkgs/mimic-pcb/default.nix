{
  flakever,
  lib,
  stdenvNoCC,
  mkShell,
  gerbv,
  kicad,
}:

stdenvNoCC.mkDerivation {
  pname = "mimic-pcb";
  inherit (flakever) version;

  src = lib.fileset.toSource {
    root = ../../pcb;
    fileset = ../../pcb;
  };

  nativeBuildInputs = [ kicad ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    export XDG_CONFIG_HOME="$TMPDIR/config"
    export XDG_CACHE_HOME="$TMPDIR/cache"
    mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" gerbers reports

    kicad-cli pcb drc --output reports/drc.rpt mimic.kicad_pcb
    kicad-cli sch erc --output reports/erc.rpt mimic.kicad_sch
    kicad-cli sch export pdf --output mimic-schematic.pdf mimic.kicad_sch
    kicad-cli pcb export gerbers --output gerbers/ \
      --layers F.Cu,In1.Cu,In2.Cu,In3.Cu,In4.Cu,B.Cu,F.Paste,B.Paste,F.Silkscreen,B.Silkscreen,F.Mask,B.Mask,Edge.Cuts \
      mimic.kicad_pcb
    kicad-cli pcb export drill --output gerbers/ mimic.kicad_pcb

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -r gerbers reports mimic-schematic.pdf "$out/"

    runHook postInstall
  '';

  passthru.shell = mkShell {
    name = "mimic-pcb-dev-shell";
    packages = [
      gerbv
      kicad
    ];
  };

  meta = {
    description = "Fabrication and review outputs for the Mimic PCB";
    license = {
      fullName = "CERN Open Hardware Licence v1.2";
      spdxId = "CERN-OHL-1.2";
      url = "https://ohwr.org/cernohl";
      free = true;
      redistributable = true;
    };
    platforms = lib.platforms.linux;
  };
}
