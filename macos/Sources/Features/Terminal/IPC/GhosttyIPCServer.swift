import Foundation
import Cocoa
import UserNotifications
import OSLog

/// A Unix domain socket server that allows external processes to control Ghostty tabs.
///
/// Protocol: newline-delimited JSON over a Unix domain socket at `/tmp/ghostty-{uid}.sock`.
///
/// Request format:
/// ```json
/// {"method": "tab.rename", "params": {"tab_id": "optional-uuid", "title": "New Title"}}
/// ```
///
/// Response format:
/// ```json
/// {"ok": true, "result": {...}}
/// {"ok": false, "error": "message"}
/// ```
@MainActor
final class GhosttyIPCServer {
    static let shared = GhosttyIPCServer()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "IPC"
    )

    private var serverFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: ClientConnection] = [:]
    private var socketPath: String = ""

    /// Per-client state for buffering partial reads.
    private class ClientConnection {
        let fd: Int32
        var readSource: DispatchSourceRead?
        var buffer: Data = Data()

        init(fd: Int32) {
            self.fd = fd
        }
    }

    private init() {}

    // MARK: - Lifecycle

    func start() {
        let uid = getuid()
        socketPath = "/tmp/ghostty-\(uid).sock"

        // Remove stale socket if it exists
        unlink(socketPath)

        // Create socket
        serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            Self.logger.warning("IPC: failed to create socket: \(errno)")
            return
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Self.logger.warning("IPC: socket path too long")
            close(serverFd)
            serverFd = -1
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for i in 0..<pathBytes.count {
                    dest[i] = pathBytes[i]
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Self.logger.warning("IPC: failed to bind socket: \(errno)")
            close(serverFd)
            serverFd = -1
            return
        }

        // Set permissions to user-only
        chmod(socketPath, 0o600)

        // Listen
        guard Darwin.listen(serverFd, 5) == 0 else {
            Self.logger.warning("IPC: failed to listen: \(errno)")
            close(serverFd)
            serverFd = -1
            return
        }

        // Set non-blocking
        let flags = fcntl(serverFd, F_GETFL)
        fcntl(serverFd, F_SETFL, flags | O_NONBLOCK)

        // Accept loop via DispatchSource
        let source = DispatchSource.makeReadSource(fileDescriptor: serverFd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.acceptClient()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.serverFd, fd >= 0 {
                close(fd)
                self?.serverFd = -1
            }
        }
        source.resume()
        acceptSource = source

        Self.logger.info("IPC: listening on \(self.socketPath)")
    }

    func stop() {
        // Cancel accept source
        acceptSource?.cancel()
        acceptSource = nil

        // Disconnect all clients
        for (_, client) in clients {
            disconnectClient(client)
        }
        clients.removeAll()

        // Remove socket file
        if !socketPath.isEmpty {
            unlink(socketPath)
        }

        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }

        Self.logger.info("IPC: stopped")
    }

    // MARK: - Client Management

    private func acceptClient() {
        var addr = sockaddr_un()
        var len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFd = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(serverFd, sockPtr, &len)
            }
        }
        guard clientFd >= 0 else { return }

        // Set non-blocking
        let flags = fcntl(clientFd, F_GETFL)
        fcntl(clientFd, F_SETFL, flags | O_NONBLOCK)

        let client = ClientConnection(fd: clientFd)

        let readSource = DispatchSource.makeReadSource(fileDescriptor: clientFd, queue: .main)
        readSource.setEventHandler { [weak self] in
            self?.readFromClient(clientFd)
        }
        readSource.setCancelHandler {
            close(clientFd)
        }
        readSource.resume()
        client.readSource = readSource

        clients[clientFd] = client
    }

    private func readFromClient(_ fd: Int32) {
        guard let client = clients[fd] else { return }

        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)

        if n <= 0 {
            // EOF or error — disconnect
            disconnectClient(client)
            clients.removeValue(forKey: fd)
            return
        }

        client.buffer.append(contentsOf: buf[0..<n])

        // Process complete lines
        while let newlineIndex = client.buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = client.buffer[client.buffer.startIndex..<newlineIndex]
            client.buffer.removeSubrange(client.buffer.startIndex...newlineIndex)

            guard !lineData.isEmpty else { continue }
            processRequest(data: Data(lineData), client: client)
        }

        // Guard against excessively large buffers (no newline after 1MB)
        if client.buffer.count > 1_048_576 {
            disconnectClient(client)
            clients.removeValue(forKey: fd)
        }
    }

    private func disconnectClient(_ client: ClientConnection) {
        client.readSource?.cancel()
        client.readSource = nil
    }

    // MARK: - Request Processing

    private func processRequest(data: Data, client: ClientConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            sendError("invalid request: expected JSON with 'method' field", to: client)
            return
        }

        let params = json["params"] as? [String: Any] ?? [:]

        switch method {
        case "tab.rename":
            handleTabRename(params: params, client: client)
        case "tab.notify":
            handleTabNotify(params: params, client: client)
        case "tab.set-status":
            handleTabSetStatus(params: params, client: client)
        case "tab.clear-status":
            handleTabClearStatus(params: params, client: client)
        case "tab.list":
            handleTabList(client: client)
        case "tab.current":
            handleTabCurrent(client: client)
        default:
            sendError("unknown method: \(method)", to: client)
        }
    }

    // MARK: - Method Handlers

    private func handleTabRename(params: [String: Any], client: ClientConnection) {
        guard let title = params["title"] as? String else {
            sendError("tab.rename requires 'title' param", to: client)
            return
        }

        guard let controller = resolveController(params: params) else {
            sendError("tab not found", to: client)
            return
        }

        controller.titleOverride = title.isEmpty ? nil : title
        sendOk(["renamed": true], to: client)
    }

    private func handleTabNotify(params: [String: Any], client: ClientConnection) {
        let title = params["title"] as? String ?? "Ghostty"
        let body = params["body"] as? String ?? ""

        // macOS notification (shows as banner when app is not focused)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.logger.warning("IPC: notification error: \(error)")
            }
        }

        // Sidebar attention indicator (visible when app is focused)
        if let controller = resolveController(params: params),
           let window = controller.window {
            NotificationCenter.default.post(
                name: .ghosttyIPCNotification,
                object: window
            )
        }

        sendOk(["notified": true], to: client)
    }

    private func handleTabSetStatus(params: [String: Any], client: ClientConnection) {
        guard let key = params["key"] as? String,
              let value = params["value"] as? String else {
            sendError("tab.set-status requires 'key' and 'value' params", to: client)
            return
        }

        guard let surface = resolveSurface(params: params) else {
            sendError("tab not found", to: client)
            return
        }

        let icon = params["icon"] as? String
        TabMetadataStore.shared.setStatus(tabId: surface.id, key: key, value: value, icon: icon)
        sendOk(["status_set": true], to: client)
    }

    private func handleTabClearStatus(params: [String: Any], client: ClientConnection) {
        guard let key = params["key"] as? String else {
            sendError("tab.clear-status requires 'key' param", to: client)
            return
        }

        guard let surface = resolveSurface(params: params) else {
            sendError("tab not found", to: client)
            return
        }

        TabMetadataStore.shared.clearStatus(tabId: surface.id, key: key)
        sendOk(["status_cleared": true], to: client)
    }

    private func handleTabList(client: ClientConnection) {
        var tabInfos: [[String: Any]] = []

        let keyWindow = NSApp.keyWindow

        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            guard let surface = controller.focusedSurface else { continue }

            tabInfos.append(tabInfo(
                surface: surface,
                controller: controller,
                window: window,
                isActive: window === keyWindow
            ))
        }

        sendOk(["tabs": tabInfos], to: client)
    }

    private func handleTabCurrent(client: ClientConnection) {
        guard let window = NSApp.keyWindow,
              let controller = window.windowController as? BaseTerminalController,
              let surface = controller.focusedSurface else {
            sendError("no active tab", to: client)
            return
        }

        sendOk(tabInfo(surface: surface, controller: controller, window: window, isActive: true), to: client)
    }

    // MARK: - Tab Resolution

    /// Resolve a `BaseTerminalController` from params. If `tab_id` is provided, finds the
    /// matching tab; otherwise returns the key window's controller.
    private func resolveController(params: [String: Any]) -> BaseTerminalController? {
        if let tabIdStr = params["tab_id"] as? String,
           let tabId = UUID(uuidString: tabIdStr) {
            return controllerForSurfaceId(tabId)
        }

        // Default: key window
        return NSApp.keyWindow?.windowController as? BaseTerminalController
    }

    /// Resolve a `Ghostty.SurfaceView` from params.
    private func resolveSurface(params: [String: Any]) -> Ghostty.SurfaceView? {
        if let tabIdStr = params["tab_id"] as? String,
           let tabId = UUID(uuidString: tabIdStr) {
            return surfaceForId(tabId)
        }

        // Default: key window's focused surface
        return (NSApp.keyWindow?.windowController as? BaseTerminalController)?.focusedSurface
    }

    /// Find the controller that owns a surface with the given UUID.
    private func controllerForSurfaceId(_ id: UUID) -> BaseTerminalController? {
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            if controller.focusedSurface?.id == id {
                return controller
            }
        }
        return nil
    }

    /// Find a surface by UUID across all windows.
    private func surfaceForId(_ id: UUID) -> Ghostty.SurfaceView? {
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            if let surface = controller.focusedSurface, surface.id == id {
                return surface
            }
        }
        return nil
    }

    // MARK: - Tab Info

    private func tabInfo(
        surface: Ghostty.SurfaceView,
        controller: BaseTerminalController,
        window: NSWindow,
        isActive: Bool
    ) -> [String: Any] {
        var info: [String: Any] = [
            "tab_id": surface.id.uuidString,
            "title": controller.titleOverride ?? window.title,
            "is_active": isActive,
        ]
        if let pwd = surface.pwd {
            info["pwd"] = pwd
        }
        return info
    }

    // MARK: - Response Helpers

    private func sendOk(_ result: [String: Any], to client: ClientConnection) {
        let response: [String: Any] = ["ok": true, "result": result]
        sendJSON(response, to: client)
    }

    private func sendError(_ message: String, to client: ClientConnection) {
        let response: [String: Any] = ["ok": false, "error": message]
        sendJSON(response, to: client)
    }

    private func sendJSON(_ obj: [String: Any], to client: ClientConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        let bytes = Array(line.utf8)
        bytes.withUnsafeBufferPointer { buf in
            var written = 0
            while written < buf.count {
                let n = write(client.fd, buf.baseAddress! + written, buf.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }
}
