// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum EnvironmentProfileReadiness: String, Equatable, Sendable {
    case exact
    case compatible
    case ready
    case unavailable

    public var label: String {
        switch self {
        case .exact: return "精确后端可用"
        case .compatible: return "兼容回退可用"
        case .ready: return "可用"
        case .unavailable: return "不可用"
        }
    }
}

public struct EnvironmentSummary: Equatable, Sendable {
    public let report: DoctorReport
    public let buildToolsAvailable: Bool
    public let arm7: EnvironmentProfileReadiness
    public let cortexM4: EnvironmentProfileReadiness
    public let stm32f4Discovery: EnvironmentProfileReadiness

    public init(report: DoctorReport) {
        self.report = report
        buildToolsAvailable = report.requiredToolsAvailable
        switch report.debugSelection(for: .arm7tdmi)?.backend {
        case .gdbSimulator?: arm7 = .exact
        case .qemuARM926Compatible?: arm7 = .compatible
        default: arm7 = .unavailable
        }
        cortexM4 = report.debugSelection(for: .cortexM4)?.available == true
            ? .ready : .unavailable
        stm32f4Discovery = report.debugSelection(for: .stm32f4Discovery)?.available == true
            ? .ready : .unavailable
    }
}

public enum EnvironmentCheckState: Equatable, Sendable {
    case idle
    case checking
    case loaded(EnvironmentSummary)
}

public protocol EnvironmentChecking: Sendable {
    func check() async -> DoctorReport
}

public struct LocalEnvironmentChecker: EnvironmentChecking, Sendable {
    public init() {}

    public func check() async -> DoctorReport {
        await Task.detached(priority: .userInitiated) {
            ToolResolver().doctor()
        }.value
    }
}

public enum FirstSuccessMilestone: String, CaseIterable, Codable, Hashable, Sendable {
    case exampleOpened
    case buildSucceeded
    case debugStopped
    case stepped
    case returnedToReady

    public var label: String {
        switch self {
        case .exampleOpened: return "打开 ARM7 示例"
        case .buildSucceeded: return "构建成功"
        case .debugStopped: return "调试停在入口"
        case .stepped: return "单步执行一次"
        case .returnedToReady: return "停止并返回就绪"
        }
    }
}

public struct FirstSuccessProgress: Equatable, Sendable {
    public private(set) var completed: Set<FirstSuccessMilestone> = []

    public init(completed: Set<FirstSuccessMilestone> = []) {
        self.completed = completed
    }

    public var isComplete: Bool {
        completed.count == FirstSuccessMilestone.allCases.count
    }

    public mutating func record(_ milestone: FirstSuccessMilestone) {
        completed.insert(milestone)
    }
}

public struct OnboardingPreferenceState: Equatable, Sendable {
    public let isDismissed: Bool
    public let isCompleted: Bool

    public init(isDismissed: Bool = false, isCompleted: Bool = false) {
        self.isDismissed = isDismissed
        self.isCompleted = isCompleted
    }
}

public protocol OnboardingPreferenceStoring: Sendable {
    func state() async -> OnboardingPreferenceState
    func setDismissed(_ value: Bool) async
    func setCompleted(_ value: Bool) async
}

public actor UserDefaultsOnboardingPreferenceStore: OnboardingPreferenceStoring {
    public static let defaultKeyPrefix = "environment-onboarding-v1"

    private let defaults: UserDefaults
    private let dismissedKey: String
    private let completedKey: String

    public init(
        suiteName: String? = nil,
        keyPrefix: String = UserDefaultsOnboardingPreferenceStore.defaultKeyPrefix
    ) {
        if let suiteName, let defaults = UserDefaults(suiteName: suiteName) {
            self.defaults = defaults
        } else {
            defaults = .standard
        }
        dismissedKey = "\(keyPrefix).dismissed"
        completedKey = "\(keyPrefix).completed"
    }

    public func state() -> OnboardingPreferenceState {
        OnboardingPreferenceState(
            isDismissed: defaults.bool(forKey: dismissedKey),
            isCompleted: defaults.bool(forKey: completedKey)
        )
    }

    public func setDismissed(_ value: Bool) {
        defaults.set(value, forKey: dismissedKey)
    }

    public func setCompleted(_ value: Bool) {
        defaults.set(value, forKey: completedKey)
    }
}
