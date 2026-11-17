import Foundation
#if os(macOS)
import AppKit

/// Deliver state even while AppKit tracks a menu or waits for termination.
public func onAppMainLoop(_ operation: @escaping @MainActor () -> Void) {
    RunLoop.main.perform(inModes: [.common, .eventTracking, .modalPanel]) {
        // RunLoop.main executes on the main thread, including AppKit's nested
        // menu/modal loops. Preserve actor checking without re-enqueuing a Task.
        MainActor.assumeIsolated { operation() }
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
}
#endif
