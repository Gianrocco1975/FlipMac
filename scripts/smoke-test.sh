#!/usr/bin/env bash
# Prova rapida del motore.
#  1. Dati: un piccolo JSON attraverso YAML, XML, CSV, Markdown, HTML, PDF e ritorno.
#  2. Immagini (solo su macOS): PNG con trasparenza, foto con rotazione EXIF, HEIC, PDF, WebP.
# Uso: ./scripts/smoke-test.sh   (serve aver già eseguito ./scripts/install.sh oppure `swift build -c release`)
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

FLIP=".build/release/flip"
if [ ! -x "$FLIP" ]; then
  FLIP="$(command -v flip || true)"
fi
if [ -z "$FLIP" ]; then
  echo "Non trovo il comando flip. Esegui prima ./scripts/install.sh"
  exit 1
fi

T="$(mktemp -d)"
echo "Cartella di prova: $T"
FAILED=0

check() {
  # check "descrizione" comando...
  local label="$1"; shift
  if "$@" >/dev/null 2>"$T/.err"; then
    echo "  ✓ $label"
  else
    echo "  ✗ $label"
    sed 's/^/      /' "$T/.err"
    FAILED=$((FAILED + 1))
  fi
}

# ---------------------------------------------------------------- 1. Dati
cat > "$T/libri.json" <<'EOF'
[
  {"titolo": "Il nome della rosa", "autore": "Umberto Eco", "anno": 1980, "disponibile": true},
  {"titolo": "Se questo è un uomo", "autore": "Primo Levi", "anno": 1947, "disponibile": false}
]
EOF

echo
echo "1. Dati strutturati"
check "JSON → YAML" "$FLIP" "$T/libri.json" --to yaml
check "YAML → XML" "$FLIP" "$T/libri.yaml" --to xml
check "XML → CSV" "$FLIP" "$T/libri.xml" --to csv
check "CSV → Markdown" "$FLIP" "$T/libri.csv" --to md
check "CSV → HTML" "$FLIP" "$T/libri.csv" --to html
check "CSV → PDF" "$FLIP" "$T/libri.csv" --to pdf
check "CSV → JSON" "$FLIP" "$T/libri.csv" --to json

if command -v python3 >/dev/null 2>&1 && [ -f "$T/libri (1).json" ]; then
  if python3 -c "import json,sys; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); sys.exit(0 if a==b else 1)" "$T/libri.json" "$T/libri (1).json"; then
    echo "  ✓ il JSON finale coincide con quello di partenza"
  else
    echo "  ✗ il JSON finale è diverso da quello di partenza"
    FAILED=$((FAILED + 1))
  fi
fi

# ---------------------------------------------------------------- 2. Immagini (macOS)
if [ "$(uname)" = "Darwin" ]; then
  echo
  echo "2. Immagini"

  # PNG 64×32 con una metà semitrasparente
  echo 'iVBORw0KGgoAAAANSUhEUgAAAEAAAAAgCAYAAACinX6EAAAASklEQVR42u3QQREAIAgAQTCNcWykzTEGD/YK3MxmnXjRWO66nf8VwwMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABP6fSUDtjTiuVYAAAAASUVORK5CYII=' \
    | base64 --decode > "$T/logo.png"

  # JPG 64×32 con orientamento EXIF 6 (come una foto di iPhone girata): dritta deve risultare 32×64
  echo '/9j/4AAQSkZJRgABAQAAAQABAAD/4QAiRXhpZgAATU0AKgAAAAgAAQESAAMAAAABAAYAAAAAAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAAgAEADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDnqKKK4D8sCiiigAooooAKKKKACiiigAooooAKKKKACiiigD//2Q==' \
    | base64 --decode > "$T/foto.jpg"

  for target in jpg bmp gif tiff pdf; do
    check "PNG → ${target}" "$FLIP" "$T/logo.png" --to "$target"
  done

  if "$FLIP" "$T/logo.png" --to webp >/dev/null 2>"$T/.err"; then
    echo "  ✓ PNG → webp"
  else
    echo "  • PNG → webp non disponibile: $(head -1 "$T/.err" | sed 's/^✗ [^:]*: //')"
  fi

  check "foto ruotata → BMP" "$FLIP" "$T/foto.jpg" --to bmp
  if [ -f "$T/foto.bmp" ]; then
    W=$(sips -g pixelWidth "$T/foto.bmp" 2>/dev/null | awk '/pixelWidth/ {print $2}')
    H=$(sips -g pixelHeight "$T/foto.bmp" 2>/dev/null | awk '/pixelHeight/ {print $2}')
    if [ "$W" = "32" ] && [ "$H" = "64" ]; then
      echo "  ✓ la foto è stata raddrizzata (32×64)"
    else
      echo "  ✗ la foto non è stata raddrizzata (risulta ${W}×${H}, atteso 32×64)"
      FAILED=$((FAILED + 1))
    fi
  fi

  if sips -s format heic "$T/logo.png" --out "$T/heic.heic" >/dev/null 2>&1; then
    check "HEIC → jpg" "$FLIP" "$T/heic.heic" --to jpg
  else
    echo "  • HEIC saltato (questo Mac non sa creare HEIC con sips)"
  fi

  for f in logo.jpg logo.pdf logo.gif; do
    [ -f "$T/$f" ] && echo "    $(file -b "$T/$f" | cut -c1-70)"
  done
fi

# ---------------------------------------------------------------- 3. PDF in ingresso (macOS)
if [ "$(uname)" = "Darwin" ]; then
  echo
  echo "3. PDF in ingresso"

  check "PDF → txt" "$FLIP" "$T/libri.pdf" --to txt
  if grep -q "Umberto Eco" "$T/libri.txt" 2>/dev/null; then
    echo "  ✓ il testo è stato estratto"
  else
    echo "  ✗ il testo estratto non contiene quello atteso"
    FAILED=$((FAILED + 1))
  fi
  check "PDF → docx" "$FLIP" "$T/libri.pdf" --to docx
  check "PDF → png" "$FLIP" "$T/libri.pdf" --to png

  # DOCX → PDF fedele con LibreOffice, se installato
  if [ -x /Applications/LibreOffice.app/Contents/MacOS/soffice ] || command -v soffice >/dev/null 2>&1; then
    mkdir -p "$T/word"
    cp "$T/libri.docx" "$T/word/libri.docx" 2>/dev/null
    check "DOCX → PDF" "$FLIP" "$T/word/libri.docx" --to pdf
    if grep -a -q "LibreOffice" "$T/word/libri.pdf" 2>/dev/null; then
      echo "  ✓ il PDF è stato impaginato da LibreOffice"
    else
      echo "  ✗ il PDF non viene da LibreOffice (solo testo)"
      FAILED=$((FAILED + 1))
    fi
  else
    echo "  • DOCX → PDF con LibreOffice saltato (LibreOffice non installato)"
  fi

  # Un CSV lungo diventa un PDF di più pagine
  {
    echo "numero,testo"
    for i in $(seq 1 300); do echo "$i,riga di prova numero $i"; done
  } > "$T/lungo.csv"
  check "CSV lungo → PDF" "$FLIP" "$T/lungo.csv" --to pdf
  check "PDF di più pagine → png" "$FLIP" "$T/lungo.pdf" --to png
  PAGES=$(find "$T" -name 'lungo - pagina *.png' | wc -l | tr -d ' ')
  if [ "$PAGES" -gt 1 ]; then
    echo "  ✓ un'immagine per pagina ($PAGES pagine)"
  else
    echo "  ✗ attese più immagini, trovate: $PAGES"
    FAILED=$((FAILED + 1))
  fi
  check "PDF di più pagine → tiff" "$FLIP" "$T/lungo.pdf" --to tiff

  # PDF → Word ricostruito e ritoccato, se pdf2docx è installato
  if command -v pdf2docx >/dev/null 2>&1 || [ -x "$HOME/.local/bin/pdf2docx" ]; then
    OUT="$("$FLIP" "$T/lungo.pdf" --to docx 2>&1 || true)"
    if [[ "$OUT" == *"ritocchi:"* ]]; then
      echo "  ✓ PDF → Word ricostruito con pdf2docx e ritoccato"
    elif [[ "$OUT" == *"✓"* ]]; then
      echo "  • PDF → Word ricostruito con pdf2docx, ma senza ritocchi"
    else
      echo "  ✗ PDF → Word con pdf2docx non riuscito: $OUT"
      FAILED=$((FAILED + 1))
    fi
  fi

  if [ -f "$T/logo.pdf" ]; then
    # flip deve fallire con un messaggio chiaro: si legge il messaggio, non il codice di uscita
    OUT="$("$FLIP" "$T/logo.pdf" --to txt 2>&1 || true)"
    if [[ "$OUT" == *scansione* ]]; then
      echo "  ✓ PDF senza testo riconosciuto (avviso di scansione)"
    else
      echo "  ✗ PDF senza testo non riconosciuto"
      FAILED=$((FAILED + 1))
    fi
  fi
fi

# ---------------------------------------------------------------- 5. File firmati .p7m (macOS)
if [ "$(uname)" = "Darwin" ] && command -v openssl >/dev/null 2>&1 && [ -f "$T/libri.pdf" ]; then
  echo
  echo "5. File firmati (.p7m)"
  mkdir -p "$T/firma/semplice" "$T/firma/base64" "$T/firma/doppia"
  # Certificato di prova e firma CAdES del PDF creato al punto 1
  if openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/firma/chiave.pem" -out "$T/firma/cert.pem" \
       -subj "/CN=Mario Rossi/O=Prova FlipMac" -days 2 >/dev/null 2>&1 &&
     openssl smime -sign -binary -nodetach -in "$T/libri.pdf" -signer "$T/firma/cert.pem" \
       -inkey "$T/firma/chiave.pem" -outform DER -out "$T/firma/semplice/atto.pdf.p7m" 2>/dev/null; then
    base64 < "$T/firma/semplice/atto.pdf.p7m" > "$T/firma/base64/atto.pdf.p7m"
    openssl smime -sign -binary -nodetach -in "$T/firma/semplice/atto.pdf.p7m" -signer "$T/firma/cert.pem" \
      -inkey "$T/firma/chiave.pem" -outform DER -out "$T/firma/doppia/atto.pdf.p7m.p7m" 2>/dev/null

    for kind in semplice base64 doppia; do
      SOURCE="$(find "$T/firma/$kind" -name 'atto.pdf.p7m*' | head -1)"
      OUT="$("$FLIP" "$SOURCE" --to pdf 2>&1 || true)"
      if cmp -s "$T/firma/$kind/atto.pdf" "$T/libri.pdf"; then
        echo "  ✓ P7M ($kind) → atto.pdf identico all'originale"
      else
        echo "  ✗ P7M ($kind) → PDF non riuscito: $OUT"
        FAILED=$((FAILED + 1))
      fi
    done
    if [[ "$OUT" == *"Mario Rossi"* ]]; then
      echo "  ✓ firmatario riconosciuto (Mario Rossi)"
    else
      echo "  • nome del firmatario non letto"
    fi
  else
    echo "  • saltato (openssl non riesce a creare il file firmato di prova)"
  fi
fi

# ---------------------------------------------------------------- 4. Video senza audio (serve ffmpeg)
if command -v ffmpeg >/dev/null 2>&1 || [ -x /opt/homebrew/bin/ffmpeg ] || [ -x /usr/local/bin/ffmpeg ]; then
  FF="$(command -v ffmpeg || true)"
  [ -z "$FF" ] && [ -x /opt/homebrew/bin/ffmpeg ] && FF=/opt/homebrew/bin/ffmpeg
  [ -z "$FF" ] && FF=/usr/local/bin/ffmpeg
  echo
  echo "4. Video senza audio"
  if "$FF" -v error -f lavfi -i testsrc=duration=1:size=160x120:rate=10 -pix_fmt yuv420p "$T/muto.mp4" 2>/dev/null; then
    LIST="$("$FLIP" "$T/muto.mp4" 2>&1 || true)"
    if [[ "$LIST" == *mp3* ]]; then
      echo "  ✗ per un video senza audio vengono proposti i formati audio"
      FAILED=$((FAILED + 1))
    else
      echo "  ✓ per un video senza audio non vengono proposti i formati audio"
    fi
    OUT="$("$FLIP" "$T/muto.mp4" --to mp3 2>&1 || true)"
    if [[ "$OUT" == *"traccia audio"* ]]; then
      echo "  ✓ messaggio chiaro se si chiede comunque l'MP3"
    else
      echo "  ✗ messaggio poco chiaro: $OUT"
      FAILED=$((FAILED + 1))
    fi
    check "video senza audio → mov" "$FLIP" "$T/muto.mp4" --to mov
  else
    echo "  • saltato (ffmpeg non riesce a creare il video di prova)"
  fi
fi

# ---------------------------------------------------------------- Esito
echo
ls -l "$T"
echo
if [ "$FAILED" -eq 0 ]; then
  echo "Tutte le prove sono riuscite."
else
  echo "Prove non riuscite: $FAILED"
  exit 1
fi
