import Foundation
import MoppoCore

enum HomebrewAuthentication {
    static func service() -> HomebrewUninstallService {
        HomebrewUninstallService(
            askpassExecutable: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/MoppoHomebrewAskpass").path
        )
    }
}
