// SPDX-License-Identifier: GPL-3.0-or-later

public enum ProfileID: String, Codable, CaseIterable, Sendable {
    case arm7tdmi
    case cortexM4 = "cortex-m4"
    case stm32f4Discovery = "stm32f4-discovery"
}
