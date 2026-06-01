import SwiftUI

struct PreservingScrollView<Content: View>: NSViewRepresentable {
    @Binding var offset: CGPoint
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = VerticalOnlyNSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .allowed

        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = host
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observedClipView = scrollView.contentView
        context.coordinator.scrollView = scrollView

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            host.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            host.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let host = scrollView.documentView as? NSHostingView<Content> else {
            return
        }

        host.rootView = content
        context.coordinator.offset = $offset

        DispatchQueue.main.async {
            let verticalOffset = CGPoint(x: 0, y: offset.y)
            guard scrollView.contentView.bounds.origin != verticalOffset else {
                return
            }
            scrollView.contentView.scroll(to: verticalOffset)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(offset: $offset)
    }

    final class Coordinator: NSObject {
        var offset: Binding<CGPoint>
        weak var scrollView: NSScrollView?
        weak var observedClipView: NSClipView?

        init(offset: Binding<CGPoint>) {
            self.offset = offset
        }

        deinit {
            if let observedClipView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: observedClipView
                )
            }
        }

        @objc func boundsDidChange(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView else {
                return
            }
            if clipView.bounds.origin.x != 0 {
                clipView.scroll(to: CGPoint(x: 0, y: clipView.bounds.origin.y))
                scrollView?.reflectScrolledClipView(clipView)
            }
            offset.wrappedValue = CGPoint(x: 0, y: clipView.bounds.origin.y)
        }
    }
}

private final class VerticalOnlyNSScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        clampHorizontalOffset()
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        clampHorizontalOffset()
    }

    private func clampHorizontalOffset() {
        guard contentView.bounds.origin.x != 0 else {
            return
        }
        contentView.scroll(to: CGPoint(x: 0, y: contentView.bounds.origin.y))
        super.reflectScrolledClipView(contentView)
    }
}
