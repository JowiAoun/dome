# Sourced by zsh and bash at startup (modules/vault.nix): the vault's
# warnings, in red, at the top of every new terminal until they are fixed.
# Two file tests when there is nothing to say, so it costs nothing then.
_vault_state="${XDG_STATE_HOME:-$HOME/.local/state}/vault"
if [ -s "$_vault_state/warnings.txt" ] || [ -s "$_vault_state/alarms.txt" ]; then
  printf '\033[1;31m'
  if [ -s "$_vault_state/warnings.txt" ]; then sed 's/^/⚠ /' "$_vault_state/warnings.txt"; fi
  if [ -s "$_vault_state/alarms.txt" ]; then cut -f2 "$_vault_state/alarms.txt" | sed 's/^/⚠ /'; fi
  printf '\033[0mRun vault check for details.\n'
fi
unset _vault_state
