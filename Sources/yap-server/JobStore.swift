import Foundation

actor JobStore {
    enum Status: Sendable {
        case queued
        case running
        case done(transcript: String, format: String)
        case failed(String)
        case cancelled
    }

    enum CancelResult { case cancelled, notFound, alreadyTerminal }

    struct Job: Sendable {
        var status: Status
        var name: String?
        var backend: String
    }

    private var jobs: [String: Job] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func create(_ id: String, name: String?, backend: String) {
        jobs[id] = Job(status: .queued, name: name, backend: backend)
    }

    func get(_ id: String) -> Job? { jobs[id] }

    /// Update status, unless the job was already cancelled (a late background
    /// update must not overwrite the canonical cancelled state).
    func update(_ id: String, status: Status) {
        guard var job = jobs[id] else { return }
        if case .cancelled = job.status { return }
        job.status = status
        jobs[id] = job
    }

    func register(_ id: String, task: Task<Void, Never>) { tasks[id] = task }
    func removeTask(_ id: String) { tasks[id] = nil }

    func cancel(_ id: String) -> CancelResult {
        guard var job = jobs[id] else { return .notFound }
        switch job.status {
        case .queued, .running:
            tasks[id]?.cancel()
            tasks[id] = nil
            job.status = .cancelled
            jobs[id] = job
            return .cancelled
        case .done, .failed, .cancelled:
            return .alreadyTerminal
        }
    }
}
