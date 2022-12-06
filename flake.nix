{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    # `import-cargo` is still used for the WASM build for now, though we expect to get rid of it in the future.
    # See https://github.com/tweag/nickel/issues/967
    import-cargo.url = "github:edolstra/import-cargo";
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  nixConfig = {
    extra-substituters = [ "https://tweag-nickel.cachix.org" ];
    extra-trusted-public-keys = [ "tweag-nickel.cachix.org-1:GIthuiK4LRgnW64ALYEoioVUQBWs0jexyoYVeLDBwRA=" ];
  };

  outputs =
    { self
    , nixpkgs
    , flake-utils
    , pre-commit-hooks
    , rust-overlay
    , import-cargo
    , crane
    }:
    let
      SYSTEMS = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      RUST_CHANNELS = [
        "stable"
        "beta"
      ];

      forEachRustChannel = fn: builtins.listToAttrs (builtins.map fn RUST_CHANNELS);

      cargoTOML = builtins.fromTOML (builtins.readFile ./Cargo.toml);

      version = "${cargoTOML.package.version}_${builtins.substring 0 8 self.lastModifiedDate}_${self.shortRev or "dirty"}";

      customOverlay = final: prev: {
        # The version of `wasm-bindgen` CLI *must* be the same as the `wasm-bindgen` Rust dependency in `Cargo.toml`.
        # The definition of `wasm-bindgen-cli` in Nixpkgs does not allow overriding directly the attrset passed to `buildRustPackage`.
        # We instead override the attrset that `buildRustPackage` generates and passes to `mkDerivation`.
        # See https://discourse.nixos.org/t/is-it-possible-to-override-cargosha256-in-buildrustpackage/4393
        wasm-bindgen-cli = prev.wasm-bindgen-cli.overrideAttrs (oldAttrs:
          let
            wasmBindgenCargoVersion = cargoTOML.dependencies.wasm-bindgen.version;
            # Remove the pinning `=` prefix of the version
            wasmBindgenVersion = builtins.substring 1 (builtins.stringLength wasmBindgenCargoVersion) wasmBindgenCargoVersion;
          in
          rec {
            pname = "wasm-bindgen-cli";
            version = wasmBindgenVersion;

            src = final.fetchCrate {
              inherit pname version;
              sha256 = "sha256-+PWxeRL5MkIfJtfN3/DjaDlqRgBgWZMa6dBt1Q+lpd0=";
            };

            cargoDeps = oldAttrs.cargoDeps.overrideAttrs (final.lib.const {
              # This `inherit src` is important, otherwise, the old `src` would be used here
              inherit src;
              outputHash = "sha256-GwLeA6xLt7I+NzRaqjwVpt1pzRex1/snq30DPv4FR+g=";
            });
          });
      };

    in
    flake-utils.lib.eachSystem SYSTEMS (system:
    let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          (import rust-overlay)
          customOverlay
        ];
      };

      cargoHome = (import-cargo.builders.importCargo {
        lockFile = ./Cargo.lock;
        inherit pkgs;
      }).cargoHome;

      # Additional packages required for some systems to build Nickel
      missingSysPkgs =
        if pkgs.stdenv.isDarwin then
          [
            pkgs.darwin.apple_sdk.frameworks.Security
            pkgs.darwin.libiconv
          ]
        else
          [ ];

      mkRust =
        { rustProfile ? "minimal"
        , rustExtensions ? [
            "rust-src"
            "rust-analysis"
            "rustfmt"
            "clippy"
          ]
        , channel ? "stable"
        , target ? pkgs.rust.toRustTarget pkgs.stdenv.hostPlatform
        }:
        if channel == "nightly" then
          pkgs.rust-bin.selectLatestNightlyWith
            (toolchain: toolchain.${rustProfile}.override {
              extensions = rustExtensions;
              targets = [ target ];
            })
        else
          pkgs.rust-bin.${channel}.latest.${rustProfile}.override {
            extensions = rustExtensions;
            targets = [ target ];
          };

      # A note on check_format: the way we invoke rustfmt here works locally but fails on CI.
      # Since the formatting is checked on CI anyway - as part of the rustfmt check - we
      # disable rustfmt in the pre-commit hook when running checks, but enable it when
      # running in a dev shell.
      pre-commit-builder = { rust ? mkRust { }, checkFormat ? false }: pre-commit-hooks.lib.${system}.run {
        src = self;
        hooks = {
          nixpkgs-fmt = {
            enable = true;
            # Excluded because they are generated by Node2nix
            excludes = [
              "lsp/client-extension/default.nix"
              "lsp/client-extension/node-env.nix"
              "lsp/client-extension/node-packages.nix"
            ];
          };

          rustfmt = {
            enable = checkFormat;
            entry = pkgs.lib.mkForce "${rust}/bin/cargo-fmt fmt -- --check --color always";
          };

          markdownlint = {
            enable = true;
            excludes = [
              "notes/(.+)\\.md$"
              "^RELEASES\\.md$"
            ];
          };

        };
      };

      # Build the various Crane artifacts (dependencies, packages, rustfmt, clippy) for a given Rust toolchain
      mkCraneArtifacts = { rust ? mkRust { } }:
        let
          craneLib = crane.lib.${system}.overrideToolchain rust;

          # Customize source filtering as Nickel uses non-standard-Rust files like `*.lalrpop`.
          src =
            let
              mkFilter = regexp: path: _type: builtins.match regexp path != null;
              lalrpopFilter = mkFilter ".*lalrpop$";
              nclFilter = mkFilter ".*ncl$";
              txtFilter = mkFilter ".*txt$";
            in
            pkgs.lib.cleanSourceWith {
              src = pkgs.lib.cleanSource ./.;

              # Combine our custom filters with the default one from Crane
              # See https://github.com/ipetkov/crane/blob/master/docs/API.md#libfiltercargosources
              filter = path: type:
                builtins.any (filter: filter path type) [
                  lalrpopFilter
                  nclFilter
                  txtFilter
                  craneLib.filterCargoSources
                ];
            };

          # Args passed to all `cargo` invocations by Crane.
          cargoExtraArgs = "--frozen --offline --workspace";

        in
        rec {
          # Build *just* the cargo dependencies, so we can reuse all of that work (e.g. via cachix) when running in CI
          cargoArtifacts = craneLib.buildDepsOnly {
            inherit
              src
              cargoExtraArgs;
          };

          nickel = craneLib.buildPackage {
            inherit
              src
              cargoExtraArgs
              cargoArtifacts;
          };

          rustfmt = craneLib.cargoFmt {
            # Notice that unlike other Crane derivations, we do not pass `cargoArtifacts` to `cargoFmt`, because it does not need access to dependencies to format the code.
            inherit src;

            # We don't reuse the `cargoExtraArgs` in scope because `cargo fmt` does not accept nor need any of `--frozen`, `--offline` or `--workspace`
            cargoExtraArgs = "--all";

            # `-- --check` is automatically prepended by Crane
            rustFmtExtraArgs = "--color always";
          };

          clippy = craneLib.cargoClippy {
            inherit
              src
              cargoExtraArgs
              cargoArtifacts;

            cargoClippyExtraArgs = "--all-targets -- --deny warnings --allow clippy::new-without-default --allow clippy::match_like_matches_macro";
          };

        };

      makeDevShell = { rust }: pkgs.mkShell {
        # Trick found in Crane's examples to get a nice dev shell
        # See https://github.com/ipetkov/crane/blob/master/examples/quick-start/flake.nix
        inputsFrom = builtins.attrValues (mkCraneArtifacts { inherit rust; });

        buildInputs = [
          pkgs.rust-analyzer
          pkgs.nodejs
          pkgs.node2nix
          pkgs.nodePackages.markdownlint-cli
        ];

        shellHook = (pre-commit-builder { inherit rust; checkFormat = true; }).shellHook + ''
          echo "=== Nickel development shell ==="
          echo "Info: Git hooks can be installed using \`pre-commit install\`"
        '';

        RUST_SRC_PATH = "${rust}/lib/rustlib/src/rust/library";
      };

      buildNickelWasm =
        { rust ? mkRust { target = "wasm32-unknown-unknown"; }
        , optimize ? true
        }:
        pkgs.stdenv.mkDerivation {
          name = "nickel-wasm-${version}";

          src = self;

          buildInputs = [
            rust
            pkgs.wasm-pack
            pkgs.wasm-bindgen-cli
            pkgs.binaryen
            cargoHome
          ] ++ missingSysPkgs;

          buildPhase = ''
            cd nickel-wasm-repl
            wasm-pack build --mode no-install -- --no-default-features --frozen --offline
            # Because of wasm-pack not using existing wasm-opt
            # (https://github.com/rustwasm/wasm-pack/issues/869), we have to
            # run wasm-opt manually
            echo "[Nix build script] Manually running wasm-opt..."
            wasm-opt ${if optimize then "-O4 " else "-O0"} pkg/nickel_repl_bg.wasm -o pkg/nickel_repl.wasm
          '';

          installPhase = ''
            mkdir -p $out
            cp -r pkg $out/nickel-repl
          '';
        };

      buildDocker = nickel: pkgs.dockerTools.buildLayeredImage {
        name = "nickel";
        tag = version;
        contents = [
          nickel
          pkgs.bashInteractive
        ];
        config = {
          Cmd = "bash";
        };
      };

      vscodeExtension =
        let node-package = (pkgs.callPackage ./lsp/client-extension { }).package;
        in
        (node-package.override rec {
          pname = "nls-client";
          outputs = [ "vsix" "out" ];
          nativeBuildInputs = with pkgs; [
            # `vsce` depends on `keytar`, which depends on `pkg-config` and `libsecret`
            pkg-config
            libsecret
          ];
          postInstall = ''
            npm run compile
            mkdir -p $vsix
            echo y | npx vsce package -o $vsix/${pname}.vsix
          '';
        }).vsix;

      userManual = pkgs.stdenv.mkDerivation {
        name = "nickel-user-manual-${version}";
        src = ./doc/manual;
        installPhase = ''
          mkdir -p $out
          cp -r ./ $out
        '';
      };

      stdlibDoc = pkgs.stdenv.mkDerivation {
        name = "nickel-stdlib-doc-${version}";
        src = ./stdlib;
        installPhase = ''
          mkdir -p $out
          for file in *
          do
            module=$(basename $file .ncl)
            ${self.packages."${system}".default}/bin/nickel doc -f "$module.ncl" \
              --output "$out/$module.md"
          done
        '';
      };

    in
    rec {
      packages = {
        nickel = (mkCraneArtifacts { }).nickel;
        default = packages.nickel;
        nickelWasm = buildNickelWasm { };
        dockerImage = buildDocker packages.nickel; # TODO: docker image should be a passthru
        inherit vscodeExtension;
        inherit userManual;
        inherit stdlibDoc;
      };

      devShells = (forEachRustChannel (channel: {
        name = channel;
        value = makeDevShell { rust = mkRust { inherit channel; rustProfile = "default"; }; };
      })) // {
        default = devShells.stable;
      };

      checks = {
        inherit (mkCraneArtifacts { })
          nickel
          clippy
          rustfmt;
        # wasm-opt can take long: eschew optimizations in checks
        nickelWasm = buildNickelWasm { optimize = false; };
        inherit vscodeExtension;
        pre-commit = pre-commit-builder { };
      };
    }
    );
}
