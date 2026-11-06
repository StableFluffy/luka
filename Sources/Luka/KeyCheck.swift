import Foundation
import LukaCore

/// Finds the Soniox region a key belongs to. A project's keys work only in its own region,
/// so the region whose API accepts the key is the one. The request sends no audio and costs nothing.
enum KeyCheck {
    enum Result: Equatable, Sendable {
        case region(SonioxRegion)
        /// Every region turned the key down.
        case invalid
        /// Some region couldn't be reached, and none accepted the key.
        case unreachable
    }

    static func run(_ key: String) async -> Result {
        await withTaskGroup(of: (SonioxRegion, Int?).self, returning: Result.self) { group in
            for region in SonioxRegion.allCases {
                group.addTask { (region, await status(of: key, in: region)) }
            }
            var rejected = 0
            for await (region, code) in group {
                if code == 200 {
                    group.cancelAll()
                    return .region(region)
                }
                if code == 401 || code == 403 { rejected += 1 }
            }
            return rejected == SonioxRegion.allCases.count ? .invalid : .unreachable
        }
    }

    private static func status(of key: String, in region: SonioxRegion) async -> Int? {
        var request = URLRequest(url: URL(string: "https://\(region.apiHost)/v1/models")!, timeoutInterval: 8)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }
}
