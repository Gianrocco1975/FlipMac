import Foundation

/// Conversioni audio/video tramite FFmpeg (eseguito in locale).
/// Sceglie gli encoder in base a quelli realmente presenti nell'ffmpeg installato.
struct MediaConverter {
    let runner: ProcessRunner

    func convert(input: URL, target: String, output: URL, progress: ((Double) -> Void)?, notes: inout [String]) throws {
        guard let ffmpeg = ToolLocator.find("ffmpeg") else {
            throw FlipError.missingTool(name: "ffmpeg", hint: "Installalo con: brew install ffmpeg")
        }
        let encoders = FFmpegEncoders.available(ffmpeg)

        if FlipFormat.audio.contains(target),
           FlipFormat.category(of: input.pathExtension) == .video,
           MediaProbe.audioStreamCount(input) == 0 {
            throw FlipError.failed("Questo video non contiene una traccia audio (succede spesso con le registrazioni dello schermo): non c'è audio da estrarre.")
        }

        var arguments = [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-progress", "pipe:1", "-nostats",
            "-i", input.path
        ]
        arguments += try codecArguments(for: target, encoders: encoders, notes: &notes)
        arguments.append(output.path)

        let totalSeconds = probeDuration(of: input)
        // ffmpeg scrive l'avanzamento su stdout ("-progress pipe:1").
        try runner.run(ffmpeg, arguments, onStdoutLine: { line in
            guard let total = totalSeconds, total > 0 else { return }
            guard line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") else { return }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let microseconds = Double(parts[1]), microseconds >= 0 else { return }
            let fraction = microseconds / 1_000_000 / total
            progress?(min(max(fraction, 0), 0.99))
        })
    }

    private func codecArguments(for target: String, encoders: Set<String>, notes: inout [String]) throws -> [String] {
        let videoMaps = ["-map", "0:v:0", "-map", "0:a:0?"]
        switch target {
        // Video
        case "mp4", "m4v", "mov":
            return videoMaps + h264(encoders, notes: &notes) + ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case "mkv":
            return videoMaps + h264(encoders, notes: &notes) + ["-c:a", "aac", "-b:a", "192k"]
        case "webm":
            return videoMaps + vp9(encoders, notes: &notes) + opus(encoders, notes: &notes)
        case "avi":
            let audio = FFmpegEncoders.has("libmp3lame", in: encoders)
                ? ["-c:a", "libmp3lame", "-q:a", "3"]
                : ["-c:a", "pcm_s16le"]
            return videoMaps + ["-c:v", "mpeg4", "-q:v", "4"] + audio
        case "wmv":
            return videoMaps + ["-c:v", "wmv2", "-b:v", "4M", "-c:a", "wmav2", "-b:a", "192k"]
        // Audio (anche estratto da un video)
        case "mp3":
            guard FFmpegEncoders.has("libmp3lame", in: encoders) else {
                throw FlipError.missingTool(name: "libmp3lame", hint: "Il tuo ffmpeg non sa creare MP3. Reinstallalo con: brew reinstall ffmpeg")
            }
            return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "wav":
            return ["-vn", "-c:a", "pcm_s16le"]
        case "flac":
            return ["-vn", "-c:a", "flac"]
        case "ogg":
            return ["-vn"] + vorbis(encoders, notes: &notes)
        case "m4a":
            return ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case "aac":
            return ["-vn", "-c:a", "aac", "-b:a", "192k", "-f", "adts"]
        case "wma":
            return ["-vn", "-c:a", "wmav2", "-b:a", "192k"]
        case "opus":
            return ["-vn"] + opus(encoders, notes: &notes)
        default:
            throw FlipError.unsupported("Formato audio/video non supportato: \(target)")
        }
    }

    private func h264(_ encoders: Set<String>, notes: inout [String]) -> [String] {
        if FFmpegEncoders.has("libx264", in: encoders) {
            return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p"]
        }
        if encoders.contains("h264_videotoolbox") {
            notes.append("libx264 non è nel tuo ffmpeg: ho usato l'encoder hardware di macOS (VideoToolbox).")
            return ["-c:v", "h264_videotoolbox", "-b:v", "6M", "-pix_fmt", "yuv420p"]
        }
        notes.append("Nessun encoder H.264 nel tuo ffmpeg: ho usato MPEG-4 (qualità inferiore).")
        return ["-c:v", "mpeg4", "-q:v", "4"]
    }

    private func vp9(_ encoders: Set<String>, notes: inout [String]) -> [String] {
        if FFmpegEncoders.has("libvpx-vp9", in: encoders) {
            return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-cpu-used", "4", "-row-mt", "1"]
        }
        notes.append("libvpx-vp9 non è nel tuo ffmpeg: ho usato VP8.")
        return ["-c:v", "libvpx", "-crf", "10", "-b:v", "2M"]
    }

    private func opus(_ encoders: Set<String>, notes: inout [String]) -> [String] {
        if FFmpegEncoders.has("libopus", in: encoders) {
            return ["-c:a", "libopus", "-b:a", "128k"]
        }
        notes.append("libopus non è nel tuo ffmpeg: ho usato l'encoder Opus interno.")
        return ["-c:a", "opus", "-strict", "-2", "-ar", "48000", "-ac", "2", "-b:a", "128k"]
    }

    private func vorbis(_ encoders: Set<String>, notes: inout [String]) -> [String] {
        if FFmpegEncoders.has("libvorbis", in: encoders) {
            return ["-c:a", "libvorbis", "-q:a", "5"]
        }
        notes.append("libvorbis non è nel tuo ffmpeg (Homebrew l'ha tolto): ho usato l'encoder Vorbis interno, stereo e di qualità un po' inferiore. Per la qualità piena: brew install ffmpeg-full")
        return ["-c:a", "vorbis", "-strict", "-2", "-ac", "2"]
    }

    /// Durata in secondi (serve per calcolare la percentuale di avanzamento).
    private func probeDuration(of input: URL) -> Double? {
        guard let ffprobe = ToolLocator.find("ffprobe") else { return nil }
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            input.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(text)
    }
}
