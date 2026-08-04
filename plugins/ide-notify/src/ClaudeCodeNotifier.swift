import Cocoa
import UserNotifications


func logLine(_ s: String) {
    guard ProcessInfo.processInfo.environment["CLAUDE_NOTIFY_DEBUG"] == "1" else { return }
    let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/ide-notify/notifier.log")
    let line = "\(Date()) \(s)\n"
    if let d = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: path) { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
        else { try? d.write(to: URL(fileURLWithPath: path)) }
    }
}

final class Delegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var postArgs: [String]?

    func applicationDidFinishLaunching(_ note: Notification) {
        logLine("launch args=\(postArgs ?? [])")
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        guard let args = postArgs else {
            // 인자 없이 실행됨 = 알림 클릭으로 재실행된 경우. 델리게이트 콜백을 기다린다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { NSApp.terminate(nil) }
            return
        }

        center.requestAuthorization(options: [.alert, .sound]) { granted, err in
            guard granted, err == nil else {
                logLine("auth denied granted=\(granted) err=\(String(describing: err))")
                DispatchQueue.main.async { exit(1) }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = args[0]
            content.subtitle = args[1]
            content.body = args[2]
            content.sound = .default
            if args.count > 3 { content.userInfo = ["target": args[3]] }

            let req = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
            center.add(req) { addErr in
                logLine(addErr == nil ? "posted OK" : "add failed: \(addErr!)")
                if addErr != nil { DispatchQueue.main.async { exit(1) } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
            }
        }
    }

    // 알림을 클릭했을 때: userInfo 에 담아둔 번들 ID 의 앱을 활성화한다.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let bid = response.notification.request.content.userInfo["target"] as? String,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
        }
        logLine("clicked")
        done()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let delegate = Delegate()
if args.count >= 3 { delegate.postArgs = args }
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
