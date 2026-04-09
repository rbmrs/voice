import Foundation

enum DictationServiceError: LocalizedError {
    case configuration(String)
    case permission(String)
    case processFailure(tool: String, details: String)
    case emptyResult(String)
    case insertionFailure(String)

    var errorDescription: String? {
        switch self {
        case .configuration(let message):
            message
        case .permission(let message):
            message
        case .processFailure(let tool, let details):
            "\(tool) failed. \(details)"
        case .emptyResult(let message):
            message
        case .insertionFailure(let message):
            message
        }
    }
}
