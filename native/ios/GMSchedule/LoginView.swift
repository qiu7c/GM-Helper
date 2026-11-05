import SwiftUI
import WebKit

struct LoginView: View {
    @EnvironmentObject var model: AppStore
    @Environment(\.dismiss) private var dismiss
    var preview = false
    @State private var username = ""
    @State private var password = ""
    @State private var save = false
    @State private var auto = false
    @State private var reveal = false
    @State private var browser = false
    @State private var qr = false
    @State private var message = ""
    @State private var working = false
    @State private var initialized = false
    var body: some View {
        NavigationView {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 13) {
                            BrandMark(size: 40)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("登录广贸课表").font(.system(size: 22, weight: .semibold)).foregroundColor(Brand.ink)
                                Text("学校统一认证账号").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer(minLength: 0)
                        }.padding(.bottom, 6)
                        VStack(alignment: .leading, spacing: 17) {
                            VStack(spacing: 10) {
                                HStack(spacing: 13) {
                                    Image(systemName: "person.crop.rectangle").foregroundColor(Brand.blue).frame(width: 24)
                                    TextField("学号", text: $username).textContentType(.username).keyboardType(.asciiCapable).autocapitalization(.none).disableAutocorrection(true)
                                }.padding(14).background(Brand.field).cornerRadius(16)
                                HStack(spacing: 13) {
                                    Image(systemName: "lock").foregroundColor(Brand.blue).frame(width: 24)
                                    Group {
                                        if reveal { TextField("密码", text: $password) }
                                        else { SecureField("密码", text: $password) }
                                    }.textContentType(.password).autocapitalization(.none).disableAutocorrection(true)
                                    Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye").foregroundColor(.secondary) }.accessibilityLabel(reveal ? "隐藏密码" : "显示密码")
                                }.padding(14).background(Brand.field).cornerRadius(16)
                            }
                            HStack {
                                preference("保存密码", value: $save)
                                Spacer()
                                preference("自动登录", value: $auto).disabled(!save).opacity(save ? 1 : 0.45)
                            }.onChange(of: save) { if !$0 { auto = false } }
                            Button { login() } label: {
                                HStack(spacing: 10) {
                                    if working { ProgressView().tint(.white) }
                                    Text(working ? "正在连接校园…" : "登录并查看课表").fontWeight(.semibold)
                                    if !working { Image(systemName: "arrow.right") }
                                }.frame(maxWidth: .infinity).padding(.vertical, 14).foregroundColor(.white)
                                    .background(Brand.blue).cornerRadius(14)
                            }.disabled(working || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || preview)
                            if !message.isEmpty {
                                Label(message, systemImage: "exclamationmark.circle").font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                            }
                        }.padding(18).background(Brand.surface).cornerRadius(22)
                        VStack(spacing: 14) {
                            Button { qr = true; browser = true } label: {
                                Label("企业微信登录", systemImage: "qrcode.viewfinder").font(.subheadline.weight(.medium)).foregroundColor(Brand.blue)
                                    .padding(.vertical, 13).frame(maxWidth: .infinity).background(Brand.surface.opacity(0.75)).cornerRadius(15)
                            }.disabled(working || preview)
                            Label("登录信息仅用于学校认证", systemImage: "lock.shield").font(.caption2).foregroundColor(.secondary)
                        }
                    }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 24).frame(maxWidth: 520).frame(maxWidth: .infinity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).padding(8).background(Brand.surface).clipShape(Circle()) }.disabled(working) } }
            .sheet(isPresented: $browser) {
                CaptchaView(username: username, password: password, save: save, auto: auto, qr: qr).environmentObject(model)
            }
            .onAppear {
                if !initialized {
                    initialized = true
                    if !preview {
                        username = model.preferences.account; password = model.savedPassword
                        save = model.preferences.savePassword; auto = model.preferences.autoLogin
                        if model.pendingLoginURL != nil { browser = true }
                    }
                }
            }
        }.navigationViewStyle(.stack).interactiveDismissDisabled(working).tint(Brand.blue)
    }
    private func preference(_ title: String, value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            HStack(spacing: 7) { Image(systemName: value.wrappedValue ? "checkmark.square.fill" : "square").font(.system(size: 18)); Text(title).font(.caption) }.foregroundColor(value.wrappedValue ? Brand.blue : .secondary)
        }.buttonStyle(.plain)
    }
    private func login() {
        working = true; message = ""
        Task {
            do { try await model.login(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password, save: save, auto: auto); dismiss() }
            catch SchoolError.captcha { qr = false; browser = true }
            catch is URLError { message = "暂时无法连接学校，请检查网络后重试。" }
            catch { message = error.localizedDescription }
            working = false
        }
    }
}

struct CaptchaView: View {
    @EnvironmentObject var model: AppStore
    @Environment(\.dismiss) private var dismiss
    let username: String
    let password: String
    let save: Bool
    let auto: Bool
    let qr: Bool
    @State private var message = "请在学校页面手动完成验证。"
    @State private var verifying = false
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Label(message, systemImage: qr ? "qrcode" : "checkmark.shield").font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(16).background(Brand.field)
                SchoolWebView(initialURL: qr ? URL(string: School.login + "&display=qrLogin")! : model.pendingLoginURL ?? URL(string: School.login)!, username: username, password: password, qr: qr, cookies: qr ? [] : model.pendingLoginCookies, onMessage: { message = $0 }, onCookies: { cookies in
                    guard !verifying else { return }; verifying = true
                    Task {
                        do { try await model.completeLogin(cookies: cookies, username: username, password: password, save: save, auto: auto); dismiss() }
                        catch { message = error.localizedDescription }
                        verifying = false
                    }
                })
            }.navigationTitle(qr ? "企业微信登录" : "完成安全验证").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() }.disabled(verifying) } }
        }.navigationViewStyle(.stack).interactiveDismissDisabled(verifying)
    }
}

struct SchoolWebView: UIViewRepresentable {
    let initialURL: URL
    let username: String
    let password: String
    let qr: Bool
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
        group.notify(queue: .main) { web.load(URLRequest(url: self.initialURL)) }
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) { context.coordinator.parent = self }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: SchoolWebView
        var qr = false
        var enteredPortal = false
        init(_ parent: SchoolWebView) { self.parent = parent; self.qr = parent.qr }
        func fill(_ web: WKWebView) {
            guard web.url?.host == "sfrz.gdgm.cn", !parent.qr else { return }
            let values = [parent.username, parent.password]
            guard let data = try? JSONSerialization.data(withJSONObject: values), let json = String(data: data, encoding: .utf8) else { return }
            // Fill only the visible fields. The user completes the school's captcha and submits.
            let script = """
            (() => { const values = \(json);
            const visible = selector => Array.from(document.querySelectorAll(selector)).find(e => e.type !== 'hidden' && e.offsetParent !== null);
            const u=visible('#mobileUsername') || visible('#username,input[name=username]');
            const p=visible('#mobilePassword') || visible('input[type=password]');
            if(!u || !p) return;
            for(const [e,value] of [[u,values[0]],[p,values[1]]]) { e.focus();e.value=value;
              for(const type of ['input','change','keyup']) e.dispatchEvent(new Event(type,{bubbles:true}));
              e.blur(); }
            })();
            """
            web.evaluateJavaScript(script)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            if url.host == "sfrz.gdgm.cn" {
                fill(webView)
                parent.onMessage(parent.qr ? "请使用企业微信完成登录。" : "请完成学校验证码，再点击学校页面的登录按钮。")
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
