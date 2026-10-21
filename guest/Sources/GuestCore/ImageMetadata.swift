import Foundation
import MaccheriProtocol

/// `images/build.sh` writes `maccheri.json` both next to the image's `config.json` on the host and
/// into the guest at ``guestPath``, where the daemon pre-boots `devices.first` from it.
extension ImageMetadata {
    public static let guestPath = "/Library/Application Support/Maccheri/\(fileName)"

    public static func load(from url: URL) throws -> ImageMetadata {
        try JSONDecoder().decode(ImageMetadata.self, from: Data(contentsOf: url))
    }
}
