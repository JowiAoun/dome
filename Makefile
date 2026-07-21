# dome — top-level targets.
#
#   sudo make system [HOST=zenbook-duo] [DRY_RUN=1]   apply the root-level system layer
#   make home [HOST=zenbook-duo]                      apply the home-manager user layer
#   make doctor                                       zenduo hardware probe (read-only, live-USB safe)
#   make update                                       pull repo + update flake inputs
#
# HOST defaults to the hostProfile in user-config.nix (falling back to "generic").

HOST ?=
DRY_RUN ?=

.PHONY: help system home doctor update

help:
	@echo "dome targets:"
	@echo "  sudo make system [HOST=zenbook-duo] [DRY_RUN=1]  - apply system layer (apt/kernel/GRUB/duo helper)"
	@echo "  make home [HOST=zenbook-duo]                     - home-manager switch for the host profile"
	@echo "  make doctor                                      - run 'duo doctor' (read-only hardware probe)"
	@echo "  make update                                      - git pull + nix flake update"

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
