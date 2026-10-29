import Combine
import Foundation

enum ToccataReleaseSource {
    static let repository = "KMnO4-zx/Toccata"
    static let repositoryAddress = "github.com/\(repository)"
    static let repositoryURL = URL(string: "https://\(repositoryAddress)")!
    static let releasesURL = repositoryURL.appendingPathComponent("releases")
    static let latestAPIURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
}

struct AvailableUpdate: Equatable {
    let version: String
    let pageURL: URL
    var package: UpdatePackage? = nil
}

struct UpdatePackage: Equatable {
    let url: URL
    let size: Int64
    let sha256: String

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}

enum UpdateCheckFailure: Error, Equatable {
    case noAccessibleRelease
    case rateLimited
    case invalidResponse
    case connectionFailed

    var title: String {
        switch self {
        case .noAccessibleRelease: return L10n.tr("尚无可访问的正式版本")
        case .rateLimited: return L10n.tr("检查过于频繁，请稍后重试")
        case .invalidResponse: return L10n.tr("暂时无法读取版本信息")
        case .connectionFailed: return L10n.tr("暂时无法连接 GitHub")
        }
    }

    var detail: String {
        switch self {
        case .noAccessibleRelease: return L10n.tr("可能尚未发布，或仓库仍为私有。可在 GitHub 登录后查看。")
        case .rateLimited: return L10n.tr("GitHub 暂时限制了请求次数。你也可以直接查看发布页面。")
        case .invalidResponse: return L10n.tr("发布信息暂不可用，请稍后重试或查看发布页面。")
        case .connectionFailed: return L10n.tr("请检查网络后重试，也可以在浏览器中打开发布页面。")
        }
    }
}

enum UpdateCheckState: Equatable {
    case idle
    case checking
    case upToDate
    case available(AvailableUpdate)
    case failed(UpdateCheckFailure)
}

struct ReleaseUpdateService {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport

    init(transport: Transport? = nil) {
        if let transport {
            self.transport = transport
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration)
            self.transport = { try await session.data(for: $0) }
        }
    }

    func check(current: AppVersion, architecture: String = UpdatePackage.architecture) async throws -> AvailableUpdate? {
        guard let installed = ReleaseVersion(current.version) else { throw UpdateCheckFailure.invalidResponse }
        var request = URLRequest(url: ToccataReleaseSource.latestAPIURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Toccata/\(current.version)", forHTTPHeaderField: "User-Agent")
        // Only a manual, anonymous version request; no task or keyboard records are sent.
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw UpdateCheckFailure.invalidResponse }
        switch http.statusCode {
        case 404: throw UpdateCheckFailure.noAccessibleRelease
        case 403, 429: throw UpdateCheckFailure.rateLimited
        case 200: break
        default: throw UpdateCheckFailure.connectionFailed
        }
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
              !release.draft, !release.prerelease,
              let latest = ReleaseVersion(release.tagName) else { throw UpdateCheckFailure.invalidResponse }
        guard latest > installed else { return nil }
        // Construct the destination from the fixed repository and validated version tag.
        // Never open an arbitrary URL from a remote response.
        let pageURL = ToccataReleaseSource.releasesURL.appendingPathComponent("tag")
            .appendingPathComponent(release.tagName)
        let version = "\(latest.major).\(latest.minor).\(latest.patch)"
        var package: UpdatePackage?
        for arch in [architecture, "universal"] {
            let name = "Toccata-\(version)-\(arch).dmg"
            let matching = (release.assets ?? []).filter { $0.name == name }
            guard matching.count == 1, let asset = matching.first,
                  asset.state == "uploaded", asset.size > 0, asset.size <= 1_073_741_824,
                  let digest = asset.digest, digest.hasPrefix("sha256:") else { continue }
            let hash = String(digest.dropFirst(7))
            guard hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
            // Asset URLs are derived from our repository, never remote URL fields.
            package = UpdatePackage(url: ToccataReleaseSource.releasesURL.appendingPathComponent("download")
                .appendingPathComponent(release.tagName).appendingPathComponent(name), size: asset.size, sha256: hash)
            break
        }
        return AvailableUpdate(version: version, pageURL: pageURL, package: package)
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]?

        struct Asset: Decodable {
            let name: String
            let size: Int64
            let state: String
            let digest: String?
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft, prerelease, assets
        }
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var state: UpdateCheckState = .idle
    private let service: ReleaseUpdateService
    private let current: AppVersion

    init(service: ReleaseUpdateService = ReleaseUpdateService(), current: AppVersion = .current) {
        self.service = service
        self.current = current
    }

    func check() async {
        guard state != .checking else { return }
        state = .checking
        do {
            if let update = try await service.check(current: current) {
                state = .available(update)
            } else {
                state = .upToDate
            }
        } catch let error as UpdateCheckFailure {
            state = .failed(error)
        } catch {
            state = .failed(.connectionFailed)
        }
    }
}
