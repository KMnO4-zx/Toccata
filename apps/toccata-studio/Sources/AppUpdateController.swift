import AppKit
import Combine
import Foundation

enum AppUpdateState: Equatable {
    case idle, downloading(Double), verifying, ready, installing
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .installing: return true
        default: return false
        }
    }
}

@MainActor
final class AppUpdateController: ObservableObject {
    typealias Prepare = (AvailableUpdate, @escaping @Sendable (Double?) -> Void) async throws -> PreparedAppUpdate
    @Published private(set) var state: AppUpdateState = .idle
    private(set) var prepared: PreparedAppUpdate?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let prepare: Prepare
    private var termination: AnyCancellable?

    init(prepare: Prepare? = nil) {
        self.prepare = prepare ?? { update, progress in
            try await UpdatePackagePreparer().prepare(update, progress: progress)
        }
        if CommandLine.arguments.contains("--update-failed") {
            state = .failed(L10n.tr("自动安装未完成，当前应用仍可使用。请重新检查更新。"))
        }
        termination = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.cancel() }
    }

    func download(_ update: AvailableUpdate) {
        guard !state.isBusy else { return }
        prepared?.discard()
        prepared = nil
        let generation = UUID()
        self.generation = generation
        state = .downloading(0)
        task = Task { [weak self, prepare] in
            do {
                let result = try await prepare(update) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation, self.state.isBusy else { return }
                        self.state = progress.map { .downloading(min(1, max(0, $0))) } ?? .verifying
                    }
                }
                guard let self, !Task.isCancelled, self.generation == generation else {
                    result.discard()
                    return
                }
                self.prepared = result
                self.state = .ready
            } catch {
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.state = .failed((error as? UpdateInstallFailure)?.message ?? L10n.tr("下载更新失败，请检查网络后重试。"))
            }
        }
    }

    func cancel() {
        guard state != .installing else { return }
        generation = UUID()
        task?.cancel()
        task = nil
        prepared?.discard()
        prepared = nil
        state = .idle
    }

    func install() {
        guard let prepared, !state.isBusy else { return }
        guard let application = NSApp.delegate as? ToccataApplicationDelegate else {
            state = .failed(L10n.tr("请从已安装的 Toccata.app 中更新。"))
            return
        }
        state = .installing
        application.installUpdate(start: {
            try await prepared.startInstaller()
        }, failed: { [weak self] error in
            self?.state = .failed((error as? UpdateInstallFailure)?.message ?? L10n.tr("暂时无法安装更新，请稍后重试。"))
        })
    }
}
