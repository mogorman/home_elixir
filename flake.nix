{
  description = "HomeElixir - NixOS package + module for the Home Assistant flow engine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # nixpkgs only carries elixir up to 1.19; the app requires ~> 1.20.
        # Reuse nixpkgs's generic elixir builder (OTP 28 set) with the
        # 1.20.4 source.
        elixir = pkgs.beam28Packages.elixir_1_19.overrideAttrs (final: prev: {
          version = "1.20.4";
          src = pkgs.fetchFromGitHub {
            owner = "elixir-lang";
            repo = "elixir";
            rev = "v1.20.4";
            hash = "sha256-Z/lAmD3wyiTnX2e7n2gHELkTpZ3AgGSjqNmvDxCH91g=";
          };
        });
        erlang = pkgs.beam28Packages.erlang;
      in
      {
        packages.home-elixir = pkgs.callPackage ./home-elixir.nix {
          inherit elixir erlang;
          hexDeps = (import ./nix/hermetic-deps.nix) { inherit (pkgs) fetchurl; };
          hermetic = ./nix/hermetic;
        };

        devShells.default = pkgs.mkShell {
          packages = [ elixir erlang pkgs.git ];
        };
      }
    )
    // {
      nixosModules.home-elixir = ./nixos/module.nix;
    };
}
