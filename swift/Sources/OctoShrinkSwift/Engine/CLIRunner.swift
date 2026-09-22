import Foundation

// MARK: - CPU 预算：每个子进程只占 1 份并行能力
//
// 并发文件数由 CompressionScheduler 管，这里是第二层 —— 单个编码器内部线程。
// 两层都吃满的话，"上限 = 4" 实际会变成"4 个文件 × 每个用满全部核心"。
// 与 Rust 侧 `engine.rs::per_task_threads` + `cpu_flags` 一一对应。
struct CPUResourcePolicy {
    let threadLimit: Int

    static let shared = CPUResourcePolicy(threadLimit: 1)

    init(threadLimit: Int) {
        self.threadLimit = max(1, threadLimit)
    }

    /// 各工具压制内部线程的开关名不一样，集中在这一个映射里，
    /// 不在 PNG / JPG / WebP / AVIF / GIF 每个函数复制一套。
    func flags(for tool: String) -> [String] {
        switch tool {
        // avifenc 的 --jobs 默认值随发行版本而变，必须显式给。
        case "avifenc": return ["--jobs", "\(threadLimit)"]
        // oxipng 内部是 rayon 多线程，显式 --threads 比只靠环境变量更确定。
        case "oxipng": return ["--threads", "\(threadLimit)"]
        // cwebp 的 -mt 只能开或不开，没法指定线程数 —— 单 worker 就别开。
        case "cwebp": return threadLimit > 1 ? ["-mt"] : []
        default: return []
        }
    }

    /// 只对认这些变量的 runtime 有效，不能假设第三方二进制都遵守，
    /// 所以上面的命令行开关才是主要手段。
    var environment: [String: String] {
        let threads = String(threadLimit)
        return ["OMP_NUM_THREADS": threads, "RAYON_NUM_THREADS": threads]
    }
}

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

    /// 子进程的统一环境。CPU 预算必须无条件生效，不能只在资源目录存在时才带上。
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in CPUResourcePolicy.shared.environment { env[key] = value }
        if let lib = libDir() {
            let existing = env["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
            env["DYLD_FALLBACK_LIBRARY_PATH"] = existing.isEmpty
                ? lib.path
                : "\(lib.path):\(existing)"
        }
        return env
    }

    static func run(
        tool: String,
        args: [String],
        stdinData: Data? = nil
    ) -> Data? {
        guard let toolURL = toolURL(for: tool) else { return nil }
        let process = Process()
        process.executableURL = toolURL
        // CPU 开关排在调用方参数之前：avifenc / oxipng 在第一个位置参数之后可能不再解析选项。
        process.arguments = CPUResourcePolicy.shared.flags(for: tool) + args
        process.environment = environment()
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
        // CPU 开关排在调用方参数之前：avifenc / oxipng 在第一个位置参数之后可能不再解析选项。
        process.arguments = CPUResourcePolicy.shared.flags(for: tool) + args
        process.environment = environment()
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
