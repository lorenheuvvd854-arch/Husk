// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Combine

/// Manages Google Play authentication, session persistence, searching, browsing, and downloads.
@MainActor
final class PlayStoreManager: ObservableObject {
    static let shared = PlayStoreManager()

    private static let sessionKey = "husk_play_session"

    @Published var session: PlaySession?
    @Published var isLoading = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    // Browse / Search state
    @Published var featuredApps: [PlayAPI.PlayApp] = []
    @Published var searchResults: [PlayAPI.PlayApp] = []
    @Published var isSearching = false

    // Download progress: [packageName: fractional progress 0.0 ... 1.0]
    @Published var downloadProgress: [String: Double] = [:]
    // Installing packages
    @Published var installingPackages: Set<String> = []

    init() {
        loadSavedSession()
    }

    var isSignedIn: Bool {
        session != nil && !(session?.email.isEmpty ?? true)
    }

    // MARK: - Session Persistence

    private func loadSavedSession() {
        if let data = UserDefaults.standard.data(forKey: Self.sessionKey),
           let s = try? JSONDecoder().decode(PlaySession.self, from: data) {
            self.session = s
            Task {
                await refreshSessionIfNeeded()
            }
        }
    }

    func saveSession(_ s: PlaySession) {
        self.session = s
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: Self.sessionKey)
        }
    }

    func signOut() {
        self.session = nil
        self.featuredApps = []
        self.searchResults = []
        self.downloadProgress = [:]
        UserDefaults.standard.removeObject(forKey: Self.sessionKey)
    }

    // MARK: - Login Flow with EmbeddedSetup oauth_token

    /// Trades oauth_token from EmbeddedSetup for full Play Store session
    func signIn(email: String, oauthToken: String) async {
        isLoading = true
        errorMessage = nil
        statusMessage = "Exchanging token with Google…"

        do {
            // 1. Trade oauth_token for aasToken
            let aas = try await PlayAPI.accountToken(email: email, oauthToken: oauthToken)
            var s = PlaySession(email: email, aasToken: aas)

            // 2. Checkin (register device)
            statusMessage = "Registering device with Google Play…"
            let (gsfID, consistency) = try await PlayAPI.checkin()
            s.gsfID = gsfID
            s.consistencyToken = consistency

            // 3. Acquire bearer token for Play Store
            statusMessage = "Authorizing Google Play session…"
            let bearer = try await PlayAPI.playToken(s)
            s.bearer = bearer

            // 4. Upload device config (Pixel 8)
            statusMessage = "Uploading device profile…"
            let configToken = try await PlayAPI.uploadDeviceConfig(s)
            s.deviceConfigToken = configToken

            saveSession(s)
            statusMessage = nil
            isLoading = false

            // Load initial apps
            await loadBrowseApps()
        } catch {
            isLoading = false
            statusMessage = nil
            errorMessage = error.localizedDescription
            HuskLog.log("store", "Sign-in error: \(error.localizedDescription)")
        }
    }

    // MARK: - Aurora Guest Flow

    /// Obtains an anonymous guest session using Aurora's token dispenser server
    func signInAsGuest(customDispenserURL: String? = nil) async {
        isLoading = true
        errorMessage = nil
        statusMessage = "Connecting to Aurora guest server…"

        do {
            let url = customDispenserURL ?? PlayAPI.defaultDispenserURL
            let s = try await PlayAPI.fetchAuroraGuestSession(dispenserURL: url)
            saveSession(s)
            statusMessage = nil
            isLoading = false
            await loadBrowseApps()
        } catch {
            isLoading = false
            statusMessage = nil
            errorMessage = error.localizedDescription
            HuskLog.log("store", "Aurora guest sign-in error: \(error.localizedDescription)")
        }
    }

    /// Refresh Play Store bearer token if needed
    func refreshSessionIfNeeded() async {
        guard var s = session else { return }
        if s.isAnonymous {
            // Refresh anonymous guest token from dispenser
            do {
                let fresh = try await PlayAPI.fetchAuroraGuestSession()
                saveSession(fresh)
                await loadBrowseApps()
            } catch {
                errorMessage = error.localizedDescription
                HuskLog.log("store", "Failed to refresh Aurora guest token: \(error.localizedDescription)")
            }
            return
        }
        guard !s.aasToken.isEmpty else { return }
        do {
            let bearer = try await PlayAPI.playToken(s)
            s.bearer = bearer
            saveSession(s)
            await loadBrowseApps()
        } catch {
            HuskLog.log("store", "Failed to refresh Play token: \(error.localizedDescription)")
        }
    }

    // MARK: - Store Browsing & Searching

    /// Run a store call, and when Google says the token is spent (401, or 429 for a shared guest token) get a new one and run it
    /// once more. Tokens were only refreshed at launch, so a Store left open for an hour stopped answering for good.
    private func withFreshToken<T>(_ call: (PlaySession) async throws -> T) async throws -> T {
        guard let s = session, !s.bearer.isEmpty else { throw PlayError("Not signed in to Google Play.") }
        do {
            return try await call(s)
        } catch let e as PlayError where e.needsNewToken {
            HuskLog.log("store", "token refused (\(e.message)); getting a new one and trying again")
            await renewToken()
            guard let fresh = session, !fresh.bearer.isEmpty else { throw e }
            return try await call(fresh)
        }
    }

    /// A new bearer token for the session as it is, without reloading anything.
    private func renewToken() async {
        guard var s = session else { return }
        do {
            if s.isAnonymous {
                saveSession(try await PlayAPI.fetchAuroraGuestSession())
            } else if !s.aasToken.isEmpty {
                s.bearer = try await PlayAPI.playToken(s)
                saveSession(s)
            }
        } catch {
            HuskLog.log("store", "could not renew the Play token: \(error.localizedDescription)")
        }
    }

    /// Bumped by every search, so only the newest one may touch the results.
    private var searchGeneration = 0

    func loadBrowseApps() async {
        guard session?.bearer.isEmpty == false else { return }
        if !featuredApps.isEmpty { return }
        isLoading = true
        do {
            let apps = try await withFreshToken { try await PlayAPI.browse(session: $0) }
            self.featuredApps = apps
            self.isLoading = false
        } catch {
            self.isLoading = false
            HuskLog.log("store", "Failed to browse apps: \(error.localizedDescription)")
        }
    }

    func search(query: String) async {
        guard session?.bearer.isEmpty == false else { return }
        searchGeneration += 1
        let generation = searchGeneration
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        do {
            let results = try await withFreshToken { try await PlayAPI.search(query: trimmed, session: $0) }
            // A slower, older search finishing after a newer one used to overwrite its results.
            guard generation == searchGeneration else { return }
            self.searchResults = results
            self.isSearching = false
        } catch is CancellationError {
            // Typed over: the newer search owns the spinner and the results.
        } catch {
            guard generation == searchGeneration else { return }
            self.isSearching = false
            self.errorMessage = "Search failed: \(error.localizedDescription)"
            HuskLog.log("store", "Failed to search '\(query)': \(error.localizedDescription)")
        }
    }

    func fetchDetails(for packageName: String) async -> PlayAPI.PlayApp? {
        try? await withFreshToken { try await PlayAPI.details(packageName: packageName, session: $0) }
    }

    // MARK: - Download & Install Flow

    func downloadAndInstall(app: PlayAPI.PlayApp) {
        guard let s = session else { return }
        let pkg = app.id
        guard downloadProgress[pkg] == nil else { return }

        downloadProgress[pkg] = 0.05
        installingPackages.insert(pkg)

        Task {
            do {
                // If versionCode is 0, fetch details first to get current versionCode
                var versionCode = app.versionCode
                if versionCode == 0 {
                    if let fresh = try? await PlayAPI.details(packageName: pkg, session: s), fresh.versionCode > 0 {
                        versionCode = fresh.versionCode
                    } else {
                        versionCode = 1
                    }
                }

                HuskLog.log("store", "Starting download for \(pkg) (vc: \(versionCode))")
                let files = try await PlayAPI.downloadApp(
                    packageName: pkg,
                    versionCode: versionCode,
                    session: s
                ) { [weak self] p in
                    self?.downloadProgress[pkg] = p
                }

                HuskLog.log("store", "Downloaded \(files.count) files for \(pkg), handing to IncomingFiles")
                self.downloadProgress.removeValue(forKey: pkg)
                self.installingPackages.remove(pkg)

                // Hand to Husk's IncomingFiles flow, which automatically presents IncomingChooser!
                IncomingFiles.shared.receive(files)
            } catch {
                self.downloadProgress.removeValue(forKey: pkg)
                self.installingPackages.remove(pkg)
                self.errorMessage = "Failed to download \(app.title): \(error.localizedDescription)"
                HuskLog.log("store", "Download error for \(pkg): \(error.localizedDescription)")
            }
        }
    }
}
