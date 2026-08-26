import Foundation
import CoreFoundation

enum BridgeMessage: Int32 {
    case ping = 1
    case apply = 2
    case clear = 3
    case status = 4
    case reload = 5
}

enum BridgeError: LocalizedError {
    case unavailable
    case ipc(Int32)
    case rejected(String)
    case badPayload

    var errorDescription: String? {
        switch self {
        case .unavailable: return "SpringBoard Bridge не загружен."
        case .ipc(let code): return "Ошибка IPC со SpringBoard: \(code)"
        case .rejected(let text): return text
        case .badPayload: return "Некорректная тема."
        }
    }
}

final class SpringBoardBridgeClient {
    static let shared = SpringBoardBridgeClient()
    private let portName = "com.nomadvorga.opaqueiconthemer.bridge" as CFString

    private init() {}

    func ping() -> Bool {
        guard let data = try? request(.ping, payload: Data()) else { return false }
        return String(data: data, encoding: .utf8) == "pong"
    }

    func status() -> String {
        guard let data = try? request(.status, payload: Data()) else {
            return "Bridge unavailable"
        }
        return String(data: data, encoding: .utf8) ?? "Bridge active"
    }

    func apply(_ theme: [String: Data]) throws -> String {
        guard PropertyListSerialization.propertyList(theme, isValidFor: .binary) else {
            throw BridgeError.badPayload
        }
        let payload = try PropertyListSerialization.data(
            fromPropertyList: theme,
            format: .binary,
            options: 0
        )
        let reply = try request(.apply, payload: payload, timeout: 3.0)
        let text = String(data: reply, encoding: .utf8) ?? ""
        guard text.hasPrefix("ok:") else {
            throw BridgeError.rejected(text.isEmpty ? "SpringBoard отклонил тему." : text)
        }
        return text
    }

    func clear() throws -> String {
        let reply = try request(.clear, payload: Data(), timeout: 2.0)
        let text = String(data: reply, encoding: .utf8) ?? ""
        guard text.hasPrefix("ok:") else {
            throw BridgeError.rejected(text.isEmpty ? "Сброс не выполнен." : text)
        }
        return text
    }

    private func request(
        _ message: BridgeMessage,
        payload: Data,
        timeout: CFTimeInterval = 1.0
    ) throws -> Data {
        guard let remote = CFMessagePortCreateRemote(kCFAllocatorDefault, portName) else {
            throw BridgeError.unavailable
        }

        var response: Unmanaged<CFData>?
        let result = CFMessagePortSendRequest(
            remote,
            message.rawValue,
            payload as CFData,
            timeout,
            timeout,
            CFRunLoopMode.defaultMode.rawValue,
            &response
        )
        guard result == kCFMessagePortSuccess else {
            throw BridgeError.ipc(result)
        }
        return (response?.takeRetainedValue() as Data?) ?? Data()
    }
}
