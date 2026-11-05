import SwiftUI
import UIKit
#if DEBUG
import OSLog
#endif

struct ChatTimelineView: View {
    let model: SessionChatModel
    let onAttachment: (V2AttachmentContent) -> Void
    let onFile: (String) -> Void

    var body: some View {
        if #available(iOS 18.0, *), AppCompatibility.useNativeUI {
            NativeChatTimeline(model: model, onAttachment: onAttachment, onFile: onFile)
        } else {
            legacyTimeline
        }
    }

    private var legacyTimeline: some View {
        LegacyChatTimeline(model: model, onAttachment: onAttachment, onFile: onFile)
    }
}

@available(iOS 18.0, *)
private struct NativeChatTimeline: View {
    let model: SessionChatModel
    let onAttachment: (V2AttachmentContent) -> Void
    let onFile: (String) -> Void
    @State private var historyLayout: TimelineHistoryLayout?
    @State private var historyPosition: TimelineHistoryPosition?
    @State private var hasRequestedOlder = false
    @State private var position = ScrollPosition()
    @State private var scrolling = TimelineScrollState()
    @State private var viewportSample = ChatViewportSample()
    @State private var viewportUpdates = ChatLayoutUpdate()
    @State private var historyUpdates = ChatLayoutUpdate()
    @State private var latestPull = TimelineHistoryPull()
    @State private var olderPull = TimelineHistoryPull(edge: .older)
    @State private var olderPromptVisible = false
    @State private var olderLoadRequest: Int?
    @State private var latestPromptVisible = false
    @State private var latestLoadRequest: Int?
    @State private var nativePhase = TimelineScrollState.Phase.idle
    /// The return pill would sit on top of the keyboard while typing.
    @State private var keyboardIsVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sidebarDrawerIsTransitioning) private var sidebarIsTransitioning
    @Environment(\.sidebarDrawerObscuresDetail) private var sidebarObscuresDetail
    @ScaledMetric(relativeTo: .caption) private var returnPillHeight: CGFloat = 32
#if DEBUG
    private static let drawerLayoutLog = Logger(subsystem: "agents.anywhere", category: "drawer-layout")
#endif

    private var hasInteractions: Bool {
        model.session.notices.notices.contains { $0.isVisible && $0.notice.type == "interaction" }
    }
    private var viewport: TimelineViewport { viewportSample.value ?? scrolling.viewport }
    private var navigationIsSuspended: Bool { sidebarIsTransitioning || sidebarObscuresDetail }

    var body: some View { AppObservationTracking { nativeTimeline } }

    @available(iOS 18.0, *)
    private var nativeTimeline: some View {
        // A sibling overlay receives taps independently of the scroll view's
        // deceleration recognizer. The explicit return intent survives its callbacks.
        ZStack(alignment: .bottom) {
            ScrollView {
                ChatTimelineContent(model: model, onAttachment: onAttachment, onFile: onFile,
                    latestPullReady: latestPull.isReady, isLoadingLatest: latestLoadRequest != nil,
                    olderPullReady: olderPull.isReady, isLoadingOlder: olderLoadRequest != nil,
                    keepsOlderPrompt: hasRequestedOlder, historyAnchor: historyPosition?.origin,
                    onLoadOlder: loadOlder, onLoadLatest: loadLatest,
                    onHistoryLayout: historyDidLayOut,
                    onPromptVisibility: { latestPromptVisible = $0 },
                    onOlderPromptVisibility: { olderPromptVisible = $0 },
                    onTailVisibility: { region, visible in scrolling.tailVisibilityChanged(region, visible: visible) })
                    .equatable()
                    .background { ChatPageScrollEdge() }
            }
            .accessibilityIdentifier("chat.timeline.scroll")
            .scrollPosition($position)
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.always, axes: .vertical)
            .appScrollEdgeEffect(.soft, for: .top)
            .defaultScrollAnchor(.top, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .allowsHitTesting(model.isContentVisible)
            .accessibilityHidden(!model.isContentVisible)
            .onScrollPhaseChange { _, phase, context in
                // A phase callback carries a newer authoritative sample.
                viewportUpdates.cancel()
                let mapped: TimelineScrollState.Phase
                switch phase {
                case .idle: mapped = .idle
                case .tracking: mapped = .tracking
                case .interacting: mapped = .interacting
                case .decelerating: mapped = .decelerating
                case .animating: mapped = .animating
                @unknown default: mapped = .idle
                }
                let current = TimelineViewport(geometry: context.geometry)
                let wasInteracting = scrolling.phase == .interacting
                viewportSample.value = current
                scrolling.geometryChanged(current)
                nativePhase = mapped
                // The drawer owns horizontal navigation. Do not interpret its
                // interrupted scroll callbacks as a fresh vertical reading intent.
                if navigationIsSuspended { return }
                if scrolling.phaseChanged(mapped, viewport: current) {
                    // Release ScrollPosition's persistent edge target as soon
                    // as the user takes over, including interrupted animations.
                    releaseScrollPosition()
                    historyPosition?.cancelRestoration()
                    olderPull.begin(at: current, promptVisible: olderPromptVisible,
                        canLoad: model.session.hasOlderItems && !model.session.isLoadingHistory && olderLoadRequest == nil && latestLoadRequest == nil)
                    latestPull.begin(at: current, promptVisible: latestPromptVisible,
                        canLoad: model.session.hasNewerItems && !model.session.isLoadingHistory && latestLoadRequest == nil && olderLoadRequest == nil)
                }
                if mapped == .interacting { latestPull.update(current); olderPull.update(current) }
                if mapped == .idle || mapped == .decelerating {
                    let shouldLoadLatest = latestPull.end(), shouldLoadOlder = olderPull.end()
                    if wasInteracting {
                        if shouldLoadOlder { loadOlder() }
                        else if shouldLoadLatest { loadLatest() }
                    }
                } else if mapped == .animating { latestPull.cancel(); olderPull.cancel() }
            }
            .onScrollGeometryChange(for: TimelineViewport.self) { geometry in
                TimelineViewport(geometry: geometry)
            } action: { previous, value in
#if DEBUG
                // A device recording cannot distinguish a changed native
                // offset from an upstream reflow. Record only vertical changes
                // during drawer navigation, without logging message contents.
                if ChatLayoutDiagnostics.isEnabled, navigationIsSuspended,
                   abs(value.contentHeight - previous.contentHeight) > 1
                    || abs(value.visibleHeight - previous.visibleHeight) > 1
                    || abs(value.offsetY - previous.offsetY) > 1 {
                    Self.drawerLayoutLog.debug("Drawer geometry: content \(previous.contentHeight, privacy: .public) -> \(value.contentHeight, privacy: .public), viewport \(previous.visibleHeight, privacy: .public) -> \(value.visibleHeight, privacy: .public), offset \(previous.offsetY, privacy: .public) -> \(value.offsetY, privacy: .public)")
                }
#endif
                viewportUpdates.submit(value) { value in
                    // Offset samples are needed for restoration, but do not change
                    // the rendered page. Publish only dimensions used by following.
                    viewportSample.value = value
                    let previous = scrolling.viewport
                    if previous.contentHeight != value.contentHeight || previous.visibleHeight != value.visibleHeight
                        || previous.topInset != value.topInset {
                        scrolling.geometryChanged(value)
                    }
                    if !navigationIsSuspended && scrolling.phase == .interacting {
                        var latest = latestPull, older = olderPull
                        latest.update(value); older.update(value)
                        if latest != latestPull { latestPull = latest }
                        if older != olderPull { olderPull = older }
                    }
                }
            }
            .onChange(of: navigationIsSuspended, initial: true) { _, suspended in
                viewportUpdates.cancel()
                scrolling.setNavigationSuspended(suspended)
                if suspended {
                    releaseScrollPosition()
                    latestPull.cancel(); olderPull.cancel()
                } else {
                    scrolling.phaseChanged(nativePhase, viewport: viewport)
                    if let historyLayout { historyDidLayOut(historyLayout) }
                }
            }
            .onChange(of: model.session.pendingMessages.last?.id) { _, id in
                if model.isContentVisible, id != nil && !hasInteractions { scrolling.requestBottom() }
            }
            .onChange(of: model.responseRevision) { _, _ in
                if model.isContentVisible { scrolling.requestBottom() }
            }
            .onChange(of: hasInteractions, initial: true) { _, presented in
                scrolling.setInteractionPresented(presented)
            }
            .onChange(of: model.isContentVisible, initial: true) { _, ready in
                if ready { scrolling.open(interactionPresented: hasInteractions) }
            }
            .onChange(of: scrolling.navigationGeneration) { _, _ in
                releaseScrollPosition()
            }
            .task(id: scrolling.pendingBottomRequest) {
                guard let request = scrolling.pendingBottomRequest, !navigationIsSuspended else { return }
                // Coalesce actual layout changes. Scrolling through the same
                // layout cannot restart this animation on every offset callback.
                do { try await ClientTask.sleep(for: .milliseconds(24)) } catch { return }
                guard !Task.isCancelled, !navigationIsSuspended, let command = scrolling.begin(request) else { return }
                scrollToBottom(command)
            }
            .task(id: UserScrollSettlement(needed: scrolling.needsUserScrollSettlement,
                tail: scrolling.tail, generation: scrolling.navigationGeneration)) {
                guard scrolling.needsUserScrollSettlement else { return }
                // Reconcile visibility after the native phase callback. This
                // never holds opening behind a spinner or repeats a scroll.
                do { try await ClientTask.sleep(for: .milliseconds(64)) } catch { return }
                guard !Task.isCancelled else { return }
                scrolling.settleUserScroll()
            }
            .task(id: olderLoadRequest) {
                guard let request = olderLoadRequest else { return }
                await model.session.loadOlder()
                guard !Task.isCancelled, historyPosition?.id == request else { return }
                if !model.session.isValid { historyPosition = nil; olderLoadRequest = nil; return }
                historyPosition?.receivedPage(firstRowID: model.session.timeline.first { $0.value.isVisibleInChat }?.id)
            }
            .task(id: HistorySettlement(id: historyPosition?.id, ready: historyPosition?.isReadyToFinish == true,
                offset: historyPosition?.restoredOffset)) {
                guard let request = historyPosition?.id, historyPosition?.isReadyToFinish == true else { return }
                // Let the point correction reach native layout before releasing
                // its target or ending the spinner. A new measurement restarts this.
                do { try await ClientTask.sleep(for: .milliseconds(64)) } catch { return }
                guard !Task.isCancelled, historyPosition?.id == request else { return }
                if scrolling.navigationGeneration == request, historyPosition?.restoredOffset != nil {
                    position.isPositionedByUser = true
                }
                historyPosition = nil; olderLoadRequest = nil
            }
            .task(id: latestLoadRequest) {
                guard let generation = latestLoadRequest else { return }
                await model.session.loadLatest()
                guard !Task.isCancelled else { return }
                // A drag during the fetch must not be undone when it finishes.
                if scrolling.navigationGeneration == generation { scrolling.requestBottom() }
                latestLoadRequest = nil
            }
            if !keyboardIsVisible, scrolling.showsBottomButton() {
                Button {
                    latestPull.cancel(); olderPull.cancel()
                    historyPosition?.cancelRestoration()
                    scrolling.requestBottom()
                } label: {
                    Label(String(localized: "到底部"), appSymbol: "arrow.down").font(.caption.weight(.medium)).foregroundStyle(.primary)
                        .padding(.horizontal, 12).frame(height: returnPillHeight)
                        .appGlassEffect(.interactive, in: Capsule())
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("chat.timeline.bottom")
                .padding(.bottom, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .traceChatLayout("timeline-viewport")
        .onDisappear { viewportUpdates.cancel(); historyUpdates.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardIsVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardIsVisible = false
        }
    }
    @available(iOS 18.0, *)
    private func loadOlder() {
        guard model.session.isValid, model.session.hasOlderItems,
              !model.session.isLoadingHistory, olderLoadRequest == nil, latestLoadRequest == nil else { return }
        olderPull.cancel(); latestPull.cancel()
        scrolling.browseHistory()
        position.isPositionedByUser = true
        let layout = historyLayout.flatMap { $0.firstRowID == model.timeline.rows.first?.id ? $0 : nil }
        historyPosition = TimelineHistoryPosition(id: scrolling.navigationGeneration, layout: layout,
            offsetY: viewport.offsetY, topInset: viewport.topInset)
        hasRequestedOlder = true
        olderLoadRequest = scrolling.navigationGeneration
    }
    @available(iOS 18.0, *)
    private func loadLatest() {
        guard model.session.isValid, model.session.hasNewerItems,
              !model.session.isLoadingHistory, latestLoadRequest == nil, olderLoadRequest == nil else { return }
        olderPull.cancel(); latestPull.cancel()
        historyPosition?.cancelRestoration()
        scrolling.requestBottom()
        latestLoadRequest = scrolling.navigationGeneration
    }
    @available(iOS 18.0, *)
    private func scrollToBottom(_ command: TimelineScrollState.BottomCommand) {
        withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.28, dampingFraction: 1, blendDuration: 0.12),
            completionCriteria: .removed) {
            // Let the scroll view resolve its own safe-area/inset coordinate
            // system. The edge target is released when this animation finishes
            // or as soon as a gesture/drawer/approval cancels the command.
            position.scrollTo(edge: .bottom)
        } completion: {
            if scrolling.complete(command) { releaseScrollPosition() }
        }
    }
    @available(iOS 18.0, *)
    private func releaseScrollPosition() {
        guard position.edge != nil || position.point != nil else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { position.isPositionedByUser = true }
    }
    @available(iOS 18.0, *)
    private func historyDidLayOut(_ layout: TimelineHistoryLayout) {
        historyUpdates.submit(layout) { layout in
            if historyLayout != layout { historyLayout = layout }
            guard !navigationIsSuspended, var restoration = historyPosition else { return }
            let offset = restoration.laidOut(layout, generation: scrolling.navigationGeneration)
            if historyPosition != restoration { historyPosition = restoration }
            guard let offset else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { position.scrollTo(y: offset) }
        }
    }
    private struct HistorySettlement: Equatable {
        let id: Int?
        let ready: Bool
        let offset: CGFloat?
    }
    private struct UserScrollSettlement: Equatable {
        let needed: Bool
        let tail: TimelineTailVisibility
        let generation: Int
    }
}

/// The original transcript with iOS 15 scroll APIs. Network task ownership,
/// reading intent and layout restoration have independent lifetimes.
private struct LegacyChatTimeline: View {
    let model: SessionChatModel
    let onAttachment: (V2AttachmentContent) -> Void
    let onFile: (String) -> Void

    @State private var driver = AppTimelineScrollDriver()
    @State private var scrolling = TimelineScrollState()
    @State private var historyLoad = TimelineHistoryLoadState()
    @State private var hasRequestedOlder = false
    @State private var isVisible = false
    @State private var animatesReturn = false
    @State private var keyboardVisible = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sidebarDrawerIsTransitioning) private var sidebarIsTransitioning
    @Environment(\.sidebarDrawerObscuresDetail) private var sidebarObscuresDetail
    @ScaledMetric(relativeTo: .caption) private var returnPillHeight: CGFloat = 32

    private var viewportIsActive: Bool {
        isVisible && scenePhase == .active && !sidebarIsTransitioning && !sidebarObscuresDetail
    }
    private var hasInteractions: Bool {
        model.session.notices.notices.contains { $0.isVisible && $0.notice.type == "interaction" }
    }

    var body: some View {
        AppObservationTracking {
            ZStack(alignment: .bottom) {
                ScrollViewReader { proxy in
                    // ScrollViewReader evaluates its builder after body tracking
                    // has ended, as does ScrollView's content builder.
                    AppObservationTracking {
                        ScrollView {
                            AppObservationTracking {
                                ChatTimelineContent(model: model, onAttachment: onAttachment, onFile: onFile,
                                    latestPullReady: false, isLoadingLatest: historyLoad.isLoadingLatest,
                                    olderPullReady: false, isLoadingOlder: historyLoad.isLoadingOlder,
                                    keepsOlderPrompt: hasRequestedOlder, historyAnchor: nil,
                                    onLoadOlder: loadOlder, onLoadLatest: loadLatest,
                                    onHistoryLayout: { _ in }, onPromptVisibility: { _ in },
                                    onOlderPromptVisibility: { _ in }, onTailVisibility: { _, _ in },
                                    legacyScroll: LegacyTimelineConfiguration(driver: driver, isActive: viewportIsActive,
                                        onSample: { sample in
                                            receivedSample(sample)
                                            updateBottom(using: proxy)
                                        }, revealAnchor: { id in
                                            guard viewportIsActive, driver.canNavigate else { return }
                                            withoutAnimation { proxy.scrollTo(id, anchor: .top) }
                                        }))
                                    .equatable()
                            }
                        }
                        .accessibilityIdentifier("chat.timeline.scroll")
                        .appScrollDismissesKeyboardInteractively()
                        .appHiddenScrollIndicators()
                        .appAlwaysVerticalBounce()
                        .appScrollEdgeEffect(.soft, for: .top)
                        .allowsHitTesting(model.isContentVisible)
                        .accessibilityHidden(!model.isContentVisible)
                        .appOnChange(of: viewportIsActive, initial: true) { _, active in
                            scrolling.setNavigationSuspended(!active)
                            if !active { driver.suspend() }
                        }
                        .appOnChange(of: model.isContentVisible, initial: true) { _, ready in
                            if ready { scrolling.open(interactionPresented: hasInteractions) }
                        }
                        .appOnChange(of: hasInteractions, initial: true) { _, presented in
                            scrolling.setInteractionPresented(presented)
                            if presented { driver.cancelHistoryRestoration() }
                        }
                        .appOnChange(of: model.session.pendingMessages.last?.id) { _, id in
                            if model.isContentVisible, id != nil && !hasInteractions {
                                driver.cancelHistoryRestoration()
                                scrolling.requestBottom()
                            }
                        }
                        .appOnChange(of: model.responseRevision) { _, _ in
                            if model.isContentVisible {
                                driver.cancelHistoryRestoration()
                                scrolling.requestBottom()
                            }
                        }
                        .appOnChange(of: scrolling.pendingBottomRequest, initial: true) { _, _ in
                            updateBottom(using: proxy)
                        }
                        .task(id: UserSettlement(needed: scrolling.needsUserScrollSettlement,
                            tail: scrolling.tail, generation: scrolling.navigationGeneration)) {
                            guard scrolling.needsUserScrollSettlement, viewportIsActive else { return }
                            do { try await ClientTask.sleep(for: .milliseconds(64)) } catch { return }
                            guard !Task.isCancelled, viewportIsActive else { return }
                            scrolling.settleUserScroll()
                        }
                        .task(id: historyLoad.request) {
                            guard let request = historyLoad.request else { return }
                            // A cancellation or an old completion can clear only
                            // the task that owns this particular indicator.
                            defer { historyLoad.finish(request) }
                            if request.direction == .older { await model.session.loadOlder() }
                            else { await model.session.loadLatest() }
                            guard !Task.isCancelled, historyLoad.request == request,
                                  model.session.isValid,
                                  scrolling.navigationGeneration == request.navigationGeneration else { return }
                            if request.direction == .older {
                                driver.receivedHistoryPage(id: request.id,
                                    firstRowID: model.session.timeline.first { $0.value.isVisibleInChat }?.id)
                            } else {
                                scrolling.requestBottom()
                            }
                        }
                    }
                }
                if !keyboardVisible, scrolling.showsBottomButton() {
                    Button {
                        driver.cancelHistoryRestoration()
                        animatesReturn = true
                        scrolling.requestBottom()
                    } label: {
                        Label(String(localized: "到底部"), appSymbol: "arrow.down")
                            .font(.caption.weight(.medium)).foregroundStyle(.primary)
                            .padding(.horizontal, 12).frame(height: returnPillHeight)
                            .background(.regularMaterial, in: Capsule())
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("chat.timeline.bottom")
                    .padding(.bottom, 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .traceChatLayout("timeline-viewport")
            .onAppear { isVisible = true }
            .onDisappear {
                isVisible = false
                scrolling.setNavigationSuspended(true)
                historyLoad.cancel()
                driver.suspend()
                driver.cancelHistoryRestoration()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardVisible = false
            }
        }
    }

    private func loadOlder() {
        guard viewportIsActive, model.session.isValid, model.session.hasOlderItems,
              !model.session.isLoadingHistory, historyLoad.request == nil else { return }
        scrolling.browseHistory()
        hasRequestedOlder = true
        if let request = historyLoad.begin(.older, generation: scrolling.navigationGeneration) {
            driver.beginHistoryRestoration(id: request.id)
        }
    }

    private func loadLatest() {
        guard viewportIsActive, model.session.isValid, model.session.hasNewerItems,
              !model.session.isLoadingHistory, historyLoad.request == nil else { return }
        driver.cancelHistoryRestoration()
        scrolling.browseHistory()
        historyLoad.begin(.latest, generation: scrolling.navigationGeneration)
    }

    private func updateBottom(using proxy: ScrollViewProxy) {
        guard scrolling.pendingBottomRequest != nil, viewportIsActive else { driver.cancelBottom(); return }
        driver.coalesceBottom {
            guard viewportIsActive, driver.canNavigate, let request = scrolling.pendingBottomRequest,
                  let command = scrolling.begin(request) else { return }
            let animate = animatesReturn && !reduceMotion
            animatesReturn = false
            appWithAnimation(animate ? .easeOut(duration: 0.2) : nil, completionDelay: 0.22) {
                // A permanent target follows notices, pending sends and grouped
                // tools. Streaming changes in the same row can follow it too.
                proxy.scrollTo("tail", anchor: .bottom)
            } completion: {
                guard viewportIsActive, driver.canNavigate else { return }
                _ = scrolling.complete(command)
            }
        }
    }

    private func receivedSample(_ sample: AppTimelineScrollDriver.Sample) {
        guard viewportIsActive else { return }
        var next = scrolling
        let previous = next.viewport, viewport = sample.viewport
        // Pure offset samples stay in the driver, outside SwiftUI state. They
        // cannot reconstruct the content tree or restart an unchanged request.
        if previous.contentHeight != viewport.contentHeight || previous.visibleHeight != viewport.visibleHeight
            || previous.topInset != viewport.topInset {
            next.geometryChanged(viewport)
        }
        if next.phase != sample.phase {
            if next.phaseChanged(sample.phase, viewport: viewport) {
                animatesReturn = false
                driver.cancelHistoryRestoration()
            }
        }
        next.tailVisibilityChanged(.near, visible: sample.nearTail)
        next.tailVisibilityChanged(.end, visible: sample.atTail)
        if scrolling != next { scrolling = next }
    }

    private func withoutAnimation(_ action: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, action)
    }

    private struct UserSettlement: Equatable {
        let needed: Bool
        let tail: TimelineTailVisibility
        let generation: Int
    }
}

private struct LegacyTimelineConfiguration {
    let driver: AppTimelineScrollDriver
    let isActive: Bool
    let onSample: (AppTimelineScrollDriver.Sample) -> Void
    let revealAnchor: (String) -> Void
}


/// Keep the latest measurement without publishing View state inside a layout
/// callback. One main-queue delivery handles a burst; removal invalidates it.
///
/// Deliberately NOT generic. With a generic class the optimised build crashed
/// the Swift compiler itself inside `EarlyPerfInliner`
/// (`isCallerAndCalleeLayoutConstraintsCompatible`) while inlining its implicit
/// `deinit`, which forced every shipped IPA to be `-Onone` — the dominant cost
/// behind the slow transcript on device. The stored state is already type-erased
/// to `(() -> Void)?`, so only `submit` needs the type parameter.
@MainActor private final class ChatLayoutUpdate {
    private var pending: (() -> Void)?
    private var scheduled = false
    private var generation = 0

    func submit<Value>(_ value: Value, apply: @escaping (Value) -> Void) {
        pending = { apply(value) }
        guard !scheduled else { return }
        scheduled = true
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }
            let update = self.pending
            self.pending = nil
            self.scheduled = false
            update?()
        }
    }

    func cancel() {
        generation &+= 1
        pending = nil
        scheduled = false
    }
}

private struct ChatTimelineContent: View, Equatable {
    let model: SessionChatModel
    let onAttachment: (V2AttachmentContent) -> Void
    let onFile: (String) -> Void
    let latestPullReady: Bool
    let isLoadingLatest: Bool
    let olderPullReady: Bool
    let isLoadingOlder: Bool
    let keepsOlderPrompt: Bool
    let historyAnchor: TimelineHistoryLayout?
    let onLoadOlder: () -> Void
    let onLoadLatest: () -> Void
    let onHistoryLayout: (TimelineHistoryLayout) -> Void
    let onPromptVisibility: (Bool) -> Void
    let onOlderPromptVisibility: (Bool) -> Void
    let onTailVisibility: (TimelineTailVisibility.Region, Bool) -> Void
    var legacyScroll: LegacyTimelineConfiguration? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.latestPullReady == rhs.latestPullReady && lhs.isLoadingLatest == rhs.isLoadingLatest
            && lhs.olderPullReady == rhs.olderPullReady && lhs.isLoadingOlder == rhs.isLoadingOlder
            && lhs.keepsOlderPrompt == rhs.keepsOlderPrompt && lhs.historyAnchor == rhs.historyAnchor
            && lhs.legacyScroll?.driver === rhs.legacyScroll?.driver
            && lhs.legacyScroll?.isActive == rhs.legacyScroll?.isActive
    }
    var body: some View {
        AppObservationTracking {
            // Snapshot every model read before the stack's deferred builder.
            // ForEach remains a direct stack child, preserving LazyVStack's
            // per-group laziness instead of wrapping the entire list as one row.
            let rows = model.timeline.rows
            let pendingMessages = model.timeline.pendingMessages
            let notices = model.session.notices.notices
            let visibleNotices = notices.filter { $0.isVisible && !$0.blocks(model.session.id) }
            let groups = TimelineGrouping.groups(rows, interactionTargets: Set(notices.filter(\.isVisible).compactMap(\.timelineTargetID)))
            let rowIDs = Set(rows.map(\.id))
            let noticesByTarget = Dictionary(grouping: visibleNotices.filter { $0.timelineTargetID != nil }) { $0.timelineTargetID! }
            let hasOlder = model.session.hasOlderItems, hasNewer = model.session.hasNewerItems
            let historyIsBusy = model.session.isLoadingHistory
            let running = model.isRunning
            let placeholder = model.sendingPlaceholder
            let firstRowID = rows.first?.id
            let actions = TimelineTurnActions.build(groups: groups, suppressLatest: running || hasNewer,
                hasPendingUserMessage: !hasNewer && (!pendingMessages.isEmpty || !model.session.pendingMessages.isEmpty))
            let anchorGroup = historyAnchor.flatMap { anchor in groups.first { $0.rows.contains { $0.id == anchor.anchorRowID } } }
                ?? groups.first { $0.rows.first?.structure.groupKind == .single } ?? groups.last
            let anchorEdge = historyAnchor?.edge ?? (anchorGroup?.rows.first?.structure.groupKind == .single ? .top : .bottom)
            let legacyAnchors = legacyScroll == nil ? [] : groups.map {
                AppTimelineScrollDriver.GroupAnchor(id: $0.id, rowIDs: $0.rows.map(\.id), usesTrailingEdge: $0.kind != .single)
            }
            ChatTimelineStack(isLazy: legacyScroll != nil) {
                if hasOlder || keepsOlderPrompt {
                    Group {
                        if isLoadingOlder {
                            HStack(spacing: 8) {
                                ProgressView().progressViewStyle(.circular).controlSize(.small)
                                Text(String(localized: "正在加载较早的消息…"))
                            }.accessibilityElement(children: .combine)
                                .accessibilityIdentifier("chat.timeline.older.loading")
                        } else if hasOlder {
                            Button(action: onLoadOlder) {
                                Text(olderPullReady ? String(localized: "松开加载较早的消息") : String(localized: "加载较早的消息"))
                                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                            }
                            .disabled(historyIsBusy || isLoadingLatest)
                            .accessibilityIdentifier("chat.timeline.older")
                        } else {
                            Text(String(localized: "已到达会话开头")).foregroundStyle(.secondary)
                        }
                    }
                    .font(.footnote).frame(maxWidth: .infinity, minHeight: 44)
                    .timelineVisibility(threshold: 0.9) { onOlderPromptVisibility($0) }
                }
                ForEach(groups) { group in
                    AppObservationTracking {
                        SessionTimelineGroupView(group: group, chat: model, onAttachment: onAttachment, onFile: onFile,
                            turnAction: actions[group.id], inlineNotices: group.rows.flatMap { noticesByTarget[$0.id] ?? [] })
                            .equatable()
                    }
                    .id(group.id)
                    .background {
                        if let legacyScroll {
                            AppTimelineAnchorProbe(driver: legacyScroll.driver, groupID: group.id)
                        } else if group.id == anchorGroup?.id, let firstRowID {
                            // Only captured value types are read in this deferred
                            // geometry closure, including on the native path.
                            Color.clear.appOnGeometryChange(for: TimelineHistoryLayout.self) { geometry in
                                let frame = geometry.frame(in: .named("chat.timeline.content"))
                                return TimelineHistoryLayout(firstRowID: firstRowID,
                                    anchorRowID: historyAnchor?.anchorRowID ?? group.id, edge: anchorEdge,
                                    y: anchorEdge == .top ? frame.minY : frame.maxY)
                            } action: { onHistoryLayout($0) }
                        }
                    }
                }
                ForEach(visibleNotices.filter { notice in
                    notice.timelineTargetID.map { !rowIDs.contains($0) } ?? true
                }) { item in
                    AppObservationTracking { SessionInteractionCard(item: item, chat: model) }
                }
                ForEach(pendingMessages) { pending in
                    AppObservationTracking {
                        PendingMessageRow(pending: pending, chat: model, onAttachment: onAttachment,
                            onDismiss: { model.session.dismissPendingMessage(id: pending.id) })
                    }
                    .id(pending.id)
                }
                if hasNewer {
                    Button(action: onLoadLatest) {
                        Group {
                            if isLoadingLatest { ProgressView(String(localized: "正在加载更新的记录…")) }
                            else { Text(latestPullReady ? String(localized: "松开加载更新的记录") : String(localized: "继续上拉加载更新的记录")) }
                        }.font(.footnote).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(historyIsBusy || isLoadingLatest || isLoadingOlder)
                    .accessibilityIdentifier("chat.timeline.latest")
                    .timelineVisibility { onPromptVisibility($0) }
                }
                Group {
                    if let text = placeholder {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    } else { Color.clear }
                }.frame(height: 32)
                    .traceChatLayout("tail-spacer")
                    .background {
                        if let legacyScroll { AppTimelineAnchorProbe(driver: legacyScroll.driver, isTail: true) }
                    }
                    .overlay(alignment: .bottom) {
                        Color.clear.frame(height: 96)
                            .timelineVisibility(threshold: 0.01) { onTailVisibility(.near, $0) }
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    .overlay(alignment: .bottom) {
                        Color.clear.frame(height: 2)
                            .timelineVisibility(threshold: 0.5) { onTailVisibility(.end, $0) }
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    .id("tail")
            }
            .modifier(ChatPageContentColumn(horizontalInset: nil))
            .coordinateSpace(name: "chat.timeline.content")
            .background {
                if let legacyScroll {
                    AppTimelineScrollProbe(driver: legacyScroll.driver, isActive: legacyScroll.isActive,
                        firstRowID: firstRowID, groups: legacyAnchors, onSample: legacyScroll.onSample,
                        revealAnchor: legacyScroll.revealAnchor)
                }
            }
            .traceChatLayout("timeline-content", state: "groups=\(groups.count), footers=\(actions.count), running=\(running)")
        }
    }
}

/// Keep the modern layout unchanged. Only iOS 15's adapter opts into deferred
/// group layout; every card, Markdown body and expanded tool still uses its view.
private struct ChatTimelineStack<Content: View>: View {
    let isLazy: Bool
    @ViewBuilder let content: () -> Content
    var body: some View {
        if isLazy { LazyVStack(alignment: .leading, spacing: 20, content: content) }
        else { VStack(alignment: .leading, spacing: 20, content: content) }
    }
}

@available(iOS 18.0, *)
private extension TimelineViewport {
    init(geometry: ScrollGeometry) {
        self.init(contentHeight: geometry.contentSize.height, containerHeight: geometry.containerSize.height,
            topInset: geometry.contentInsets.top, bottomInset: geometry.contentInsets.bottom, offsetY: geometry.contentOffset.y)
    }
}

/// Native offset storage deliberately does not invalidate the SwiftUI view tree.
@MainActor private final class ChatViewportSample {
    var value: TimelineViewport?
}
