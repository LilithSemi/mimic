{
  flakever,
  lib,
  stdenvNoCC,
  mkShell,
  makeFontsConf,
  liberation_ttf,
  mesa,
  openscad-unstable,
}:

let
  fontsConf = makeFontsConf { fontDirectories = [ liberation_ttf ]; };
in
stdenvNoCC.mkDerivation {
  pname = "mimic-case";
  inherit (flakever) version;

  src = lib.fileset.toSource {
    root = ../../case;
    fileset = ../../case;
  };

  nativeBuildInputs = [ openscad-unstable ];

  dontConfigure = true;

  # The renders use the Mesa software renderer, because the sandbox has no
  # display and no GPU.
  env = {
    FONTCONFIG_FILE = fontsConf;
    __EGL_VENDOR_LIBRARY_FILENAMES = "${mesa}/share/glvnd/egl_vendor.d/50_mesa.json";
    EGL_PLATFORM = "surfaceless";
  };

  buildPhase = ''
    runHook preBuild

    export HOME="$TMPDIR"
    mkdir -p print renders

    scad() {
      openscad --backend=manifold --hardwarnings "$@" mimic-v1-case.scad
    }

    for part in tray lid cap; do
      scad -D "part=\"$part\"" -D print=true -o "print/mimic-v1-$part.stl"
      scad -D "part=\"$part\"" -D print=true -o "print/mimic-v1-$part.3mf"
    done

    for view in closed assembly exploded cap_off; do
      scad -D "part=\"$view\"" --viewall --autocenter --imgsize=1600,1200 \
        -o "renders/$view.png"
    done

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -r print renders "$out/"

    runHook postInstall
  '';

  passthru.shell = mkShell {
    name = "mimic-case-dev-shell";
    packages = [ openscad-unstable ];
    FONTCONFIG_FILE = fontsConf;
  };

  meta = {
    description = "Print and review outputs for the Mimic V1 case";
    license = {
      fullName = "CERN Open Hardware Licence Version 2 - Strongly Reciprocal";
      spdxId = "CERN-OHL-S-2.0";
      url = "https://ohwr.org/cern_ohl_s_v2.txt";
      free = true;
      redistributable = true;
    };
    platforms = lib.platforms.linux;
  };
}
