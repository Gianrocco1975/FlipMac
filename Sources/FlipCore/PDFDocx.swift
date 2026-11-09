import Foundation

/// PDF → Word ricostruito (paragrafi, titoli, grassetti, elenchi, tabelle, immagini) con pdf2docx,
/// e da quel Word gli altri formati di testo (ODT, RTF, HTML, TXT, Markdown).
/// pdf2docx si installa con: brew install pipx && pipx install pdf2docx
///
/// Dopo pdf2docx il Word viene ritoccato da un piccolo script Python, eseguito con lo stesso Python di pdf2docx:
/// celle di tabella non più tagliate, testo che scorre tra le pagine, elenchi allineati,
/// intestazioni e piè di pagina ripetuti (ad esempio quelli del browser) tolti.
/// Se lo script non parte, si usa pdf2docx così com'è.
struct PDFDocx {
    let runner: ProcessRunner

    static var isAvailable: Bool {
        return ToolLocator.find("pdf2docx") != nil
    }

    func convert(input: URL, target: String, output: URL, progress: ((Double) -> Void)?, notes: inout [String]) throws {
        guard let pdf2docx = ToolLocator.find("pdf2docx") else {
            throw FlipError.missingTool(name: "pdf2docx", hint: "Installalo con: brew install pipx && pipx install pdf2docx")
        }

        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory.appendingPathComponent("flip-\(UUID().uuidString)")
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let title = input.deletingPathExtension().lastPathComponent
        let docx = workDirectory.appendingPathComponent("\(title).docx")

        // pdf2docx scrive l'avanzamento su stderr: "[3/4] Parsing pages..." poi "(5/11) Page 5" (due giri).
        var phase = 0.0
        let onProgress: (String) -> Void = { line in
            if line.contains("[4/4]") { phase = 1 }
            guard let match = line.range(of: #"\(\d+/\d+\)"#, options: .regularExpression) else { return }
            let numbers = line[match].dropFirst().dropLast().split(separator: "/")
            guard numbers.count == 2, let page = Double(numbers[0]), let total = Double(numbers[1]), total > 0 else { return }
            progress?(min((phase + page / total) / 2, 1) * 0.9)
        }

        var polished = false
        if let python = Self.python(for: pdf2docx) {
            let script = workDirectory.appendingPathComponent("flip_pdf2docx.py")
            try TextIO.write(Self.polishScript, to: script)
            var summary = ""
            do {
                try runner.run(python, [script.path, input.path, docx.path],
                               onStdoutLine: { line in
                                   if line.hasPrefix("ritocchi") { summary = line }
                               },
                               onStderrLine: onProgress)
                polished = fileManager.fileExists(atPath: docx.path)
                if polished && !summary.isEmpty {
                    notes.append("Word ricostruito con pdf2docx — \(summary)")
                }
            } catch FlipError.cancelled {
                throw FlipError.cancelled
            } catch {
                try? fileManager.removeItem(at: docx)
                polished = false
            }
        }
        if !polished {
            phase = 0
            try runner.run(pdf2docx, ["convert", input.path, docx.path], onStderrLine: onProgress)
        }
        guard fileManager.fileExists(atPath: docx.path) else {
            throw FlipError.failed("pdf2docx non ha creato il file Word.")
        }

        switch target {
        case "docx":
            try fileManager.moveItem(at: docx, to: output)
        case "odt", "rtf":
            // LibreOffice è il più fedele; altrimenti pandoc o textutil.
            if try LibreOffice(runner: runner).convert(docx, to: target, output: output) { return }
            try fromDocx(docx, target: target, output: output, title: title, workDirectory: workDirectory)
        default:
            try fromDocx(docx, target: target, output: output, title: title, workDirectory: workDirectory)
        }
    }

    private func fromDocx(_ docx: URL, target: String, output: URL, title: String, workDirectory: URL) throws {
        if let pandoc = ToolLocator.find("pandoc") {
            var arguments = ["-f", "docx", "-o", output.path]
            switch target {
            case "html":
                arguments += ["-t", "html5", "-s", "--embed-resources", "--metadata", "pagetitle=\(title)"]
            case "md":
                // Le immagini del Word non hanno un posto dove stare accanto al Markdown: si tolgono.
                let filter = workDirectory.appendingPathComponent("senza-immagini.lua")
                try TextIO.write("function Image(el) return {} end\n", to: filter)
                arguments += ["-t", "gfm", "--wrap=none", "--lua-filter=\(filter.path)"]
            case "txt":
                arguments += ["-t", "plain", "--wrap=none"]
            case "odt":
                arguments += ["-t", "odt"]
            case "rtf":
                arguments += ["-t", "rtf", "-s"]
            default:
                throw FlipError.unsupported("Da PDF non si può convertire in .\(target)")
            }
            arguments.append(docx.path)
            try runner.run(pandoc, arguments)
            return
        }
        if target != "md", let textutil = ToolLocator.find("textutil") {
            try runner.run(textutil, ["-convert", target, "-output", output.path, docx.path])
            return
        }
        throw FlipError.missingTool(name: "pandoc", hint: "Installalo con: brew install pandoc")
    }

    /// Il Python con cui gira pdf2docx (con pipx: quello del suo ambiente, accanto al comando).
    static func python(for pdf2docx: URL) -> URL? {
        let fileManager = FileManager.default
        let resolved = pdf2docx.resolvingSymlinksInPath()
        for name in ["python", "python3"] {
            let candidate = resolved.deletingLastPathComponent().appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        // Altrimenti si legge la prima riga del comando ("#!/percorso/python").
        guard let handle = try? FileHandle(forReadingFrom: resolved) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2048) else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        guard let first = lines.first, first.hasPrefix("#!") else { return nil }
        var path = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)

        if path == "/bin/sh", lines.count > 1 {
            // Percorsi con spazi: pip scrive una seconda riga con  exec "/percorso/python" "$0" "$@"
            path = lines[1].split(whereSeparator: { $0 == "\"" || $0 == "'" })
                .map(String.init)
                .first(where: { $0.hasPrefix("/") }) ?? ""
        } else if path.hasPrefix("/usr/bin/env ") {
            let name = path.dropFirst("/usr/bin/env ".count).split(separator: " ").first.map(String.init) ?? ""
            return name.isEmpty ? nil : ToolLocator.find(name)
        }
        return fileManager.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    // MARK: - Script Python dei ritocchi

    static let polishScript = #"""
# FlipMac: PDF -> Word con pdf2docx, più alcuni ritocchi al Word creato.
#
# Uso: python flip_pdf2docx.py <input.pdf> <output.docx>
# L'avanzamento di pdf2docx esce su stderr ("(3/11) Page 3"); il riepilogo dei ritocchi su stdout.
import logging
import re
import sys

from pdf2docx import Converter

source, target = sys.argv[1], sys.argv[2]
logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")

converter = Converter(source)
try:
    converter.convert(target)
finally:
    converter.close()


STANDARD_FONTS = {
    "times": "Times New Roman", "helvetica": "Helvetica", "courier": "Courier New",
    "symbol": "Symbol", "zapfdingbats": "Zapf Dingbats", "arial": "Arial",
}


def font_family(name):
    # Nome del carattere nel PDF ("ABCDEF+Helvetica-Bold", "TimesNewRomanPSMT") -> famiglia ("Helvetica").
    name = re.sub(r"^[A-Z]{6}\+", "", name or "")
    if not name or name.startswith("Type3"):
        return None
    base = re.split(r"[-,]", name)[0]
    base = re.sub(r"(PSMT|PS|MT)$", "", base)
    if base.lower() in STANDARD_FONTS:
        return STANDARD_FONTS[base.lower()]
    if " " not in base:
        base = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", base)
    return base.strip() or None


def pdf_fonts(path):
    # Carattere di ogni pezzo di testo del PDF e carattere principale (quello con più testo).
    try:
        try:
            import pymupdf as mupdf
        except ImportError:
            import fitz as mupdf
        by_text, totals = {}, {}
        with mupdf.open(path) as pdf:
            for page in pdf:
                for block in page.get_text("dict")["blocks"]:
                    for line in block.get("lines", []):
                        for span in line["spans"]:
                            family = font_family(span.get("font"))
                            text = span.get("text", "").strip()
                            if family and text:
                                by_text.setdefault(text, family)
                                totals[family] = totals.get(family, 0) + len(text)
        main = max(totals, key=totals.get) if totals else None
        return by_text, main
    except Exception:
        return {}, None


def polish(path, pdf_path):
    from docx import Document
    from docx.oxml import OxmlElement
    from docx.oxml.ns import qn

    W_P, W_R, W_T, W_TAB = qn("w:p"), qn("w:r"), qn("w:t"), qn("w:tab")
    W_RPR, W_PPR, W_TBL = qn("w:rPr"), qn("w:pPr"), qn("w:tbl")
    W_SECT, W_DRAWING = qn("w:sectPr"), qn("w:drawing")

    document = Document(path)
    body = document.element.body
    summary = {}

    def text_of(element):
        return "".join(t.text or "" for t in element.iter(W_T))

    # 1) Righe di tabella ad altezza minima invece che fissa: il testo nelle celle non viene tagliato.
    count = 0
    for height in body.iter(qn("w:trHeight")):
        if height.get(qn("w:hRule")) == "exact":
            height.set(qn("w:hRule"), "atLeast")
            count += 1
    summary["righe di tabella non più tagliate"] = count

    # 2) Sezioni continue: il testo scorre da una pagina all'altra, senza pagine quasi vuote.
    count = 0
    for section in body.iter(W_SECT):
        kind = section.find(qn("w:type"))
        if kind is None:
            kind = OxmlElement("w:type")
            page_size = section.find(qn("w:pgSz"))
            if page_size is not None:
                page_size.addprevious(kind)
            else:
                section.append(kind)
        kind.set(qn("w:val"), "continuous")
        count += 1
    summary["sezioni rese continue"] = count

    # 3) Intestazioni e piè di pagina ripetuti (ad esempio quelli aggiunti dal browser: data, nome, indirizzo, "1/11").
    #    Si guardano i primi e gli ultimi pezzi di testo di ogni pagina: quelli uguali (a parte i numeri) in più
    #    della metà delle pagine si tolgono. Date e numeri da soli si tolgono solo se accanto a un'intestazione
    #    riconosciuta (o se sono numeri di pagina), così una tabella che inizia con una data non viene toccata.
    sections, current = [], []
    for element in list(body):
        if element.tag == W_SECT:
            continue
        current.append(element)
        properties = element.find(W_PPR) if element.tag == W_P else None
        if properties is not None and properties.find(W_SECT) is not None:
            sections.append(current)
            current = []
    if current:
        sections.append(current)

    page_number = re.compile(r"^(#\s*/\s*#|(pag\.?|pagina|page)\s*#(\s*(di|of|/)\s*#)?)$", re.IGNORECASE)

    def run_key(run):
        text = re.sub(r"\s+", " ", "".join(t.text or "" for t in run.iter(W_T))).strip()
        return re.sub(r"\d+", "#", text) if 0 < len(text) <= 250 else ""

    def letters(key):
        return sum(ch.isalpha() for ch in key)

    count = 0
    if len(sections) >= 3:
        threshold = max(3, (len(sections) + 1) // 2)
        occurrences = {}  # chiave -> [(sezione, run, blocco)]
        for index, blocks in enumerate(sections):
            runs = [(run, block) for block in blocks for run in block.iter(W_R) if run_key(run)]
            seen = set()
            for run, block in runs[:4] + runs[-4:]:
                key = run_key(run)
                if (key, id(run)) in seen:
                    continue
                seen.add((key, id(run)))
                occurrences.setdefault(key, []).append((index, run, block))

        def pages(key):
            return len({index for index, _, _ in occurrences[key]})

        strong = {k for k in occurrences if letters(k) >= 3 and pages(k) >= threshold}
        header_blocks = {id(block) for k in strong for _, _, block in occurrences[k]}
        to_remove = []
        for key, items in occurrences.items():
            if key in strong:
                to_remove += items
            elif pages(key) >= threshold and letters(key) < 3:
                for item in items:
                    if page_number.match(key) or id(item[2]) in header_blocks:
                        to_remove.append(item)

        touched = []
        for _, run, block in to_remove:
            parent = run.getparent()
            if parent is None:
                continue
            paragraph = run
            while paragraph is not None and paragraph.tag != W_P:
                paragraph = paragraph.getparent()
            parent.remove(run)
            count += 1
            if paragraph is not None:
                touched.append((paragraph, block))

        def has_content(element):
            return bool(text_of(element).strip()) or any(True for _ in element.iter(W_DRAWING))

        for paragraph, block in touched:
            # Tabulazioni e spazi rimasti all'inizio o alla fine della riga.
            for edge in (0, -1):
                while True:
                    runs = paragraph.findall(W_R)
                    if not runs:
                        break
                    run = runs[edge]
                    content = [c for c in run if c.tag != W_RPR]
                    blank = all(c.tag == W_TAB for c in content) or (
                        not any(c.tag == W_DRAWING for c in run.iter()) and not text_of(run).strip())
                    if not blank:
                        break
                    paragraph.remove(run)
            if paragraph.getparent() is body and not has_content(paragraph):
                properties = paragraph.find(W_PPR)
                if properties is not None and properties.find(W_SECT) is not None:
                    continue
                body.remove(paragraph)
        for _, _, block in to_remove:
            if block.tag == W_TBL and block.getparent() is body and not has_content(block):
                body.remove(block)
    summary["pezzi di intestazione/piè di pagina tolti"] = count

    # 4) Righe del PDF spezzate con tabulazioni dentro lo stesso paragrafo: diventano testo continuo.
    #    Negli elenchi (pallino + tabulazione) si imposta un rientro sporgente, così le righe restano allineate.
    count = 0
    for paragraph in body.iter(W_P):
        runs = paragraph.findall(W_R)
        previous = None
        for run in runs:
            content = [child for child in run if child.tag != W_RPR]
            if len(content) == 1 and content[0].tag == W_TAB:
                if previous is not None and previous.strip():
                    if previous.endswith((" ", " ")):
                        paragraph.remove(run)
                    else:
                        run.remove(content[0])
                        space = OxmlElement("w:t")
                        space.set(qn("xml:space"), "preserve")
                        space.text = " "
                        run.append(space)
                    count += 1
                continue
            text = "".join(t.text or "" for t in run.iter(W_T))
            if text:
                previous = text
            elif any(child.tag == W_DRAWING for child in run.iter()):
                previous = None

        # Elenco: il primo elemento è un'immagine (il pallino) seguita da una tabulazione.
        remaining = paragraph.findall(W_R)
        if len(remaining) >= 2 and any(c.tag == W_DRAWING for c in remaining[0].iter()):
            # Pallino disegnato come immagine minuscola: diventa il carattere "•", che tutti i programmi allineano bene.
            extent = next(remaining[0].iter(qn("wp:extent")), None)
            if extent is not None and int(extent.get("cx", "0")) <= 152400 and int(extent.get("cy", "0")) <= 152400:
                for child in [c for c in remaining[0] if c.tag != W_RPR]:
                    remaining[0].remove(child)
                bullet = OxmlElement("w:t")
                bullet.text = "•"
                remaining[0].append(bullet)
            second = [c for c in remaining[1] if c.tag != W_RPR]
            properties = paragraph.find(W_PPR)
            if second and second[0].tag == W_TAB and properties is not None:
                tabs = properties.find(qn("w:tabs"))
                indent = properties.find(qn("w:ind"))
                if tabs is not None and indent is not None:
                    positions = [int(t.get(qn("w:pos"))) for t in tabs.findall(qn("w:tab")) if t.get(qn("w:pos"), "").lstrip("-").isdigit()]
                    left = int(indent.get(qn("w:left"), "0") or 0)
                    stops = [p for p in positions if p > left]
                    if stops:
                        indent.set(qn("w:left"), str(stops[0]))
                        indent.set(qn("w:hanging"), str(stops[0] - left))
                        if indent.get(qn("w:firstLine")) is not None:
                            del indent.attrib[qn("w:firstLine")]
                        # Il rientro sporgente fa già da tabulazione: quella esplicita confonderebbe alcuni programmi.
                        for stop in tabs.findall(qn("w:tab")):
                            if stop.get(qn("w:pos")) == str(stops[0]):
                                tabs.remove(stop)
                        if len(tabs) == 0:
                            properties.remove(tabs)
    summary["righe ricongiunte"] = count

    # 5) Margini: pdf2docx copia quelli del PDF, spesso quasi a zero (la prima riga finisce attaccata al bordo
    #    e Word avvisa che si esce dall'area stampabile). Minimo 2 cm sopra e sotto, 1 cm ai lati.
    count = 0
    for section in body.iter(W_SECT):
        margin = section.find(qn("w:pgMar"))
        if margin is None:
            continue
        changed = False
        for attribute, minimum in (("w:top", 1134), ("w:bottom", 1134), ("w:left", 567), ("w:right", 567)):
            value = margin.get(qn(attribute))
            if value is not None and value.lstrip("-").isdigit() and abs(int(value)) < minimum:
                margin.set(qn(attribute), str(minimum))
                changed = True
        for attribute in ("w:header", "w:footer"):
            value = margin.get(qn(attribute))
            if value is not None and value.isdigit() and int(value) > 567:
                margin.set(qn(attribute), "567")
        count += 1 if changed else 0
    summary["sezioni con margini corretti"] = count

    # 6) Caratteri: pdf2docx a volte lascia vuoto il nome del carattere (Word allora usa il suo predefinito).
    #    Ogni pezzo di testo riprende il carattere che aveva nel PDF; quello principale diventa il predefinito.
    by_text, main_family = pdf_fonts(pdf_path)
    count = 0
    if main_family:
        for run in body.iter(W_R):
            properties = run.find(W_RPR)
            fonts = properties.find(qn("w:rFonts")) if properties is not None else None
            if fonts is None or fonts.get(qn("w:ascii")) or fonts.get(qn("w:hAnsi")):
                continue
            chosen = by_text.get(text_of(run).strip(), main_family)
            for attribute in ("w:ascii", "w:hAnsi", "w:eastAsia", "w:cs"):
                fonts.set(qn(attribute), chosen)
            count += 1
        defaults = document.styles.element.find(".//" + qn("w:rPrDefault") + "//" + qn("w:rFonts"))
        if defaults is not None:
            for attribute in ("w:asciiTheme", "w:hAnsiTheme", "w:cstheme"):
                if defaults.get(qn(attribute)) is not None:
                    del defaults.attrib[qn(attribute)]
            for attribute in ("w:ascii", "w:hAnsi", "w:cs"):
                defaults.set(qn(attribute), main_family)
    summary["caratteri ripristinati"] = count

    document.save(path)
    return summary


try:
    result = polish(target, source)
    print("ritocchi: " + ", ".join(f"{k} {v}" for k, v in result.items()))
except Exception as error:  # i ritocchi sono facoltativi: il Word di pdf2docx resta comunque valido
    print(f"ritocchi non applicati: {error}")
"""#
}
