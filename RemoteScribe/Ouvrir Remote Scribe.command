#!/bin/zsh
set -u

PROJECT_DIR="${0:A:h}"
QR_PATH="$HOME/Library/Application Support/RemoteScribe/web/remote-scribe-iphone-qr.png"

cd "$PROJECT_DIR" || {
  print -u2 "Impossible d’ouvrir le dossier Remote Scribe."
  read -r "?Appuyez sur Entrée pour fermer…"
  exit 1
}

if nc -z 127.0.0.1 8443 >/dev/null 2>&1 && nc -z 127.0.0.1 8080 >/dev/null 2>&1; then
  print "Remote Scribe est déjà actif."
  if [[ -f "$QR_PATH" ]]; then
    /usr/bin/open "$QR_PATH"
  fi
  exit 0
fi

print "Démarrage de Remote Scribe…"
print "Cette fenêtre doit rester ouverte pendant l’utilisation."
print

./WebClient/run-webclient.sh --backend superwhisper --show-qr
status=$?

if (( status != 0 )); then
  print
  print -u2 "Remote Scribe s’est arrêté avec une erreur."
  read -r "?Appuyez sur Entrée pour fermer…"
fi

exit $status
