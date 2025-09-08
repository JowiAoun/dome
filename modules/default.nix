{ lib, ... }:

{
  imports = [
    ./python.nix
    ./node.nix
    ./java.nix
    ./ai.nix
    ./cloud.nix
  ];

  options = {
    modules = {
      python.enable = lib.mkEnableOption "Python development environment";
      node.enable = lib.mkEnableOption "Node.js development environment";
      java.enable = lib.mkEnableOption "Java development environment";
      ai.enable = lib.mkEnableOption "AI development tools (Claude, Ollama, Copilot, etc.)";
      cloud.enable = lib.mkEnableOption "Cloud development tools (Terraform, Pulumi, AWS CLI, etc.)";
    };
    
    user = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "User's full name";
      };
      email = lib.mkOption {
        type = lib.types.str;
        description = "User's email address";
      };
    };
  };
}