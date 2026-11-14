import Foundation

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    /// Header names are lowercased.
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, query: [String: String], headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

public enum HTTPParse: Sendable {
    case incomplete
    case invalid
    case complete(HTTPRequest)
}

extension HTTPRequest {
    private static let maxHeaderBytes = 16_384
    private static let terminator = Data("\r\n\r\n".utf8)

    /// Parses one HTTP/1.1 request from `buffer`. Returns `.incomplete` until the headers
    /// and the full `Content-Length` body have arrived.
    public static func parse(_ buffer: Data, maxBody: Int = 256_000) -> HTTPParse {
        guard let headEnd = buffer.range(of: terminator) else {
            return buffer.count > maxHeaderBytes ? .invalid : .incomplete
        }
        guard headEnd.lowerBound <= maxHeaderBytes,
              let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8)
        else { return .invalid }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/"),
              requestLine[0].allSatisfy({ $0.isASCII && $0.isUppercase }),
              requestLine[1].hasPrefix("/")
        else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return .invalid }
            let name = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        var length = 0
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else { return .invalid }
            length = n
        }
        guard length <= maxBody else { return .invalid }

        let bodyStart = headEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])

        let target = String(requestLine[1])
        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<q])
            for pair in target[target.index(after: q)...].split(separator: "&", omittingEmptySubsequences: true) {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[0])
                let rawValue = kv.count > 1 ? String(kv[1]) : ""
                query[key] = rawValue.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawValue
            }
        }
        path = path.removingPercentEncoding ?? path

        return .complete(HTTPRequest(method: String(requestLine[0]), path: path, query: query, headers: headers, body: body))
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }

    private var reason: String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "Status"
        }
    }

    public func serialized() -> Data {
        var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        return out
    }
}
