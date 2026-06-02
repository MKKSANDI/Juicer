//
//  BatteryManager.swift
//  Juicer
//

import AppKit
import Combine
import CoreGraphics
import CoreImage
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

enum DrainIntensity: String, CaseIterable, Identifiable {
    case strong
    case turbo
    case max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strong: return "Strong"
        case .turbo: return "Turbo"
        case .max: return "Max"
        }
    }

    var detail: String {
        switch self {
        case .strong:
            return "High CPU load with screen boost."
        case .turbo:
            return "More workers plus graphics load."
        case .max:
            return "CPU, graphics, memory, and temp disk churn."
        }
    }

    var cpuWorkerMultiplier: Int {
        switch self {
        case .strong: return 1
        case .turbo: return 2
        case .max: return 3
        }
    }

    var graphicsWorkers: Int {
        switch self {
        case .strong: return 0
        case .turbo: return 1
        case .max: return 2
        }
    }

    var diskWorkers: Int {
        self == .max ? 1 : 0
    }

    var vectorSize: Int {
        switch self {
        case .strong: return 16_384
        case .turbo: return 24_576
        case .max: return 32_768
        }
    }

    var diskChunkSize: Int {
        switch self {
        case .strong: return 0
        case .turbo: return 0
        case .max: return 16 * 1024 * 1024
        }
    }

    var graphicsDimension: Int {
        switch self {
        case .strong: return 0
        case .turbo: return 1024
        case .max: return 1536
        }
    }
}

final class BatteryManager: ObservableObject {
    @Published var currentPercentage: Double = 100
    @Published var isCharging: Bool = false
    @Published var isBatteryAvailable: Bool = true
    @Published var stats = PerformanceStats()

    private var batteryTimer: Timer?
    private var statsTimer: Timer?
    private var drainWorkItems: [DispatchWorkItem] = []
    private var assertionIDs: [IOPMAssertionID] = []
    private var targetPercentage: Double = 50
    private var originalBrightness: Float?

    private let stateLock = NSLock()
    private var activeFlag = false

    private let counterLock = NSLock()
    private var operationCounter: Int64 = 0
    private var lastOperationCount: Int64 = 0
    private var startTime: Date?

    init() {
        updateBatteryStatus()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateBatteryStatus()
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStatistics()
        }
    }

    deinit {
        batteryTimer?.invalidate()
        statsTimer?.invalidate()
        stopJuicing()
    }

    func startJuicing(targetPercentage: Double, intensity: DrainIntensity) {
        stopJuicing()

        self.targetPercentage = targetPercentage
        setActive(true)
        operationCounter = 0
        lastOperationCount = 0
        startTime = Date()
        stats.reset(modeName: intensity.title)

        preventSleep()
        maximizeBrightness()
        startDrainWork(intensity: intensity)
    }

    func stopJuicing() {
        setActive(false)
        drainWorkItems.forEach { $0.cancel() }
        drainWorkItems.removeAll()
        restoreSleep()
        restoreBrightness()
    }

    private var isActive: Bool {
        stateLock.withLock { activeFlag }
    }

    private func setActive(_ active: Bool) {
        stateLock.withLock {
            activeFlag = active
        }
    }

    private func preventSleep() {
        createAssertion(type: kIOPMAssertionTypeNoIdleSleep as CFString, reason: "Juicer is draining battery")
        createAssertion(type: kIOPMAssertionTypeNoDisplaySleep as CFString, reason: "Juicer keeps the display active while draining")
    }

    private func createAssertion(type: CFString, reason: String) {
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess {
            assertionIDs.append(assertionID)
        }
    }

    private func restoreSleep() {
        assertionIDs.forEach { IOPMAssertionRelease($0) }
        assertionIDs.removeAll()
    }

    private func maximizeBrightness() {
        var brightness: Float = 0.5
        var iterator: io_iterator_t = 0

        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayWrangler"),
            &iterator
        ) == KERN_SUCCESS else {
            return
        }

        let service = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        if IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &brightness) == KERN_SUCCESS {
            originalBrightness = brightness
            IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, 1.0)
        }
    }

    private func restoreBrightness() {
        guard let originalBrightness else { return }
        self.originalBrightness = nil

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayWrangler"),
            &iterator
        ) == KERN_SUCCESS else {
            return
        }

        let service = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, originalBrightness)
    }

    private func updateBatteryStatus() {
        guard let batteryInfo = getBatteryInfo() else {
            isBatteryAvailable = false
            currentPercentage = 100
            isCharging = false
            return
        }

        isBatteryAvailable = true
        currentPercentage = batteryInfo.percentage
        isCharging = batteryInfo.isCharging

        if isActive && currentPercentage <= targetPercentage {
            stopJuicing()
            NotificationCenter.default.post(name: .juicingStopped, object: nil)
        }
    }

    private func getBatteryInfo() -> (percentage: Double, isCharging: Bool)? {
        guard let powerSources = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(powerSources)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(powerSources, source)?.takeUnretainedValue() as? [String: Any],
                  let type = description[kIOPSTypeKey] as? String,
                  type == kIOPSInternalBatteryType else {
                continue
            }

            let percentage = description[kIOPSCurrentCapacityKey] as? Int ?? 100
            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            return (Double(percentage), isCharging)
        }

        return nil
    }

    private func startDrainWork(intensity: DrainIntensity) {
        let processorCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let cpuWorkers = min(processorCount * intensity.cpuWorkerMultiplier, processorCount * 4)
        let totalWorkers = cpuWorkers + intensity.graphicsWorkers + intensity.diskWorkers
        stats.activeThreads = totalWorkers
        stats.powerLevel = min(100, 35 + intensity.cpuWorkerMultiplier * 20 + intensity.graphicsWorkers * 10 + intensity.diskWorkers * 10)

        for index in 0..<cpuWorkers {
            scheduleWorkItem {
                self.runCPUWorker(workerIndex: index, intensity: intensity)
            }
        }

        for index in 0..<intensity.graphicsWorkers {
            scheduleWorkItem {
                self.runGraphicsWorker(workerIndex: index, intensity: intensity)
            }
        }

        for index in 0..<intensity.diskWorkers {
            scheduleWorkItem {
                self.runDiskWorker(workerIndex: index, intensity: intensity)
            }
        }
    }

    private func scheduleWorkItem(_ body: @escaping () -> Void) {
        let workItem = DispatchWorkItem(block: body)
        drainWorkItems.append(workItem)
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    private func runCPUWorker(workerIndex: Int, intensity: DrainIntensity) {
        var state = UInt64(0x9E3779B97F4A7C15) &+ UInt64(workerIndex)
        var values = [Double](repeating: 0, count: intensity.vectorSize)
        var scratch = [Double](repeating: 0, count: intensity.vectorSize)

        for index in values.indices {
            values[index] = nextUnitDouble(&state)
        }

        var localOperations: Int64 = 0
        while isActive {
            autoreleasepool {
                for index in values.indices {
                    state = state &* 2862933555777941757 &+ 3037000493
                    let jitter = Double(state & 0xFFFF) / 65_535.0
                    let x = values[index] + jitter
                    let mixed = sin(x * 12.9898) * cos(x * 78.233) + sqrt(abs(x) + 0.0001)
                    scratch[index] = mixed.truncatingRemainder(dividingBy: 1.0)
                }

                var dot = 0.0
                for index in values.indices {
                    dot += values[index] * scratch[index]
                    values[index] = scratch[index] + dot.truncatingRemainder(dividingBy: 0.000_001)
                }

                localOperations += Int64(values.count * 2)
                if localOperations >= 100_000 {
                    addOperations(localOperations)
                    localOperations = 0
                }
            }
        }

        if localOperations > 0 {
            addOperations(localOperations)
        }
    }

    private func runGraphicsWorker(workerIndex: Int, intensity: DrainIntensity) {
        let dimension = intensity.graphicsDimension
        guard dimension > 0 else { return }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CIContext(options: [.cacheIntermediates: false])
        let bounds = CGRect(x: 0, y: 0, width: dimension, height: dimension)
        let rowBytes = dimension * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * dimension)
        var frame = 0

        while isActive {
            autoreleasepool {
                let input = CIFilter(name: "CIRandomGenerator")?.outputImage?.cropped(to: bounds)
                let blur = input?.applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: 6 + (frame % 8)
                ]).cropped(to: bounds)
                let output = blur?.applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 1.2 + Double(workerIndex) * 0.2,
                    kCIInputContrastKey: 1.4
                ])

                if let output {
                    pixels.withUnsafeMutableBytes { buffer in
                        guard let baseAddress = buffer.baseAddress else { return }
                        context.render(
                            output,
                            toBitmap: baseAddress,
                            rowBytes: rowBytes,
                            bounds: bounds,
                            format: .RGBA8,
                            colorSpace: colorSpace
                        )
                    }
                    addOperations(Int64(dimension * dimension))
                }
                frame &+= 1
            }
        }
    }

    private func runDiskWorker(workerIndex: Int, intensity: DrainIntensity) {
        let chunkSize = intensity.diskChunkSize
        guard chunkSize > 0 else { return }

        var state = UInt64(0xD1B54A32D192ED03) &+ UInt64(workerIndex)
        var chunk = Data(count: chunkSize)
        chunk.withUnsafeMutableBytes { buffer in
            guard let bytes = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<chunkSize {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
            }
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Juicer-\(UUID().uuidString)-\(workerIndex).bin")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        while isActive {
            autoreleasepool {
                try? chunk.write(to: fileURL, options: .atomic)
                _ = try? Data(contentsOf: fileURL, options: .mappedIfSafe)
                addOperations(Int64(chunkSize / 1024))
            }
        }
    }

    private func addOperations(_ count: Int64) {
        counterLock.withLock {
            operationCounter &+= count
        }
    }

    private func nextUnitDouble(_ state: inout UInt64) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }

    private func updateStatistics() {
        guard isActive else {
            stats.reset()
            return
        }

        let currentOps = counterLock.withLock { operationCounter }
        let opsPerSecond = currentOps - lastOperationCount
        lastOperationCount = currentOps

        stats.operationsPerSecond = max(0, Int(clamping: opsPerSecond))
        stats.totalOperations = Int(clamping: currentOps)
        stats.runtime = startTime.map { Date().timeIntervalSince($0) } ?? 0
        stats.powerLevel = min(100, max(stats.powerLevel, min(100, stats.operationsPerSecond / 200_000)))
    }
}

struct PerformanceStats {
    var operationsPerSecond: Int = 0
    var totalOperations: Int = 0
    var activeThreads: Int = 0
    var runtime: TimeInterval = 0
    var powerLevel: Int = 0
    var modeName: String = ""

    mutating func reset(modeName: String? = nil) {
        operationsPerSecond = 0
        totalOperations = 0
        activeThreads = 0
        runtime = 0
        powerLevel = 0
        self.modeName = modeName ?? ""
    }

    var formattedRuntime: String {
        let minutes = Int(runtime) / 60
        let seconds = Int(runtime) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var formattedOperationsPerSecond: String {
        if operationsPerSecond >= 1_000_000 {
            return String(format: "%.2fM ops/s", Double(operationsPerSecond) / 1_000_000)
        }
        if operationsPerSecond >= 1_000 {
            return String(format: "%.2fK ops/s", Double(operationsPerSecond) / 1_000)
        }
        return "\(operationsPerSecond) ops/s"
    }

    var formattedTotalOperations: String {
        if totalOperations >= 1_000_000_000 {
            return String(format: "%.2fB", Double(totalOperations) / 1_000_000_000)
        }
        if totalOperations >= 1_000_000 {
            return String(format: "%.2fM", Double(totalOperations) / 1_000_000)
        }
        if totalOperations >= 1_000 {
            return String(format: "%.2fK", Double(totalOperations) / 1_000)
        }
        return "\(totalOperations)"
    }
}

extension NSNotification.Name {
    static let juicingStopped = NSNotification.Name("JuicingStopped")
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
