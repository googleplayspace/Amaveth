import Flutter
import UIKit
import Photos
import UserNotifications
import Darwin
import UniformTypeIdentifiers

public class ShellBridgePlugin: NSObject, FlutterPlugin {
  private var channel: FlutterMethodChannel!
  private var timer: Timer?
  private var count = 0
  private func deviceModel() -> String {
    var info = utsname()
    uname(&info)
    let capacity = MemoryLayout.size(ofValue: info.machine)
    return withUnsafePointer(to: &info.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
    }
  }
  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = ShellBridgePlugin()
    instance.channel = FlutterMethodChannel(name: "yueh/shell", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: instance.channel)
    ShellStartup.shared.attach(registrar.messenger(), events:instance.channel)
    NotificationCenter.default.addObserver(instance, selector: #selector(instance.memory), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
  }
  @objc private func memory() { channel.invokeMethod("memory", arguments: nil) }
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if ShellStartup.shared.handle(call,result:result) { return }
    switch call.method {
    case "log":
      let message = (call.arguments as? [String:Any])?["message"] as? String ?? ""
      NSLog("SSGShell %@", message)
      result(nil)
    case "clearBadge":
      if #available(iOS 16, *) {
        UNUserNotificationCenter.current().setBadgeCount(0) { error in
          DispatchQueue.main.async { if let error = error { result(FlutterError(code:"badge",message:error.localizedDescription,details:nil)) } else { result(nil) } }
        }
      } else { UIApplication.shared.applicationIconBadgeNumber = 0; result(nil) }
    case "clearThread":
      let args = call.arguments as? [String:Any] ?? [:]
      let chat = args["chatId"] as? String ?? ""
      let thread = args["threadId"] as? String ?? chat
      UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
        let identifiers = notifications.filter { notification in
          let content = notification.request.content
          let custom = content.userInfo["custom"] as? [String:Any]
          let data = custom?["a"] as? [String:Any] ?? content.userInfo as? [String:Any] ?? [:]
          let id = data["chat_id"] as? String ?? data["chatId"] as? String ?? ""
          return (!thread.isEmpty && content.threadIdentifier == thread) || (!chat.isEmpty && id == chat)
        }.map { $0.request.identifier }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        DispatchQueue.main.async { result(nil) }
      }
    case "metadata":
      result(["platform":"ios", "bundleId":Bundle.main.bundleIdentifier ?? "",
        "shellVersion":Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
        "deviceModel":deviceModel(), "osVersion":UIDevice.current.systemVersion,
        "webviewVersion":ShellStartup.shared.webkitVersion])
    case "saveMedia":
      guard let args = call.arguments as? [String:Any], let path = args["path"] as? String, let mime = args["mime"] as? String else {
        result(FlutterError(code:"arguments",message:"Media file is missing",details:nil)); return
      }
      let save: (PHAuthorizationStatus) -> Void = { status in
        guard status == .authorized || status == .limited else {
          DispatchQueue.main.async { result(FlutterError(code:"permission",message:"Allow saving to Photos in device settings",details:nil)) }; return
        }
        PHPhotoLibrary.shared().performChanges({
          let request = PHAssetCreationRequest.forAsset()
          let options = PHAssetResourceCreationOptions()
          options.originalFilename = args["name"] as? String
          options.uniformTypeIdentifier = UTType(mimeType: mime)?.identifier
          request.addResource(with: mime.hasPrefix("video/") ? .video : .photo, fileURL: URL(fileURLWithPath:path), options:options)
        }) { success, error in DispatchQueue.main.async {
          if success { result(true) } else { result(FlutterError(code:"save",message:error?.localizedDescription ?? "Could not save the file",details:nil)) }
        }}
      }
      if #available(iOS 14, *) { PHPhotoLibrary.requestAuthorization(for:.addOnly, handler:save) }
      else { PHPhotoLibrary.requestAuthorization(save) }
    case "active":
      timer?.invalidate(); timer = nil; count = 0
      if (call.arguments as? [String:Any])?["value"] as? Bool == true {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
          guard let self = self else { return }
          self.count += 1
          self.channel.invokeMethod("tick", arguments:["heartbeat":self.count % 4 == 0])
        }
      }
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }
  deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self) }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    ShellStartup.shared.start()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ShellBridge") {ShellBridgePlugin.register(with: registrar)}
  }
}

// §2.3 / §9.6: one process-owned WKWebView, loaded before the first Flutter frame.
import WebKit
import PhotosUI
import AVFoundation

private final class ShellMessageProxy: NSObject, WKScriptMessageHandler {
  weak var owner: ShellStartup?
  init(_ owner: ShellStartup) { self.owner = owner }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    owner?.received(message)
  }
}
private final class ShellNativeController: UIViewController {
  override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }
  override func viewDidLoad() { super.viewDidLoad(); view.backgroundColor = .white }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    ShellStartup.shared.visible(UIApplication.shared.applicationState == .active)
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    ShellStartup.shared.visible(false)
  }
}

final class ShellStartup: NSObject, WKNavigationDelegate, WKUIDelegate, URLSessionTaskDelegate {
  static let shared = ShellStartup()
  private let defaults = UserDefaults.standard
  private var startup: FlutterMethodChannel?
  private var events: FlutterMethodChannel?
  private var checking = false
  private var face = "pending"
  private var entry: String?
  private var reason = "initial"
  private var awaitingA = false
  private var revision = 0
  private var generation = 0
  private var live = false
  private var queued: [(String, Any)] = []
  private var script = ""
  private var suffix = ""
  private var web: WKWebView?
  private var window: UIWindow?
  private weak var flutterWindow: UIWindow?
  private var host: ShellNativeController?
  private var cover: UIView?
  private var overlay: UIView?
  private var fullUserAgent = ""
  var webkitVersion: String {
    Bundle(for:WKWebView.self).object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "WebKit / iOS \(UIDevice.current.systemVersion)"
  }
  private var webReady = false
  private var entryReloadPending = false
  private var startedAt = ProcessInfo.processInfo.systemUptime
  private var coverTask: DispatchWorkItem?
  private var openPanel: (([URL]?) -> Void)?
  private var pickerFiles: [URL] = []
  private lazy var session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 4
    c.timeoutIntervalForResource = 6
    return URLSession(configuration: c,delegate:self,delegateQueue:nil)
  }()
  private var configURL: URL? {
    let raw = Bundle.main.object(forInfoDictionaryKey: "SSGDartDefines") as? String ?? ""
    for part in raw.split(separator: ",") {
      if let data = Data(base64Encoded: String(part)), let value = String(data: data, encoding: .utf8), value.hasPrefix("SSG_CONFIG_URL=") {
        return URL(string: String(value.dropFirst("SSG_CONFIG_URL=".count)))
      }
    }
    return URL(string: "https://u4k2.top/api/config")
  }
  private func log(_ stage: String) {
    NSLog("SSGStartup %@ elapsedMs=%.1f", stage, (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
  }
  func start() {
    startedAt = ProcessInfo.processInfo.systemUptime
    log("didFinishLaunching")
    entry = defaults.string(forKey:"shell.h5url") ?? defaults.string(forKey:"flutter.remoteConfig.url")
    if let raw = entry, Self.valid(raw) {
      face = "b"; configure(raw); createAndLoad(raw)
    } else { entry = nil }
    NotificationCenter.default.addObserver(self, selector:#selector(foreground), name:UIApplication.didBecomeActiveNotification, object:nil)
    NotificationCenter.default.addObserver(self, selector:#selector(background), name:UIApplication.didEnterBackgroundNotification, object:nil)
    refresh()
  }
  @objc private func foreground() { if face == "b" { visible(true) }; refresh() }
  @objc private func background() {
    visible(false)
    if #available(iOS 15.0, *) { web?.pauseAllMediaPlayback(completionHandler:nil) }
  }
  func visible(_ value: Bool) { emit("imEvent", ["type":"visible", "value":value]) }
  func attach(_ messenger: FlutterBinaryMessenger, events: FlutterMethodChannel) {
    self.events = events
    startup = FlutterMethodChannel(name:"yueh/startup", binaryMessenger:messenger)
    startup?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      if call.method == "snapshot" { result(self.snapshot()) }
      else if call.method == "refresh" { self.refresh(); result(nil) }
      else if call.method == "ackA" {
        if self.face == "a", (call.arguments as? [String:Any])?["revision"] as? Int == self.revision {
          self.awaitingA = false; self.window?.isHidden = true; self.flutterWindow?.makeKeyAndVisible()
        }
        result(nil)
      }
      else { result(FlutterMethodNotImplemented) }
    }
  }
  private func snapshot() -> [String:Any] {
    ["face":face, "url":entry as Any? ?? NSNull(), "reason":reason, "revision":revision]
  }
  private func publish() {
    revision += 1
    startup?.invokeMethod("decision", arguments:snapshot())
    if face == "a" {
      awaitingA = host != nil
      if awaitingA { webReady = false; addCover() }
      else { window?.isHidden = true }
    } else { showWindow() }
  }
  func bind(_ scene: UIWindowScene) {
    guard face != "a" else { return }
    flutterWindow = scene.windows.first { $0.rootViewController is FlutterViewController }
    let w = UIWindow(windowScene:scene)
    let controller = ShellNativeController()
    w.rootViewController = controller
    w.windowLevel = UIWindow.Level.normal + 1
    w.overrideUserInterfaceStyle = .light
    window = w; host = controller
    controller.loadViewIfNeeded()
    installWeb()
    addCover()
    w.makeKeyAndVisible()
  }
  private func showWindow() {
    if window == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { bind(scene) }
    window?.makeKeyAndVisible()
    installWeb()
  }
  private func addCover() {
    guard !webReady else { return }
    guard let root = host?.view else { return }
    cover?.removeFromSuperview()
    let launch = UIStoryboard(name:"LaunchScreen", bundle:nil).instantiateInitialViewController()!.view!
    launch.frame = root.bounds; launch.autoresizingMask = [.flexibleWidth,.flexibleHeight]
    root.addSubview(launch); cover = launch
    armCover()
  }
  private func armCover() {
    coverTask?.cancel()
    let task = DispatchWorkItem { [weak self] in
      guard let self = self, self.face != "pending" else { return }
      self.cover?.removeFromSuperview(); self.cover = nil
    }
    coverTask = task
    DispatchQueue.main.asyncAfter(deadline:.now()+30, execute:task)
  }
  private func installWeb() {
    guard let root = host?.view, let web = web, web.superview !== root else { return }
    web.removeFromSuperview(); web.translatesAutoresizingMaskIntoConstraints = false
    root.insertSubview(web, at:0)
    NSLayoutConstraint.activate([
      web.topAnchor.constraint(equalTo:root.safeAreaLayoutGuide.topAnchor),
      web.bottomAnchor.constraint(equalTo:root.safeAreaLayoutGuide.bottomAnchor),
      web.leadingAnchor.constraint(equalTo:root.safeAreaLayoutGuide.leadingAnchor),
      web.trailingAnchor.constraint(equalTo:root.safeAreaLayoutGuide.trailingAnchor)])
  }
  private static func valid(_ raw: String) -> Bool {
    guard raw == raw.trimmingCharacters(in:.whitespacesAndNewlines), let u = URL(string:raw) else { return false }
    return u.scheme == "https" && !(u.host ?? "").isEmpty && u.user == nil
  }
  private func configure(_ raw: String) {
    let ver = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? ""
    suffix = "SSGShell/\(ver) iOS"
    var system = utsname(); uname(&system)
    let size = MemoryLayout.size(ofValue:system.machine)
    let model = withUnsafePointer(to:&system.machine) { $0.withMemoryRebound(to:CChar.self, capacity:size) { String(cString:$0) } }
    let metadata = ["platform":"ios", "bundleId":Bundle.main.bundleIdentifier ?? "", "shellVersion":ver,
      "webviewVersion":webkitVersion, "deviceModel":model, "osVersion":UIDevice.current.systemVersion]
    let data = try! JSONSerialization.data(withJSONObject:metadata, options:[.sortedKeys])
    let origin = originOf(raw)
    let literal = String(data:try! JSONSerialization.data(withJSONObject:[origin]), encoding:.utf8)!.dropFirst().dropLast()
    script = "if(window===window.top&&location.origin===\(literal)){window.__SSG_SHELL__=\(String(data:data,encoding:.utf8)!);};"
  }
  private func originOf(_ raw: String) -> String {
    guard let u = URLComponents(string:raw), let scheme = u.scheme, let host = u.host?.lowercased() else { return "" }
    return "\(scheme)://\(host)" + (u.port.map { $0 == 443 ? "" : ":\($0)" } ?? "")
  }
  private func trusted(_ url: URL?) -> Bool {
    guard let raw = url?.absoluteString, let entry = entry else { return false }
    return originOf(raw) == originOf(entry)
  }
  private func createAndLoad(_ raw: String) {
    generation += 1; webReady = false
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    config.applicationNameForUserAgent = suffix
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    config.userContentController.addUserScript(WKUserScript(source:script, injectionTime:.atDocumentStart, forMainFrameOnly:true))
    let proxy = ShellMessageProxy(self)
    for name in ["eventWebReady","eventRegister","eventLogin","eventLogout","eventMessageSent","eventWebAlive","eventChatOpen","eventChatClose","eventChatRead","eventUnreadCount","shellConsole"] {
      config.userContentController.add(proxy, name:name)
    }
    config.userContentController.addUserScript(WKUserScript(source:"for(const k of ['log','warn','error']){const f=console[k];console[k]=(...a)=>{f.apply(console,a);try{webkit.messageHandlers.shellConsole.postMessage({level:k,message:a.map(String).join(' ')})}catch(e){}}}", injectionTime:.atDocumentStart, forMainFrameOnly:true))
    let page = WKWebView(frame:.zero, configuration:config)
    page.navigationDelegate = self; page.uiDelegate = self
    page.isOpaque = false; page.backgroundColor = .white
    page.scrollView.backgroundColor = .white
    page.scrollView.contentInsetAdjustmentBehavior = .never
    page.scrollView.bounces = false
    web = page; installWeb()
    log("webview.loadUrl cachedOrEntry")
    page.load(URLRequest(url:URL(string:raw)!))
  }
  private func parse(_ data: Data) -> String? {
    guard data.count <= 262144, let json = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else { return nil }
    let value = json["h5url"] ?? (json["data"] as? [String:Any])?["h5url"]
    guard let raw = value as? String, Self.valid(raw) else { return nil }
    return raw
  }
  func refresh(_ attempt: Int = 0) {
    if attempt == 0 { if checking { return }; checking = true }
    guard let endpoint = configURL, endpoint.scheme == "https" else { finishUnavailable(); return }
    var request = URLRequest(url:endpoint); request.setValue("application/json", forHTTPHeaderField:"Accept")
    session.downloadTask(with:request) { [weak self] file, response, error in
      var data: Data?
      if let file = file, let handle = try? FileHandle(forReadingFrom:file) {
        data = try? handle.read(upToCount:262145)
        try? handle.close()
      }
      DispatchQueue.main.async {
        guard let self = self else { return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        self.log("mock.response status=\(status)")
        if status == 404 {
          self.checking = false; self.face = "a"; self.entry = nil; self.reason = "http404"
          self.defaults.removeObject(forKey:"shell.h5url"); self.defaults.removeObject(forKey:"flutter.remoteConfig.url")
          self.forget(); self.publish()
        } else if error == nil, status == 200, let raw = data.flatMap(self.parse) {
          self.checking = false
          let changed = self.face != "b" || self.entry != raw
          self.face = "b"; self.reason = "http200"
          self.entry = raw; self.defaults.set(raw, forKey:"shell.h5url")
          if changed {
            self.configure(raw); self.live = false; self.queued.removeAll()
            self.entryReloadPending = true
            if let page = self.web {
              page.configuration.userContentController.removeAllUserScripts()
              page.configuration.userContentController.addUserScript(WKUserScript(source:self.script,injectionTime:.atDocumentStart,forMainFrameOnly:true))
              page.load(URLRequest(url:URL(string:raw)!)); self.webReady = false; self.addCover()
            } else { self.createAndLoad(raw) }
            self.showWindow(); self.addCover(); self.publish()
          }
        } else if attempt < 2 { self.refresh(attempt+1) }
        else { self.finishUnavailable() }
      }
    }.resume()
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil) // A redirect/login page is not the mock interface's 404.
  }
  private func replayWhenReady(_ attempt: Int = 0) {
    guard !live else { return }
    guard webReady, let page = web, attempt < 30 else { replay(); return }
    page.evaluateJavaScript("!!window.__ssgShell") { [weak self] value,error in
      guard let self = self else { return }
      if value as? Bool == true { self.replay() }
      else { DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { self.replayWhenReady(attempt+1) } }
    }
  }
  private func replay() {
    live = true
    let pending = queued; queued.removeAll()
    for (name,args) in pending { events?.invokeMethod(name,arguments:args) }
    visible(UIApplication.shared.applicationState == .active)
  }
  private func finishUnavailable() {
    checking = false
    if entry == nil && face == "pending" { face = "a"; reason = "unavailableWithoutCache"; publish() }
  }
  private func forget() {
    visible(false)
    live = false; queued.removeAll(); webReady = false
    web?.stopLoading(); web?.removeFromSuperview(); web = nil
    coverTask?.cancel()
  }
  private func emit(_ name: String, _ arguments: Any) {
    if live { events?.invokeMethod(name, arguments:arguments) }
    else if queued.count < 500 { queued.append((name, arguments)) }
  }
  func received(_ message: WKScriptMessage) {
    guard message.webView === web, message.frameInfo.isMainFrame, trusted(message.frameInfo.request.url) else { return }
    if message.name == "shellConsole", let args = message.body as? [String:Any] {
      emit("imEvent", ["type":"console","level":args["level"] ?? "log","message":args["message"] ?? ""]); return
    }
    guard let payload = message.body as? [String:Any], let data = try? JSONSerialization.data(withJSONObject:payload), let text = String(data:data,encoding:.utf8) else { return }
    if message.name == "eventWebReady" {
      webReady = true; coverTask?.cancel(); cover?.removeFromSuperview(); cover = nil
    }
    emit("webEvent", ["viewId":generation,"name":message.name,"json":text])
  }
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) -> Bool {
    let args = call.arguments as? [String:Any] ?? [:]
    switch call.method {
    case "imPrepare":
      guard face == "b", args["url"] as? String == entry else { result(FlutterError(code:"stale_config",message:"The startup decision changed",details:nil)); return true }
      // Startup already loaded the authoritative native URL. Refresh metadata for later navigation.
      result(["documentStart":true,"ua":fullUserAgent.isEmpty ? suffix : fullUserAgent]); return true
    case "imOpen":
      guard face == "b" else { result(nil); return true }
      showWindow(); result(generation)
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.replayWhenReady()
      }
      return true
    case "imEvaluate":
      guard let page = web else { result(nil); return true }
      page.evaluateJavaScript(args["source"] as? String ?? "") { value,error in
        guard error == nil, let value = value, let data = try? JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed]), let raw = String(data:data,encoding:.utf8) else { result(nil); return }
        result(raw)
      }; return true
    case "imUrl": result(web?.url?.absoluteString); return true
    case "imReload": web?.reload(); result(nil); return true
    case "imLoad": if let raw = args["url"] as? String, let u = URL(string:raw), trusted(u) { web?.load(URLRequest(url:u)) }; result(nil); return true
    case "imRebuild":
      guard face == "b" else { result(nil); return true }
      let raw = entryReloadPending ? entry : (trusted(web?.url) ? web!.url!.absoluteString : entry)
      entryReloadPending = false
      web?.stopLoading(); web?.removeFromSuperview(); web = nil; live = false; queued.removeAll()
      if let raw = raw { createAndLoad(raw); addCover() }
      result(generation)
      DispatchQueue.main.async { [weak self] in self?.live = true; let pending = self?.queued ?? []; self?.queued.removeAll(); for (name,args) in pending { self?.events?.invokeMethod(name, arguments:args) } }
      return true
    case "imForget": forget(); result(nil); return true
    case "imState":
      if let error = args["error"] as? String { showError(error) }
      else { overlay?.removeFromSuperview(); overlay = nil }
      result(nil); return true
    case "imToast": result(nil); return true
    case "imDiagnostics":
      guard let host = host else { result(nil); return true }
      let alert = UIAlertController(title:"Diagnostics",message:args["text"] as? String,preferredStyle:.alert)
      alert.addAction(UIAlertAction(title:"Close",style:.cancel))
      alert.addAction(UIAlertAction(title:"Export",style:.default) { _ in host.present(UIActivityViewController(activityItems:[args["text"] as? String ?? ""],applicationActivities:nil),animated:true) })
      host.present(alert,animated:true); result(nil); return true
    default: return false
    }
  }
  private func showError(_ message: String) {
    guard let root = host?.view else { return }
    coverTask?.cancel(); cover?.removeFromSuperview(); cover = nil; overlay?.removeFromSuperview()
    let background = UIView(frame:root.bounds); background.backgroundColor = .white; background.autoresizingMask = [.flexibleWidth,.flexibleHeight]
    let label = UILabel(); label.text = message; label.numberOfLines = 0; label.textAlignment = .center
    let button = UIButton(type:.system); button.setTitle("Retry",for:.normal); button.addTarget(self,action:#selector(retry),for:.touchUpInside)
    let stack = UIStackView(arrangedSubviews:[label,button]); stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(stack); root.addSubview(background); overlay = background
    NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo:background.centerXAnchor),stack.centerYAnchor.constraint(equalTo:background.centerYAnchor),stack.widthAnchor.constraint(lessThanOrEqualTo:background.widthAnchor,multiplier:0.85)])
  }
  @objc private func retry() { overlay?.removeFromSuperview(); overlay = nil; emit("imEvent",["type":"retry"]) }
  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    guard webView === web else { return }
    entryReloadPending = false
    webReady = false; emit("imEvent",["type":"loadStart"])
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard webView === web else { return }
    emit("imEvent",["type":"loadStop"])
    webView.evaluateJavaScript("navigator.userAgent") { [weak self] value,error in
      guard let self = self, webView === self.web, let ua = value as? String else { return }
      self.fullUserAgent = ua
      self.emit("imEvent",["type":"userAgent","value":ua])
    }
  }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    guard webView === web else { return }
    if (error as NSError).code == NSURLErrorCancelled { return }
    showError("Could not load the page. Check your connection and try again."); emit("imEvent",["type":"loadError"])
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    self.webView(webView,didFailProvisionalNavigation:navigation,withError:error)
  }
  func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    guard webView === web else { decisionHandler(.cancel); return }
    if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
      showError("The server returned \(response.statusCode). Please try again.")
      emit("imEvent",["type":"httpError","status":response.statusCode]); decisionHandler(.cancel)
    } else { decisionHandler(.allow) }
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { guard webView === web else { return }; emit("imEvent",["type":"gone"]) }
  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard webView === web else { decisionHandler(.cancel); return }
    guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
    if navigationAction.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
    if trusted(url) { decisionHandler(.allow) }
    else { decisionHandler(.cancel); if ["https","http","mailto","tel"].contains(url.scheme ?? "") { UIApplication.shared.open(url) } }
  }
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    guard webView === web else { return nil }
    if let u = navigationAction.request.url { if trusted(u) { webView.load(URLRequest(url:u)) } else { UIApplication.shared.open(u) } }; return nil
  }
  @available(iOS 15.0, *)
  func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
    guard webView === web, type == .microphone, trusted(frame.request.url) else { decisionHandler(.deny); return }
    AVAudioSession.sharedInstance().requestRecordPermission { granted in DispatchQueue.main.async {
      decisionHandler(granted ? .grant : .deny)
      if !granted, let host = self.host {
        let alert = UIAlertController(title:"Microphone access",message:"Allow microphone access in Settings to send voice messages.",preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"Cancel",style:.cancel))
        alert.addAction(UIAlertAction(title:"Settings",style:.default) { _ in UIApplication.shared.open(URL(string:UIApplication.openSettingsURLString)!) })
        host.present(alert,animated:true)
      }
    }}
  }
}

extension ShellStartup: PHPickerViewControllerDelegate {
  @available(iOS 18.4, *)
  func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
    guard webView === web, trusted(frame.request.url), let host = host, openPanel == nil else { completionHandler(nil); return }
    openPanel = completionHandler
    var configuration = PHPickerConfiguration()
    configuration.selectionLimit = parameters.allowsMultipleSelection ? 0 : 1
    configuration.filter = .any(of:[.images,.videos])
    configuration.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration:configuration)
    picker.delegate = self
    host.present(picker,animated:true)
  }
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated:true)
    guard let completion = openPanel else { return }
    openPanel = nil
    if results.isEmpty { completion(nil); return }
    let group = DispatchGroup()
    let lock = NSLock()
    var selected: [Int:URL] = [:]
    var failed = false
    for (index,item) in results.enumerated() {
      let provider = item.itemProvider
      let type = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ? UTType.movie.identifier : UTType.image.identifier
      group.enter()
      provider.loadFileRepresentation(forTypeIdentifier:type) { url,error in
        defer { group.leave() }
        do {
          guard let source = url else { throw NSError(domain:"picker",code:1) }
          let size = (try source.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
          guard size <= 512 * 1024 * 1024 else { throw NSError(domain:"picker",code:2) }
          let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
          try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
          var name = provider.suggestedName ?? source.lastPathComponent
          name = URL(fileURLWithPath:name).lastPathComponent
          if URL(fileURLWithPath:name).pathExtension.isEmpty { name += "." + source.pathExtension }
          var target = directory.appendingPathComponent(name)
          if ["heic","heif"].contains(source.pathExtension.lowercased()) {
            guard let image = UIImage(contentsOfFile:source.path), let jpeg = image.jpegData(compressionQuality:0.92) else { throw NSError(domain:"picker",code:3) }
            target = target.deletingPathExtension().appendingPathExtension("jpg")
            try jpeg.write(to:target,options:.atomic)
          } else { try FileManager.default.copyItem(at:source,to:target) }
          lock.lock(); selected[index] = target; lock.unlock()
        } catch { lock.lock(); failed = true; lock.unlock() }
      }
    }
    group.notify(queue:.main) {
      let files = selected.keys.sorted().compactMap { selected[$0] }
      completion(files.isEmpty ? nil : files)
      if failed, let host = self.host {
        let alert = UIAlertController(title:"Attachment unavailable",message:"Some files could not be attached. Choose a readable image or video no larger than 512 MB.",preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"OK",style:.default)); host.present(alert,animated:true)
      }
    }
  }
}
