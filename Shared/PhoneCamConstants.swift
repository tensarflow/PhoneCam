import Foundation

/// Values shared by the menu bar app and the camera extension.
enum PhoneCamConstants {
    /// Fixed so the app can find the extension's camera device by its UID.
    static let deviceUUID = UUID(uuidString: "5C0A6E2B-7D4F-4C61-9B8E-2F1A3D5E7C90")!
    static let cameraName = "PhoneCam"
    /// The extension's identifier is the app's plus ".CameraExtension" (the prefix is set at build time).
    static var extensionBundleID: String {
        let identifier = Bundle.main.bundleIdentifier ?? "PhoneCam"
        return identifier.hasSuffix(".CameraExtension") ? identifier : identifier + ".CameraExtension"
    }

    static let width: Int32 = 1920
    static let height: Int32 = 1080
    static let frameRate: Int32 = 30
}
