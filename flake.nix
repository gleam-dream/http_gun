{
  description = "Development environment for http_gun";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      treefmt-nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        elixirPackage = pkgs.beam29Packages.elixir_1_18;

        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          settings.global.excludes = [
            "**/*.pdf"
            ".render/**"
          ];
          programs.gleam = {
            enable = true;
            package = pkgs.gleam;
          };
          programs.mix-format = {
            enable = true;
            package = elixirPackage;
          };
          programs.nixfmt.enable = true;
          programs.prettier.enable = true;
        };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            lefthook
            gleam
            beam29Packages.erlang
            rebar3
            elixirPackage
            python3
            nghttp2
            ripgrep
          ];
        };

        devShells.otp28 = pkgs.mkShell {
          packages = with pkgs; [
            gleam
            beam28Packages.erlang
            beam28Packages.rebar3
            python3
            nghttp2
            ripgrep
          ];
        };

        devShells.otp27 = pkgs.mkShell {
          packages = with pkgs; [
            gleam
            beam27Packages.erlang
            beam27Packages.rebar3
            python3
            nghttp2
            ripgrep
          ];
        };

        formatter = treefmtEval.config.build.wrapper;

        checks.formatting = treefmtEval.config.build.check ./.;
      }
    );
}
