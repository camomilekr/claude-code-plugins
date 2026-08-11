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

// 5번째 인자(소리 지정)를 UNNotificationSound 로 변환한다.
//   ""/"default" → 시스템 기본음, "none"/"silent"/"off" → 무음,
//   그 외 → 사운드 이름. 확장자가 없으면 사운드 검색 경로(~/Library/Sounds,
//   /Library/Sounds, /System/Library/Sounds)에서 파일을 찾아 확장자를 붙인다.
//   UNNotificationSound(named:)가 같은 경로를 탐색하지만 파일명(확장자 포함)을
//   요구하기 때문이다. 못 찾으면 시스템 사운드 관례인 .aiff 로 가정한다.
func resolveSound(_ spec: String) -> UNNotificationSound? {
    switch spec {
    case "", "default":
        return .default
    case "none", "silent", "off":
        return nil
    default:
        break
    }
    var name = spec
    if !name.contains(".") {
        let dirs = [NSHomeDirectory() + "/Library/Sounds", "/Library/Sounds", "/System/Library/Sounds"]
        let exts = ["aiff", "aif", "wav", "caf"]
        search: for dir in dirs {
            for ext in exts where FileManager.default.fileExists(atPath: "\(dir)/\(name).\(ext)") {
                name = "\(name).\(ext)"
                break search
            }
        }
        if !name.contains(".") { name += ".aiff" }
    }
    logLine("sound spec=\(spec) resolved=\(name)")
    return UNNotificationSound(named: UNNotificationSoundName(name))
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
            content.sound = resolveSound(args.count > 4 ? args[4] : "")
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
