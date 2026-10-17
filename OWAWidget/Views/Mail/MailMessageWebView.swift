import AppKit
import SwiftUI
import WebKit

/// Blocks every network load in the reader, compiled once. The document's CSP blocks them too;
/// this does not depend on the document.
@MainActor
enum MailContentBlocker {
    private static var ruleList: WKContentRuleList?
    private static var isCompiling = false

    /// One rule per scheme: WebKit's `url-filter` has no alternation (`a|b`), and a list that
    /// fails to compile silently leaves the reader without this layer.
    static let rules = """
    [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^file:"},"action":{"type":"block"}}]
    """

    static func prepare() {
        guard ruleList == nil, !isCompiling else { return }
        isCompiling = true
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "owawidget-mail-block-all", encodedContentRuleList: rules) { list, error in
            if let error {
                DiagnosticLog.event("Mail content blocker failed to compile: \(error.localizedDescription)")
            }
            Task { @MainActor in
                ruleList = list
                isCompiling = false
            }
        }
    }

    static func apply(to controller: WKUserContentController) {
        if let ruleList { controller.add(ruleList) }
    }
}

/// A link the user clicked in a message: where it goes and what it said.
struct MailLinkActivation: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let text: String?
}

/// One message body in a WebKit view that runs no page script, loads nothing from the network
/// and navigates nowhere: clicks on links are handed to `onLink`.
///
/// The view has no scrolling of its own — it is sized to its content (`height`) and the wheel
/// goes to the enclosing scroll view, so a thread scrolls as one page.
struct MailMessageWebView: NSViewRepresentable {
    let html: String
    @Binding var height: CGFloat
    let onLink: (MailLinkActivation) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MailReaderWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        MailContentBlocker.apply(to: configuration.userContentController)
        let view = MailReaderWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = false
        view.allowsBackForwardNavigationGestures = false
        view.onWidthChange = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.measure(view)
        }
        context.coordinator.load(html, into: view)
        return view
    }

    func updateNSView(_ view: MailReaderWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedHTML != html {
            context.coordinator.load(html, into: view)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: MailMessageWebView
        private(set) var loadedHTML: String?
        private var linkTexts: [String: String] = [:]

        init(_ parent: MailMessageWebView) { self.parent = parent }

        func load(_ html: String, into view: WKWebView) {
            loadedHTML = html
            linkTexts = [:]
            view.loadHTMLString(html, baseURL: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            // The document itself (loaded from a string) is the only navigation allowed.
            if navigationAction.navigationType == .other, navigationAction.request.url?.absoluteString == "about:blank" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                parent.onLink(MailLinkActivation(url: url, text: linkTexts[url.absoluteString]))
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // `target="_blank"` links (the server adds them) arrive here instead.
            if let url = navigationAction.request.url {
                parent.onLink(MailLinkActivation(url: url, text: linkTexts[url.absoluteString]))
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(webView)
            // Fonts and data: images settle a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak webView] in
                guard let webView else { return }
                self?.measure(webView)
            }
            // App-side script in its own world: page script stays off. Collects each link's text
            // so a click can be checked against where the link really goes.
            let collect = "Array.from(document.links).slice(0, 500).map(a => [a.href, (a.innerText || '').slice(0, 200)])"
            webView.evaluateJavaScript(collect, in: nil, in: .defaultClient) { [weak self] result in
                guard case .success(let value) = result, let pairs = value as? [[String]] else { return }
                Task { @MainActor in
                    for pair in pairs where pair.count == 2 { self?.linkTexts[pair[0]] = pair[1] }
                }
            }
        }

        /// Fits a wide message (fixed-width newsletter tables) to the view by scaling it down, as
        /// Mail does, then reports the height of the content itself. The viewport is not measured:
        /// it is as tall as the frame, so the frame could only ever grow.
        static let fitScript = """
        (function () {
          var r = document.getElementById('owaw-root');
          if (!r) { return document.documentElement.scrollHeight; }
          r.style.transform = ''; r.style.width = '';
          var w = document.documentElement.clientWidth;
          var s = r.scrollWidth;
          var z = 1;
          if (s > w + 1) {
            z = Math.max(0.45, w / s);
            r.style.width = (w / z) + 'px';
            r.style.transformOrigin = '0 0';
            r.style.transform = 'scale(' + z + ')';
          }
          return Math.ceil(r.offsetHeight * z);
        })()
        """

        func measure(_ webView: WKWebView) {
            webView.evaluateJavaScript(Self.fitScript, in: nil, in: .defaultClient) { [weak self] result in
                guard case .success(let value) = result, let number = value as? NSNumber else { return }
                Task { @MainActor in
                    let height = CGFloat(truncating: number)
                    if abs((self?.parent.height ?? 0) - height) > 1 { self?.parent.height = max(20, height) }
                }
            }
        }
    }
}

/// Passes the scroll wheel on to the enclosing scroll view and reports width changes, which
/// reflow the text and change the height.
final class MailReaderWebView: WKWebView {
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - lastWidth) > 0.5 {
            lastWidth = newSize.width
            onWidthChange?()
        }
    }
}
