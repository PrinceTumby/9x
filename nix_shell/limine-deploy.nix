let
  pkgs = import <nixpkgs> {};
in
  pkgs.stdenv.mkDerivation rec {
    name = "limine-deploy";
    version = "4.20221216.0";

    src = pkgs.fetchFromGitHub {
      owner = "limine-bootloader";
      repo = "limine";
      rev = "b2e238d16f07513755823b6502e8b85de7a0eaab";
      sha256 = "e+Mk3nFTv7EkNZWJ2aXb1NtH11PR4nqVfMXlSQFncBg=";
    };

    buildPhase = ''
      make limine-deploy
    '';

    installPhase = ''
      mkdir -p $out/bin
      cp ./limine-deploy $out/bin
      chmod +x $out/bin/limine-deploy
    '';
  }
