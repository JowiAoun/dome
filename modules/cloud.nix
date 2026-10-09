{ config, lib, pkgs, ... }:

let
  cfg = config.modules.cloud;

  # ── Google Cloud CLI (`gcloud`) ─────────────────────────────────────────────
  # Installed from Google's own tarball by the activation hook below, NOT from
  # nixpkgs. Same reasoning as Claude Code in modules/ai.nix, for two reasons:
  #
  #   * Latest. `pkgs.google-cloud-sdk` is frozen at the flake pin — 548.0.0
  #     when this was written, against 580.0.0 upstream, eight months of gcloud
  #     behind — and a read-only store path cannot update itself. The official
  #     install self-updates with `gcloud components update`.
  #   * Components. nixpkgs serves those through a REBUILD
  #     (`google-cloud-sdk.withExtraComponents`) and the wrapper refuses
  #     `gcloud components install` outright. The real CLI installs them at
  #     runtime, which is what `gcloudComponents` below relies on.
  #
  # The target is Ubuntu / Codespaces (glibc, FHS), where Google's binaries and
  # the Python 3.14 bundled in the tarball run exactly as shipped.
  gcloudDir = "${config.home.homeDirectory}/.local/google-cloud-sdk";

  # Extra components to keep installed. Reconciled on EVERY activation against
  # <sdk>/.install/<id>.manifest, so adding one here is enough — this list is
  # not a first-install-only promise that later silently stops being true.
  #
  # gke-gcloud-auth-plugin: kubectl ships in this same module, and since
  # Kubernetes 1.26 `kubectl` against a GKE cluster fails outright without it.
  gcloudComponents = [ "gke-gcloud-auth-plugin" ];

  # Put the SDK's bin on PATH from shell init as well as home.sessionPath.
  #
  # sessionPath alone does NOT reach a terminal opened after `make home`, and
  # this is the trap: sessionPath only takes effect through
  # hm-session-vars.sh, which self-guards with __HM_SESS_VARS_SOURCED and
  # returns immediately when that is already set. The GNOME session exports the
  # guard (confirmed in gnome-shell's own /proc/<pid>/environ, alongside the
  # PATH captured at login), so EVERY terminal in an already-running session
  # inherits guard-set + pre-switch PATH and skips the new file entirely. The
  # result looks exactly like a failed install — `gcloud: command not found` in
  # a brand-new terminal — and only a full logout/login fixes it.
  #
  # Shell init has no such guard: it runs per interactive shell, so a new
  # terminal is enough. The case test makes it a no-op once sessionPath does
  # kick in at the next login, so PATH never grows a duplicate — which is also
  # why this is hand-written rather than sourcing the SDK's path.zsh.inc, a
  # bare `export PATH=…/bin:$PATH` with no already-there check.
  gcloudPathGuard = ''
    case ":$PATH:" in
      *":${gcloudDir}/bin:"*) ;;
      *) export PATH="${gcloudDir}/bin:$PATH" ;;
    esac
  '';
in
{
  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [
      # Infrastructure as Code Tools
      terraform
      pulumi
      terraform-ls

      # Cloud Provider CLIs
      # google-cloud-sdk is deliberately absent — see gcloudDir above; the
      # official gcloud is installed by home.activation.installGcloud.
      awscli2
      azure-cli
      oci-cli

      # Container & Kubernetes Tools
      kubectl
      kubernetes-helm  # Kubernetes package manager, not audio synthesizer
      docker
    ];

    # VS Code extensions for cloud development
    programs.vscode = lib.mkIf config.programs.vscode.enable {
      profiles.default = {
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
    };

    home.sessionVariables = {
      # Terraform
      TF_PLUGIN_CACHE_DIR = "$HOME/.terraform.d/plugin-cache";

      # Pulumi
      PULUMI_HOME = "$HOME/.pulumi";

      # Kubernetes
      KUBECONFIG = "$HOME/.kube/config";

      # CLOUDSDK_PYTHON is deliberately NOT set. bin/gcloud picks
      # platform/bundledpythonunix/bin/python3 — the interpreter Google tests
      # against and ships in the tarball — but ONLY when CLOUDSDK_PYTHON is
      # empty; any value wins over the bundle. Pointing it at pkgs.python3 (as
      # this module did while gcloud came from nixpkgs, which has no bundle)
      # would now quietly swap the interpreter out from under the official CLI.
    };

    # gcloud, gsutil, bq, docker-credential-gcloud all live in the SDK's own bin.
    #
    # sessionPath is the declarative half, and it is what reaches NON-interactive
    # shells — a `gcloud` in a script, a Makefile or a VS Code task. It is not
    # enough on its own: see gcloudPathGuard, which covers the interactive half.
    home.sessionPath = [ "${gcloudDir}/bin" ];

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
      ${gcloudPathGuard}
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
      
      # Google Cloud CLI (completion only — PATH comes from home.sessionPath)
      if [ -f "${gcloudDir}/completion.bash.inc" ]; then
        source "${gcloudDir}/completion.bash.inc"
      fi
    '';

    programs.zsh.initContent = lib.mkIf config.programs.zsh.enable ''
      ${gcloudPathGuard}
      # AWS CLI completion
      if command -v aws_completer >/dev/null 2>&1; then
        complete -C aws_completer aws
      fi
      
      # Kubectl completion
      if command -v kubectl >/dev/null 2>&1; then
        source <(kubectl completion zsh)
        # `_kubectl`, not `__start_kubectl` — the latter is the name kubectl's
        # BASH completion defines (used correctly in the bash block above); the
        # zsh script only defines _kubectl, so the old line bound `k` to a
        # nonexistent function and printed "command not found" on every TAB.
        compdef _kubectl k
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
      
      # Google Cloud CLI (completion only — PATH comes from home.sessionPath)
      if [ -f "${gcloudDir}/completion.zsh.inc" ]; then
        source "${gcloudDir}/completion.zsh.inc"
      fi
    '';

    # Install the official Google Cloud CLI during activation — which is what
    # ./bootstrap.sh, ./install.sh and `make home` all run — so enabling the
    # cloud module is the only step. Install when missing, then leave it alone:
    # `gcloud components update` is how it moves forward from here, and a
    # reinstall would throw away the components and credentials already there.
    #
    # Activation runs with a minimal PATH, so curl/tar have to be put on it
    # explicitly (the mistake that made the Claude Code hook in modules/ai.nix
    # silently do nothing for a while).
    home.activation.installGcloud = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export PATH="${lib.makeBinPath [ pkgs.curl pkgs.coreutils pkgs.gnutar pkgs.gzip ]}:$PATH"

      sdk="${gcloudDir}"

      # Google publishes one tarball per architecture and no others; the
      # unversioned name is their "latest" alias, so this always lands on the
      # newest release rather than a version pinned in this repo.
      case "$(uname -m)" in
        x86_64)  gcloud_tgz=google-cloud-cli-linux-x86_64.tar.gz ;;
        aarch64) gcloud_tgz=google-cloud-cli-linux-arm.tar.gz ;;
        *)       gcloud_tgz="" ;;
      esac

      # Default to "plenty" when df cannot answer: a disk check that fails to
      # read the disk must not be the reason gcloud never gets installed.
      #
      # The `|| true` is load-bearing. Home Manager runs activation under
      # `set -eu` AND `set -o pipefail`, and the exit status of a bare
      # `var="$(pipeline)"` assignment IS the pipeline's — so an unreadable
      # $HOME (a stale network mount is enough) would abort the whole
      # `home-manager switch` here, not merely skip the install below.
      gcloud_avail="$(df --output=avail "$HOME" 2>/dev/null | tail -n1 | tr -d ' ' || true)"

      if [ -x "$sdk/bin/gcloud" ]; then
        : # already installed — it self-updates
      elif [ -z "$gcloud_tgz" ]; then
        echo "⚠️ no official Google Cloud CLI build for $(uname -m) — skipping" >&2
      elif command -v gcloud >/dev/null 2>&1; then
        # An apt/snap copy is already on PATH. Two gclouds on one PATH is a
        # coin toss over which one answers, so defer to the existing one.
        echo "ℹ️ gcloud already installed at $(command -v gcloud) — not adding a second copy"
      elif [ "''${gcloud_avail:-99999999}" -lt 1572864 ]; then
        echo "⚠️ less than 1.5 GiB free — not installing the Google Cloud CLI (it unpacks to ~600 MB)" >&2
      elif [ -n "''${DRY_RUN_CMD:-}" ]; then
        echo "(dry run) would install the latest Google Cloud CLI to $sdk"
      else
        echo "📦 Installing the latest Google Cloud CLI (official tarball, ~100 MB download)…"
        gcloud_tmp="$(mktemp -d)"
        # Unpack to a scratch directory and move it into place only once the
        # whole tree is there. A half-extracted $sdk would look installed to
        # every later activation, and Google's own bootstrap installer refuses
        # to run against an existing directory rather than repairing it.
        if curl -fsSL --retry 3 -o "$gcloud_tmp/gcloud.tar.gz" \
             "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/$gcloud_tgz" \
           && tar -C "$gcloud_tmp" -xzf "$gcloud_tmp/gcloud.tar.gz"; then
          mkdir -p "$(dirname "$sdk")"
          mv "$gcloud_tmp/google-cloud-sdk" "$sdk"
          # --path-update / --command-completion = false: PATH and completion
          # are home-manager's job above. Left at their defaults, install.sh
          # appends its own lines to ~/.bashrc and ~/.zshrc — files this
          # configuration generates, so the edit is wiped on the next switch
          # and silently reapplied on the one after.
          #
          # Logged rather than shown: install.sh signs off by telling you to
          # source path.zsh.inc and completion.zsh.inc "in your profile", which
          # is advice for a hand-managed shell config and wrong here — doing it
          # would double up a PATH entry home.sessionPath already owns. The log
          # is printed in full if the step actually fails.
          if ! "$sdk/install.sh" --quiet --usage-reporting=false \
                 --path-update=false --command-completion=false \
                 >"$gcloud_tmp/install.log" 2>&1; then
            echo "⚠️ gcloud post-install step failed — check with: $sdk/bin/gcloud version" >&2
            sed 's/^/    /' "$gcloud_tmp/install.log" >&2 || true
          fi
          echo "✅ Google Cloud CLI $(cat "$sdk/VERSION" 2>/dev/null) installed to $sdk"
          echo "   Sign in with: gcloud init"
        else
          echo "⚠️ Google Cloud CLI download failed (network?). Re-run 'make home' to retry." >&2
        fi
        rm -rf "$gcloud_tmp"
      fi

      # Components. Presence is read off <sdk>/.install/<id>.manifest, which the
      # component manager writes on install — cheap enough to check on every
      # activation, unlike `gcloud components list` (a full Python start-up and
      # a network round trip).
      if [ -x "$sdk/bin/gcloud" ]; then
        gcloud_missing=""
        for gcloud_c in ${lib.concatStringsSep " " gcloudComponents}; do
          [ -f "$sdk/.install/$gcloud_c.manifest" ] || gcloud_missing="$gcloud_missing $gcloud_c"
        done
        if [ -n "$gcloud_missing" ]; then
          if [ -n "''${DRY_RUN_CMD:-}" ]; then
            echo "(dry run) would install gcloud components:$gcloud_missing"
          else
            echo "📦 Installing gcloud components:$gcloud_missing"
            gcloud_log="$(mktemp)"
            # Word splitting is the point — the list is a set of component ids.
            # shellcheck disable=SC2086
            if ! "$sdk/bin/gcloud" components install --quiet $gcloud_missing \
                   >"$gcloud_log" 2>&1; then
              echo "⚠️ component install failed. Retry: gcloud components install$gcloud_missing" >&2
              sed 's/^/    /' "$gcloud_log" >&2 || true
            fi
            rm -f "$gcloud_log"
          fi
        fi
      fi
    '';
  };
}