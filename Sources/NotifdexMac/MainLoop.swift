import Foundation
#if os(macOS)
import AppKit

/// Deliver state even while AppKit tracks a menu or waits for termination.
public func onAppMainLoop(_ operation: @escaping () -> Void) {
    RunLoop.main.perform(inModes: [.common, .eventTracking, .modalPanel], block: operation)
    CFRunLoopWakeUp(CFRunLoopGetMain())
}
#endif
