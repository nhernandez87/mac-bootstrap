#!/usr/bin/env bash
# Bootstrap de una Mac limpia. Uso:
#   curl -fsSL https://raw.githubusercontent.com/nhernandez87/mac-bootstrap/main/bootstrap.sh | bash
#
# Unico requisito: tener a mano el Emergency Kit de 1Password (Secret Key) para el login.
# El resto (SSH keys, dotfiles, config, repos, .env) sale de 1Password + git automaticamente.
# Este script NO contiene secretos: las keys se bajan de 1Password en runtime (con tu login).
set -euo pipefail
say(){ printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }

say "1/6  Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv)"

say "2/6  1Password + CLI + git"
brew install --cask 1password >/dev/null 2>&1 || true
brew install 1password-cli git >/dev/null 2>&1 || true

say "3/6  Login 1Password  (ACCION MANUAL)"
cat <<'MSG'
  1. Abri 1Password (Cmd+Space -> "1Password") y logueate:
       email  +  Secret Key (del Emergency Kit)  +  master password
  2. Settings > Developer: activa "Integrate with 1Password CLI"  y  el "SSH Agent"
  3. Volve a esta terminal y apreta ENTER
MSG
read -r _ </dev/tty

say "4/6  Restaurando SSH keys desde 1Password"
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
op document list --vault Private 2>/dev/null | awk 'NR>1 && $2 ~ /^ssh-/ {print $2}' | while read -r doc; do
  name="${doc#ssh-}"
  if [ "$name" = "config" ]; then out="$HOME/.ssh/config"; else out="$HOME/.ssh/$name"; fi
  op document get "$doc" --vault Private --out-file "$out" --force
  if [ "$name" != "config" ]; then
    chmod 600 "$out"
    ssh-keygen -y -f "$out" > "$out.pub" 2>/dev/null || true
  fi
  echo "  restored: $doc"
done
echo "  test github:"; ssh -o StrictHostKeyChecking=accept-new -T git@github-nhernandez 2>&1 | head -1 || true

say "5/6  Clonando dotfiles + install --full"
mkdir -p "$HOME/repos/naguer"
[ -d "$HOME/repos/naguer/bootstrap/.git" ] || git clone git@github.com:nhernandez87/dotfiles.git "$HOME/repos/naguer/bootstrap"
cd "$HOME/repos/naguer/bootstrap"
bash install.sh --full

say "6/6  Restaurando .env de los jobs"
bash restore-env.sh || true

say "LISTO. Reinicia la terminal (exec zsh) y verifica."
