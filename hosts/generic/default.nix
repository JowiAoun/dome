# Host profile: generic — any non-Duo machine (WSL, Codespaces, plain Linux).
# Deliberately empty so `home-manager switch --flake .#generic` reproduces the
# pre-hosts behavior exactly; machine-specific config belongs in sibling
# profiles like hosts/zenbook-duo.
{ ... }:

{
}
