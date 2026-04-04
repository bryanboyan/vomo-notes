import SwiftUI
import WebKit

struct VoiceGraphWebView: UIViewRepresentable {
    let graphManager: VoiceGraphManager
    let onNodeTap: (String, String) -> Void  // (nodeId, nodeLabel)
    let onDeselect: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let handler = context.coordinator
        config.userContentController.add(handler, name: "voiceGraphHandler")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator

        if let htmlURL = Bundle.main.url(forResource: "voice_graph", withExtension: "html") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }

        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onNodeTap = onNodeTap
        context.coordinator.onDeselect = onDeselect

        // Send updated graph data
        if let json = graphManager.graphData.toJSON() {
            context.coordinator.pendingGraphJSON = json
        }

        // Send updated opacities
        let opacities = graphManager.nodeOpacities()
        if let data = try? JSONSerialization.data(withJSONObject: opacities),
           let json = String(data: data, encoding: .utf8) {
            context.coordinator.pendingOpacitiesJSON = json
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onNodeTap: onNodeTap, onDeselect: onDeselect)
    }

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onNodeTap: (String, String) -> Void
        var onDeselect: () -> Void
        weak var webView: WKWebView?
        var pageLoaded = false

        var pendingGraphJSON: String? {
            didSet { sendGraphIfReady() }
        }
        var pendingOpacitiesJSON: String? {
            didSet { sendOpacitiesIfReady() }
        }

        init(onNodeTap: @escaping (String, String) -> Void, onDeselect: @escaping () -> Void) {
            self.onNodeTap = onNodeTap
            self.onDeselect = onDeselect
            super.init()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "voiceGraphHandler",
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }

            switch action {
            case "nodeSelected":
                if let nodeId = body["nodeId"] as? String,
                   let label = body["nodeLabel"] as? String {
                    DispatchQueue.main.async {
                        self.onNodeTap(nodeId, label)
                    }
                }
            case "deselected":
                DispatchQueue.main.async {
                    self.onDeselect()
                }
            case "ready":
                pageLoaded = true
                sendGraphIfReady()
                sendOpacitiesIfReady()
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if !pageLoaded {
                pageLoaded = true
                sendGraphIfReady()
                sendOpacitiesIfReady()
            }
        }

        private func sendGraphIfReady() {
            guard pageLoaded, let json = pendingGraphJSON else { return }
            webView?.evaluateJavaScript("updateGraph(\(json))") { _, error in
                if let error { print("🔗 [VOICE GRAPH] JS error: \(error)") }
            }
        }

        private func sendOpacitiesIfReady() {
            guard pageLoaded, let json = pendingOpacitiesJSON else { return }
            webView?.evaluateJavaScript("updateOpacities(\(json))") { _, error in
                if let error { print("🔗 [VOICE GRAPH] Opacities JS error: \(error)") }
            }
        }
    }
}
