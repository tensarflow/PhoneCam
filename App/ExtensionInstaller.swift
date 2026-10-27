import Foundation
import SystemExtensions

/// Activates the bundled camera extension (macOS asks the user to approve it once).
final class ExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    enum State: Equatable {
        case activating
        case needsApproval
        case activated
        case failed(String)
    }

    var onStateChange: ((State) -> Void)?
    private var forceReplace = false

    /// `reinstall` re-registers the same build. Use it only when the camera is missing: macOS
    /// sometimes fails to start a freshly swapped-in extension (launchd still tearing down the old
    /// one), and nothing retries until the extension is registered again.
    func activate(reinstall: Bool = false) {
        forceReplace = reinstall
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: PhoneCamConstants.extensionBundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        // Only swap the extension when this app ships a different build of it: every swap risks
        // the macOS race above, and the display version (1.0 vs 1.0.0) doesn't change the code.
        if forceReplace { return .replace }
        return existing.bundleVersion == ext.bundleVersion ? .cancel : .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onStateChange?(.needsApproval)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        onStateChange?(.activated)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        // Cancelling a same-version replacement means it's already installed.
        if (error as NSError).code == OSSystemExtensionError.requestCanceled.rawValue {
            onStateChange?(.activated)
        } else {
            onStateChange?(.failed(error.localizedDescription))
        }
    }
}
