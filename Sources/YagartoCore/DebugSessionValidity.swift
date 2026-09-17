// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

package final class DebugSessionValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    package init() {}

    package func invalidate(onLockAttempt: () -> Void = {}) {
        onLockAttempt()
        lock.lock()
        active = false
        lock.unlock()
    }

    @discardableResult
    package func performIfActive(_ operation: () throws -> Void) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return false }
        try operation()
        return true
    }
}
