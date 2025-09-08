{ config, lib, pkgs, ... }:

let
  cfg = config.modules.cloud;
in
{
  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [
      # Infrastructure as Code Tools
      terraform
      pulumi
      terraform-ls
      
      # Cloud Provider CLIs
      awscli2
      azure-cli
      google-cloud-sdk
      oci-cli
      
      # Container & Kubernetes Tools
      kubectl
      kubernetes-helm  # Kubernetes package manager, not audio synthesizer
      docker
    ];

    # VS Code extensions for cloud development
    programs.vscode = lib.mkIf config.programs.vscode.enable {
      extensions = with pkgs.vscode-extensions; [
        hashicorp.terraform
        ms-kubernetes-tools.vscode-kubernetes-tools
        ms-azuretools.vscode-docker
      ];
      
      userSettings = {
        "terraform.languageServer.enable" = true;
        "terraform.validation.enable" = true;
        "terraform.codelens.referenceCount" = true;
        "kubernetes.kubectl-path.linux" = "${pkgs.kubectl}/bin/kubectl";
      };
    };

    home.sessionVariables = {
      # Terraform
      TF_PLUGIN_CACHE_DIR = "$HOME/.terraform.d/plugin-cache";
      
      # Pulumi
      PULUMI_HOME = "$HOME/.pulumi";
      
      # Kubernetes
      KUBECONFIG = "$HOME/.kube/config";
      
      # Google Cloud SDK
      CLOUDSDK_PYTHON = "${pkgs.python3}/bin/python3";
    };

    # Create plugin cache directory for Terraform
    home.file.".terraform.d/plugin-cache/.keep".text = "";

    programs.bash.shellAliases = lib.mkIf config.programs.bash.enable {
      # Terraform shortcuts
      tf = "terraform";
      tfa = "terraform apply";
      tfp = "terraform plan";
      tfi = "terraform init";
      tfd = "terraform destroy";
      
      # Kubernetes shortcuts  
      k = "kubectl";
      kgp = "kubectl get pods";
      kgs = "kubectl get svc";
      kgd = "kubectl get deployments";
      kdp = "kubectl describe pod";
      kds = "kubectl describe svc";
      
      # Docker shortcuts
      d = "docker";
      dc = "docker-compose";
      
      # Pulumi shortcuts
      pu = "pulumi";
      puu = "pulumi up";
      pud = "pulumi destroy";
      pus = "pulumi stack";
    };

    programs.zsh.shellAliases = lib.mkIf config.programs.zsh.enable {
      # Terraform shortcuts
      tf = "terraform";
      tfa = "terraform apply";
      tfp = "terraform plan";
      tfi = "terraform init";
      tfd = "terraform destroy";
      
      # Kubernetes shortcuts  
      k = "kubectl";
      kgp = "kubectl get pods";
      kgs = "kubectl get svc";
      kgd = "kubectl get deployments";
      kdp = "kubectl describe pod";
      kds = "kubectl describe svc";
      
      # Docker shortcuts
      d = "docker";
      dc = "docker-compose";
      
      # Pulumi shortcuts
      pu = "pulumi";
      puu = "pulumi up";
      pud = "pulumi destroy";
      pus = "pulumi stack";
    };

    # Initialize cloud CLI completions
    programs.bash.initExtra = lib.mkIf config.programs.bash.enable ''
      # AWS CLI completion
      if command -v aws_completer >/dev/null 2>&1; then
        complete -C aws_completer aws
      fi
      
      # Kubectl completion
      if command -v kubectl >/dev/null 2>&1; then
        source <(kubectl completion bash)
        complete -F __start_kubectl k
      fi
      
      # Helm completion
      if command -v helm >/dev/null 2>&1; then
        source <(helm completion bash)
      fi
      
      # Terraform completion
      if command -v terraform >/dev/null 2>&1; then
        complete -C $(which terraform) terraform
        complete -C $(which terraform) tf
      fi
      
      # Pulumi completion
      if command -v pulumi >/dev/null 2>&1; then
        source <(pulumi completion bash)
      fi
      
      # Google Cloud SDK
      if [ -f "${pkgs.google-cloud-sdk}/completion.bash.inc" ]; then
        source "${pkgs.google-cloud-sdk}/completion.bash.inc"
      fi
      if [ -f "${pkgs.google-cloud-sdk}/path.bash.inc" ]; then
        source "${pkgs.google-cloud-sdk}/path.bash.inc"
      fi
    '';

    programs.zsh.initExtra = lib.mkIf config.programs.zsh.enable ''
      # AWS CLI completion
      if command -v aws_completer >/dev/null 2>&1; then
        complete -C aws_completer aws
      fi
      
      # Kubectl completion
      if command -v kubectl >/dev/null 2>&1; then
        source <(kubectl completion zsh)
        compdef __start_kubectl k
      fi
      
      # Helm completion
      if command -v helm >/dev/null 2>&1; then
        source <(helm completion zsh)
      fi
      
      # Terraform completion
      if command -v terraform >/dev/null 2>&1; then
        complete -C $(which terraform) terraform
        complete -C $(which terraform) tf
      fi
      
      # Pulumi completion
      if command -v pulumi >/dev/null 2>&1; then
        source <(pulumi completion zsh)
      fi
      
      # Google Cloud SDK
      if [ -f "${pkgs.google-cloud-sdk}/completion.zsh.inc" ]; then
        source "${pkgs.google-cloud-sdk}/completion.zsh.inc"
      fi
      if [ -f "${pkgs.google-cloud-sdk}/path.zsh.inc" ]; then
        source "${pkgs.google-cloud-sdk}/path.zsh.inc"
      fi
    '';
  };
}