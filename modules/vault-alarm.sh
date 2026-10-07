#!/usr/bin/env bash
# The vault's last-resort warning. systemd runs it (vault-alarm@<unit>) when
# vault-check fails outright: crashed, hung, or could not start at all. That
# is the one failure vault.py cannot report itself, because it did not run,
# so this is plain shell and needs nothing it needs. A broken vault.py breaks
# the guard too, and the guard's crashes are what the check reports, so this
# one alarm covers both.
#
# It raises a critical notification and leaves a line in alarms.txt, which
# vault-banner.sh shows at the top of every new terminal. The line goes once
# the unit runs cleanly again: vault.py clears it.
unit="${1:?usage: vault-alarm <unit>}"
state="${XDG_STATE_HOME:-$HOME/.local/state}/vault"

case "$unit" in
  vault-check.service)
    title="Vault: the 2-minute check failed to run"
    body="Nothing covers for the guard or clears vault traces until it runs again." ;;
  *)
    title="Vault: $unit failed"
    body="Part of the vault is not working." ;;
esac

mkdir -p "$state"
fresh=no
if ! grep -qF "$unit	" "$state/alarms.txt" 2>/dev/null; then
  printf '%s\t%s\n' "$unit" "$title" >> "$state/alarms.txt"
  fresh=yes
fi

# Once when it starts failing, then every four hours while it keeps failing,
# not on every two-minute run in between.
if [ "$fresh" = yes ] || [ -n "$(find "$state/alarms.txt" -mmin +240 2>/dev/null)" ]; then
  touch "$state/alarms.txt"
  notify-send -a Vault -u critical -i dialog-warning "$title" \
    "$body See the error with: journalctl --user -u $unit" || true
fi
