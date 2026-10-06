{
  description = "Development environment for http_gun";

  inputs = {
    design-layer.url = "github:lostbean/design-layer";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
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

        # The upstream apps pin the renderer; authored imports also need its
        # generated local projection on a fresh checkout.
        designApp =
          name:
          let
            wrapper = pkgs.writeShellApplication {
              name = "design-gate-${name}";
              runtimeInputs = [ pkgs.coreutils ];
              text = ''
                project_layer() {
                  if [ -f "$1/design.typ" ]; then
                    mkdir -p "$1/.render"
                    cp -RL --remove-destination --no-preserve=mode ${
                      design-layer.packages.${system}.gate-bundle
                    }/render/. "$1/.render/"
                  fi
                }
                project_layer "''${1:-docs/design}"
                exec ${design-layer.apps.${system}.${name}.program} "$@"
              '';
            };
          in
          {
            type = "app";
            program = "${wrapper}/bin/design-gate-${name}";
          };

        elixirPackage = pkgs.beam29Packages.elixir_1_18;

        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          settings.global.excludes = [
            "**/*.pdf"
            ".render/**"
            "build/**"
            "examples/*/build/**"
            "docs/history/**"
            "dev/dependencies/**"
            "dev/results/**"
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
        apps.design-gate-check = designApp "check";
        apps.design-gate-render = designApp "render";
        apps.design-gate-context = designApp "context";

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            lefthook
            gleam
            beam29Packages.erlang
            rebar3
            elixirPackage
            python3
            actionlint
            shellcheck
            ruff
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
            actionlint
            shellcheck
            ruff
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
            actionlint
            shellcheck
            ruff
            nghttp2
            ripgrep
          ];
        };

        formatter = treefmtEval.config.build.wrapper;

        checks.formatting = treefmtEval.config.build.check ./.;
        checks.tooling =
          pkgs.runCommand "http-gun-tooling"
            {
              nativeBuildInputs = [
                pkgs.actionlint
                pkgs.shellcheck
                pkgs.ruff
              ];
            }
            ''
              cd ${./.}
              actionlint -shellcheck=${pkgs.shellcheck}/bin/shellcheck .github/workflows/*.yml
              shellcheck --shell=sh dev/env dev/gate dev/matrix dev/linux-gate dev/consumers dev/async-consumer dev/ip-fixture .envrc
              ruff check --no-cache dev
              touch "$out"
            '';
      }
    );
}
