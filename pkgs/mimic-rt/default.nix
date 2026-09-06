{
  lib,
  stdenv,
  flakever,
  mkShell,
  zig,
  zippy,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "mimic-rt";
  inherit (flakever) version;

  src = ../../runtime;

  nativeBuildInputs = [
    zig
  ];

  passthru.shell = mkShell {
    name = "mimic-rt-dev-shell";
    packages = [
      zig
      zippy
    ];
  };
})
