{ lib, ... }:

{
  imports = [
    ./python.nix
    ./node.nix
    ./java.nix
  ];

  options = {
    modules = {
      python.enable = lib.mkEnableOption "Python development environment";
      node.enable = lib.mkEnableOption "Node.js development environment";
      java.enable = lib.mkEnableOption "Java development environment";
    };
  };
}