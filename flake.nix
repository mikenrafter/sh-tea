{
  description = "sh-tea — transparent pipeline stage logger (tee pun) for stdin→stdout filters; CLI is `tea` for short, `sh-tea` ships as an alias";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
    lib = nixpkgs.lib;
    pkgs = import nixpkgs { inherit system; };

    filterTools = import ./tools.nix { inherit pkgs; };

    # Package builder, parameterized by user-defined extra wraps: extraTools
    # maps a tool name to the real binary's outpath (e.g. a store path like
    # "${pkgs.ripgrep}/bin/rg", never an env-resolved path). Entries merge
    # into tools.nix's
    # canonical list, so each gets a wrapper binary that lands on PATH
    # everywhere the package is installed, plus a [tools.<name>] config
    # section and completions. The runtime-only equivalent — TEA_EXTRA_TOOLS,
    # turned into shadow functions by the fish hook in interactive shells
    # only — lives in hooks/tea-extra-tools.fish.
    mkTea =
      { extraTools ? { } }:
      let
        allTools = filterTools // extraTools;
        toolNames = lib.sort lib.lessThan (lib.attrNames allTools);

        toolsJson = pkgs.writeText "tea-tools.json" (builtins.toJSON allTools);

        defaultConfigToml =
          let
            toolSections = lib.concatMapStrings (name: ''
              [tools.${name}]
              enabled = true
            '') toolNames;
          in
          pkgs.writeText "tea-default-config.toml" ''
            # tea — transparent pipeline logger
            # Copied to $XDG_CONFIG_HOME/tea/config.toml on first use when missing.

            [defaults]
            # When true, activate in interactive sessions (stderr is a TTY) without --tea.
            default-interactive = true
            # When true, ONLY --tea activates (ignore interactive + agentic auto-detect).
            manual-only = false
            # Append logs.csv to .gitignore when logging in a git work tree.
            update-gitignore = true
            # Keep at most this many rows in ./logs.csv (oldest dropped; .tea files removed).
            max-log-records = 20
            # Suppress the stderr blurb that announces the log path.
            quiet = false
            # Post-activation filter: drop the log if the stage's own elapsed
            # wall-clock time was under this many ms. Only applies to auto-detected
            # activation (agentic/interactive); --tea/TEA_FORCE always log.
            min-duration-ms = 5000
            # Restrict activation by git context (both false = anywhere).
            only-in-git-repos = false
            only-outside-git-repos = false

            # Per-tool overrides inherit defaults; set enabled = false to disable a wrap.
            ${toolSections}
          '';

        teaRust = pkgs.rustPlatform.buildRustPackage {
          pname = "tea";
          version = "0.1.0";
          src = lib.cleanSourceWith {
            src = ./.;
            filter =
              path: type:
              let
                base = baseNameOf path;
              in
              (lib.cleanSourceFilter path type)
              && !(builtins.elem base [
                "flake.nix"
                "flake.lock"
                "man"
                "tools.nix"
                "target"
                "tests"
              ]);
          };
          cargoLock.lockFile = ./Cargo.lock;
          doCheck = false;
          meta = with lib; {
            description = "Transparent pipeline stage logger for stdin→stdout filters";
            license = licenses.mit;
            mainProgram = "tea";
          };
        };

        mkWrap =
          tool: real:
          pkgs.writeScriptBin tool ''
            #!${pkgs.runtimeShell}
            export TEA_DEFAULT_CONFIG="${defaultConfigToml}"
            export TEA_TOOLS_JSON="${toolsJson}"
            exec ${teaRust}/bin/tea-wrap ${tool} ${real} "$@"
          '';

        wrapPkgs = lib.mapAttrsToList (name: real: mkWrap name real) allTools;

        teaCli = pkgs.writeScriptBin "tea" ''
          #!${pkgs.runtimeShell}
          export TEA_DEFAULT_CONFIG="${defaultConfigToml}"
          export TEA_TOOLS_JSON="${toolsJson}"
          exec ${teaRust}/bin/tea "$@"
        '';

        # sh-tea is a plain alias for tea — same CLI, same env vars, same config —
        # kept around so the project name also works as a command.
        teaAlias = pkgs.writeScriptBin "sh-tea" ''
          #!${pkgs.runtimeShell}
          export TEA_DEFAULT_CONFIG="${defaultConfigToml}"
          export TEA_TOOLS_JSON="${toolsJson}"
          exec ${teaRust}/bin/tea "$@"
        '';

        teaMan = pkgs.runCommand "tea-man" { } ''
          mkdir -p $out/share/man/man1
          cp ${./man/tea.1} $out/share/man/man1/tea.1
          ln -s tea.1 $out/share/man/man1/sh-tea.1
        '';

        # Completions: generate fish loop + bash complete lines from toolNames.
        fishCompletion = pkgs.writeText "tea.fish" (
          ''
            # fish completions for tea wrappers — additive flags only
            for cmd in ${lib.concatStringsSep " " toolNames}
                complete -c $cmd -l tea -d 'tea: enable transparent pipeline logging'
                complete -c $cmd -l no-tea -d 'tea: disable transparent pipeline logging'
                complete -c $cmd -l coffee -d 'tea: disable transparent pipeline logging (alias)'
            end

          ''
          + lib.concatMapStrings (cmd: ''
            complete -c ${cmd} -f
            complete -c ${cmd} -n __fish_use_subcommand -a last -d 'Print path of most recent logfile'
            complete -c ${cmd} -n __fish_use_subcommand -a list -d 'Print logs.csv'
            complete -c ${cmd} -n __fish_use_subcommand -a show -d 'Print a logfile (optional id)'
            complete -c ${cmd} -n __fish_use_subcommand -a config -d 'Ensure/print config.toml path'
            complete -c ${cmd} -n __fish_use_subcommand -a which -d 'Debug activation for a tool'
            complete -c ${cmd} -n '__fish_seen_subcommand_from which' -a '${lib.concatStringsSep " " toolNames}'
          '') [ "tea" "sh-tea" ]
        );

        bashCompletion = pkgs.writeText "tea.bash" (
          ''
            # bash completions for tea/sh-tea CLI + light --tea/--coffee hints on wrappers.
            _tea_cli() {
              local cur="''${COMP_WORDS[COMP_CWORD]}"
              local prev="''${COMP_WORDS[COMP_CWORD-1]}"
              if [[ $COMP_CWORD -eq 1 ]]; then
                COMPREPLY=( $(compgen -W "last list show config which -h --help" -- "$cur") )
                return
              fi
              if [[ $prev == which ]]; then
                COMPREPLY=( $(compgen -W "${lib.concatStringsSep " " toolNames}" -- "$cur") )
                return
              fi
            }

            _tea_wrap_flags() {
              local cur="''${COMP_WORDS[COMP_CWORD]}"
              case "$cur" in
                --tea*|--no-tea*|--coffee*|--cof*)
                  COMPREPLY=( $(compgen -W "--tea --no-tea --coffee" -- "$cur") )
                  ;;
              esac
            }

            complete -F _tea_cli tea
            complete -F _tea_cli sh-tea
          ''
          + lib.concatMapStrings (name: ''
            complete -F _tea_wrap_flags -o bashdefault -o default ${name}
          '') toolNames
        );

        teaCompletions = pkgs.runCommand "tea-completions" { } ''
          mkdir -p $out/share/bash-completion/completions
          mkdir -p $out/share/fish/vendor_completions.d
          cp ${bashCompletion} $out/share/bash-completion/completions/tea
          cp ${bashCompletion} $out/share/bash-completion/completions/sh-tea
          ${lib.concatMapStrings (name: ''
            cp ${bashCompletion} $out/share/bash-completion/completions/${name}
          '') toolNames}
          cp ${fishCompletion} $out/share/fish/vendor_completions.d/tea.fish
          cp ${fishCompletion} $out/share/fish/vendor_completions.d/sh-tea.fish
        '';

        teaHooks = pkgs.runCommand "tea-hooks" { } ''
          mkdir -p $out/share/fish/vendor_conf.d $out/share/fish/vendor_functions.d
          cp ${./hooks/grep.fish} $out/share/fish/vendor_functions.d/grep.fish
          cp ${./hooks/tea-user-pipe.fish} $out/share/fish/vendor_conf.d/tea-user-pipe.fish
          cp ${./hooks/tea-extra-tools.fish} $out/share/fish/vendor_conf.d/tea-extra-tools.fish
        '';

        # tea-wrap itself: the fish hook's TEA_EXTRA_TOOLS shadow functions exec
        # it via PATH (command tea-wrap), so the internal binary ships alongside
        # the wrappers instead of living only in the teaRust store path.
        teaWrapBin = pkgs.runCommand "tea-wrap-bin" { } ''
          mkdir -p $out/bin
          ln -s ${teaRust}/bin/tea-wrap $out/bin/tea-wrap
        '';

        teaPkg = pkgs.symlinkJoin {
          name = "tea-0.1.0";
          paths = [ teaCli teaAlias teaMan teaCompletions teaHooks teaWrapBin ] ++ wrapPkgs;
          meta = with lib; {
            description = "Transparent pipeline stage logger for stdin→stdout filters";
            mainProgram = "tea";
            license = licenses.mit;
          };
        };
      in
      lib.hiPrio teaPkg;
  in
  {
    overlays.default = final: prev: {
      sh-tea = self.packages.${prev.system}.sh-tea;
    };

    # .override { extraTools = { rg = "${pkgs.ripgrep}/bin/rg"; }; } adds
    # user-defined wraps at build time — wrapper binaries on PATH everywhere.
    packages.${system}.sh-tea = lib.makeOverridable mkTea { };

    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [
        cargo
        rustc
        gcc
        rust-analyzer
      ];
    };
  };
}
