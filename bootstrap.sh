#!/usr/bin/env bash
# Bootstrap de una Mac limpia. Uso (bajar a archivo y correr, NO 'curl | bash':
# el instalador de Homebrew se come el stdin del pipe y trunca el script):
#   curl -fsSL https://raw.githubusercontent.com/nhernandez87/mac-bootstrap/main/bootstrap.sh -o ~/bootstrap.sh && bash ~/bootstrap.sh
#
# Unico requisito: tener a mano el Emergency Kit de 1Password (Secret Key) para el login.
# El resto (SSH keys, dotfiles, config, repos, .env) sale de 1Password + git automaticamente.
# Este script NO contiene secretos: las keys se bajan de 1Password en runtime (con tu login).
set -euo pipefail
say(){ printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }

say "1/6  Homebrew"
if [ ! -x /opt/homebrew/bin/brew ]; then
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/null
fi
eval "$(/opt/homebrew/bin/brew shellenv)"

say "2/6  1Password + CLI + git"
[ -d /Applications/1Password.app ] || brew install --cask 1password >/dev/null 2>&1 || true
command -v op  >/dev/null 2>&1 || brew install 1password-cli >/dev/null 2>&1 || true
command -v git >/dev/null 2>&1 || brew install git >/dev/null 2>&1 || true

say "3/6  Login 1Password  (ACCION MANUAL)"
cat <<'MSG'
  1. Abri 1Password (Cmd+Space -> "1Password") y logueate:
       email  +  Secret Key (del Emergency Kit)  +  master password
  2. Settings > Developer: activa "Integrate with 1Password CLI"  y  el "SSH Agent"
  3. Volve a esta terminal y apreta ENTER
MSG
read -r _ </dev/tty

say "4/6  Restaurando SSH keys desde 1Password"
# `op` autentica de dos formas y las dos fallan distinto:
#  - integracion con la app (Settings > Developer): funciona en cualquier shell, es la buena.
#  - `op account add` + `op signin`: la sesion vive en una VARIABLE DE ENTORNO del shell que
#    la creo. Correr el signin a mano y despues `bash bootstrap.sh` NO sirve: el script es
#    otro proceso y no hereda nada. Por eso el signin tiene que pasar ACA adentro.
# Sin esto, `op document list` abria un prompt interactivo ("add an account manually?") que
# dejaba el script colgado esperando una respuesta que nadie habia pedido (visto 2026-10-07).
if ! op whoami >/dev/null 2>&1; then
  if op account list 2>/dev/null | grep -q .; then
    echo "  cuenta encontrada, firmando (pide tu master password o Touch ID)"
    eval "$(op signin --raw >/tmp/.op_tok 2>/dev/null && echo export OP_SESSION_my=$(cat /tmp/.op_tok))" 2>/dev/null || true
    rm -f /tmp/.op_tok
  fi
fi
if ! op whoami >/dev/null 2>&1; then
  cat <<'MSG'
  op no puede autenticar todavia. La via corta:
    1. Abri 1Password y logueate (email + Secret Key + master password)
    2. Settings > Developer > "Integrate with 1Password CLI"  (y el SSH Agent)
    3. Volve a correr: bash ~/bootstrap.sh
  Comprobalo con: op whoami
MSG
  exit 1
fi
if [ -f "$HOME/.ssh/github-nhernandez" ] && [ -f "$HOME/.ssh/config" ]; then
  echo "  ya restauradas, skip"
else
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  op document list --vault Private --format=json 2>/dev/null \
    | python3 -c 'import json,sys; [print(i["title"]) for i in json.load(sys.stdin) if i.get("title","").startswith("ssh-")]' \
    | while read -r doc; do
    name="${doc#ssh-}"
    if [ "$name" = "config" ]; then out="$HOME/.ssh/config"; else out="$HOME/.ssh/$name"; fi
    op document get "$doc" --vault Private --out-file "$out" --force
    if [ "$name" != "config" ]; then
      chmod 600 "$out"
      ssh-keygen -y -f "$out" > "$out.pub" 2>/dev/null || true
    fi
    echo "  restored: $doc"
  done
fi
# authorized_keys viaja con las demas: sin esto una Mac recien reconstruida no acepta SSH de
# nucleus hasta que alguien pega una clave publica a mano, que es justo el paso manual que este
# script existe para borrar. No es un secreto (son claves PUBLICAS), pero vive en 1Password
# porque es la lista de quien puede entrar.
if op document get ssh-authorized_keys --vault Private --out-file "$HOME/.ssh/authorized_keys" --force >/dev/null 2>&1; then
  chmod 600 "$HOME/.ssh/authorized_keys"; echo "  restored: ssh-authorized_keys"
else
  echo "  (sin ssh-authorized_keys en 1Password: el acceso por SSH desde nucleus habra que darlo a mano)"
fi
echo "  test github:"; ssh -o StrictHostKeyChecking=accept-new -T git@github-nhernandez 2>&1 | head -1 || true

say "5/7  Clonando dotfiles + install --full"
mkdir -p "$HOME/repos/naguer"
# usar el alias github-nhernandez (del ~/.ssh/config restaurado) para forzar la key
# personal: con 'git@github.com' pelado + 4 cuentas, GitHub da 404 en el repo privado.
[ -d "$HOME/repos/naguer/bootstrap/.git" ] || GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" git clone git@github-nhernandez:nhernandez87/dotfiles.git "$HOME/repos/naguer/bootstrap"
cd "$HOME/repos/naguer/bootstrap"
bash install.sh --full

say "6/7  Restaurando .env de los jobs"
bash restore-env.sh || true

say "7/7  Aislamiento por job (.envrc + kubeconfig + azure dirs)"
# Step 0 de cualquier job: sin esto cada repo resuelve al contexto cloud que tuviera el shell
# padre, que en la practica es el de otro cliente.
bash restore-job-isolation.sh || true

say "Verificacion final"
command -v starship >/dev/null 2>&1 && echo "  ok: starship (prompt)"      || echo "  FALTA: starship"
command -v op       >/dev/null 2>&1 && echo "  ok: op (1password cli)"      || echo "  FALTA: op"
command -v gh       >/dev/null 2>&1 && echo "  ok: gh"                        || echo "  FALTA: gh"
[ -d "$HOME/.oh-my-zsh" ]           && echo "  ok: oh-my-zsh"                 || echo "  FALTA: oh-my-zsh"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github-nhernandez 2>&1 | grep -q "successfully authenticated" \
                                    && echo "  ok: github ssh"                || echo "  revisar: github ssh"
[ -d "$HOME/repos/naguer/second-brain" ] && echo "  ok: repos clonados"       || echo "  FALTA: repos"
[ -d "/Applications/Tailscale.app" ]      && echo "  ok: tailscale (app)"            || echo "  FALTA: tailscale"
command -v direnv >/dev/null 2>&1        && echo "  ok: direnv"                      || echo "  FALTA: direnv"
[ -f "$HOME/.aws/config" ]               && echo "  ok: ~/.aws/config"               || echo "  FALTA: ~/.aws/config (copiar de otra maquina)"
[ -s "$HOME/.ssh/authorized_keys" ]      && echo "  ok: authorized_keys"             || echo "  revisar: authorized_keys (nadie puede entrar por SSH)"
command -v check-job-isolation >/dev/null 2>&1 && { check-job-isolation >/dev/null 2>&1 \
  && echo "  ok: aislamiento por job" || echo "  revisar: check-job-isolation falla"; }
if command -v systemsetup >/dev/null 2>&1 && systemsetup -getremotelogin 2>/dev/null | grep -qi on; then
  echo "  ok: Remote Login (SSH)"
else
  echo "  PENDIENTE MANUAL: Remote Login -> Ajustes > General > Compartir > Sesion remota"
  echo "                    (o: sudo systemsetup -setremotelogin on)"
fi
echo "  PENDIENTE MANUAL: login de Tailscale desde el icono de la barra (la CLI sola no conecta)"
echo "  PENDIENTE MANUAL: instalar pCloud (pcloud.com) + aprobar macFUSE y reiniciar"
echo "  PENDIENTE MANUAL: repos de jobs -> bash ~/repos/naguer/bootstrap/restore-jobs.sh (necesita rclone con remote pcloud)"

say "LISTO. Reinicia la terminal (exec zsh)."
