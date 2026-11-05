import LinkPresentation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Only the scroll backend changes. Each hosted card is the original SwiftUI
/// card, retained by its notice/toast ID with the caller's complete environment.
struct AppChatLegacyPager<Card: View>: UIViewControllerRepresentable {
    let ids: [String]
    let axis: Axis
    let pageHeight: CGFloat
    let spacing: CGFloat
    var edgeInset: CGFloat = 0
    var reduceMotion = false
    var scalesPages = false
    var clipsToBounds = true
    var limitsToOnePage = true
    @Binding var selectedID: String?
    @ViewBuilder let card: (Int) -> Card

    func makeUIViewController(context: Context) -> AppChatPagerController<Card> {
        let controller = AppChatPagerController<Card>()
        controller.update(self, environment: context.environment, animated: false)
        return controller
    }
    func updateUIViewController(_ controller: AppChatPagerController<Card>, context: Context) {
        controller.update(self, environment: context.environment,
            animated: context.transaction.animation != nil && !context.transaction.disablesAnimations)
    }
    static func dismantleUIViewController(_ controller: AppChatPagerController<Card>, coordinator: ()) {
        controller.finish()
    }
}

private struct AppChatHostedCard<Card: View>: View {
    let card: Card
    let environment: EnvironmentValues
    var body: some View {
        card.environment(\.self, environment).ignoresSafeArea(.container, edges: .all)
    }
}

final class AppChatPagerController<Card: View>: UIViewController, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var configuration: AppChatLegacyPager<Card>?
    private var hosts: [String: UIHostingController<AppChatHostedCard<Card>>] = [:]
    private var heights: [String: NSLayoutConstraint] = [:]
    private var crossConstraint: NSLayoutConstraint?
    private var installedAxis: Axis?
    private var dragStartIndex = 0
    private var animating = false
    private var positionedID: String?

    /// Explicit and empty: same generic-`@MainActor` implicit-destructor crash as
    /// StableViewModel under `-O` on a deployment target below the
    /// isolated-deinit floor. See StableViewModel for the full note.
    deinit {}

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scroll.backgroundColor = .clear
        scroll.delegate = self
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.isDirectionalLockEnabled = true
        scroll.decelerationRate = .fast
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.alignment = .fill
        stack.distribution = .fill
        stack.isLayoutMarginsRelativeArrangement = true
        stack.preservesSuperviewLayoutMargins = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor)
        ])
    }

    func update(_ next: AppChatLegacyPager<Card>, environment: EnvironmentValues, animated: Bool) {
        loadViewIfNeeded()
        configuration = next
        scroll.clipsToBounds = next.clipsToBounds
        scroll.bounces = next.ids.count > 1
        scroll.alwaysBounceVertical = next.axis == .vertical && next.ids.count > 1
        scroll.alwaysBounceHorizontal = next.axis == .horizontal && next.ids.count > 1
        stack.spacing = next.spacing
        stack.layoutMargins = next.axis == .vertical
            ? UIEdgeInsets(top: next.edgeInset, left: 0, bottom: next.edgeInset, right: 0)
            : UIEdgeInsets(top: 0, left: next.edgeInset, bottom: 0, right: next.edgeInset)
        if installedAxis != next.axis {
            crossConstraint?.isActive = false
            stack.axis = next.axis == .vertical ? .vertical : .horizontal
            crossConstraint = next.axis == .vertical
                ? stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
                : stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
            crossConstraint?.isActive = true
            installedAxis = next.axis
        }
        let retained = Set(next.ids)
        for id in Array(hosts.keys) where !retained.contains(id) {
            guard let host = hosts.removeValue(forKey: id) else { continue }
            host.willMove(toParent: nil)
            stack.removeArrangedSubview(host.view)
            host.view.removeFromSuperview()
            host.removeFromParent()
            heights.removeValue(forKey: id)?.isActive = false
        }
        for (index, id) in next.ids.enumerated() {
            let root = AppChatHostedCard(card: next.card(index), environment: environment)
            let host: UIHostingController<AppChatHostedCard<Card>>
            if let existing = hosts[id] {
                host = existing
                host.rootView = root
            } else {
                host = UIHostingController(rootView: root)
                host.view.backgroundColor = .clear
                host.view.translatesAutoresizingMaskIntoConstraints = false
                addChild(host)
                stack.addArrangedSubview(host.view)
                host.didMove(toParent: self)
                hosts[id] = host
                let dimension = next.axis == .vertical
                    ? host.view.heightAnchor.constraint(equalToConstant: next.pageHeight)
                    : host.view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
                dimension.isActive = true
                heights[id] = dimension
            }
            if next.axis == .vertical { heights[id]?.constant = next.pageHeight }
            if stack.arrangedSubviews.firstIndex(of: host.view) != index {
                stack.removeArrangedSubview(host.view)
                stack.insertArrangedSubview(host.view, at: index)
            }
        }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        positionSelection(animated: animated && !next.reduceMotion)
        updateCardPresentation()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        positionSelection(animated: false)
        updateCardPresentation()
    }

    private var stride: CGFloat {
        guard let configuration else { return 0 }
        return (configuration.axis == .vertical ? configuration.pageHeight : scroll.bounds.width) + configuration.spacing
    }
    private var offset: CGFloat { configuration?.axis == .vertical ? scroll.contentOffset.y : scroll.contentOffset.x }
    private func nearestIndex(to offset: CGFloat) -> Int {
        guard let configuration, !configuration.ids.isEmpty, stride > 0 else { return 0 }
        return min(configuration.ids.count - 1, max(0, Int((offset / stride).rounded())))
    }
    private func positionSelection(animated: Bool) {
        guard let configuration, !scroll.isDragging, !scroll.isDecelerating, !animating,
              scroll.bounds.width > 0, let selected = configuration.selectedID,
              let index = configuration.ids.firstIndex(of: selected), stride > 0 else { return }
        let destination = CGFloat(index) * stride
        guard positionedID != selected || abs(offset - destination) > 0.5 else { return }
        positionedID = selected
        animating = animated && view.window != nil
        let point = configuration.axis == .vertical ? CGPoint(x: 0, y: destination) : CGPoint(x: destination, y: 0)
        scroll.setContentOffset(point, animated: animating)
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        animating = false
        dragStartIndex = nearestIndex(to: offset)
    }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard let configuration, !configuration.ids.isEmpty, stride > 0 else { return }
        let projected = configuration.axis == .vertical ? targetContentOffset.pointee.y : targetContentOffset.pointee.x
        var index = nearestIndex(to: projected)
        if configuration.limitsToOnePage { index = min(dragStartIndex + 1, max(dragStartIndex - 1, index)) }
        index = min(configuration.ids.count - 1, max(0, index))
        let destination = CGFloat(index) * stride
        targetContentOffset.pointee = configuration.axis == .vertical
            ? CGPoint(x: 0, y: destination) : CGPoint(x: destination, y: 0)
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateCardPresentation() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settleSelection() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settleSelection() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        animating = false
        settleSelection()
    }
    private func settleSelection() {
        guard let configuration, !configuration.ids.isEmpty else { return }
        let index = nearestIndex(to: offset)
        let next = configuration.ids[index]
        positionedID = next
        if configuration.selectedID != next { configuration.selectedID = next }
    }
    private func updateCardPresentation() {
        guard let configuration else { return }
        let center = scroll.contentOffset.y + scroll.bounds.height / 2
        for host in hosts.values {
            guard configuration.scalesPages, configuration.axis == .vertical, stride > 0 else {
                host.view.transform = .identity
                host.view.alpha = 1
                continue
            }
            let phase = min(1, abs(host.view.center.y - center) / stride)
            let scale: CGFloat = configuration.reduceMotion ? 1 : 1 - phase * 0.04
            host.view.transform = CGAffineTransform(scaleX: scale, y: scale)
            host.view.alpha = 1 - phase * 0.3
        }
    }
    func finish() {
        scroll.delegate = nil
        scroll.setContentOffset(scroll.contentOffset, animated: false)
    }
}

extension View {
    @ViewBuilder func appChatSingleNoticeAlignment() -> some View {
        if #available(iOS 26.0, *) {
            scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
        } else if #available(iOS 17.0, *) {
            scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        } else {
            self
        }
    }
}

/// Matches the original Layout's welcome anchor; status does not recenter it.
struct AppChatWelcomeLayout<Welcome: View, Status: View>: View {
    let viewportHeight: CGFloat
    @ViewBuilder let welcome: () -> Welcome
    @ViewBuilder let status: () -> Status
    @State private var welcomeHeight: CGFloat = 0
    @State private var statusHeight: CGFloat = 0
    private var top: CGFloat { max(0, (viewportHeight - welcomeHeight) / 2) }
    private var height: CGFloat { max(viewportHeight, top + welcomeHeight + (statusHeight > 0 ? 28 + statusHeight : 0)) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            welcome().fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: AppChatWelcomeHeight.self, value: geometry.size.height)
                })
                .offset(y: top)
            status().fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: AppChatStatusHeight.self, value: geometry.size.height)
                })
                .offset(y: top + welcomeHeight + 28)
        }
        .frame(height: height, alignment: .topLeading)
        .onPreferenceChange(AppChatWelcomeHeight.self) { next in
            DispatchQueue.main.async { if welcomeHeight != next { welcomeHeight = next } }
        }
        .onPreferenceChange(AppChatStatusHeight.self) { next in
            DispatchQueue.main.async { if statusHeight != next { statusHeight = next } }
        }
    }
}
private struct AppChatWelcomeHeight: PreferenceKey {
    nonisolated static var defaultValue: CGFloat { 0 }
    nonisolated static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct AppChatStatusHeight: PreferenceKey {
    nonisolated static var defaultValue: CGFloat { 0 }
    nonisolated static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct AppChatNavigationChoice: Identifiable {
    let id: String
    let title: String
    var enabled = true
}
struct AppChatNavigationPicker: View {
    let title: String
    let choices: [AppChatNavigationChoice]
    @Binding var selection: String

    var body: some View {
        if #available(iOS 16.0, *), AppCompatibility.useNativeUI {
            Picker(title, selection: $selection) {
                ForEach(choices) { choice in Text(choice.title).tag(choice.id).disabled(!choice.enabled) }
            }.pickerStyle(.navigationLink)
        } else {
            NavigationLink {
                AppChatNavigationChoices(title: title, choices: choices, selection: $selection)
            } label: {
                AppLabeledContent(title, value: choices.first { $0.id == selection }?.title ?? "")
            }
        }
    }
}
private struct AppChatNavigationChoices: View {
    let title: String
    let choices: [AppChatNavigationChoice]
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List(choices) { choice in
            Button { selection = choice.id; dismiss() } label: {
                HStack {
                    Text(choice.title).foregroundStyle(.primary)
                    Spacer()
                    if selection == choice.id { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!choice.enabled)
                .accessibilityAddTraits(selection == choice.id ? .isSelected : [])
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

/// Unbounded multiline path entry. TextEditor with a fixed five-line frame would
/// change the form's row height; the older text view reports its actual height.
struct AppChatGrowingPathField: View {
    let title: String
    @Binding var text: String
    @State private var measuredHeight: CGFloat = 22
    var body: some View {
        if #available(iOS 16.0, *), AppCompatibility.useNativeUI {
            TextField(title, text: $text, axis: .vertical)
        } else {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(title).font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color(uiColor: .placeholderText)).allowsHitTesting(false)
                }
                AppChatPathEditor(text: $text, height: $measuredHeight).frame(height: measuredHeight)
            }
        }
    }
}
private struct AppChatPathEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> AppChatPathTextView {
        let view = AppChatPathTextView()
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.delegate = context.coordinator
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.onHeight = { [weak coordinator = context.coordinator] next in
            DispatchQueue.main.async { if coordinator?.parent.height != next { coordinator?.parent.height = next } }
        }
        return view
    }
    func updateUIView(_ view: AppChatPathTextView, context: Context) {
        context.coordinator.parent = self
        let category = context.environment.sizeCategory.uiCategory
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: 17, weight: .regular),
            compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
        view.textColor = .label
        view.isUserInteractionEnabled = context.environment.isEnabled
        view.isEditable = context.environment.isEnabled
        if view.markedTextRange == nil, view.text != text { view.text = text }
        view.setNeedsLayout()
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AppChatPathEditor
        init(parent: AppChatPathEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            textView.setNeedsLayout()
        }
    }
}
private final class AppChatPathTextView: UITextView {
    var onHeight: ((CGFloat) -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        let fitted = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        onHeight?(ceil(max(font?.lineHeight ?? 22, fitted.height)))
    }
}
private extension ContentSizeCategory {
    var uiCategory: UIContentSizeCategory {
        switch self {
        case .extraSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .extraLarge: .extraLarge
        case .extraExtraLarge: .extraExtraLarge
        case .extraExtraExtraLarge: .extraExtraExtraLarge
        case .accessibilityMedium: .accessibilityMedium
        case .accessibilityLarge: .accessibilityLarge
        case .accessibilityExtraLarge: .accessibilityExtraLarge
        case .accessibilityExtraExtraLarge: .accessibilityExtraExtraLarge
        case .accessibilityExtraExtraExtraLarge: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}

struct AppChatTextShareButton<Label: View>: View {
    let title: String
    let text: () -> String
    @ViewBuilder let label: () -> Label
    @State private var payload: AppChatTextSharePayload?
    var body: some View {
        Button { payload = .init(title: title, text: text()) } label: { label() }
            .sheet(item: $payload) { payload in AppChatTextShareSheet(payload: payload) }
    }
}
private struct AppChatTextSharePayload: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}
private struct AppChatTextShareSheet: UIViewControllerRepresentable {
    let payload: AppChatTextSharePayload
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [AppChatTextShareSource(payload: payload)], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
private final class AppChatTextShareSource: NSObject, UIActivityItemSource {
    let payload: AppChatTextSharePayload
    init(payload: AppChatTextSharePayload) { self.payload = payload }
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { payload.text }
    func activityViewController(_ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { payload.text }
    func activityViewController(_ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String { UTType.plainText.identifier }
    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = payload.title
        return metadata
    }
}
