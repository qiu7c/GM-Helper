import SwiftUI
import WebKit

struct LoginView: View {
    @EnvironmentObject var model: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var save = false
    @State private var auto = false
    @State private var qr = false
    @State private var revision = 0
    @State private var message = "密码由学校网页加密提交；验证码需在下方手动完成。"
    @State private var verifying = false
    @State private var initialized = false
    var body: some View {
        NavigationView {
            VStack(spacing: 8) {
                TextField("学号", text: $username).textContentType(.username).keyboardType(.asciiCapable).autocapitalization(.none).textFieldStyle(.roundedBorder)
                SecureField("密码（可选自动填入学校网页）", text: $password).textContentType(.password).textFieldStyle(.roundedBorder)
                HStack {
                    Toggle("保存密码", isOn: $save)
                    Toggle("自动登录", isOn: $auto).disabled(!save)
                }.font(.caption)
                HStack {
                    Button("填入网页登录") { revision += 1 }
                    Spacer()
                    Button(qr ? "密码登录" : "企业微信扫码") { qr.toggle(); revision += 1 }
                }
                Text(message).font(.caption).foregroundColor(.secondary)
                SchoolWebView(username: username, password: password, qr: qr, revision: revision, automatic: auto && model.automaticLogin && !model.freshLogin, cookies: model.freshLogin ? [] : model.client.cookies.cookies ?? [], onMessage: { message = $0 }, onCookies: { cookies in
                    guard !verifying else { return }; verifying = true
                    Task {
                        do { try await model.completeLogin(cookies: cookies, username: username, password: password, save: save, auto: auto); dismiss() }
                        catch { message = error.localizedDescription }
                        verifying = false
                    }
                })
            }
            .padding(.horizontal)
            .navigationTitle("学校统一认证").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .onAppear {
                if !initialized {
                    initialized = true
                    username = model.preferences.account; password = model.savedPassword
                    save = model.preferences.savePassword; auto = model.preferences.autoLogin
                }
            }
        }.navigationViewStyle(.stack)
    }
}

struct SchoolWebView: UIViewRepresentable {
    let username: String
    let password: String
    let qr: Bool
    let revision: Int
    let automatic: Bool
    let cookies: [HTTPCookie]
    let onMessage: (String) -> Void
    let onCookies: ([HTTPCookie]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The browser Cookie jar is memory-only. Durable credentials live only in Keychain.
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        let group = DispatchGroup()
        for cookie in cookies where SchoolClient.schoolCookie(cookie) {
            group.enter()
            config.websiteDataStore.httpCookieStore.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) { web.load(URLRequest(url: URL(string: School.login)!)) }
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.revision != revision {
            context.coordinator.revision = revision
            if context.coordinator.qr != qr {
                context.coordinator.qr = qr
                context.coordinator.enteredPortal = false
                web.load(URLRequest(url: URL(string: School.login + (qr ? "&display=qrLogin" : ""))!))
            } else { context.coordinator.fill(web, submit: false) }
        }
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: SchoolWebView
        var revision = 0
        var qr = false
        var enteredPortal = false
        var submitted = false
        init(_ parent: SchoolWebView) { self.parent = parent }
        func fill(_ web: WKWebView, submit: Bool) {
            guard web.url?.host == "sfrz.gdgm.cn", !parent.qr else { return }
            let values = [parent.username, parent.password]
            guard let data = try? JSONSerialization.data(withJSONObject: values), let json = String(data: data, encoding: .utf8) else { return }
            // Values are JSON encoded, never interpolated as executable JavaScript.
            let script = """
            (() => { const values = \(json); const u=document.querySelector('#username,input[name=username]'); const p=document.querySelector('#password,input[name=password]');
            if(!u || !p) return; u.value=values[0];p.value=values[1];for(const e of [u,p]){e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));}
            \(submit ? "const button=document.querySelector('#login_submit,#login_submit_pwd,button[type=submit],input[type=submit]');if(button) button.click();" : "")
            })();
            """
            web.evaluateJavaScript(script)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            if url.host == "sfrz.gdgm.cn" {
                fill(webView, submit: parent.automatic && !submitted && !parent.password.isEmpty)
                submitted = true
                parent.onMessage("请在学校页面确认登录；遇到验证码请手动完成。")
            }
            if url.host == "eportal.gdgm.cn", (url.path.contains("/new/index") || url.path == "/index.html"), !enteredPortal {
                enteredPortal = true
                parent.onMessage("正在通过门户进入教务系统…")
                webView.load(URLRequest(url: School.entry))
            }
            if url.host == "jw.gdgm.cn", ["/jsxsd/framework/xsMain.jsp", "/jsxsd/framework/xsMain_new.jsp"].contains(url.path) {
                // sso.jsp's JavaScript and second CAS authorization run inside this WebView.
                parent.onMessage("正在验证教务业务会话…")
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] values in
                    self?.parent.onCookies(values.filter(SchoolClient.schoolCookie))
                }
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if ["weixin", "wxwork"].contains(url.scheme ?? "") {
                UIApplication.shared.open(url); decisionHandler(.cancel); return
            }
            let host = url.host ?? ""
            let trusted = host == "gdgm.cn" || host.hasSuffix(".gdgm.cn") || host == "open.weixin.qq.com" || host == "open.work.weixin.qq.com"
            if url.scheme == "https" && trusted { decisionHandler(.allow) }
            else if url.scheme == "about" { decisionHandler(.allow) }
            else { decisionHandler(.cancel); parent.onMessage("该外部链接请使用系统浏览器打开。") }
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { parent.onMessage("学校登录页面暂时无法打开，请检查网络后重新打开登录。") }
        }
    }
}
