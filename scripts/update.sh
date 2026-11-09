#!/usr/bin/env bash
# Aggiorna FlipMac dalla repo GitHub: scarica le modifiche, ricompila il comando flip e l'app.
# Uso: ./scripts/update.sh             aggiorna e ricrea build/FlipMac.app
#      ./scripts/update.sh --install   aggiorna e reinstalla anche in ~/Applications
# Lo usa anche il menu dell'app ("Aggiorna ora").
set -euo pipefail

cd "$(dirname "$0")/.."

echo "→ Scarico gli aggiornamenti da GitHub…"
git pull --ff-only

echo "→ Ricompilo il comando flip…"
./scripts/install.sh

echo "→ Ricompilo l'app…"
if [ "${1:-}" = "--install" ]; then
  ./scripts/build-app.sh --install
else
  ./scripts/build-app.sh
fi

echo "✓ Aggiornamento completato: $(git log -1 --format='%h %s')"
