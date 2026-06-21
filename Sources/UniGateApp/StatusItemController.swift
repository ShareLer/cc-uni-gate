import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var popoverController: NSHostingController<AnyView>?
    private var noticePopover: NSPopover?
    private var noticeDismissTask: Task<Void, Never>?
    private var noticeToken = UUID()
    private var lastNoticeMessage: String?
    private var lastNoticeDate: Date?
    private var cancellables: Set<AnyCancellable> = []

    var isPopoverShown: Bool {
        popover?.isShown == true
    }

    func install(state: UniGateAppState) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = "CC Uni Gate"
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let controller = NSHostingController(rootView: AnyView(UniGatePopoverRootView(state: state)))
        if #available(macOS 13.0, *) {
            controller.sizingOptions = [.preferredContentSize]
        } else {
            controller.preferredContentSize = NSSize(width: 420, height: 620)
        }
        popover.contentViewController = controller
        popover.delegate = self
        self.popover = popover
        self.popoverController = controller

        Publishers.CombineLatest(state.$proxyStatus, state.$proxyPort)
            .sink { [weak self] status, port in
                self?.updateStatusItem(status: status, port: port)
            }
            .store(in: &cancellables)
        updateStatusItem(status: state.proxyStatus, port: state.proxyPort)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover else {
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            closeNotice()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func showNotice(message: String, accentColor: NSColor) {
        guard !isPopoverShown, let button = statusItem?.button else {
            return
        }

        let now = Date()
        if lastNoticeMessage == message,
           let lastNoticeDate,
           now.timeIntervalSince(lastNoticeDate) < 3 {
            return
        }
        lastNoticeMessage = message
        lastNoticeDate = now

        closeNotice()

        let token = UUID()
        noticeToken = token
        let noticePopover = NSPopover()
        noticePopover.behavior = .transient
        noticePopover.animates = true
        let noticeSize = NSSize(width: 320, height: 98)
        noticePopover.contentSize = noticeSize
        let controller = NSHostingController(
            rootView: StatusNoticeView(message: message, accentColor: accentColor)
        )
        controller.preferredContentSize = noticeSize
        noticePopover.contentViewController = controller
        self.noticePopover = noticePopover
        noticePopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        noticeDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard noticeToken == token else {
                return
            }
            closeNotice()
        }
    }

    private func closeNotice() {
        noticeDismissTask?.cancel()
        noticeDismissTask = nil
        noticePopover?.performClose(nil)
        noticePopover = nil
    }

    private func updateStatusItem(status: ProxyStatus, port: UInt16) {
        guard let button = statusItem?.button else {
            return
        }
        let title = NSMutableAttributedString(
            string: "UniGate ",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor
            ]
        )
        title.append(NSAttributedString(
            string: "●",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: status.accentColor,
                .baselineOffset: 1
            ]
        ))
        button.attributedTitle = title
        button.toolTip = "CC Uni Gate · \(status.title(port: port))"
    }
}

private struct StatusNoticeView: View {
    let message: String
    let accentColor: NSColor

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(nsColor: accentColor))
                .frame(width: 18)

            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 320, height: 98)
        .background(.regularMaterial)
    }
}
