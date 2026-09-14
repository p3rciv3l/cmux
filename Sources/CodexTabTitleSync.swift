import Foundation
import Darwin

/// One terminal's title bridge. Synchronizes names in both directions, suppressing echoes and stale reads.
@MainActor
final class CodexTabTitleSync {
    let sessionID: String
    private(set) var isApplyingSessionName = false
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var ready = false
    private var threadAvailable = false
    private var reading = false
    private var readAgain = false
    private var pendingName: String?
    private var lastName: String?
    private var generation = 0
    private var readGeneration = 0
    private var nextID = 2
    private var readID: Int?
    private var renameIDs: Set<Int> = []
    private var watchers: [DispatchSourceFileSystemObject] = []
    private let home: URL
    private let sessionNameChanged: (String) -> Void
    private let failure: (String) -> Void
    private let didRename: () -> Void

    init(sessionID: String, executable: URL, home: URL,
         sessionNameChanged: @escaping (String) -> Void, failure: @escaping (String) -> Void,
         didRename: @escaping () -> Void = {}) throws {
        self.sessionID = sessionID
        self.home = home
        self.sessionNameChanged = sessionNameChanged
        self.failure = failure
        self.didRename = didRename
        process.executableURL = executable
        let socket = home.appendingPathComponent("app-server-control/app-server-control.sock").path
        process.arguments = FileManager.default.fileExists(atPath: socket)
            ? ["app-server", "proxy", "--sock", socket] : ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        try process.run()
        send(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "cmux_title_sync", "version": "1"]
        ]])
        watchName()
    }

    deinit {
        output.fileHandleForReading.readabilityHandler = nil
        watchers.forEach { $0.cancel() }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    func rename(_ name: String) {
        guard !name.isEmpty else { return }
        generation += 1
        lastName = name
        pendingName = name
        flushRename()
    }

    private func flushRename() {
        guard ready, threadAvailable, renameIDs.isEmpty, let name = pendingName else { return }
        pendingName = nil
        let id = nextID
        nextID += 1
        renameIDs.insert(id)
        send(["id": id, "method": "thread/name/set", "params": ["threadId": sessionID, "name": name]])
    }

    private func refreshName() {
        guard ready else { return }
        guard !threadAvailable || (renameIDs.isEmpty && pendingName == nil) else { readAgain = true; return }
        guard !reading else { readAgain = true; return }
        reading = true
        readGeneration = generation
        readID = nextID
        nextID += 1
        send(["id": readID!, "method": "thread/read", "params": ["threadId": sessionID]])
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else {
            output.fileHandleForReading.readabilityHandler = nil
            ready = false
            stopWatching()
            failure("Codex title connection closed")
            return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            buffer.removeSubrange(...newline)
            guard let message else { continue }
            let id = message["id"] as? Int
            if id == 1, message["result"] != nil {
                ready = true
                send(["method": "initialized"])
                flushRename()
                refreshName()
            } else if let id, renameIDs.remove(id) != nil {
                if let error = message["error"] { failure(String(describing: error)) }
                else { didRename() }
                flushRename()
                if readAgain { readAgain = false; refreshName() }
            } else if let id, id == readID {
                reading = false
                readID = nil
                let result = message["result"] as? [String: Any]
                let thread = result?["thread"] as? [String: Any]
                threadAvailable = thread != nil
                if readGeneration == generation { adopt(thread?["name"] as? String) }
                else { readAgain = true }
                flushRename()
                if readAgain { readAgain = false; refreshName() }
            } else if message["method"] as? String == "thread/name/updated",
                      let params = message["params"] as? [String: Any],
                      params["threadId"] as? String == sessionID {
                adopt(params["threadName"] as? String)
            } else if id == 1, let error = message["error"] {
                failure(String(describing: error))
            }
        }
    }

    private func adopt(_ name: String?) {
        guard renameIDs.isEmpty, pendingName == nil else { readAgain = true; return }
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != lastName else { return }
        lastName = name
        isApplyingSessionName = true
        sessionNameChanged(name)
        isApplyingSessionName = false
    }

    private func send(_ message: [String: Any]) {
        do {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch { failure(error.localizedDescription) }
    }

    /// File events cover titles written by a separate TUI server, without polling or opening its DB.
    private func watchName() {
        stopWatching()
        let files = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        // Codex appends every name change here; watching the WAL would also wake on token traffic.
        for url in [home] + files.filter({ $0.lastPathComponent == "session_index.jsonl" }) {
            let fd = open(url.path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            // DispatchSource is the native filesystem event API; no async-native replacement exists.
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if url == self.home { self.watchName() }
                    self.refreshName()
                }
            }
            source.setCancelHandler { close(fd) }
            watchers.append(source)
            source.resume()
        }
    }

    private func stopWatching() {
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
    }
}
