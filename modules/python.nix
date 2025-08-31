{ config, lib, pkgs, ... }:

let
  cfg = config.modules.python;
in
{
  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [
      python3
      python3Packages.pip
      python3Packages.virtualenv
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
  };
}