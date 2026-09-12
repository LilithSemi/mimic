{
  lib,
  stdenvNoCC,
  yosys,
  nextpnr,
  trellis,
  icestorm,
}:

lib.extendMkDerivation {
  constructDrv = stdenvNoCC.mkDerivation;
  excludeDrvArgNames = [ "ip" ];

  extendDrvArgs =
    finalAttrs:
    {
      ip,
      name ? "${ip.name}-bitstream",
      ...
    }@args:
    builtins.removeAttrs args [ "ip" ]
    // {
      inherit name;
      dontUnpack = true;
      dontConfigure = true;
      nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [
        yosys
        nextpnr
        trellis
        icestorm
      ];

      buildPhase = ''
        runHook preBuild
        cp -r ${ip}/. .
        chmod -R u+w .
        make all
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        cp -r rtl support "$out/"
        cp Makefile synth.tcl mimic.json "$out/"
        cp *.json *.config *.bit *.lpf "$out/"
        runHook postInstall
      '';

      passthru = {
        inherit ip;
      }
      // (args.passthru or { });
    };
}
