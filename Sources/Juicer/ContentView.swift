//
//  ContentView.swift
//  Juicer
//

import SwiftUI

struct ContentView: View {
    @StateObject private var batteryManager = BatteryManager()
    @State private var targetPercentage: Double = 50
    @State private var intensity: DrainIntensity = .turbo
    @State private var isJuicing = false

    var body: some View {
        VStack(spacing: 24) {
            header
            batteryCard
            targetCard
            intensityCard
            actionButton
            statusText

            if isJuicing {
                statsCard
            }
        }
        .padding(34)
        .frame(width: 540)
        .background(Color(NSColor.windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .juicingStopped)) { _ in
            isJuicing = false
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("Juicer")
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange, .red],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("Controlled battery draining for Mac laptops")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var batteryCard: some View {
        VStack(spacing: 10) {
            Text("Current Battery")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("\(Int(batteryManager.currentPercentage))%")
                .font(.system(size: 62, weight: .bold))
                .foregroundColor(batteryColor)

            HStack(spacing: 8) {
                Image(systemName: batteryManager.isCharging ? "bolt.fill" : "battery.100")
                Text(batteryManager.isCharging ? "Charging" : "On Battery")
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(batteryManager.isCharging ? .orange : .secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
    }

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Stop at")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(targetPercentage))%")
                    .font(.title2.weight(.semibold))
            }

            Slider(value: $targetPercentage, in: 1...99, step: 1)
                .disabled(isJuicing)
        }
        .padding(18)
        .background(cardBackground)
    }

    private var intensityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Power Mode")
                .font(.headline)
                .foregroundColor(.secondary)

            Picker("Power Mode", selection: $intensity) {
                ForEach(DrainIntensity.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isJuicing)

            Text(intensity.detail)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(18)
        .background(cardBackground)
    }

    private var actionButton: some View {
        Button {
            if isJuicing {
                batteryManager.stopJuicing()
                isJuicing = false
            } else {
                batteryManager.startJuicing(targetPercentage: targetPercentage, intensity: intensity)
                isJuicing = true
            }
        } label: {
            HStack {
                Image(systemName: isJuicing ? "stop.circle.fill" : "flame.fill")
                    .font(.title2)
                Text(isJuicing ? "Stop Juicing" : "Start Juicing")
                    .font(.title2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: isJuicing ? [.red, .orange] : [.orange, .yellow],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .foregroundColor(.white)
            .cornerRadius(12)
            .shadow(color: .orange.opacity(0.3), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(canStart == false && isJuicing == false)
    }

    @ViewBuilder
    private var statusText: some View {
        if batteryManager.isBatteryAvailable == false {
            Label("No internal battery detected", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.orange)
        } else if batteryManager.isCharging && isJuicing == false {
            Label("Unplug power to drain faster", systemImage: "powerplug.fill")
                .font(.caption)
                .foregroundColor(.orange)
        } else if batteryManager.currentPercentage <= targetPercentage && isJuicing == false {
            Label("Target must be below the current battery level", systemImage: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var statsCard: some View {
        VStack(spacing: 14) {
            ProgressView(value: max(0, 100 - batteryManager.currentPercentage), total: 100)
                .progressViewStyle(.linear)
                .tint(.orange)

            VStack(spacing: 8) {
                StatRow(label: "Mode", value: batteryManager.stats.modeName, icon: "gauge.with.dots.needle.67percent")
                StatRow(label: "Power Level", value: "\(batteryManager.stats.powerLevel)%", icon: "bolt.fill")
                StatRow(label: "Operations/sec", value: batteryManager.stats.formattedOperationsPerSecond, icon: "cpu")
                StatRow(label: "Total Operations", value: batteryManager.stats.formattedTotalOperations, icon: "number")
                StatRow(label: "Active Workers", value: "\(batteryManager.stats.activeThreads)", icon: "square.stack.3d.up")
                StatRow(label: "Runtime", value: batteryManager.stats.formattedRuntime, icon: "clock")
            }
        }
        .padding(18)
        .background(cardBackground)
    }

    private var canStart: Bool {
        batteryManager.isBatteryAvailable
            && batteryManager.currentPercentage > targetPercentage
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(NSColor.controlBackgroundColor))
    }

    private var batteryColor: Color {
        let percentage = batteryManager.currentPercentage
        if percentage > 50 {
            return .green
        } else if percentage > 20 {
            return .orange
        } else {
            return .red
        }
    }
}

struct StatRow: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.orange)
                .frame(width: 22)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value.isEmpty ? "-" : value)
                .font(.caption.weight(.semibold))
                .foregroundColor(.primary)
        }
    }
}
