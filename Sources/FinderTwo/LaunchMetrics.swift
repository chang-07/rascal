import Foundation

/// Tracks key timing milestones during startup. Each numeric field is set
/// at most once and read by tests or the optional `FT_PRINT_LAUNCH_TIMING=1`
/// environment variable.
final class LaunchMetrics {
    static let shared = LaunchMetrics()
    var processStart: TimeInterval = 0
    var didFinishLaunching: TimeInterval = 0
    var firstWindowOnScreen: TimeInterval = 0
}
