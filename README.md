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

## Modules

This dotfiles setup includes modular development environments:

- **Python**: Python 3, pip, poetry, black, flake8, mypy, pytest, jupyter
- **Node.js**: Node 20, npm, yarn, pnpm, TypeScript, ESLint, Prettier
- **Java**: JDK 21, Maven, Gradle, Spring Boot CLI

Enable/disable modules in `home.nix`:
```nix
modules = {
  python.enable = true;   # Python development tools
  node.enable = true;     # Node.js development tools  
  java.enable = false;    # Java development tools
};
```

## Customization

Edit `home.nix` to:
- Enable/disable development modules in `modules.*`
- Add/remove packages in `home.packages`
- Configure programs under `programs.*`
- Set environment variables in `home.sessionVariables`
- Add dotfiles via `home.file`

Add new modules in `modules/` directory following the existing pattern.
