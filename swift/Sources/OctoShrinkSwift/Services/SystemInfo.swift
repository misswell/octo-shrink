import Foundation

// MARK: - CPU 能力检测与并行预算
//
// 语义边界与 Rust 侧 `system_info.rs` 完全一致：这里报的是「有多少份并行能力」，
// 不是「绑哪几个核心」。不做 CPU affinity —— Apple Silicon 的 P/E 调度归系统管。

struct CpuInfo {
    let architecture: String
    let logicalCpus: Int
    let physicalCpus: Int?
    let performanceCpus: Int?
    let efficiencyCpus: Int?
    let modelName: String?
    /// 进程实际该采用的并行度上限（Swift 侧 = `activeProcessorCount`）。
    let availableParallelism: Int

    var budgetCeiling: Int { max(1, availableParallelism) }

    /// 苹果自研芯片只能看型号名 + 架构；`arm64` 也可能是 Windows / Linux on ARM。
    var isAppleSilicon: Bool {
        architecture == "aarch64" && (modelName ?? "").hasPrefix("Apple ")
    }

    static func detect() -> CpuInfo {
        let available = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let model = sysctlString("machdep.cpu.brand_string")
        return CpuInfo(
            architecture: machineArchitecture(),
            logicalCpus: sysctlInt("hw.logicalcpu") ?? available,
            physicalCpus: sysctlInt("hw.physicalcpu"),
            performanceCpus: performanceCpus(),
            efficiencyCpus: efficiencyCpus(),
            modelName: model,
            availableParallelism: available
        )
    }

    // uname 的 machine 是 arm64 / x86_64，Rust 的 consts::ARCH 是 aarch64 / x86_64。
    // 三线共用一份设置文件，这里统一成 Rust 的写法。
    static func machineArchitecture() -> String {
        var name = utsname()
        guard uname(&name) == 0 else { return "" }
        let machine = withUnsafeBytes(of: &name.machine) { buffer in
            String(decoding: Array(buffer.prefix(while: { $0 != 0 })), as: UTF8.self)
        }
        return machine == "arm64" ? "aarch64" : machine
    }

    /// 性能核数量。只有大小核架构（hw.nperflevels > 1）才有意义。
    static func performanceCpus() -> Int? {
        guard (perfLevels() ?? 0) > 1 else { return nil }
        return sysctlInt("hw.perflevel0.physicalcpu")
    }

    /// 能效核数量：perflevel1 往后全部算进去（Apple 目前只有两级）。
    static func efficiencyCpus() -> Int? {
        guard let levels = perfLevels(), levels > 1 else { return nil }
        let counts = (1..<levels).compactMap { sysctlInt("hw.perflevel\($0).physicalcpu") }
        guard !counts.isEmpty else { return nil }
        return counts.reduce(0, +)
    }

    static func perfLevels() -> Int? { sysctlInt("hw.nperflevels") }

    static func sysctlInt(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size == 4 || size == 8 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let read = bytes.withUnsafeMutableBytes {
            sysctlbyname(name, $0.baseAddress, &size, nil, 0)
        }
        guard read == 0, let value = signedLittleEndian(bytes) else { return nil }
        // 负的 sysctl 值表示「未知」，不是核数。
        return value >= 0 ? value : nil
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let read = bytes.withUnsafeMutableBytes {
            sysctlbyname(name, $0.baseAddress, &size, nil, 0)
        }
        guard read == 0 else { return nil }
        let text = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func signedLittleEndian(_ bytes: [UInt8]) -> Int? {
        guard bytes.count == 4 || bytes.count == 8 else { return nil }
        var value: Int64 = 0
        for (index, byte) in bytes.enumerated() {
            value |= Int64(byte) << (8 * index)
        }
        // 4 字节字段要按 int32 符号扩展，否则 0xFFFFFFFF 会读成 42 亿。
        let signBit = 8 * bytes.count - 1
        if bytes.count < MemoryLayout<Int64>.size, value & (1 << signBit) != 0 {
            value -= 1 << (8 * bytes.count)
        }
        return Int(exactly: value)
    }
}

// MARK: - CPU 并行预算的取值规则（与 Rust app_settings.rs 一致）

enum CPULimit {
    /// 自动档不默认吃满全核：这个功能的目的就是「压缩的同时电脑还能干活」。
    static let autoParallelism = 3
    static let minParallelism = 1

    static func autoLimit(detected: Int) -> Int {
        max(minParallelism, min(autoParallelism, max(1, detected)))
    }

    /// `nil` = 自动。换到核更少的机器不报错，自动收敛到本机上限。
    static func effective(configured: Int?, detected: Int) -> Int {
        let ceiling = max(minParallelism, detected)
        let picked = configured ?? autoLimit(detected: ceiling)
        return min(max(picked, minParallelism), ceiling)
    }
}

// MARK: - 展示文案
//
// Tauri 前端 app.js 里有同名实现，两边必须一字不差；方案 §63 明确禁止写
// 「使用 4 个性能核」这类承诺绑定核心的措辞。

enum CPUStatusText {
    static func architectureLabel(_ architecture: String) -> String {
        architecture == "aarch64" ? "ARM64" : architecture
    }

    static func device(_ info: CpuInfo) -> String {
        [info.modelName, info.architecture.isEmpty ? nil : architectureLabel(info.architecture)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// 核心构成。Apple Silicon 才报 P/E 核，其他平台不能假装知道。
    static func cores(_ info: CpuInfo) -> String {
        let ceiling = max(1, info.availableParallelism)
        if info.isAppleSilicon, let p = info.performanceCpus, let e = info.efficiencyCpus {
            return "\(info.physicalCpus ?? ceiling) 核 CPU（\(p) 性能核 + \(e) 能效核）"
        }
        if let physical = info.physicalCpus, info.logicalCpus > physical {
            return "\(physical) 个物理核心 · \(info.logicalCpus) 个逻辑处理器"
        }
        if info.logicalCpus > 0 { return "\(info.logicalCpus) 个逻辑处理器" }
        return "最多 \(ceiling) 份并行计算"
    }

    static func limitLabel(info: CpuInfo, configured: Int?, effective: Int) -> String {
        let ceiling = max(1, info.availableParallelism)
        let limit = min(max(effective, 1), ceiling)
        guard configured != nil else { return "自动（\(limit)）" }
        return limit >= ceiling ? "\(limit) / \(ceiling)（全部）" : "\(limit) / \(ceiling)"
    }

    /// 队列摘要尾巴：「· CPU 4/10」，自动档不假装知道具体数字。
    static func summary(info: CpuInfo, configured: Int?, effective: Int) -> String {
        let ceiling = max(1, info.availableParallelism)
        guard configured != nil else { return " · CPU 自动" }
        return " · CPU \(min(max(effective, 1), ceiling))/\(ceiling)"
    }
}
