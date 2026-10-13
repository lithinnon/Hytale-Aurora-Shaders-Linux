# Dev shell for the Aurora Shaders Linux port (shader hook + installer + tools).
#   nix develop          -> shell with a C compiler and Python 3
#   nix develop -c ./hook/linux/build.sh
{
  description = "Aurora Shaders Linux port - build environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            stdenv.cc   # the hook is plain C: cc + libc headers are all the build needs
            python3     # tools/prepare_shaders.py
            git
          ];
        };
      });
    };
}
