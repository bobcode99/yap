import Foundation
import Hummingbird
import NIOCore

enum SSEHandler {
    static func eventStream(store: JobStore, id: String) async -> AsyncStream<ByteBuffer> {
        let events = await store.subscribe(id: id)
        return AsyncStream { continuation in
            // retry: tells EventSource how long to wait before reconnecting.
            continuation.yield(.init(string: "retry: 3000\n\n"))
            let eventsTask = Task {
                var seq = 0
                for await event in events {
                    seq += 1
                    continuation.yield(encode(event: event, jobID: id, seq: seq))
                }
                continuation.finish()
            }
            let keepaliveTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    continuation.yield(.init(string: ": keepalive\n\n"))
                }
            }
            continuation.onTermination = { @Sendable _ in
                eventsTask.cancel()
                keepaliveTask.cancel()
            }
        }
    }

    private static func encode(event: JobEvent, jobID: String, seq: Int) -> ByteBuffer {
        let payload = jsonPayload(event: event, jobID: jobID)
        return .init(string: "id: \(seq)\nevent: \(event.statusLabel)\ndata: \(payload)\n\n")
    }

    private static func jsonPayload(event: JobEvent, jobID: String) -> String {
        // Report 100 on done so a client progress bar can reach completion.
        let progress = event.isTerminal && event.transcript != nil ? 100 : event.progressValue
        let obj: [String: Any?] = [
            "id": jobID,
            "status": event.statusLabel,
            "progress": progress,
            "transcript": event.transcript,
            "format": event.format,
            "error": event.error,
        ]
        let compact = obj.compactMapValues { $0 }
        guard let data = try? JSONSerialization.data(withJSONObject: compact) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
