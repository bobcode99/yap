import Foundation

actor JobStore {
    typealias EventContinuation = AsyncStream<JobEvent>.Continuation

    enum Status: Sendable {
        case queued
        case running
        case done(transcript: String, format: String)
        case failed(String)
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .done, .failed, .cancelled: true
            case .queued, .running: false
            }
        }
    }

    enum CancelResult { case cancelled, notFound, alreadyTerminal }

    struct Job: Sendable {
        var status: Status
        var name: String?
        var backend: String
        var progress: Int?
    }

    private var jobs: [String: Job] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var subscribers: [String: [UUID: EventContinuation]] = [:]

    func subscribe(id: String) -> AsyncStream<JobEvent> {
        let (stream, continuation) = AsyncStream<JobEvent>.makeStream()
        let subID = UUID()
        subscribers[id, default: [:]][subID] = continuation
        if let job = jobs[id] {
            continuation.yield(JobEvent(from: job.status, progress: job.progress))
            if job.status.isTerminal {
                continuation.finish()
            }
        }
        continuation.onTermination = { @Sendable [self, id, subID] _ in
            Task { await self.removeSubscriber(id: id, subID: subID) }
        }
        return stream
    }

    private func removeSubscriber(id: String, subID: UUID) {
        subscribers[id]?.removeValue(forKey: subID)
    }

    private func broadcast(_ id: String, event: JobEvent) {
        for (_, c) in subscribers[id] ?? [:] { c.yield(event) }
        if event.isTerminal {
            for (_, c) in subscribers[id] ?? [:] { c.finish() }
            subscribers[id] = nil
        }
    }

    func create(_ id: String, name: String?, backend: String) {
        jobs[id] = Job(status: .queued, name: name, backend: backend)
        broadcast(id, event: .queued)
    }

    func get(_ id: String) -> Job? { jobs[id] }

    func update(_ id: String, status: Status) {
        guard var job = jobs[id] else { return }
        if case .cancelled = job.status { return }
        job.status = status
        jobs[id] = job
        broadcast(id, event: JobEvent(from: status, progress: job.progress))
    }

    func updateProgress(_ id: String, progress: Int) {
        guard var job = jobs[id], case .running = job.status else { return }
        job.progress = progress
        jobs[id] = job
        broadcast(id, event: .running(progress: progress))
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
            broadcast(id, event: .cancelled)
            return .cancelled
        case .done, .failed, .cancelled:
            return .alreadyTerminal
        }
    }
}

// MARK: - Conversion

extension JobEvent {
    init(from status: JobStore.Status, progress: Int?) {
        switch status {
        case .queued: self = .queued
        case .running: self = .running(progress: progress)
        case let .done(t, f): self = .done(transcript: t, format: f)
        case let .failed(e): self = .failed(e)
        case .cancelled: self = .cancelled
        }
    }
}
