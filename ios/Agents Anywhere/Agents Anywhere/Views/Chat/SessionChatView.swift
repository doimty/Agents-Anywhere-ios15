import Perception
import SwiftUI
import QuickLook

struct SessionChatView: View, Equatable {
    @StateObject private var storage: StableViewModel<SessionChatModel>
    private var model: SessionChatModel { storage.value }
    private let sessionIdentity: V2SessionModel
    let deviceName: String?
    let onMenu: () -> Void
    @State private var sheet: SessionSheet?
    @State private var expandedNoticeID: String?
    private let fileService: V2WorkspaceFilesService
    private let detailService: V2SessionDetailService
    private enum SessionSheet: Identifiable {
        case notices, details, files, preview(SessionFileReference, root: String? = nil)
        var id: String { switch self { case .notices: "notices"; case .details: "details"; case .files: "files"; case .preview(let reference, let root): "file:\(root ?? ""):\(reference.id)" } }
    }
    @State private var previewURL: URL?
    @State private var previewDirectory: URL?
    @State private var isDownloading = false
    @State private var toasts = ChatToastStore()
    @State private var pendingTakeover: Bool?
    @State private var hasStartedLoading = false
    @State private var openingTimedOut = false
    /// Bumped by both retry buttons so the stall watch re-arms per attempt
    /// instead of firing once for the lifetime of the page.
    @State private var openingAttempt = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var bodyLineHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .footnote) private var takeoverPillHeight: CGFloat = 32

    init(session: V2SessionModel, services: V2ClientServices, deviceName: String?,
         onMenu: @escaping () -> Void) {
        _storage = StateObject(wrappedValue: StableViewModel {
            let chat = SessionChatModel(session: session, repository: services.sessionRepository, attachments: services.attachments,
                files: services.workspaceFiles)
            chat.onEditCreation = { [weak services, weak session] pending in
                if let session { services?.editCreation(session, pending: pending) }
            }
            chat.onDiscardCreation = { [weak services] in services?.discardCreation(session.id) }
            return chat
        })
        sessionIdentity = session
        self.deviceName = deviceName
        fileService = services.workspaceFiles; detailService = services.sessionDetail
        self.onMenu = onMenu
    }
    private var controls: ChatControlMetrics { .init(bodyLineHeight: bodyLineHeight) }
    private var session: V2SessionModel { model.session }
    private var requiresTakeover: Bool { session.metadata?.takeover == false }
    // Sidebar motion changes the containing card, not the session. Observable
    // model changes and real size/environment changes still update this subtree.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sessionIdentity === rhs.sessionIdentity && lhs.deviceName == rhs.deviceName
    }
    var body: some View {
        AppObservationTracking {
        GeometryReader { geometry in
            AppObservationTracking {
                Group {
                    if hasStartedLoading {
                        ChatTimelineView(model: model,
                            onAttachment: openAttachment, onFile: openFile)
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                    .overlay {
                        AppObservationTracking {
                            if model.isContentVisible && model.timeline.rows.isEmpty && model.timeline.pendingMessages.isEmpty {
                                VStack(spacing: 12) {
                                    Text(String(localized: "在这里继续你的任务")).foregroundStyle(.secondary)
                                }.allowsHitTesting(false)
                            }
                        }
                    }
                    .overlay {
                        // This branch is the only overlay in this file that was
                        // left outside the tracking scope. On iOS 15/16 a read of
                        // @Perceptible state outside WithPerceptionTracking
                        // registers no dependency, so once layout settled the
                        // decision "not visible yet" was never revisited and the
                        // mask stayed on top of a transcript that had already
                        // loaded. Entering from the drawer loses that race far more
                        // often, because the closing animation stops the body from
                        // re-evaluating right after the frame that decided it.
                        AppObservationTracking {
                            // Never cover rows that already exist unless there is a
                            // failure to report. The mask is a first-paint shield
                            // for an empty page; leaving it on top of a presented
                            // transcript turns a stale readiness flag into a
                            // permanent spinner. Hit testing still follows
                            // isContentVisible, so early rows stay read-only until
                            // the runtime facts arrive.
                            if !model.isContentVisible,
                               model.timeline.rows.isEmpty || model.openingError != nil {
                                if openingTimedOut {
                                    // A stalled sync feed can withhold every frame,
                                    // and the opaque mask then reads as a black
                                    // hang. After a bounded wait show a small status
                                    // card with an explicit retry.
                                    openingSlowBanner
                                } else {
                                    openingMask
                                }
                            }
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        AppObservationTracking {
                            VStack(spacing: 0) {
                                SessionInteractionDock(chat: model,
                                    onShowAll: { expandedNoticeID = $0; sheet = .notices })
                                    .traceChatLayout("interaction-dock")
                                ChatComposerDock(draft: session.composer, settings: model.settings,
                                    maximumEditorHeight: min(160, max(72, geometry.size.height * 0.30)), controls: controls,
                                    canSend: session.canSend, canAttach: model.canAttach,
                                    canSelectModel: session.runtime.allows("catalog.model"),
                                    canSelectPermission: session.runtime.allows("catalog.permission"),
                                    isStreaming: model.isRunning, canStop: session.runtime.allows("session.interrupt"),
                                    isBusy: model.isWorking || !model.isOpeningReady, placeholder: requiresTakeover ? String(localized: "请先接管") : String(localized: "询问 Agents"),
                                    isLoadingSettings: model.isLoadingSettings,
                                    settingsError: model.settingsError, sessionChat: model,
                                    onSend: model.send, onStop: model.interrupt, onLoadSettings: model.loadSettings,
                                    onApplySettings: model.applySettings, applyError: { model.settingsError },
                                    onDraftChange: { model.repository.draftDidChange(sessionID: model.session.id) })
                                    .traceChatLayout("composer-dock")
                            }
                            .frame(maxWidth: ChatControlMetrics.maximumContentWidth).frame(maxWidth: .infinity)
                            // Native safe-area layout owns both the visible scroll
                            // region and the dock's space; do not add a second margin.
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        AppObservationTracking {
                            VStack(alignment: .leading, spacing: 4) {
                                // Metadata can arrive after history. Transient controls
                                // float below the header instead of resizing its inset.
                                if requiresTakeover {
                                    takeoverPill.frame(maxWidth: .infinity, alignment: .center)
                                }
                                ChatErrorToasts(store: toasts, isRetrying: session.isLoading, onRetry: { _ in await session.refresh() })
                                if let success = model.commandSuccess {
                                    CommandSuccessToast(feedback: success) { model.commandSuccess = nil }
                                        .frame(maxWidth: .infinity, alignment: .center)
                                }
                            }.padding(.top, 8)
                        }
                    }
            }
        }
        .modifier(ChatPageToolbar(title: session.metadata?.title ?? String(localized: "会话"),
            subtitle: [session.metadata?.runtimeName ?? session.metadata?.runtime ?? String(localized: "Agent"),
                deviceName ?? session.metadata?.connectorId].compactMap { $0 }.joined(separator: " · "),
            status: model.headerStatus, alignsTitleLeading: true, onMenu: onMenu))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { sheet = .files } label: { AppSymbol("folder") }
                    .accessibilityLabel(String(localized: "文件管理"))
                    .disabled(session.metadata?.cwd?.isEmpty != false)
                Menu {
                    Button(String(localized: "会话详情与导出"), systemImage: "info.circle") { sheet = .details }
                    Button(String(localized: "复制会话 ID"), systemImage: "number") { UIPasteboard.general.string = session.id }
                } label: { AppSymbol("ellipsis") }
                .accessibilityLabel(String(localized: "会话菜单"))
            }
        }
        .modifier(SessionTakeoverConfirmation(pending: $pendingTakeover, isDsh: model.isDsh) { enabled in
            model.error = nil
            if !(await model.setTakeover(enabled)), let error = model.takeoverError { model.error = error }
        })
        .completionFeedback(trigger: model.isRunning) { wasRunning, isRunning in
            wasRunning && !isRunning && model.isOpeningReady && session.runtime.isFresh
                && session.runtime.state?.status == .idle
        }
        .onAppear {
            // Measured on device: the loading flag never turned true for a session
            // opened from the drawer, because both paths to it were async and the
            // page was torn down and rebuilt several times a second while the app
            // was busy. Anything that has to await a timer before setting a flag
            // can be cancelled every time. Set it here, synchronously, on every
            // mount; the work below is idempotent and the repository coalesces it.
            // Pin the model first so the load cannot be evicted underneath itself.
            model.repository.retainSession(model.session.id)
            guard !hasStartedLoading else { return }
            model.reportReclaimedOpening()
            hasStartedLoading = true
        }
        .task(id: openingAttempt) {
            // This watchdog must not depend on any of the gates it is meant to
            // report. Keyed on the loading flag it never fired on the exact path
            // that hangs -- the one where the flag never turns true -- so a stuck
            // page showed a bare spinner and could not describe itself.
            openingTimedOut = false
            do { try await ClientTask.sleep(for: .seconds(8)) } catch { return }
            guard !Task.isCancelled, !model.isContentVisible else { return }
            openingTimedOut = true
        }
        .task(id: OpeningLoadKey(started: hasStartedLoading, attempt: openingAttempt)) {
            guard hasStartedLoading else { return }
            // Reattaching a loaded detail only resumes observation.
            await model.prepareOpening()
            guard !Task.isCancelled else { return }
            await model.timeline.run(sessionID: session.id, repository: model.repository)
        }
        .appOnChange(of: scenePhase != .active, initial: true) { _, suspended in
            // The drawer owns hit-testing and visual occlusion. It must not
            // suspend the session's initial snapshot: a stale drawer motion
            // state would otherwise leave rows staged forever behind the mask.
            model.timeline.setPresentationSuspended(suspended)
        }
        .sheet(item: $sheet) { destination in
            AppObservationTracking {
                switch destination {
                case .notices: SessionNoticesSheet(model: model, initialNoticeID: expandedNoticeID)
                case .details: SessionDetailsSheet(chat: model, service: detailService)
                case .files:
                    if let meta = session.metadata, let cwd = meta.cwd {
                        WorkspaceFilesSheet(connectorId: meta.connectorId,
                            deviceName: deviceName ?? meta.connectorId,
                            workspace: V2DeviceWorkspace(path: cwd, name: String(localized: "会话文件"), sessionCount: 1, lastActiveAt: nil),
                            service: fileService, session: session)
                    }
                case .preview(let reference, let root):
                    if let meta = session.metadata {
                        WorkspaceFilePreviewSheet(connectorId: meta.connectorId, root: root ?? meta.cwd ?? ".", path: reference.path,
                            service: fileService, session: session, location: reference)
                    }
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let reference = SessionFileReference.reference(from: url) {
                if session.isValid { sheet = .preview(reference) }
                return .handled
            }
            return ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
        .quickLookPreview($previewURL)
        .appOnChange(of: previewURL) { _, url in if url == nil { cleanPreview() } }
        .onDisappear {
            model.repository.releaseSession(model.session.id)
            model.timeline.setPresentationSuspended(false)
            if previewURL == nil { cleanPreview() }
            // A composer that still holds focus leaves the keyboard's inset
            // reserved on the WINDOW, and SwiftUI applies that window-wide: the
            // next page's bottom controls read the inflated safe area and float
            // upward. Release the responder at the source; this is a no-op when
            // nothing is focused.
            session.composer.isFocused = false
            let keyWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
            _ = keyWindow?.endEditing(true)
        }
        .appOnChange(of: session.failure, initial: true) { _, failure in
            toasts.update(source: "session", failure: failure, canRetry: failure?.kind != .authentication)
        }
        .appOnChange(of: model.error, initial: true) { _, message in
            toasts.update(source: "operation", failure: message.map { V2ClientFailure(kind: .rejected, message: $0) })
        }
        .appOnChange(of: model.commandFailure) { _, feedback in
            // Each command failure is new, even when its text repeats a dismissed one.
            toasts.update(source: "command", failure: nil)
            toasts.update(source: "command", failure: feedback.map { V2ClientFailure(kind: .rejected, message: $0.message ?? "") }, title: feedback?.title)
        }
        .appOnChange(of: model.openingError, initial: true) { _, message in
            toasts.update(source: "opening", failure: message.map { V2ClientFailure(kind: .unavailable, message: $0) })
        }
        }
    }

    private var openingMask: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            VStack(spacing: 12) {
                // A presented snapshot is not the same as an authorized one: the
                // live feed can stage rows while the aggregate read is still the
                // thing withholding readiness. Requiring both flags here hid the
                // failure behind a bare spinner that never offered a retry.
                if let error = model.openingError {
                    Text(error).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .accessibilityIdentifier("chat.opening.error")
                    Button(String(localized: "重试")) { retryOpening() }
                        .accessibilityIdentifier("chat.opening.retry")
                } else {
                    ProgressView().progressViewStyle(.circular).accessibilityLabel(String(localized: "正在加载会话"))
                        .accessibilityIdentifier("chat.opening.loading")
                }
                // Shown from the first frame, not only after the stall timer: a
                // page that hangs before any gate flips must still report which
                // gate it is waiting on.
                Text(verbatim: openingGateReport)
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("chat.opening.gates")
            }
            .padding(24).frame(maxWidth: 320)
        }
        .transition(.identity)
    }

    private var takeoverPill: some View {
        Button { pendingTakeover = true } label: {
            Label(String(localized: "接管会话以继续交互"), appSymbol: "hand.raised")
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppTheme.primaryText(colorScheme))
                .padding(.horizontal, 14).frame(minHeight: takeoverPillHeight)
                .appGlassEffect(.interactive, in: Capsule())
                .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!model.canChangeTakeover)
        .accessibilityIdentifier("chat.session.takeover")
        .padding(.horizontal, 20).padding(.bottom, 4)
    }

    /// Which gate is still unsatisfied. The spinner was the only visible symptom
    /// of four different failures, so a stuck page could never be reported
    /// without guessing. This line names the failing gate on the device itself.
    private var openingGateReport: String {
        let error = String(model.openingError?.prefix(80) ?? "")
        return ["auth=\(model.hasAuthoritativeOpening ? 1 : 0)",
                "prepared=\(model.isOpeningPrepared ? 1 : 0)",
                "snap=\(model.timeline.hasPresentedSnapshot ? 1 : 0)",
                "preview=\(model.isShowingHistoricPreview ? 1 : 0)",
                "started=\(hasStartedLoading ? 1 : 0)",
                "meta=\(session.metadata == nil ? "nil" : "ok")",
                "err=\(error.isEmpty ? "-" : error)"].joined(separator: "  ")
    }

    private var openingSlowBanner: some View {
        VStack(spacing: 12) {
            ProgressView().progressViewStyle(.circular)
                .accessibilityIdentifier("chat.opening.slow")
            // The hint replaces the spinner, so it also has to inherit the
            // failure that arrived while it was counting down. Otherwise a read
            // that errors at second 12 would be reported as "still syncing".
            Text(String(localized: "正在同步 Agent 状态，稍等片刻…"))
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let error = model.openingError {
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("chat.opening.error")
            }
            Text(verbatim: openingGateReport)
                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("chat.opening.gates")
            Button(String(localized: "重试")) { retryOpening() }
                .accessibilityIdentifier("chat.opening.slow.retry")
        }
        .padding(20).frame(maxWidth: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    /// Both masks offer the same gesture: drop the hint, re-arm the stall watch
    /// and re-run the aggregate read that owns the user-visible error.
    private func retryOpening() {
        openingTimedOut = false
        openingAttempt &+= 1
        Task { await model.prepareOpening() }
    }

    private func openFile(_ path: String) {
        guard session.isValid, !path.isEmpty else { return }
        sheet = .preview(SessionFileReference.parse(path))
    }

    private func openAttachment(_ file: V2AttachmentContent) {
        if file.readsFromDevice, let path = file.devicePath { sheet = .preview(SessionFileReference(path: path), root: file.root); return }
        guard !isDownloading, let fileID = file.fileId else { return }
        isDownloading = true
        model.error = nil
        Task { @MainActor in
            defer { isDownloading = false }
            do {
                let data = try await model.download(fileID)
                guard session.isValid, sheet == nil else { return }
                cleanPreview()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-preview-\(UUID().uuidString)", isDirectory: true)
                let name = (file.name ?? String(localized: "Attachment")) as NSString
                let safeName = name.lastPathComponent.isEmpty ? String(localized: "Attachment") : name.lastPathComponent
                let url = directory.appendingPathComponent(safeName)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                previewDirectory = directory; previewURL = url
            } catch { model.error = error.localizedDescription }
        }
    }
    private func cleanPreview() {
        if let directory = previewDirectory { try? FileManager.default.removeItem(at: directory) }
        previewDirectory = nil
    }
}

/// Restarts the load on a new page visit and on every retry. Keyed on the flag
/// alone, a cancelled first attempt could never be re-run: the flag did not
/// change again, so the task did not restart and retry did nothing.
private struct OpeningLoadKey: Equatable {
    let started: Bool
    let attempt: Int
}

/// Command success is transient, like the Web/Desktop toast; failures use the
/// dismissible error toasts instead.
private struct CommandSuccessToast: View {
    let feedback: CommandFeedback
    let onDismiss: () -> Void

    var body: some View {
            AppObservationTracking {
        Button(action: onDismiss) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AppSymbol("checkmark.circle", size: 14).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(feedback.title).font(.subheadline.weight(.medium))
                    if let message = feedback.message, !message.isEmpty {
                        Text(message).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .appGlassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, ChatControlMetrics.collapsedHorizontalInset)
        .accessibilityHint(String(localized: "轻点关闭"))
        .task(id: feedback.id) {
            try? await ClientTask.sleep(for: .seconds(4))
            if !Task.isCancelled { onDismiss() }
        }
            }
        }
}
