#!/usr/bin/env bash
# Compila FlipMac e installa il comando `flip`.
# Uso: ./scripts/install.sh            (installa in ~/.local/bin)
#      PREFIX=/usr/local ./scripts/install.sh   (installa in /usr/local/bin, può richiedere sudo)
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift non trovato. Installa gli strumenti da riga di comando con:  xcode-select --install"
  exit 1
fi

echo "→ Compilo in modalità release (la prima volta scarica la dipendenza Yams)…"
swift build -c release

PREFIX="${PREFIX:-$HOME/.local}"
mkdir -p "$PREFIX/bin"
install -m 755 .build/release/flip "$PREFIX/bin/flip"
echo "✓ Installato: $PREFIX/bin/flip"

case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *)
    echo
    echo "Aggiungi questa riga a ~/.zshrc, poi apri un nuovo Terminale:"
    echo "  export PATH=\"$PREFIX/bin:\$PATH\""
    ;;
esac

echo
"$PREFIX/bin/flip" --doctor
