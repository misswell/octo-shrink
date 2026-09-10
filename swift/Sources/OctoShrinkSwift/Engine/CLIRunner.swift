import Foundation

enum CLIRunner {
    static func toolURL(for name: String) -> URL? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("bin").appendingPathComponent(name)
            if fm.fileExists(atPath: bundled.path) { return bundled }
            let alt = res.appendingPathComponent("resources/bin").appendingPathComponent(name)
            if fm.fileExists(atPath: alt.path) { return alt }
        }
        let dev = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("src-tauri/resources/bin")
            .appendingPathComponent(name)
        if fm.fileExists(atPath: dev.path) { return dev }
        let homebrew = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for dir in homebrew {
            let p = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if fm.fileExists(atPath: p.path) { return p }
        }
        return nil
    }

    static func libDir() -> URL? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL {
            let lib = res.appendingPathComponent("lib")
            if fm.fileExists(atPath: lib.path) { return lib }
            let alt = res.appendingPathComponent("resources/lib")
            if fm.fileExists(atPath: alt.path) { return alt }
        }
        let dev = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("src-tauri/resources/lib")
        if fm.fileExists(atPath: dev.path) { return dev }
        return nil
    }

    static func run(
        tool: String,
        args: [String],
        stdinData: Data? = nil
    ) -> Data? {
        guard let toolURL = toolURL(for: tool) else { return nil }
        let process = Process()
        process.executableURL = toolURL
        process.arguments = args
        if let lib = libDir() {
            var env = ProcessInfo.processInfo.environment
            let existing = env["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
            env["DYLD_FALLBACK_LIBRARY_PATH"] = existing.isEmpty
                ? lib.path
                : "\(lib.path):\(existing)"
            process.environment = env
        }
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        if let stdinData = stdinData {
            let inPipe = Pipe()
            process.standardInput = inPipe
            do {
                try process.run()
                inPipe.fileHandleForWriting.write(stdinData)
                try? inPipe.fileHandleForWriting.close()
            } catch {
                return nil
            }
        } else {
            do {
                try process.run()
            } catch {
                return nil
            }
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    static func runToFile(
        tool: String,
        args: [String],
        outputPath: String
    ) -> Data? {
        guard let toolURL = toolURL(for: tool) else { return nil }
        let process = Process()
        process.executableURL = toolURL
        process.arguments = args
        if let lib = libDir() {
            var env = ProcessInfo.processInfo.environment
            let existing = env["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
            env["DYLD_FALLBACK_LIBRARY_PATH"] = existing.isEmpty
                ? lib.path
                : "\(lib.path):\(existing)"
            process.environment = env
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        guard let data = FileManager.default.contents(atPath: outputPath), !data.isEmpty else { return nil }
        return data
    }
}
