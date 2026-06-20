import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var popoverController: NSHostingController<AnyView>?
    private var cancellables: Set<AnyCancellable> = []

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
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
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
