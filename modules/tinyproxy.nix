{ config, lib, pkgs, ... }:

# Tinyproxy (modules.tinyproxy): a small HTTP/HTTPS forward proxy, run as a
# user service on 127.0.0.1:8888.
#
# What it is for: one address any program on this machine can be pointed at
# with http_proxy/https_proxy or `curl -x`, so that program's traffic shows up
# in one log, can be limited with tinyproxy's filter list, or handed on to an
# upstream proxy. It is a plain forward proxy: HTTP is relayed, HTTPS goes
# through as a CONNECT tunnel and is never decrypted, so the log shows the
# host, not the URL.
#
# Nothing is pointed at it by default. Setting http_proxy for the whole
# session would route every tool on the machine through it, so that stays a
# per-program choice:
#
#   curl -x http://127.0.0.1:8888 https://example.com
#   http_proxy=http://127.0.0.1:8888 https_proxy=http://127.0.0.1:8888 <cmd>
#
# It runs as this user, not root. The port is above 1024 and the config is a
# store path, so the unit needs nothing the session does not already have;
# tinyproxy itself logs "Not running as root, so not changing UID/GID" and
# carries on. Measured on 1.11.2: with -d and no LogFile the log goes to
# stdout, which under systemd is the journal, so
# `journalctl --user -u tinyproxy` is the access log. Without -d it forks and
# the log is lost, and systemd sees the parent exit.
#
# Only local clients are allowed. To share the connection with another device
# on the LAN, set `listen` to this machine's address (or "0.0.0.0") AND add the
# client to `allow`: the two are independent, and a wider Listen with the
# default Allow is a proxy that hears everyone and answers only itself.

let
  cfg = config.modules.tinyproxy;

  # A store path on purpose: ExecStart names it, so a change here changes the
  # unit file and home-manager restarts the service on `make home`. A file
  # under ~/.config would need a restart trigger of its own. Read the live one
  # with `systemctl --user cat tinyproxy`.
  confFile = pkgs.writeText "tinyproxy.conf" ''
    # Managed by dome (modules/tinyproxy.nix). Edit the module, then `make home`.
    Port ${toString cfg.port}
    Listen ${cfg.listen}
    Timeout 600
    DefaultErrorFile "${pkgs.tinyproxy}/share/tinyproxy/default.html"
    StatFile "${pkgs.tinyproxy}/share/tinyproxy/stats.html"
    LogLevel Info
    MaxClients 100
    ${lib.concatMapStringsSep "\n" (a: "Allow ${a}") cfg.allow}
    ViaProxyName "tinyproxy"
    ${cfg.extraConfig}
  '';
in
{
  options.modules.tinyproxy = {
    enable = lib.mkEnableOption ''
      tinyproxy, a small HTTP/HTTPS forward proxy, as a user service on
      127.0.0.1:8888. Nothing is pointed at it unless you do so per program
    '';

    port = lib.mkOption {
      type = lib.types.port;
      default = 8888;
      description = "TCP port the proxy listens on. 8888 is tinyproxy's own default.";
    };

    listen = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = ''
        Address to listen on. The default is loopback only, so nothing off
        this machine can reach it. Widen it together with `allow`.
      '';
    };

    allow = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "127.0.0.1" "::1" ];
      example = [ "127.0.0.1" "::1" "192.168.1.0/24" ];
      description = ''
        Client addresses, or CIDR ranges, allowed to use the proxy. Anyone
        else gets a 403.
      '';
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = "Upstream http proxy.example.net:3128";
      description = ''
        Extra lines appended to tinyproxy.conf: an upstream proxy, a filter
        file, a different Via name. See `man 5 tinyproxy.conf`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The binary and its man pages, so `tinyproxy -h` and `man tinyproxy.conf`
    # work from a shell too.
    home.packages = [ pkgs.tinyproxy ];

    systemd.user.services.tinyproxy = {
      Unit = {
        Description = "tinyproxy: HTTP/HTTPS forward proxy on ${cfg.listen}:${toString cfg.port}";
        Documentation = [ "man:tinyproxy(8)" "man:tinyproxy.conf(5)" ];
      };
      Service = {
        # -d keeps it in the foreground: systemd owns the process and the log
        # lands in the journal (see the header).
        ExecStart = "${pkgs.tinyproxy}/bin/tinyproxy -d -c ${confFile}";
        Restart = "on-failure";
        RestartSec = 2;
        # It reads a store path and writes nothing, so it never needs more
        # than it starts with. No mount-namespace options (PrivateTmp,
        # ProtectHome): Ubuntu's AppArmor userns restriction can make those
        # fail with status 226/NAMESPACE for a user unit.
        NoNewPrivileges = true;
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
