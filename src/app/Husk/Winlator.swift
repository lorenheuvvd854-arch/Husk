// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Windows programs (.exe, .msi), run inside Android by Winlator: Wine for the Windows side and Box64 for the x86 code.
///
/// Husk has no Windows layer of its own. Android does, as an app, so a Windows program goes to Android's Download folder,
/// which Winlator mounts as drive D: in every container, and Winlator is installed from its GitHub release the first time.
/// It is slow -- x86 code translated by Box64 inside an Android that is itself emulated -- so it suits small programs and old
/// games, not anything recent.
enum Winlator {
    /// The packages Winlator is published under: the original and the forks people use most, in the order they are preferred.
    static let packages = ["com.winlator", "com.winlator.cmod"]

    /// Where Windows programs go in Android. Download is drive D: in Winlator, so this is D:\Windows.
    static let guestFolder = "/sdcard/Download/Windows"

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// The Winlator package installed in the guest, if any.
    static func installedPackage() -> String? {
        let out = (try? GuestBridge.shared.shell("pm list packages com.winlator", timeout: 60)) ?? ""
        let listed = Set(out.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "package:", with: "")
        })
        return packages.first(where: listed.contains)
    }

    private static var cacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Winlator", isDirectory: true)
    }

    /// Winlator's APK, downloaded once and kept until it is installed.
    static func downloadAPK(progress: @escaping (String) -> Void) async throws -> URL {
        let dest = cacheFolder.appendingPathComponent("winlator.apk")
        if let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.intValue, size > 1_000_000 {
            return dest
        }
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)

        var req = URLRequest(url: URL(string: "https://api.github.com/repos/brunodev85/winlator/releases/latest")!)
        req.timeoutInterval = 30
        req.setValue("Husk", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure("GitHub did not answer (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Try again later.")
        }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        guard let link = assets.compactMap({ $0["browser_download_url"] as? String }).first(where: { $0.lowercased().hasSuffix(".apk") }),
              let url = URL(string: link) else {
            throw Failure("Winlator's latest release has no APK.")
        }

        progress("Downloading Winlator \((obj["tag_name"] as? String) ?? "")…")
        var get = URLRequest(url: url)
        get.timeoutInterval = 300
        get.setValue("Husk", forHTTPHeaderField: "User-Agent")
        let (tmp, got) = try await URLSession.shared.download(for: get)
        guard (got as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure("Winlator's download failed (HTTP \((got as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        HuskLog.log("windows", "downloaded \(url.lastPathComponent)")
        return dest
    }

    static func forgetAPK() {
        try? FileManager.default.removeItem(at: cacheFolder)
    }
}
