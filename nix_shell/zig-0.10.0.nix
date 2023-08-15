
let
  pkgs = import <nixpkgs> {};
in
  pkgs.stdenv.mkDerivation rec {
    name = "zig";
    version = "0.10.0";

    src = builtins.fetchTarball {
      url = "https://ziglang.org/download/0.10.0/zig-macos-x86_64-0.10.0.tar.xz";
    };

    installPhase = ''
      mkdir -p $out/bin
      cp -R lib LICENSE doc $out/
      cp zig $out/bin/zig-0.10.0
      chmod +x $out/bin/zig-0.10.0
    '';
  }
