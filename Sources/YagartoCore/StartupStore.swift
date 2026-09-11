// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension ProfileID {
    public var startupSourceName: String? {
        switch self {
        case .arm7tdmi:
            return nil
        case .cortexM4:
            return "cortex-m4-startup.s"
        case .stm32f4Discovery:
            return "stm32f4-startup.s"
        }
    }
}

public enum StartupStore {
    public static func url(for profile: ProfileID) throws -> URL {
        guard let name = profile.startupSourceName else {
            throw YagartoError.missingResource("arm7tdmi 不需要启动文件")
        }
        let stem = String(name.dropLast(2))
        guard let url = Bundle.module.url(forResource: stem, withExtension: "s") else {
            throw YagartoError.missingResource(name)
        }
        return url
    }
}
