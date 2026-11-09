import Foundation

public enum FlipError: Error, LocalizedError {
    case unsupported(String)
    case missingTool(name: String, hint: String)
    case failed(String)
    case parse(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupported(let message):
            return message
        case .missingTool(let name, let hint):
            return "Strumento mancante: \(name). \(hint)"
        case .failed(let message):
            return message
        case .parse(let message):
            return message
        case .cancelled:
            return "Conversione annullata."
        }
    }
}
