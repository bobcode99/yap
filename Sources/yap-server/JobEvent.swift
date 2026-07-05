import Foundation

enum JobEvent: Sendable {
    case queued
    case running(progress: Int?)
    case done(transcript: String, format: String)
    case failed(String)
    case cancelled

    var statusLabel: String {
        switch self {
        case .queued: "queued"
        case .running: "running"
        case .done: "done"
        case .failed: "failed"
        case .cancelled: "cancelled"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .done, .failed, .cancelled: true
        case .queued, .running: false
        }
    }

    var progressValue: Int? {
        guard case let .running(p) = self else { return nil }
        return p
    }

    var transcript: String? {
        guard case let .done(t, _) = self else { return nil }
        return t
    }

    var format: String? {
        guard case let .done(_, f) = self else { return nil }
        return f
    }

    var error: String? {
        guard case let .failed(e) = self else { return nil }
        return e
    }
}
