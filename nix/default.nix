# Builds waylock, the screen locker. Upstream is
# https://codeberg.org/ifreund/waylock. This fork shows a password prompt in
# the center of each output, drawn with fcft and pixman.
#
# `waylockSource` and `version` are for a flake that has waylock as an input,
# for example:
#
#   pkgs.callPackage "${inputs.waylock}/nix" { waylockSource = inputs.waylock; }
#
# Without them, the recipe builds the files of this repository.
#
# waylock authenticates with the PAM service "waylock". NixOS has no
# system-auth service, so the recipe uses "login", and the NixOS configuration
# must give the service: security.pam.services.waylock = { }.
#
# After a change of the Zig dependencies in build.zig.zon, the hash below
# changes. Then the build fails and shows the new hash. Put that hash below.
{
  lib,
  callPackage,
  stdenv,
  zig_0_16,
  pkg-config,
  scdoc,
  wayland,
  wayland-protocols,
  wayland-scanner,
  libxkbcommon,
  pam,
  fcft,
  pixman,
  waylockSource ? ../.,
  version ? "0-unstable",
}:
let
  zigSystemDeps = callPackage ./zig-system-deps.nix { };

  # The files of the build. A change of the Nix files does not build waylock
  # again.
  source = builtins.path {
    name = "waylock-source";
    path = waylockSource;
    filter =
      path: type:
      !(builtins.elem (baseNameOf path) [
        ".git"
        ".zig-cache"
        "zig-out"
        "zig-pkg"
        "result"
        "nix"
      ]);
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "waylock";
  inherit version;
  src = source;

  deps = zigSystemDeps {
    inherit (finalAttrs) pname version src;
    hash = "sha256-3KV4mhxjqYocIWtdY6tg0A9njg25R5bL7/PPf2MvA1w=";
  };

  strictDeps = true;

  nativeBuildInputs = [
    pkg-config
    scdoc
    wayland-scanner
    zig_0_16
  ];

  buildInputs = [
    wayland
    # The scanner of zig-wayland asks pkg-config for the protocol directory of
    # wayland-scanner.
    wayland-scanner
    wayland-protocols
    libxkbcommon
    pam
    fcft
    pixman
  ];

  preBuild = ''
    substituteInPlace pam.d/waylock --replace-fail "system-auth" "login"
  '';

  zigBuildFlags = [
    "-Dman-pages"
    "--system"
    "${finalAttrs.deps}"
  ];

  # `zig build test`, with the dependencies of the build.
  doCheck = true;
  zigCheckFlags = [
    "--system"
    "${finalAttrs.deps}"
  ];

  meta = {
    description = "Small screenlocker for Wayland compositors";
    homepage = "https://github.com/menduz/waylock";
    license = lib.licenses.isc;
    mainProgram = "waylock";
    platforms = lib.platforms.linux;
  };
})
