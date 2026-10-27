import CoreMediaIO
import Foundation

let providerSource = PhoneCamProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
