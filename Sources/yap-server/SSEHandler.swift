import Foundation
import Hummingbird
import NIOCore

enum SSEHandler {
    static func eventStream(store: JobStore, id: String) async -> AsyncStream<ByteBuffer> {
        let events = await store.subscribe(id: id)
        return AsyncStream { continuation in
            let eventsTask = Task {
                for await event in events {
                    continuation.yield(encode(event: event, id: id))
                }
                continuation.finish()
            }
            let keepaliveTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    continuation.yield(.init(string: ":keepalive\n\n"))
                }
            }
            continuation.onTermination = { @Sendable _ in
                eventsTask.cancel()
                keepaliveTask.cancel()
            }
        }
    }

    private static func encode(event: JobEvent, id: String) -> ByteBuffer {
        let payload = jsonPayload(event: event, id: id)
        return .init(string: "event: \(event.statusLabel)\ndata: \(payload)\n\n")
    }

    private static func jsonPayload(event: JobEvent, id: String) -> String {
        let obj: [String: Any?] = [
            "id": id,
            "status": event.statusLabel,
            "progress": event.progressValue,
            "transcript": event.transcript,
            "format": event.format,
            "error": event.error,
        ]
        let compact = obj.compactMapValues { $0 }
        guard let data = try? JSONSerialization.data(withJSONObject: compact) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
