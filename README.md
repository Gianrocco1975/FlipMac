# FlipMac

Convertitore di file **locale** per macOS, ispirato a [FLIP](https://github.com/thetinyfoundry/FLIP) (Windows).
Nessun cloud: tutto gira sul tuo Mac. La copia convertita viene creata accanto all'originale, senza sovrascrivere nulla.

> Stato: **versione 0.4** — gesto "trascina + Freccia Giù", app nella barra dei menu con la ruota dei formati,
> avvio al login, aggiornamenti da GitHub, comando `flip`. Progetto indipendente: non contiene codice di FLIP.

## Requisiti

- macOS 13 o successivo
- Strumenti da riga di comando di Xcode: `xcode-select --install`
- Facoltativi, per più formati:

| Strumento | Installazione | Serve per |
|---|---|---|
| FFmpeg | `brew install ffmpeg` | audio e video |
| WebP | `brew install webp` | creare file WebP (macOS sa leggerli ma non scriverli) |
| pdf2docx | `brew install pipx && pipx install pdf2docx` | PDF → Word (e ODT, RTF, HTML…) ricostruito fedelmente, con tabelle |
| Pandoc | `brew install pandoc` | Markdown, EPUB, FB2, RST e altre conversioni di documenti |
| LibreOffice | `brew install --cask libreoffice` | PDF fedeli da DOCX/ODT/RTF/HTML/TXT (funziona anche se LibreOffice è aperto; FlipMac usa un suo profilo in `~/Library/Caches/FlipMac`) |

> Nota su FFmpeg: da gennaio 2026 il pacchetto `ffmpeg` di Homebrew non include più gli encoder
> `libvorbis` e `libwebp`. FlipMac se ne accorge da solo: per l'OGG usa l'encoder Vorbis interno di ffmpeg
> (stereo, qualità un po' inferiore), per il WebP usa `cwebp`. Chi vuole la qualità piena può usare
> `brew install ffmpeg-full`. `flip --doctor` mostra quali encoder ha il tuo ffmpeg.

## Installazione

```bash
git clone <URL-della-tua-repo> FlipMac
cd FlipMac
./scripts/install.sh
```

Installa il comando `flip` in `~/.local/bin` (cambia cartella con `PREFIX=/usr/local ./scripts/install.sh`).

## App nella barra dei menu

```bash
./scripts/build-app.sh --install  # crea l'app e la installa in ~/Applications
open ~/Applications/FlipMac.app   # la avvia (icona ⟳ nella barra dei menu)
./scripts/build-app.sh            # solo build/FlipMac.app, senza installarla
```

Quattro modi per far comparire la ruota dei formati:

1. **gesto ↓**: inizia a trascinare uno o più file (dal Finder, dalla Scrivania…), premi **Freccia Giù**
   tenendo premuto il mouse: la ruota compare sotto il puntatore; rilascia i file sul formato.
   Rilasciando al centro o fuori dalla ruota non succede nulla e i file restano dov'erano;
2. trascina uno o più file sull'icona nella barra dei menu;
3. menu dell'icona → **Converti file…**;
4. nel Finder: clic destro sul file → **Apri con → FlipMac**.

Nei casi 2–4 si clicca il formato. Poi la ruota diventa un anello di avanzamento con la percentuale.
**Esc** chiude la ruota o annulla la conversione in corso. Le copie convertite finiscono accanto agli originali.
Il registro diagnostico è in `~/Library/Logs/FlipMac/flip.log` (menu → Apri registro).

La prima volta che converti un file sulla Scrivania o in Documenti, macOS chiede il permesso di accedere
a quella cartella: serve per scrivere la copia convertita accanto all'originale.

### Permesso Accessibilità (gesto ↓)

Per accorgersi della Freccia Giù mentre il Finder sta trascinando, FlipMac usa un "event tap" di macOS, che
richiede il permesso **Impostazioni di Sistema → Privacy e sicurezza → Accessibilità → FlipMac**. FlipMac guarda
solo i clic del mouse e i tasti premuti, e trattiene la Freccia Giù solo durante un trascinamento di file:
in tutti gli altri casi la freccia arriva normalmente alle app. Il gesto si spegne e si riaccende dal menu.

**Facoltativo, consigliato se ricompili spesso.** Con la firma "ad-hoc" usata di base, ogni nuova compilazione
è un'app diversa per macOS e il permesso va ridato. Per evitarlo crea una volta un certificato personale:
Accesso Portachiavi → menu **Accesso Portachiavi → Assistente Certificato → Crea un certificato…** →
Nome `FlipMac Developer`, Tipo di identità **Radice autofirmata**, Tipo di certificato **Firma codice** → Crea.
Da lì in poi `build-app.sh` lo usa da solo e il permesso resta valido.

### Avvio al login

Menu dell'icona → **Apri al login**. FlipMac usa il sistema ufficiale di macOS (Impostazioni di Sistema →
Generali → Elementi login). Conviene attivarlo dopo aver installato l'app in `~/Applications`.

### Aggiornamenti

Menu dell'icona → **Controlla aggiornamenti…** (e un controllo automatico al giorno). FlipMac confronta la
versione installata con la tua repo su GitHub usando `git`, quindi funziona anche con una repo privata.
Se ci sono novità, **Aggiorna ora** esegue `scripts/update.sh`: scarica le modifiche (`git pull`), ricompila,
reinstalla e riavvia l'app. Il registro dell'aggiornamento è in `~/Library/Logs/FlipMac/update.log`.

Serve che la cartella del progetto sia una repo git collegata a GitHub, per esempio:

```bash
cd ~/Projects/FlipMac
git init -b main
git add .
git commit -m "FlipMac 0.4"
# crea una repo vuota su github.com (senza README), poi:
git remote add origin https://github.com/<tuo-utente>/FlipMac.git
git push -u origin main
./scripts/build-app.sh --install   # l'app ricorda da quale commit è stata creata
```

Da riga di comando lo stesso aggiornamento è `./scripts/update.sh --install`.

## Comando da terminale

```bash
flip video.mov --to mp4          # video → video
flip lezione.mp4 --to mp3        # estrae l'audio
flip *.png --to jpg              # più file in una volta
flip dati.json --to csv          # dati strutturati
flip relazione.docx --to pdf     # documenti
flip --formats mp4               # formati possibili da un'estensione
flip --doctor                    # controlla gli strumenti installati
```

Prova rapida, senza strumenti esterni: `./scripts/smoke-test.sh`
(dati strutturati e, su macOS, immagini: trasparenza, foto ruotate di iPhone, HEIC, PDF, WebP).

Le immagini vengono raddrizzate secondo l'orientamento EXIF, quindi una foto di iPhone resta dritta
anche in formati che non conservano l'orientamento (BMP, GIF, PDF).

## Cosa converte

| Categoria | Formati | Come |
|---|---|---|
| Video | MP4, MKV, WebM, AVI, MOV, WMV, M4V (+ estrazione audio) | FFmpeg |
| Audio | MP3, WAV, FLAC, OGG, M4A, AAC, WMA, OPUS | FFmpeg |
| Immagini | PNG, JPG, WebP, BMP, TIFF, GIF (HEIC in ingresso), PDF in uscita | ImageIO nativo; WebP in uscita con `cwebp` |
| Dati | JSON, YAML/YML, XML, CSV → anche TXT, HTML, Markdown, PDF | nativo, nessuna dipendenza |
| Documenti | TXT, MD, HTML, DOCX, EPUB, ODT, RTF, FB2, RST → anche PDF | `textutil` (incluso in macOS) e Pandoc |
| PDF | → PNG, JPG, WebP (un file per pagina), TIFF (un file con tutte le pagine), a 150 dpi | PDFKit / Core Graphics nativi |
| Firmati | .p7m (CAdES, anche in Base64 o con più firme) → PDF, oppure il documento originale (es. `fattura.xml.p7m` → XML) | Security.framework nativo |
| PDF | → DOCX, ODT, RTF, HTML, TXT, Markdown | con `pdf2docx`: documento ricostruito (titoli, grassetti, elenchi, tabelle, immagini) e ritoccato; senza: solo il testo |

Ritocchi al Word creato da pdf2docx: celle di tabella che si allargano invece di tagliare il testo, testo che
scorre da una pagina all'altra (niente pagine quasi vuote), elenchi puntati allineati, intestazioni e piè di
pagina ripetuti tolti (ad esempio data, indirizzo e "1/11" aggiunti dal browser quando si stampa in PDF).

Un PDF senza testo selezionabile (una scansione) si può convertire solo in immagini: FlipMac lo segnala.

Dai file `.p7m` FlipMac estrae il documento firmato: `atto.pdf.p7m` → `atto.pdf` (il `.p7m` resta intatto).
Se dentro c'è un Word o un'immagine, può anche trasformarlo direttamente in PDF. Il registro riporta il nome
di chi ha firmato. FlipMac **non verifica la validità legale della firma** e il file estratto non contiene la
firma: per il valore legale conta sempre il `.p7m`.

Convenzioni per i dati strutturati:

- Le chiavi mantengono l'ordine originale.
- XML: gli attributi diventano chiavi `@nome`, il testo misto diventa `#text`, gli elementi ripetuti diventano array.
- CSV: separatore riconosciuto in automatico (`,` `;` tab); la prima riga è l'intestazione; numeri e booleani vengono riconosciuti.
- Verso CSV, gli oggetti annidati diventano colonne con chiave puntata (`indirizzo.città`).

## Struttura della repo

```
Package.swift
Sources/
  FlipCore/     libreria del motore (usata dalla CLI e dall'app)
  flip/         comando da terminale
  FlipApp/      app nella barra dei menu (ruota radiale)
scripts/
  install.sh    compila e installa il comando flip
  build-app.sh  crea FlipMac.app (--install: in ~/Applications)
  update.sh     scarica gli aggiornamenti da GitHub e ricompila
  smoke-test.sh prova rapida
Resources/
  AppIcon.icns  icona dell'app (AppIcon-1024.png: originale)
```

## Roadmap

1. Motore + CLI ✓
2. App da barra dei menu (`FlipApp`): ruota radiale con avanzamento circolare e annullamento con Esc ✓
3. Gesto globale: trascina file da Finder/Desktop, premi Freccia Giù, rilascia sul formato ✓
4. Avvio al login, icona dell'app, aggiornamenti da GitHub ✓

## Licenza

MIT. Dipendenza: [Yams](https://github.com/jpsim/Yams) (MIT) per la lettura dello YAML. FFmpeg, Pandoc e LibreOffice sono programmi esterni con le proprie licenze.
