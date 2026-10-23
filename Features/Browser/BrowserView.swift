import SwiftUI
import WebKit

/// A standalone web browser. It deliberately has no dependency on the IPTV
/// server list or account state.
struct BrowserView: View {
    @StateObject private var browser = BrowserModel()
    @FocusState private var addressFocused: Bool
    @State private var addressText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search or enter website", text: $addressText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit(openAddress)
                    .accessibilityLabel("Search or enter website")
                if !addressText.isEmpty {
                    Button {
                        addressText = ""
                        addressFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityLabel("Clear address")
                }
                if browser.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background {
                let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                if #available(iOS 26.0, *) {
                    shape.fill(.clear).glassEffect(.regular, in: shape)
                } else {
                    shape.fill(.regularMaterial)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.primary.opacity(0.07), lineWidth: 1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)

            ZStack {
                BrowserWebView(browser: browser)
                    .ignoresSafeArea(edges: .bottom)
                if !browser.hasLoadedPage {
                    ContentUnavailableView {
                        Label("Browse the web", systemImage: "safari")
                    } description: {
                        Text("Search the web or enter a website address. No IPTV account needed.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.appBackground)
                }
            }

            HStack(spacing: 0) {
                browserButton("chevron.left", label: "Back", enabled: browser.canGoBack) {
                    browser.goBack()
                }
                Spacer(minLength: 0)
                browserButton("chevron.right", label: "Forward", enabled: browser.canGoForward) {
                    browser.goForward()
                }
                Spacer(minLength: 0)
                browserButton(browser.isLoading ? "xmark" : "arrow.clockwise",
                              label: browser.isLoading ? "Stop loading" : "Reload",
                              enabled: browser.hasLoadedPage) {
                    browser.isLoading ? browser.stopLoading() : browser.reload()
                }
                Spacer(minLength: 0)
                if let url = browser.currentURL {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Share page")
                } else {
                    browserButton("square.and.arrow.up", label: "Share", enabled: false) {}
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 7)
            .padding(.bottom, 4)
            .background {
                if #available(iOS 26.0, *) {
                    Capsule().fill(.clear).glassEffect(.regular)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 2)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 2)
                }
            }
        }
        .background(Color.appBackground)
        .onChange(of: browser.currentURL) { _, url in
            guard !addressFocused else { return }
            addressText = url?.absoluteString ?? ""
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func browserButton(_ symbol: String, label: String, enabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func openAddress() {
        browser.load(addressText)
        addressFocused = false
    }
}

@MainActor
private final class BrowserModel: ObservableObject {
    @Published var currentURL: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var hasLoadedPage = false

    weak var webView: WKWebView?

    func load(_ input: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let target: URL?
        if value.contains(" ") || (!value.contains(".") && !value.contains("://")) {
            var components = URLComponents(string: "https://www.google.com/search")
            components?.queryItems = [URLQueryItem(name: "q", value: value)]
            target = components?.url
        } else if let parsed = URL(string: value), parsed.scheme != nil {
            target = parsed
        } else {
            target = URL(string: "https://" + value)
        }
        guard let target else { return }
        webView?.load(URLRequest(url: target))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stopLoading() { webView?.stopLoading(); isLoading = false }

    func refreshState() {
        currentURL = webView?.url
        canGoBack = webView?.canGoBack ?? false
        canGoForward = webView?.canGoForward ?? false
        hasLoadedPage = webView?.url != nil
    }
}

private struct BrowserWebView: UIViewRepresentable {
    @ObservedObject var browser: BrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser) }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = .clear
        browser.webView = view
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if browser.webView !== uiView { browser.webView = uiView }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let browser: BrowserModel
        init(browser: BrowserModel) { self.browser = browser }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let url = navigationAction.request.url else { return nil }
            webView.load(URLRequest(url: url))
            return nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            browser.isLoading = true
            browser.refreshState()
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            browser.refreshState()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            browser.isLoading = false
            browser.refreshState()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            browser.isLoading = false
            browser.refreshState()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            browser.isLoading = false
            browser.refreshState()
        }
    }
}
