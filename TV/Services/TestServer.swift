import Foundation
import Network

/// Lets the simulator be driven from the Mac during testing: opening pages, simulated remote
/// presses and running page scripts. It only starts when Lantern is launched with LANTERN_DEBUG=1,
/// so the app on the TV never listens on the network.
@MainActor
final class TestServer {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["LANTERN_DEBUG"] == "1" }

    var onOpen: ((URL) -> Void)?
    var onCommand: (([String: Any], @escaping (Any?) -> Void) -> Void)?

    private var listener: NWListener?

    func start() {
        guard Self.isEnabled, listener == nil, let port = NWEndpoint.Port(rawValue: 8765) else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Only reachable from the Mac running the simulator.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else {
                    connection.cancel()
                    return
                }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = HTTPRequest(data: buffer) {
                    self.respond(to: request, on: connection)
                } else if isComplete || error != nil || buffer.count > 256 * 1024 {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        let send = { (response: HTTPResponse) in
            connection.send(content: response.data, completion: .contentProcessed { _ in connection.cancel() })
        }
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        switch (request.method, request.path) {
        case ("POST", "/open"):
            if let text = body["url"] as? String, let url = URLInput.resolve(text) {
                onOpen?(url)
                send(.json(["ok": true]))
            } else {
                send(.json(["ok": false], status: 400))
            }
        case ("POST", "/debug"):
            onCommand?(body) { result in
                send(.json(["result": result.map { "\($0)" } ?? NSNull()]))
            }
        default:
            send(.text("Not found", status: 404))
        }
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Returns nil until `data` holds a whole request.
    init?(data: Data) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data.subdata(in: data.startIndex..<headerEnd.lowerBound), encoding: .utf8)
        else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        method = requestLine[0].uppercased()
        path = URLComponents(string: String(requestLine[1]))?.path ?? String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers

        let length = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.endIndex - bodyStart >= length else { return nil }
        body = data.subdata(in: bodyStart..<(bodyStart + length))
    }

}

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data

    static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    static func json(_ object: [String: Any], status: Int = 200) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return HTTPResponse(status: status, contentType: "application/json", body: body)
    }

    var data: Data {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found"][status] ?? "OK"
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
