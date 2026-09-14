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

  postInstall = ''
    install -Dm444 60-mimic.rules \
      $out/lib/udev/rules.d/60-mimic.rules
  '';

  passthru.shell = mkShell {
    name = "mimic-rt-dev-shell";
    packages = [
      zig
      zippy
    ];
  };
})
