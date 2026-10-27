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

    func activate() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: PhoneCamConstants.extensionBundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        // Only swap the running extension when this app ships a different build of it.
        let same = existing.bundleVersion == ext.bundleVersion
            && existing.bundleShortVersion == ext.bundleShortVersion
        return same ? .cancel : .replace
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
