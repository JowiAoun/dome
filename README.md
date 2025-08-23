# dome
My dotfiles configuration using Nix and Home Manager

## Setup

1. Install Nix (if not already installed):
   ```bash
   sh <(curl -L https://nixos.org/nix/install) --daemon
   ```

2. Enable flakes (add to ~/.config/nix/nix.conf):
   ```
   experimental-features = nix-command flakes
   ```

3. Clone this repository:
   ```bash
   git clone <your-repo-url> ~/.dotfiles
   cd ~/.dotfiles
   ```

4. Apply the configuration:
   ```bash
   nix run home-manager/master -- switch --flake .#default
   ```

## Usage

To update your dotfiles:
```bash
cd ~/.dotfiles
home-manager switch --flake .#default
```

To update packages:
```bash
nix flake update
home-manager switch --flake .#default
```

## Configuration

- Main configuration: `home.nix`
- Flake definition: `flake.nix` 
- Additional configs can be placed in the `config/` directory

## Customization

Edit `home.nix` to:
- Add/remove packages in `home.packages`
- Configure programs under `programs.*`
- Set environment variables in `home.sessionVariables`
- Add dotfiles via `home.file`
