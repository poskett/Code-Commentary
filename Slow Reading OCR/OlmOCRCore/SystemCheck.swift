/* Declaration: Code generated using Anthropic Claude (Opus 5.5)*/
// ### Code Commentary
// All commentary below was written manually by [James Poskett](https://warwick.ac.uk/fac/arts/history/people/staff_index/poskett/) (University of Warwick).
//
// This commentary is for [v1.1.1](https://github.com/poskett/Slow-Reading-OCR/releases/tag/v1.1.1).
//
// ### Overview
// This script is for checking everything is in order at the system level, particularly hardware requirements and free memory.
//
// ### Import Libraries
// Alongside core librart Foundation, to read and write to disk. Also IOKit and Metal so we can get system information and check with MLX.
import Foundation
import IOKit.ps
import Metal

// ### Variables
// Define an enum with the two model tiers, 8 or 4 bit.
public enum ModelTier: String, Codable, CaseIterable, Sendable {
    case full
    case compact

    public var repo: String {
        switch self {
        case .full: return "mlx-community/olmOCR-2-7B-1025-8bit"
        case .compact: return "mlx-community/olmOCR-2-7B-1025-4bit"
        }
    }

    public var folderName: String {
        String(repo.split(separator: "/").last!)
    }

    public var title: String {
        switch self {
        case .full: return "Full"
        case .compact: return "Compact"
        }
    }

    public var summary: String {
        switch self {
        case .full:
            return "Best accuracy"
        case .compact:
            return "Smaller, faster"
        }
    }
// Define the rough download and memory requirements.
    public var approximateDownloadBytes: Int64 {
        switch self {
        case .full: return 9_400_000_000
        case .compact: return 5_700_000_000
        }
    }

    public var peakMemoryBytes: Int64 {
        switch self {
        case .full: return 11_500_000_000
        case .compact: return 7_700_000_000
        }
    }

    // We need a decent amount of memory, this is the required for it to work.
    public var requiredWorkingSetBytes: Int64 {
        peakMemoryBytes + 1_000_000_000
    }
}

// So assume that if less than 9GB of available memory, we'll need the compact model.
let compactRecommendedBelowBytes: Int64 = 9 * 1_073_741_824

// Another enum for basic system information, here the power source.
public enum PowerSource: String, Sendable {
    case mains
    case battery
    case unknown
}

// ### System Report
// Define a struct to hold the full system report about the Mac.
public struct SystemReport: Sendable {
    public var chip: String
    public var isAppleSilicon: Bool
    public var isTranslated: Bool
    public var physicalMemory: Int64
    public var gpuWorkingSetLimit: Int64
    public var availableMemory: Int64
    public var freeDiskSpace: Int64
    public var macOSVersion: String
    public var thermalState: ProcessInfo.ThermalState
    public var powerSource: PowerSource

    // Decide the recommended tier of model based on available memory.
    public var recommendedTier: ModelTier? {
        if availableMemory < compactRecommendedBelowBytes && supportedTiers.contains(.compact) {
            return .compact
        }
        return supportedTiers.first
    }
    public var supportedTiers: [ModelTier] {
        guard isAppleSilicon else {
            return []
        }
        return ModelTier.allCases.filter { gpuWorkingSetLimit >= $0.requiredWorkingSetBytes }
    }
    
// Define variables and errors if not running on Apple Silicon or don't have enough memory.
    public var blockingProblem: String? {
        if !isAppleSilicon {
            return "Slow Reading needs a Mac with Apple silicon (M1 or later). This Mac has an Intel processor."
        }
        if isTranslated {
            return "Slow Reading is running under Rosetta. Quit it, choose the app in Finder, select File > Get Info, and untick “Open using Rosetta”."
        }
        if supportedTiers.isEmpty {
            return "This Mac has \(formatBytes(physicalMemory)) of memory. Slow Reading needs at least 16 GB to run the model."
        }
        return nil
    }

    // Define warnings if memory is getting short, on battery, or computer getting hot.
    public func warnings(for tier: ModelTier) -> [String] {
        var messages: [String] = []
        if availableMemory < tier.peakMemoryBytes {
            messages.append(
                "Only \(formatBytes(availableMemory)) of memory is free right now. Closing other apps (especially web browsers) will make OCR faster and more stable.")
        }
        if thermalState == .serious || thermalState == .critical {
            messages.append("This Mac is hot. OCR will run slowly until it cools down.")
        }
        if powerSource == .battery {
            messages.append("This Mac is on battery. OCR uses a lot of power, so plug in for long jobs.")
        }
        return messages
    }

    public var diagnosticText: String {
        """
        Chip: \(chip)
        Apple silicon: \(isAppleSilicon)\(isTranslated ? " (running under Rosetta)" : "")
        Memory: \(formatBytes(physicalMemory)) (GPU limit \(formatBytes(gpuWorkingSetLimit)), \(formatBytes(availableMemory)) free now)
        Free disk space: \(formatBytes(freeDiskSpace))
        macOS: \(macOSVersion)
        Thermal state: \(thermalStateName(thermalState))
        Power: \(powerSource.rawValue)
        Recommended model: \(recommendedTier?.folderName ?? "none")
        """
    }
}

public func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
}

// Define the thermal states as simple names.
func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "normal"
    case .fair: return "warm"
    case .serious: return "hot"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

// Functions to read information from the kernel.
func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
        return nil
    }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
        return nil
    }
    return String(cString: buffer)
}

func sysctlInt(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
        return nil
    }
    return Int(value)
}

// ### Memory
// Calculate an estimate of the available memory.
public func availableMemoryBytes() -> Int64 {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else {
        return 0
    }
    var pageSize: vm_size_t = 0
    host_page_size(mach_host_self(), &pageSize)
    let pages = Int64(stats.free_count) + Int64(stats.inactive_count) + Int64(stats.purgeable_count)
        + Int64(stats.speculative_count)
    return pages * Int64(pageSize)
}

// Calculate the actual free space on disk.
public func freeDiskBytes(at url: URL) -> Int64 {
    var probe = url
    while !FileManager.default.fileExists(atPath: probe.path) && probe.pathComponents.count > 1 {
        probe = probe.deletingLastPathComponent()
    }
    let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage ?? 0
}

// Check the power source
public func currentPowerSource() -> PowerSource {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
    else {
        return .unknown
    }
    if type == kIOPMACPowerKey {
        return .mains
    }
    if type == kIOPMBatteryPowerKey {
        return .battery
    }
    return .unknown
}

// This function and gpuWorkingSetBytes estimate how much of the memory could be available for use by the model. Here we just estimate 2/3 if the rest is used for something else.
func simulatedGigabytes(_ name: String) -> Int64? {
    guard let text = ProcessInfo.processInfo.environment[name], let value = Double(text) else {
        return nil
    }
    return Int64(value * 1_073_741_824)
}

public func gpuWorkingSetBytes() -> Int64 {
    if let simulated = simulatedGigabytes("SLOWREADING_SIMULATE_RAM_GB") {
        return simulated * 2 / 3
    }
    return Int64(MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize ?? 0)
}

// This similarly estimates how much we can hold in memory cache for MLX.
public func memoryCacheLimit(for modelName: String) -> Int {
    if let override = ProcessInfo.processInfo.environment["SLOWREADING_CACHE_LIMIT_MB"], let megabytes = Int(override) {
        return megabytes * 1_048_576
    }
    let tier: ModelTier = modelName.contains("8bit") ? .full : .compact
    let headroom = gpuWorkingSetBytes() - tier.peakMemoryBytes
    let limit = min(max(headroom / 4, 256_000_000), 4_000_000_000)
    return Int(limit)
}

// Actually check the system and return everything as a SystemReport as defined earlier.
public func checkSystem() -> SystemReport {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return SystemReport(
        chip: sysctlString("machdep.cpu.brand_string") ?? "unknown",
        isAppleSilicon: sysctlInt("hw.optional.arm64") == 1,
        isTranslated: sysctlInt("sysctl.proc_translated") == 1,
        physicalMemory: simulatedGigabytes("SLOWREADING_SIMULATE_RAM_GB") ?? Int64(ProcessInfo.processInfo.physicalMemory),
        gpuWorkingSetLimit: gpuWorkingSetBytes(),
        availableMemory: simulatedGigabytes("SLOWREADING_SIMULATE_FREE_GB") ?? availableMemoryBytes(),
        freeDiskSpace: freeDiskBytes(at: ModelStore.modelsDirectory),
        macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
        thermalState: ProcessInfo.processInfo.thermalState,
        powerSource: currentPowerSource()
    )
}
