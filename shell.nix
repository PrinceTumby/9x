{ pkgs ? import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/2c74fcd6c5fc14a61de158fb796243543f46b217.tar.gz") {}
, limine-deploy ? import nix_shell/limine-deploy.nix
, zig ? import nix_shell/zig-0.10.0.nix
}:
pkgs.mkShell {
  buildInputs = [
    pkgs.bochs
    pkgs.which
    pkgs.just
    pkgs.binutils
    pkgs.lld_14
    pkgs.llvmPackages_14.llvm
    pkgs.xorriso
    limine-deploy
    zig
    # pkgs.zig
  ];
}
