{
  description = "sh-tea — transparent pipeline stage logger (tee pun) for stdin→stdout filters";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
    lib = nixpkgs.lib;
    pkgs = import nixpkgs { inherit system; };

    filterTools = import ./tools.nix { inherit pkgs; };
    toolNames = lib.sort lib.lessThan (lib.attrNames filterTools);

    toolsJson = pkgs.writeText "sh-tea-tools.json" (builtins.toJSON filterTools);

    defaultConfigToml =
      let
        toolSections = lib.concatMapStrings (name: ''
          [tools.${name}]
          enabled = true
        '') toolNames;
      in
      pkgs.writeText "sh-tea-default-config.toml" ''
        # sh-tea — transparent pipeline logger
        # Copied to $XDG_CONFIG_HOME/sh-tea/config.toml on first use when missing.

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
        # Restrict activation by git context (both false = anywhere).
        only-in-git-repos = false
        only-outside-git-repos = false

        # Per-tool overrides inherit defaults; set enabled = false to disable a wrap.
        ${toolSections}
      '';

    shTeaRust = pkgs.rustPlatform.buildRustPackage {
      pname = "sh-tea";
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
        mainProgram = "sh-tea";
      };
    };

    mkWrap =
      tool: real:
      pkgs.writeScriptBin tool ''
        #!${pkgs.runtimeShell}
        export SH_TEA_DEFAULT_CONFIG="${defaultConfigToml}"
        export SH_TEA_TOOLS_JSON="${toolsJson}"
        exec ${shTeaRust}/bin/sh-tea-wrap ${tool} ${real} "$@"
      '';

    wrapPkgs = lib.mapAttrsToList (name: real: mkWrap name real) filterTools;

    shTeaCli = pkgs.writeScriptBin "sh-tea" ''
      #!${pkgs.runtimeShell}
      export SH_TEA_DEFAULT_CONFIG="${defaultConfigToml}"
      export SH_TEA_TOOLS_JSON="${toolsJson}"
      exec ${shTeaRust}/bin/sh-tea "$@"
    '';

    shTeaMan = pkgs.runCommand "sh-tea-man" { } ''
      mkdir -p $out/share/man/man1
      cp ${./man/sh-tea.1} $out/share/man/man1/sh-tea.1
    '';

    # Completions: generate fish loop + bash complete lines from toolNames.
    fishCompletion = pkgs.writeText "sh-tea.fish" (
      ''
        # fish completions for sh-tea wrappers — additive flags only
        for cmd in ${lib.concatStringsSep " " toolNames}
            complete -c $cmd -l tea -d 'sh-tea: enable transparent pipeline logging'
            complete -c $cmd -l no-tea -d 'sh-tea: disable transparent pipeline logging'
            complete -c $cmd -l coffee -d 'sh-tea: disable transparent pipeline logging (alias)'
        end

        complete -c sh-tea -f
        complete -c sh-tea -n __fish_use_subcommand -a last -d 'Print path of most recent logfile'
        complete -c sh-tea -n __fish_use_subcommand -a list -d 'Print logs.csv'
        complete -c sh-tea -n __fish_use_subcommand -a show -d 'Print a logfile (optional id)'
        complete -c sh-tea -n __fish_use_subcommand -a config -d 'Ensure/print config.toml path'
        complete -c sh-tea -n __fish_use_subcommand -a which -d 'Debug activation for a tool'
        complete -c sh-tea -n '__fish_seen_subcommand_from which' -a '${lib.concatStringsSep " " toolNames}'
      ''
    );

    bashCompletion = pkgs.writeText "sh-tea.bash" (
      ''
        # bash completions for sh-tea CLI + light --tea/--coffee hints on wrappers.
        _sh_tea_cli() {
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

        _sh_tea_wrap_flags() {
          local cur="''${COMP_WORDS[COMP_CWORD]}"
          case "$cur" in
            --tea*|--no-tea*|--coffee*|--cof*)
              COMPREPLY=( $(compgen -W "--tea --no-tea --coffee" -- "$cur") )
              ;;
          esac
        }

        complete -F _sh_tea_cli sh-tea
      ''
      + lib.concatMapStrings (name: ''
        complete -F _sh_tea_wrap_flags -o bashdefault -o default ${name}
      '') toolNames
    );

    shTeaCompletions = pkgs.runCommand "sh-tea-completions" { } ''
      mkdir -p $out/share/bash-completion/completions
      mkdir -p $out/share/fish/vendor_completions.d
      cp ${bashCompletion} $out/share/bash-completion/completions/sh-tea
      ${lib.concatMapStrings (name: ''
        cp ${bashCompletion} $out/share/bash-completion/completions/${name}
      '') toolNames}
      cp ${fishCompletion} $out/share/fish/vendor_completions.d/sh-tea.fish
    '';

    shTeaPkg = pkgs.symlinkJoin {
      name = "sh-tea-0.1.0";
      paths = [ shTeaCli shTeaMan shTeaCompletions ] ++ wrapPkgs;
      meta = with lib; {
        description = "Transparent pipeline stage logger for stdin→stdout filters";
        mainProgram = "sh-tea";
        license = licenses.mit;
      };
    };
  in
  {
    overlays.default = final: prev: {
      sh-tea = self.packages.${prev.system}.sh-tea;
    };

    packages.${system}.sh-tea = lib.hiPrio shTeaPkg;

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
