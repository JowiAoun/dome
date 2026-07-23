{ config, lib, pkgs, ... }:

let
  cfg = config.modules.python;
in
{
  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [
      (python3.withPackages (ps: with ps; [
        pip
        virtualenv
        setuptools
      ]))
      pyenv
      pipx
    ];

    # VS Code extensions for Python development
    programs.vscode = lib.mkIf config.programs.vscode.enable {
      profiles.default = {
        extensions = with pkgs.vscode-extensions; [
          ms-python.python
          ms-python.vscode-pylance
          ms-python.black-formatter
          ms-python.flake8
        ];

        userSettings = {
          "python.defaultInterpreterPath" = "python";
          "python.terminal.activateEnvironment" = true;
          "python.venvPath" = "./venv";
          "python.venvFolders" = [ "envs" ".pyenv" ".direnv" "venv" ".venv" ];
          "python.analysis.autoSearchPaths" = true;
          "python.analysis.extraPaths" = [];
          "python.analysis.autoImportCompletions" = true;
        };
      };
    };

    home.sessionVariables = {
      # Derive the interpreter dir from the package so it never drifts (was a
      # hardcoded python3.11, but pkgs.python3 is 3.13 — the old path was dead).
      # Append the existing value only when there IS one: a bare ":$PYTHONPATH"
      # leaves a trailing colon when it is unset (the normal case at login), and
      # CPython reads an empty PYTHONPATH entry as the CURRENT DIRECTORY — so a
      # stray requests.py in whatever directory you happen to be in would shadow
      # the real module for every python process. Same idiom home.nix uses for
      # LD_LIBRARY_PATH/PKG_CONFIG_PATH.
      PYTHONPATH = "$HOME/.local/${pkgs.python3.sitePackages}\${PYTHONPATH:+:$PYTHONPATH}";
      PYENV_ROOT = "$HOME/.pyenv";
    };

    home.file.".config/pycodestyle".text = ''
      [pycodestyle]
      max-line-length = 88
      ignore = E203,W503
    '';

    programs.bash.shellAliases = lib.mkIf config.programs.bash.enable {
      py = "python3";
      pip = "python3 -m pip";
      venv = "python3 -m venv";
    };

    # Initialize pyenv in shell
    programs.bash.initExtra = lib.mkIf config.programs.bash.enable ''
      # Initialize pyenv
      if command -v pyenv >/dev/null 2>&1; then
        export PYENV_ROOT="$HOME/.pyenv"
        export PATH="$PYENV_ROOT/bin:$PATH"
        eval "$(pyenv init - bash)"
        # pyenv-virtualenv is an optional plugin (cloned by the activation below);
        # only initialize it once present, else it errors on every new shell.
        if [ -d "$PYENV_ROOT/plugins/pyenv-virtualenv" ]; then
          eval "$(pyenv virtualenv-init -)"
        fi
      fi
    '';

    programs.zsh.initContent = lib.mkIf config.programs.zsh.enable ''
      # Initialize pyenv
      if command -v pyenv >/dev/null 2>&1; then
        export PYENV_ROOT="$HOME/.pyenv"
        export PATH="$PYENV_ROOT/bin:$PATH"
        eval "$(pyenv init - zsh)"
        # pyenv-virtualenv is an optional plugin (cloned by the activation below);
        # only initialize it once present, else it errors on every new shell.
        if [ -d "$PYENV_ROOT/plugins/pyenv-virtualenv" ]; then
          eval "$(pyenv virtualenv-init -)"
        fi
      fi
    '';

    # Install the pyenv-virtualenv plugin (provides `pyenv virtualenv` and the
    # `virtualenv-init` used above), mirroring the node-build clone in node.nix.
    # Honors DRY_RUN_CMD (a dry-run switch must not clone into $HOME) and never
    # aborts the switch on a network failure — the activation script runs under
    # `set -eu -o pipefail`, so an unguarded failed clone would kill every later
    # activation entry and leave a half-applied generation. Same shape as
    # ai.nix's installClaudeCode.
    home.activation.pyenvPlugins = lib.hm.dag.entryAfter ["writeBoundary"] ''
      PYENV_ROOT="$HOME/.pyenv"
      PLUGIN_DIR="$PYENV_ROOT/plugins/pyenv-virtualenv"
      if [ ! -d "$PLUGIN_DIR" ]; then
        if [ -n "''${DRY_RUN_CMD:-}" ]; then
          echo "(dry run) would clone pyenv-virtualenv into $PLUGIN_DIR"
        else
          echo "Installing pyenv-virtualenv plugin for pyenv..."
          mkdir -p "$PYENV_ROOT/plugins"
          if ${pkgs.git}/bin/git clone https://github.com/pyenv/pyenv-virtualenv.git "$PLUGIN_DIR"; then
            echo "pyenv-virtualenv plugin installed"
          else
            echo "⚠️ pyenv-virtualenv clone failed (network?) — re-run 'make home' later" >&2
          fi
        fi
      fi
    '';
  };
}