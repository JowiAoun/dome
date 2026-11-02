# inkscape-mcp: an MCP server that lets Claude Code drive Inkscape, headless
# from the command line or live in an open Inkscape window over D-Bus.
# https://github.com/aravindev/inkscape_mcp
#
# Built here because `uvx inkscape_mcp`, the upstream install, compiles
# PyGObject from source, which needs cairo and gobject-introspection headers
# from apt. Nix already has PyGObject built.
#
# Called from the nixpkgs-inkscape pin in flake.nix, so the server and the
# Inkscape it runs come from the same nixpkgs. Upstream tests on Inkscape 1.4.4.
{ lib, python3, fetchPypi, inkscape }:

let
  # fastmcp 3 needs mcp 1.x. nixpkgs moved mcp to 2.x and marks fastmcp broken
  # on it, so this set goes back to mcp_1. Their tests are skipped because the
  # changed mcp means Hydra has no cached build, and they take a long time.
  python = python3.override {
    self = python;
    packageOverrides = pyself: pysuper: {
      mcp = pysuper.mcp_1;
      fastmcp-slim = pysuper.fastmcp-slim.overridePythonAttrs { doCheck = false; };
      fastmcp = pysuper.fastmcp.overridePythonAttrs { doCheck = false; };
    };
  };
  python3Packages = python.pkgs;

  # Not in nixpkgs. fastmcp's UI helpers, needed by the server's tools.
  prefab-ui = python3Packages.buildPythonPackage rec {
    pname = "prefab-ui";
    version = "0.21.1";
    format = "wheel";
    src = fetchPypi {
      pname = "prefab_ui";
      inherit version format;
      dist = "py3";
      python = "py3";
      hash = "sha256-lBhekDJHXsGzSPxw4julMo9FgnnguK+XKqfHVf+TAdM=";
    };
    dependencies = with python3Packages; [ cyclopts pydantic rich ];
    pythonImportsCheck = [ "prefab_ui" ];
  };
in
python3Packages.buildPythonApplication rec {
  pname = "inkscape-mcp";
  version = "1.3.1";
  format = "wheel";

  src = fetchPypi {
    pname = "inkscape_mcp";
    inherit version format;
    dist = "py3";
    python = "py3";
    hash = "sha256-slaZgLlTV5VT+4vQCdToB6PGrYqhJyu/Tb001Wfl7J0=";
  };

  dependencies = with python3Packages; [
    fastmcp
    inkex
    jeepney
    loguru
    mcp
    pillow
    prefab-ui
    pydantic
    pyyaml
    scour
  ];

  # Upstream caps a few versions below what nixpkgs ships.
  pythonRelaxDeps = true;

  # Run this Inkscape rather than whichever one is first on PATH. Clear
  # LD_LIBRARY_PATH for the same reason the Inkscape wrapper in flake.nix does:
  # the zsh setup in home.nix fills it with older libraries.
  makeWrapperArgs = [
    "--set-default" "INKSCAPE_BIN" "${inkscape}/bin/inkscape"
    "--unset" "LD_LIBRARY_PATH"
  ];

  pythonImportsCheck = [ "inkscape_mcp" ];

  meta = {
    description = "MCP server that drives Inkscape, headless or in a live window";
    homepage = "https://github.com/aravindev/inkscape_mcp";
    license = lib.licenses.mit;
    mainProgram = "inkscape-mcp";
  };
}
