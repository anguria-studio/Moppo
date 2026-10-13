import Foundation

/// Accepts an HTTPS feed and a complete Ed25519 public key.
struct UpdateConfiguration {
    let feedURL: URL
    let publicKey: String

    init?(feedURL: String?, publicKey: String?) {
        guard let feedURL, let url = URL(string: feedURL),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              let publicKey, Data(base64Encoded: publicKey)?.count == 32 else { return nil }
        self.feedURL = url
        self.publicKey = publicKey
    }

    init?(bundle: Bundle) {
        self.init(
            feedURL: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        )
    }
}
