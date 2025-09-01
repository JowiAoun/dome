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
      extensions = with pkgs.vscode-extensions; [
        ms-python.python
        ms-python.vscode-pylance
        ms-python.black-formatter
        ms-python.flake8
      ];
    };

    home.sessionVariables = {
      PYTHONPATH = "$HOME/.local/lib/python3.11/site-packages:$PYTHONPATH";
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
        eval "$(pyenv virtualenv-init -)"
      fi
    '';

    programs.zsh.initExtra = lib.mkIf config.programs.zsh.enable ''
      # Initialize pyenv
      if command -v pyenv >/dev/null 2>&1; then
        export PYENV_ROOT="$HOME/.pyenv"
        export PATH="$PYENV_ROOT/bin:$PATH"
        eval "$(pyenv init - zsh)"
        eval "$(pyenv virtualenv-init -)"
      fi
    '';
  };
}