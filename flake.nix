{
  description = "Development environment for http_gun";

  inputs = {
    design-layer.url = "github:lostbean/design-layer/main";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      design-layer,
      nixpkgs,
      flake-utils,
      treefmt-nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        elixirPackage = pkgs.beam29Packages.elixir_1_20;

        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          settings.global.excludes = [
            "**/*.pdf"
            ".render/**"
            "build/**"
            "examples/*/build/**"
            "docs/evidence/**"
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
          settings.formatter.ruff-format = {
            command = "${pkgs.ruff}/bin/ruff";
            options = [ "format" ];
            includes = [
              "dev/*.py"
              "dev/**/*.py"
            ];
          };
        };
      in
      {
        apps.snips = design-layer.apps.${system}.snips;
        apps.design-gate-check = design-layer.apps.${system}.check;
        apps.design-gate-render = design-layer.apps.${system}.render;
        apps.design-gate-context = design-layer.apps.${system}.context;

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            git
            lefthook
            gleam
            beam29Packages.erlang
            beam29Packages.rebar3
            elixirPackage
            python3
            ruff
            nghttp2
            openssl
            ripgrep
          ];
        };

        devShells.otp28 = pkgs.mkShell {
          packages = with pkgs; [
            git
            gleam
            beam28Packages.erlang
            beam28Packages.rebar3
            python3
            ruff
            nghttp2
            openssl
            ripgrep
          ];
        };

        devShells.otp27 = pkgs.mkShell {
          packages = with pkgs; [
            git
            gleam
            beam27Packages.erlang
            beam27Packages.rebar3
            python3
            ruff
            nghttp2
            openssl
            ripgrep
          ];
        };

        formatter = treefmtEval.config.build.wrapper;

        checks.formatting = treefmtEval.config.build.check ./.;
      }
    );
}
