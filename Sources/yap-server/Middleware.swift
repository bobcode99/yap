import Foundation
import HTTPTypes
import Hummingbird

struct APIKeyMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext
    let apiKey: String

    func handle(
        _ request: Request,
        context: BasicRequestContext,
        next: (Request, BasicRequestContext) async throws -> Response
    ) async throws -> Response {
        if request.uri.path == "/health" {
            return try await next(request, context)
        }
        guard request.headers[HTTPField.Name("X-API-Key")!] == apiKey else {
            return Response(
                status: .unauthorized,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(string: #"{"error":"Invalid API key"}"#))
            )
        }
        return try await next(request, context)
    }
}
