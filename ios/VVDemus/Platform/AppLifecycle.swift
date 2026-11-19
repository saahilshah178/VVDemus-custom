import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The moments after which this process may never run another line.
///
/// Named in one place because the two platforms mean different things by "going away". A Mac
/// app is quit, and is told so. A phone app is almost never quit: it is sent to the background,
/// suspended some time later without notice, and ended later still without notice — so on iOS
/// the last moment that can be relied on is entering the background, long before anything has
/// actually ended.
enum AppLifecycle {
    @MainActor
    static var lastChancesToSave: [Notification.Name] {
        #if os(iOS)
        // `willTerminate` as well: it is what an app still running in the background gets
        // when it is swiped away, which is exactly the state this one is in while playing.
        [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification]
        #elseif os(macOS)
        [NSApplication.willTerminateNotification]
        #else
        []
        #endif
    }
}
