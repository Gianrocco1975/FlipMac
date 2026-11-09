#!/usr/bin/env bash
# Crea l'app FlipMac.app (icona nella barra dei menu) nella cartella build/.
# Uso: ./scripts/build-app.sh             crea build/FlipMac.app
#      ./scripts/build-app.sh --install   la copia anche in ~/Applications
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="0.4.0"
APP="build/FlipMac.app"
PLIST="$APP/Contents/Info.plist"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift non trovato. Installa gli strumenti da riga di comando con:  xcode-select --install"
  exit 1
fi

echo "→ Compilo FlipApp in modalità release…"
swift build -c release --product FlipApp
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "→ Preparo $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/FlipApp" "$APP/Contents/MacOS/FlipMac"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>FlipMac</string>
  <key>CFBundleDisplayName</key>
  <string>FlipMac</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.flipmac</string>
  <key>CFBundleExecutable</key>
  <string>FlipMac</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>MIT License</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>File da convertire</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.data</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
EOF

# Da dove viene questa app: servono a "Controlla aggiornamenti…" (confronto con la repo su GitHub).
plutil -replace FlipMacSourceDir -string "$(pwd)" "$PLIST"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && git rev-parse HEAD >/dev/null 2>&1; then
  plutil -replace FlipMacCommit -string "$(git rev-parse HEAD)" "$PLIST"
  plutil -replace FlipMacBranch -string "$(git rev-parse --abbrev-ref HEAD)" "$PLIST"
  echo "  Compilata dal commit $(git rev-parse --short HEAD) ($(git rev-parse --abbrev-ref HEAD))"
else
  echo "  Nota: la cartella non è una repo git con commit: il controllo aggiornamenti resta spento (vedi README)."
fi

plutil -lint "$PLIST" >/dev/null

# Firma. Con un certificato personale stabile ("FlipMac Developer", vedi README) il permesso Accessibilità
# del gesto ↓ resta valido tra una compilazione e l'altra. Con la firma ad-hoc, invece, ogni compilazione
# è un'app "nuova" per macOS: si azzera il vecchio permesso (che non varrebbe più) e macOS lo richiede.
IDENTITY="${FLIPMAC_SIGN_IDENTITY:-FlipMac Developer}"
SIGNED=0
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo "→ Firma con il certificato \"$IDENTITY\""
  if codesign --force --sign "$IDENTITY" "$APP"; then
    SIGNED=1
  else
    echo "  Firma con il certificato non riuscita: uso la firma ad-hoc."
  fi
fi
if [ "$SIGNED" -eq 0 ]; then
  echo "→ Firma locale (ad-hoc)"
  codesign --force --sign - "$APP"
  tccutil reset Accessibility io.github.flipmac >/dev/null 2>&1 || true
  echo "  Nota: con la firma ad-hoc, dopo ogni compilazione macOS chiede di nuovo il permesso"
  echo "  Accessibilità per il gesto ↓. Per evitarlo crea il certificato \"$IDENTITY\" (vedi README)."
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/FlipMac.app"
  cp -R "$APP" "$HOME/Applications/"
  if [ -x "$LSREGISTER" ]; then "$LSREGISTER" -f "$HOME/Applications/FlipMac.app" || true; fi
  echo "✓ Installata: $HOME/Applications/FlipMac.app"
  echo "  Avviala con:  open ~/Applications/FlipMac.app"
else
  if [ -x "$LSREGISTER" ]; then "$LSREGISTER" -f "$APP" || true; fi
  echo "✓ Pronta: $APP"
  echo "  Avviala con:  open $APP"
fi
