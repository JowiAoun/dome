# dome — top-level targets.
#
#   sudo make system [HOST=zenbook-duo] [DRY_RUN=1]   apply the root-level system layer
#   make home [HOST=zenbook-duo]                      apply the home-manager user layer
#   make doctor                                       zenduo hardware probe (read-only, live-USB safe)
#   make update                                       pull repo + update flake inputs
#   make rollback                                     undo a bad flake update: restore flake.lock + re-activate
#
# HOST defaults to the hostProfile in user-config.nix (falling back to "generic").

HOST ?=
DRY_RUN ?=

# Resolve the default host profile exactly like system/lib.sh host_profile():
# HOST > user-config.nix hostProfile > generic. Without this, `make home` and
# `make rollback` jumped straight to "generic" and silently activated a
# generation with no zenduo services / battery limit / genericLinux integration.
HOST_RESOLVED := $(if $(HOST),$(HOST),$(shell sed -nE 's/.*hostProfile *= *"([^"]+)".*/\1/p' user-config.nix 2>/dev/null | head -n1))
HOST_RESOLVED := $(if $(HOST_RESOLVED),$(HOST_RESOLVED),generic)

.PHONY: help setup system home doctor test audit-apps preflight-wipe backup restore update rollback gc

help:
	@echo "dome targets:"
	@echo "  make setup                                       - interactive machine setup (writes user-config.nix)"
	@echo "  sudo make system [HOST=zenbook-duo] [DRY_RUN=1]  - apply system layer (apt/kernel/GRUB/duo helper)"
	@echo "  make home [HOST=zenbook-duo]                     - home-manager switch for the host profile"
	@echo "  make doctor                                      - run 'duo doctor' (read-only hardware probe)"
	@echo "  make test                                        - unit-test system/lib.sh (sudo make test covers root paths)"
	@echo "  make audit-apps                                  - report duplicate apps / colliding .desktop ids"
	@echo "  make update                                      - git pull + nix flake update"
	@echo "  make rollback                                    - undo a bad update (restore flake.lock + re-activate)"
	@echo "  make gc                                          - delete Nix generations older than 30 days"
	@echo ""
	@echo "  reinstalling this machine:"
	@echo "  make preflight-wipe [DEST=/media/you/STICK]      - what an erase would destroy that git cannot restore"
	@echo "  make backup DEST=/media/you/STICK                - capture it (run last, browsers closed)"
	@echo "  restore runs from the media itself: bash <DEST>/dome-backup/restore.sh"

setup:
	bash setup.sh

system:
	DRY_RUN="$(DRY_RUN)" HOST="$(HOST)" bash system/run.sh

# path:. (not plain .) so the gitignored user-config.nix is included in the
# flake source — a git+file flake copies tracked files only.
home:
	home-manager switch --flake path:.#$(HOST_RESOLVED) -b backup

doctor:
	bash duo/bin/duo doctor

# Behavioural tests for system/lib.sh. Plain bash + coreutils, so this runs on a
# fresh machine before Nix exists. Without sudo the root-only cases (install_conf
# writes root-owned files) report as skipped rather than failing.
test:
	bash tests/test-lib.sh

# Read-only: which apps are installed from where, and which .desktop ids clash.
audit-apps:
	bash setup.sh --audit-apps

# Read-only. DEST is optional: without it, candidate destinations are listed.
preflight-wipe:
	bash setup.sh --preflight-wipe "$(DEST)"

# Deliberately no default for DEST. A backup silently written to the disk that
# is about to be erased is worse than no backup, so the target must be named.
backup:
	@test -n "$(DEST)" || { echo "usage: make backup DEST=/media/$$USER/STICK" >&2; exit 2; }
	bash migrate/backup.sh "$(DEST)"

update:
	git pull --ff-only
	nix flake update
	@echo "[dome] flake.lock updated — if 'make home' misbehaves, run 'make rollback'"

# Undo a bad `make update`: revert flake.lock to the committed pin and re-activate
# via `nix run` (works even when the profile's git/home-manager got broken by the
# bad update — nix's own fetcher doesn't depend on the profile binaries).
rollback:
	git restore flake.lock 2>/dev/null || git checkout -- flake.lock
	nix run home-manager/master -- switch --flake path:.#$(HOST_RESOLVED) -b backup

# Every `make home` leaves the previous generation behind, and each one pins its
# whole closure — nothing is ever reclaimed without this. 30 days keeps enough
# history to roll back a bad switch while stopping the store growing forever.
# Deliberately not automatic: deleting the generation you were about to roll back
# to is exactly the kind of surprise a provisioning run should not spring on you.
gc:
	nix-collect-garbage --delete-older-than 30d
	@echo "[dome] older generations removed. 'nix path-info -S ~/.nix-profile' shows the current closure size."
