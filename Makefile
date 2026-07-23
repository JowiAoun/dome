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

.PHONY: help setup system home doctor update rollback

help:
	@echo "dome targets:"
	@echo "  make setup                                       - interactive machine setup (writes user-config.nix)"
	@echo "  sudo make system [HOST=zenbook-duo] [DRY_RUN=1]  - apply system layer (apt/kernel/GRUB/duo helper)"
	@echo "  make home [HOST=zenbook-duo]                     - home-manager switch for the host profile"
	@echo "  make doctor                                      - run 'duo doctor' (read-only hardware probe)"
	@echo "  make update                                      - git pull + nix flake update"
	@echo "  make rollback                                    - undo a bad update (restore flake.lock + re-activate)"

setup:
	bash setup.sh

system:
	DRY_RUN="$(DRY_RUN)" HOST="$(HOST)" bash system/run.sh

# path:. (not plain .) so the gitignored user-config.nix is included in the
# flake source — a git+file flake copies tracked files only.
home:
	home-manager switch --flake path:.#$(if $(HOST),$(HOST),generic) -b backup

doctor:
	bash duo/bin/duo doctor

update:
	git pull --ff-only
	nix flake update
	@echo "[dome] flake.lock updated — if 'make home' misbehaves, run 'make rollback'"

# Undo a bad `make update`: revert flake.lock to the committed pin and re-activate
# via `nix run` (works even when the profile's git/home-manager got broken by the
# bad update — nix's own fetcher doesn't depend on the profile binaries).
rollback:
	git restore flake.lock 2>/dev/null || git checkout -- flake.lock
	nix run home-manager/master -- switch --flake path:.#$(if $(HOST),$(HOST),generic) -b backup
