import Foundation
import NibCore

extension EngineDelegate {

    /// Map URLError codes onto something a user can act on. `-1202` is not a message.
    static func failure(from error: Error) -> SendEvent.Failure {
        guard let urlError = error as? URLError else {
            return SendEvent.Failure(kind: .other(code: 0), message: error.localizedDescription)
        }

        switch urlError.code {
        case .cancelled:
            return SendEvent.Failure(kind: .cancelled, message: "Cancelled.")
        case .timedOut:
            return SendEvent.Failure(
                kind: .timedOut, message: "The request timed out. Raise the timeout in settings.")
        case .cannotConnectToHost, .networkConnectionLost:
            return SendEvent.Failure(
                kind: .cannotConnect,
                message: "Could not connect to the host. Is it running and reachable?")
        case .cannotFindHost:
            return SendEvent.Failure(
                kind: .dnsFailure, message: "Could not resolve the hostname. Check for a typo.")
        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
            .secureConnectionFailed:
            return SendEvent.Failure(
                kind: .tlsUntrusted(reason: urlError.localizedDescription),
                message: urlError.localizedDescription
                    + " You can disable TLS verification for this request in its settings."
            )
        case .httpTooManyRedirects:
            return SendEvent.Failure(
                kind: .tooManyRedirects, message: "Too many redirects.")
        default:
            return SendEvent.Failure(
                kind: .other(code: urlError.errorCode), message: urlError.localizedDescription)
        }
    }
}
