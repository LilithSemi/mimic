{
  lib,
  stdenvNoCC,
  mimic-ip,
}:

lib.extendMkDerivation {
  constructDrv = stdenvNoCC.mkDerivation;

  excludeDrvArgNames = [
    "board"
    "target"
    "pdkRoot"
    "pins"
  ];

  extendDrvArgs =
    finalAttrs:
    {
      name,
      board ? null,
      target ? null,
      pdkRoot ? null,
      pins ? [ ],
      ...
    }@args:
    let
      option = flag: value: lib.optionalString (value != null) "${flag} ${lib.escapeShellArg value}";
      pinFlags = lib.concatMapStringsSep " " (pin: "--pin ${lib.escapeShellArg pin}") pins;
    in
    builtins.removeAttrs args [
      "board"
      "target"
      "pdkRoot"
      "pins"
    ]
    // {
      inherit name;
      dontUnpack = true;
      dontConfigure = true;
      nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [ mimic-ip ];

      buildPhase = ''
        runHook preBuild
        mimic-genip \
          --output "$out" \
          ${option "--board" board} \
          ${option "--target" target} \
          ${option "--pdk-root" pdkRoot} \
          ${pinFlags}
        runHook postBuild
      '';

      dontInstall = true;

      passthru = {
        inherit
          board
          target
          pdkRoot
          pins
          ;
      }
      // (args.passthru or { });
    };
}
