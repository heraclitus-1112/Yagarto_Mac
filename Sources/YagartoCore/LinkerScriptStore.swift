// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension ProfileID {
    public var linkerScriptName: String {
        switch self {
        case .arm7tdmi:
            return "arm7tdmi.ld"
        case .cortexM4:
            return "mps2-an386.ld"
        case .stm32f4Discovery:
            return "stm32f4-discovery.ld"
        }
    }
}

public enum LinkerScriptStore {
    public static func url(for profile: ProfileID) throws -> URL {
        let name = profile.linkerScriptName
        let stem = String(name.dropLast(3))
        guard let url = Bundle.module.url(forResource: stem, withExtension: "ld") else {
            throw YagartoError.missingResource(name)
        }
        return url
    }
}
