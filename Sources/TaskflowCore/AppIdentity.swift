import Foundation

/// Identifiers shared by the app, the CLI and the Keychain. Keep these in sync with Resources/Info.plist.
public enum AppIdentity {
    public static let bundleId = "io.github.shihab-abir.taskflow"
    /// Distributed notification the CLI uses to drive the running app (show / hide / quit / reload).
    public static let commandNotification = Notification.Name("\(bundleId).command")
}
