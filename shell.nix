# Same dev shell for non-flake users:  nix-shell
{ pkgs ? import <nixpkgs> { } }:
pkgs.mkShell {
  packages = with pkgs; [ stdenv.cc python3 git ];
}
