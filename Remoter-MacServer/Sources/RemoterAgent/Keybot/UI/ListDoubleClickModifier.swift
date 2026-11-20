import SwiftUI
import AppKit

extension View {
    func onDoubleClick(perform action: @escaping () -> Void) -> some View {
        modifier(DoubleClickModifier(action: action))
    }
}

private struct DoubleClickModifier: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        content.background(DoubleClickHelper(action: action))
    }
}

private struct DoubleClickHelper: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> HookView {
        let v = HookView()
        v.coordinator = context.coordinator
        context.coordinator.action = action
        return v
    }

    func updateNSView(_ nsView: HookView, context: Context) {
        context.coordinator.action = action
    }

    // Custom NSView that hooks up when it enters the window hierarchy
    final class HookView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            guard superview != nil else { return }
            DispatchQueue.main.async { [weak self] in
                self?.wireUp()
            }
        }

        private func wireUp() {
            guard let coordinator else { return }
            // Walk UP the hierarchy; at each level search DOWN for NSTableView
            var node: NSView? = self.superview
            while let v = node {
                if let table = firstTableView(in: v) {
                    table.doubleAction = #selector(Coordinator.doubleClicked(_:))
                    table.target = coordinator
                    objc_setAssociatedObject(table, &associatedKey,
                                            coordinator, .OBJC_ASSOCIATION_RETAIN)
                    return
                }
                node = v.superview
            }
        }

        private func firstTableView(in view: NSView) -> NSTableView? {
            if let t = view as? NSTableView { return t }
            for sub in view.subviews {
                if let found = firstTableView(in: sub) { return found }
            }
            return nil
        }
    }

    final class Coordinator: NSObject {
        var action: (() -> Void)?
        @objc func doubleClicked(_ sender: Any?) { action?() }
    }
}

private var associatedKey: UInt8 = 0
