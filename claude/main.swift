import Cocoa
import CommonCrypto
import SwiftUI

struct LimitWindow: Codable {
    let utilization: Double?
    let resets_at: String?
    var remaining: Int? {
        guard let value = utilization, value.isFinite else { return nil }
        return max(0, min(100, Int((100 - value).rounded())))
    }
    var reset: Date? {
        guard let value = resets_at else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

struct Usage: Codable {
    let five_hour: LimitWindow?
    let seven_day: LimitWindow?
    func label(stale: Bool = false, prefix: String = "C") -> String {
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "h:mma"
        time.amSymbol = "a"
        time.pmSymbol = "p"
        let day = DateFormatter()
        day.dateFormat = "d"
        func part(_ window: LimitWindow?, _ formatter: DateFormatter) -> String {
            let percentage = window?.remaining.map { "\($0)%" } ?? "—"
            return percentage + (window?.reset.map { "·" + formatter.string(from: $0) } ?? "")
        }
        return prefix + (stale ? "~" : "") + part(five_hour, time) + "/" + part(seven_day, day)
    }
}

enum BarError: LocalizedError {
    case unavailable(String)
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .http(let code): return code == 429 ? "Claude is rate-limiting checks" : "Claude returned HTTP \(code)"
        }
    }
}

/// One tracked account. Loaded from ~/.config/ailimitbar/accounts.json (see accounts.example.json).
struct Account: Codable {
    let name: String
    let tag: String              // menu bar pill, e.g. "C1"
    let type: String             // "claude", "codex" or "antigravity"
    var profile: String? = nil   // Claude only: profile folder in ~/Library/Application Support
    var app: String? = nil       // app path, or bundle ID; optional
    var plan: String? = nil      // fixed plan label; optional (otherwise read from the service)
    var letter: String { tag + " " }
    var folder: String { profile ?? "Claude" }
    var isClaude: Bool { type == "claude" }
    var key: String { isClaude ? folder : name }   // storage key for the last reading
    var symbol: String? { type == "codex" ? "chevron.left.forwardslash.chevron.right" : isClaude ? nil : "sparkle" }
    /// One reading (and plan) for this account.
    func fetch(needPlan: Bool) throws -> (Usage, String?) {
        switch type {
        case "codex": let (usage, profile) = try Fetcher.codex(); return (usage, profile.plan)
        case "antigravity": return try Fetcher.antigravity(needPlan: needPlan)
        default: return (try Fetcher.fetch(folder: folder), needPlan ? Fetcher.profile(folder: folder)?.plan : nil)
        }
    }
    func open() {
        let target = app ?? (type == "codex" ? "com.openai.codex" : type == "antigravity" ? "/Applications/Antigravity.app"
                             : folder == "Claude" ? "/Applications/Claude.app" : "/Applications/\(name).app")
        if target.hasPrefix("/") { NSWorkspace.shared.open(URL(fileURLWithPath: target)) }
        else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) { NSWorkspace.shared.open(url) }
    }
}

enum Accounts {
    static let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ailimitbar/accounts.json")
    struct Config: Codable { let accounts: [Account] }
    static func parse(_ data: Data) throws -> [Account] {
        let accounts = try JSONDecoder().decode(Config.self, from: data).accounts
        guard !accounts.isEmpty, accounts.allSatisfy({ ["claude", "codex", "antigravity"].contains($0.type) }) else {
            throw BarError.unavailable("accounts.json: need at least one account; type must be claude, codex or antigravity")
        }
        return accounts
    }
    /// Without a config: the main Claude app, plus Codex and Antigravity when they are installed.
    static var detected: [Account] {
        var accounts = [Account(name: "Claude", tag: "C1", type: "claude", profile: "Claude")]
        let fm = FileManager.default
        if fm.fileExists(atPath: fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json").path) {
            accounts.append(Account(name: "Codex", tag: "CX", type: "codex"))
        }
        if fm.fileExists(atPath: "/Applications/Antigravity.app") { accounts.append(Account(name: "Antigravity", tag: "AG", type: "antigravity")) }
        return accounts
    }
    static let all: [Account] = (try? Data(contentsOf: configURL)).flatMap { try? parse($0) } ?? detected
}

enum Credentials {
    static func token(folder: String = "Claude") throws -> String {
        // Read Claude's existing encrypted cache; never persist or print tokens.
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(folder)/config.json")
        guard let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any] else {
            throw BarError.unavailable("Open Claude and sign in first.")
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Safe Storage", "-w"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let passwordData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let password = String(data: passwordData, encoding: .utf8)?.trimmingCharacters(in: .newlines),
              !password.isEmpty else {
            throw BarError.unavailable("Claude Safe Storage is unavailable. Allow access if macOS asks.")
        }
        var key = [UInt8](repeating: 0, count: 16)
        let salt = Array("saltysalt".utf8)
        let derived = password.withCString { pointer in
            salt.withUnsafeBufferPointer { saltPointer in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pointer, password.utf8.count,
                    saltPointer.baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003, &key, key.count)
            }
        }
        guard derived == kCCSuccess else { throw BarError.unavailable("Cannot read Claude's sign-in cache.") }
        defer { key = [UInt8](repeating: 0, count: key.count) }
        let account = config["lastKnownAccountUuid"] as? String
        var candidates: [(priority: Int, expiration: Double, token: String)] = []
        for name in ["oauth:tokenCacheV2", "oauth:tokenCache"] {
            guard let encoded = config[name] as? String,
                  let encrypted = Data(base64Encoded: encoded), encrypted.count > 3,
                  String(data: encrypted.prefix(3), encoding: .utf8) == "v10" else { continue }
            let ciphertext = Data(encrypted.dropFirst(3))
            let iv = [UInt8](repeating: 32, count: 16)
            var plaintext = [UInt8](repeating: 0, count: ciphertext.count + 16)
            var length = 0
            let capacity = plaintext.count
            let status = key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    ciphertext.withUnsafeBytes { cipherBytes in
                        plaintext.withUnsafeMutableBytes { plainBytes in
                            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count,
                                ivBytes.baseAddress, cipherBytes.baseAddress, ciphertext.count,
                                plainBytes.baseAddress, capacity, &length)
                        }
                    }
                }
            }
            guard status == kCCSuccess,
                  let entries = try? JSONSerialization.jsonObject(with: Data(plaintext.prefix(length))) as? [String: Any] else { continue }
            for (name, raw) in entries {
                guard name.contains(":https://api.anthropic.com:"), name.contains("user:profile"),
                      account == nil || name.hasPrefix("acct:\(account!)|"),
                      let entry = raw as? [String: Any], let token = entry["token"] as? String,
                      !token.isEmpty, let expiration = entry["expiresAt"] as? Double,
                      expiration > Date().timeIntervalSince1970 * 1000 else { continue }
                candidates.append((0, expiration, token))
            }
        }
        guard let candidate = candidates.sorted(by: {
            $0.priority == $1.priority ? $0.expiration > $1.expiration : $0.priority < $1.priority
        }).first else {
            throw BarError.unavailable("Open Claude to refresh your sign-in, then choose Refresh Now.")
        }
        return candidate.token
    }
}

final class Fetcher {
    static func request(_ url: String, token: String?, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 20) throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let token = token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body = body { request.httpMethod = "POST"; request.httpBody = body }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: LocalTrust(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error { result = .failure(error); return }
            guard let response = response as? HTTPURLResponse else {
                result = .failure(BarError.unavailable("No response.")); return
            }
            guard response.statusCode == 200 else {
                result = .failure(BarError.http(response.statusCode)); return
            }
            result = .success(data ?? Data())
        }.resume()
        guard semaphore.wait(timeout: .now() + timeout + 5) == .success, let result = result else {
            throw BarError.unavailable("Request timed out.")
        }
        return try result.get()
    }
    static func claude(_ endpoint: String, folder: String) throws -> Data {
        try request("https://api.anthropic.com/api/oauth/\(endpoint)", token: Credentials.token(folder: folder),
                    headers: ["anthropic-beta": "oauth-2025-04-20"])
    }
    static func fetch(folder: String = "Claude") throws -> Usage {
        let usage = try JSONDecoder().decode(Usage.self, from: claude("usage", folder: folder))
        guard usage.five_hour?.remaining != nil || usage.seven_day?.remaining != nil else {
            throw BarError.unavailable("Claude did not return subscription usage limits.")
        }
        return usage
    }
    static func profile(folder: String) -> Profile? {
        guard let data = try? claude("profile", folder: folder),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Profile(json)
    }
    /// Codex limits from ~/.codex/auth.json (kept fresh by the Codex app); same shape as Claude's.
    // shortcut: no `codex` CLI fallback like the old Codex bar; add it if auth.json goes stale.
    static func codex() throws -> (Usage, Profile) {
        let authURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let auth = try? JSONSerialization.jsonObject(with: Data(contentsOf: authURL)) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any], let token = tokens["access_token"] as? String else {
            throw BarError.unavailable("Open Codex and sign in first.")
        }
        var headers = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"]
        headers["ChatGPT-Account-ID"] = tokens["account_id"] as? String
        let data = try request("https://chatgpt.com/backend-api/wham/usage", token: token, headers: headers)
        return try codexUsage(data)
    }
    static func codexUsage(_ data: Data) throws -> (Usage, Profile) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limit = (json["rate_limit"] ?? (json["rate_limit_warning"] as? [String: Any])?["rate_limit"]) as? [String: Any] else {
            throw BarError.unavailable("Codex did not return usage limits.")
        }
        func window(_ key: String) -> LimitWindow? {
            guard let raw = limit[key] as? [String: Any] else { return nil }
            let reset = (raw["reset_at"] as? Double).map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) }
            return LimitWindow(utilization: raw["used_percent"] as? Double, resets_at: reset)
        }
        let plan = (json["plan_type"] as? String)?.capitalized
        return (Usage(five_hour: window("primary_window"), seven_day: window("secondary_window")), Profile(plan: plan))
    }
}

/// Antigravity's local language server: its own HTTPS port with a self-signed cert, found from `ps`.
extension Fetcher {
    private static var antigravityServer: (port: String, token: String)?
    static func antigravity(needPlan: Bool) throws -> (Usage, String?) {
        if antigravityServer == nil { antigravityServer = try findAntigravityServer() }
        guard let server = antigravityServer else { throw BarError.unavailable("Open Antigravity first.") }
        do {
            let usage = try antigravityUsage(antigravityCall("RetrieveUserQuotaSummary", server)).0
            var plan: String?
            if needPlan, let data = try? antigravityCall("GetUserStatus", server),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tier = ((json["userStatus"] as? [String: Any])?["userTier"] as? [String: Any])?["description"] as? String {
                plan = tier.replacingOccurrences(of: "Google AI ", with: "").replacingOccurrences(of: "Google ", with: "")
            }
            return (usage, plan)
        } catch {
            antigravityServer = nil   // server restarted or moved: find it again next time
            throw error
        }
    }
    static func antigravityCall(_ method: String, _ server: (port: String, token: String)) throws -> Data {
        try request("https://127.0.0.1:\(server.port)/exa.language_server_pb.LanguageServerService/\(method)", token: nil,
                    headers: ["Content-Type": "application/json", "Connect-Protocol-Version": "1", "X-Codeium-Csrf-Token": server.token],
                    body: Data("{}".utf8), timeout: 5)
    }
    static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func findAntigravityServer() throws -> (port: String, token: String) {
        guard let line = run("/bin/ps", ["-axo", "pid=,command="]).split(separator: "\n")
                .first(where: { $0.contains("/Antigravity.app/Contents/Resources/bin/language_server") }),
              let pid = line.split(separator: " ").first,
              let tokenRange = line.range(of: #"--csrf_token \S+"#, options: .regularExpression) else {
            throw BarError.unavailable("Open Antigravity to see its limits.")
        }
        let token = String(line[tokenRange].dropFirst("--csrf_token ".count))
        let ports = run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"])
            .split(separator: "\n").filter { $0.hasPrefix("n") }.compactMap { $0.split(separator: ":").last.map(String.init) }
        for port in ports where (try? antigravityCall("RetrieveUserQuotaSummary", (port, token))) != nil { return (port, token) }
        throw BarError.unavailable("Antigravity's limits are not available yet.")
    }
    /// Gemini group only: its 5-hour and weekly buckets.
    static func antigravityUsage(_ data: Data) throws -> (Usage, String?) {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let groups = (json?["response"] as? [String: Any])?["groups"] as? [[String: Any]] ?? []
        guard let gemini = groups.first(where: { ($0["displayName"] as? String ?? "").localizedCaseInsensitiveContains("gemini") }),
              let buckets = gemini["buckets"] as? [[String: Any]] else {
            throw BarError.unavailable("Antigravity did not return Gemini limits.")
        }
        func window(_ name: String) -> LimitWindow? {
            guard let bucket = buckets.first(where: { $0["window"] as? String == name }) else { return nil }
            return LimitWindow(utilization: (bucket["remainingFraction"] as? Double).map { (1 - $0) * 100 }, resets_at: bucket["resetTime"] as? String)
        }
        return (Usage(five_hour: window("5h"), seven_day: window("weekly")), nil)
    }
}

/// Trusts only 127.0.0.1's self-signed certificate (Antigravity's local server); everything else is checked normally.
final class LocalTrust: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.host == "127.0.0.1", let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// Plan shown on each card (no names or emails are shown or stored).
struct Profile {
    let plan: String?
    init(plan: String?) { self.plan = plan }
    init(_ json: [String: Any]) {
        let account = json["account"] as? [String: Any] ?? [:]
        let org = json["organization"] as? [String: Any] ?? [:]
        let type = (org["organization_type"] as? String ?? "").lowercased()
        if type.contains("enterprise") { plan = "Enterprise" }
        else if type.contains("team") { plan = "Team" }
        else if account["has_claude_max"] as? Bool == true || type.contains("max") { plan = "Max" }
        else if account["has_claude_pro"] as? Bool == true || type.contains("pro") { plan = "Pro" }
        else { plan = nil }
    }
}

struct AccountState {
    var usage: Usage?
    var plan: String?
    var updated: Date?
    var error: String?
    var failures = 0
    var nextRefresh = Date.distantPast   // earliest next request (schedule or backoff)
    var stale: Bool { error != nil || (updated.map { Date().timeIntervalSince($0) > 900 } ?? true) }
    /// Lower of the two limits: how much this account can still do.
    var headroom: Int? { [usage?.five_hour?.remaining, usage?.seven_day?.remaining].compactMap { $0 }.min() }
}

final class Model: ObservableObject {
    // Last good reading and plan per account survive restarts, so cards are never blank.
    @Published var states: [AccountState] = Accounts.all.map { account in
        let defaults = UserDefaults.standard
        var state = AccountState()
        state.usage = defaults.data(forKey: "usage." + account.key).flatMap { try? JSONDecoder().decode(Usage.self, from: $0) }
        state.updated = defaults.object(forKey: "updated." + account.key) as? Date
        state.plan = defaults.string(forKey: "plan." + account.key)
        return state
    }
    @Published var selected = min(max(UserDefaults.standard.integer(forKey: "account"), 0), Accounts.all.count - 1)
    @Published var fetching = false
    @Published var now = Date()
    var select: (Int) -> Void = { _ in }
    var refresh: () -> Void = {}
    /// Claude account with the most limit left; nil when nothing is known.
    var best: Int? { Model.best(states, Accounts.all) }
    /// Claude account with the most limit left; nil when nothing is known.
    static func best(_ states: [AccountState], _ accounts: [Account]) -> Int? {
        accounts.indices.filter { accounts[$0].isClaude && (states[$0].headroom ?? 0) > 0 && states[$0].error == nil }
            .max { (states[$0].headroom ?? 0, -$0) < (states[$1].headroom ?? 0, -$1) }
    }
}

/// Menu bar art: account pill, then a ring gauge, % and reset for 5-hour and weekly.
enum BarArt {
    static let height: CGFloat = 22
    static func level(_ remaining: Int?, _ color: NSColor) -> NSColor {
        guard let remaining = remaining else { return .tertiaryLabelColor }
        return remaining <= 10 ? .systemRed : remaining <= 25 ? .systemOrange : color
    }
    static func image(tag: String, color: NSColor, usage: Usage?, stale: Bool, failed: Bool) -> NSImage {
        let tagFont = NSFont.systemFont(ofSize: 9, weight: .heavy)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        let resetFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        let time = DateFormatter(); time.locale = Locale(identifier: "en_US_POSIX"); time.dateFormat = "h:mma"
        time.amSymbol = "a"; time.pmSymbol = "p"
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "EEE"
        let parts: [(LimitWindow?, DateFormatter)] = usage == nil ? [] : [(usage?.five_hour, time), (usage?.seven_day, day)]
        func size(_ text: String, _ font: NSFont) -> CGSize { (text as NSString).size(withAttributes: [.font: font]) }
        // Layout first, so the image is exactly as wide as its content.
        let tagWidth = size(tag, tagFont).width + 10
        var width = tagWidth
        for (window, formatter) in parts {
            width += 6 + 12 + 4 + size(window?.remaining.map { "\($0)%" } ?? "—", valueFont).width
            if let reset = window?.reset { width += 3 + size(formatter.string(from: reset), resetFont).width }
        }
        if usage == nil { width += 6 + size(failed ? "!" : "…", valueFont).width }
        let image = NSImage(size: NSSize(width: ceil(width) + 1, height: height), flipped: false) { _ in
            NSGraphicsContext.current?.cgContext.setAlpha(stale ? 0.55 : 1)
            func text(_ string: String, _ font: NSFont, _ color: NSColor, at x: CGFloat) -> CGFloat {
                let s = size(string, font)
                (string as NSString).draw(at: NSPoint(x: x, y: (height - s.height) / 2), withAttributes: [.font: font, .foregroundColor: color])
                return x + s.width
            }
            // Account pill.
            let pill = NSRect(x: 0.5, y: 3.5, width: tagWidth, height: 15)
            NSGradient(starting: color.blended(withFraction: 0.15, of: .white) ?? color, ending: color)?
                .draw(in: NSBezierPath(roundedRect: pill, xRadius: 4.5, yRadius: 4.5), angle: -90)
            _ = text(tag, tagFont, .white, at: pill.minX + 5)
            var x = pill.maxX
            for (window, formatter) in parts {
                x += 6
                let center = NSPoint(x: x + 6, y: height / 2), radius: CGFloat = 4.8
                let track = NSBezierPath(); track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                track.lineWidth = 2.4; NSColor.labelColor.withAlphaComponent(0.25).setStroke(); track.stroke()
                if let remaining = window?.remaining, remaining > 0 {
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(remaining) / 100, clockwise: true)
                    arc.lineWidth = 2.4; arc.lineCapStyle = .round; level(remaining, color).setStroke(); arc.stroke()
                }
                x += 12 + 4
                let remaining = window?.remaining
                x = text(remaining.map { "\($0)%" } ?? "—", valueFont, remaining.map { $0 <= 10 ? .systemRed : .labelColor } ?? .secondaryLabelColor, at: x)
                if let reset = window?.reset { x = text(formatter.string(from: reset), resetFont, NSColor.labelColor.withAlphaComponent(0.72), at: x + 3) }
            }
            if usage == nil { _ = text(failed ? "!" : "…", valueFont, failed ? .systemOrange : .secondaryLabelColor, at: x + 6) }
            return true
        }
        image.cacheMode = .never   // redraw with the current light/dark menu bar colours
        return image
    }
}

enum Look {
    // One colour per account, in config order (e.g. Claude 1–4, Codex, Antigravity).
    static let colors = [NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1),
                         NSColor(srgbRed: 0.93, green: 0.27, blue: 0.53, alpha: 1),   // rose: stands out on blue-tinted menu bars
                         NSColor(srgbRed: 0.04, green: 0.66, blue: 0.88, alpha: 1),   // sky cyan: bright on blue-tinted menu bars
                         NSColor(srgbRed: 0.95, green: 0.65, blue: 0.12, alpha: 1),
                         NSColor(srgbRed: 0.10, green: 0.70, blue: 0.56, alpha: 1),
                         NSColor(srgbRed: 0.58, green: 0.40, blue: 0.92, alpha: 1)]
    static func nsColor(_ index: Int) -> NSColor { colors[index % colors.count] }
    static func color(_ index: Int) -> Color { Color(nsColor: nsColor(index)) }
    static func resetText(_ date: Date?, now: Date) -> String? {
        guard let date = date else { return nil }
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86400, hours = seconds % 86400 / 3600, minutes = seconds % 3600 / 60
        let relative = days > 0 ? "\(days)d \(hours)h" : hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = days > 0 ? "EEE h a" : "h:mm a"
        return "Resets \(relative) · \(formatter.string(from: date))"
    }
    static func ago(_ date: Date?, now: Date) -> String {
        guard let date = date else { return "not checked yet" }
        let minutes = Int(now.timeIntervalSince(date) / 60)
        return minutes < 1 ? "updated just now" : minutes < 60 ? "updated \(minutes)m ago" : "updated \(minutes / 60)h ago"
    }
}

struct Meter: View {
    let label: String
    let window: LimitWindow?
    let color: Color
    let now: Date
    var body: some View {
        let remaining = window?.remaining
        let fill = remaining.map { $0 <= 10 ? Color.red : $0 <= 25 ? Color.orange : color } ?? .secondary
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                Spacer()
                Text(remaining.map { "\($0)%" } ?? "—").font(.system(size: 13, weight: .semibold).monospacedDigit())
                    + Text(" left").font(.system(size: 10)).foregroundColor(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(LinearGradient(colors: [fill.opacity(0.7), fill], startPoint: .leading, endPoint: .trailing))
                        .frame(width: remaining.map { max(5, geometry.size.width * CGFloat($0) / 100) } ?? 0)
                }
            }
            .frame(height: 6)
            Text(Look.resetText(window?.reset, now: now) ?? " ").font(.system(size: 10)).foregroundColor(.secondary)
                .lineLimit(1).minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .combine)
    }
}

struct AccountCard: View {
    let index: Int
    @ObservedObject var model: Model
    @State private var hover = false
    var body: some View {
        let state = model.states[index]
        let account = Accounts.all[index]
        let color = Look.color(index)
        let selected = model.selected == index
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [color, color.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if let symbol = account.symbol {
                        Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                    } else {
                        Text(account.letter.dropFirst().trimmingCharacters(in: .whitespaces)).font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                    }
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if let plan = account.plan ?? state.plan { Tag(text: plan, color: color, filled: false) }
                    }
                    Text(Look.ago(state.updated, now: model.now)).font(.system(size: 10.5)).foregroundColor(.secondary)
                }
                Spacer(minLength: 4)
                if selected {
                    Label("In menu bar", systemImage: "checkmark.circle.fill").font(.system(size: 10, weight: .semibold))
                        .foregroundColor(color)
                }
                Button { account.open() } label: { Image(systemName: "arrow.up.forward.app").font(.system(size: 15)) }
                    .buttonStyle(.borderless)
                    .help("Open \(account.name)")
            }
            HStack(spacing: 14) {
                Meter(label: "5-hour", window: state.usage?.five_hour, color: color, now: model.now)
                Meter(label: "Weekly", window: state.usage?.seven_day, color: color, now: model.now)
            }
            .opacity(state.stale && state.usage != nil ? 0.65 : 1)
            if let error = state.error {
                Label(error + " · next try " + DateFormatter.localizedString(from: state.nextRefresh, dateStyle: .none, timeStyle: .short),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundColor(.orange).lineLimit(2)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(color.opacity(selected ? 0.16 : hover ? 0.10 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(color.opacity(selected ? 0.85 : 0.2), lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { model.select(index) }
        .onHover { hover = $0 }
        .help(selected ? "Shown in the menu bar" : "Click to show \(account.name) in the menu bar")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct Tag: View {
    let text: String
    let color: Color
    let filled: Bool
    var body: some View {
        Text(text).font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1.5)
            .foregroundColor(filled ? .white : color)
            .background(Capsule().fill(filled ? color : color.opacity(0.15)))
    }
}

struct Panel: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("AI Usage").font(.system(size: 15, weight: .bold))
                    Text("Click an account to show it in the menu bar").font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                Button { model.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                        .rotationEffect(.degrees(model.fetching ? 360 : 0))
                        .animation(model.fetching ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: model.fetching)
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
            }
            if Accounts.all.contains(where: { $0.isClaude }) { Section(title: "CLAUDE") }
            ForEach(Accounts.all.indices.filter { Accounts.all[$0].isClaude }, id: \.self) { AccountCard(index: $0, model: model) }
            if let best = model.best {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundColor(Look.color(best))
                    Text("Most left: ").font(.system(size: 11)).foregroundColor(.secondary)
                        + Text(Accounts.all[best].name).font(.system(size: 11, weight: .semibold))
                        + Text(" · \(model.states[best].headroom ?? 0)%").font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                    if best != model.selected { Button("Use") { model.select(best) }.controlSize(.small) }
                }
                .padding(.horizontal, 4)
            }
            if Accounts.all.contains(where: { !$0.isClaude }) {
                if Accounts.all.contains(where: { $0.isClaude }) {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).padding(.vertical, 2)
                }
                Section(title: Accounts.all.filter { !$0.isClaude }.map { $0.name.uppercased() }.joined(separator: " · "))
            }
            ForEach(Accounts.all.indices.filter { !Accounts.all[$0].isClaude }, id: \.self) { AccountCard(index: $0, model: model) }
            Divider().padding(.top, 2)
            HStack {
                Button { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) } label: {
                    Label("Claude usage page", systemImage: "safari")
                }
                Spacer()
                Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
        }
        .padding(14)
        .frame(width: 380)
        .background(Color.white)   // solid white: text stays readable over any wallpaper
    }
    struct Section: View {
        let title: String
        var body: some View {
            Text(title).font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundColor(.secondary).padding(.leading, 4)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    // The menu bar account is checked every 30 s so drops show at once; the others only when the panel opens.
    static let selectedEvery: TimeInterval = 25   // + 10 s timer tick ≈ every 30 s
    static let othersEvery: TimeInterval = 30
    private var status: NSStatusItem!
    private var popover = NSPopover()
    private let model = Model()
    private var timer: Timer?
    private var account: Int { model.selected }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        status.button?.target = self
        status.button?.action = #selector(clicked)
        model.select = { [weak self] in self?.switchTo($0) }
        model.refresh = { [weak self] in self?.refresh(Array(Accounts.all.indices), manual: true) }
        popover = makePopover()
        render()
        refresh([account])
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.model.now = Date(); self.render(); self.refresh([self.account])
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func woke() { refresh([account]) }
    /// Fetch the given accounts if they are due. Each account keeps its own schedule and backoff.
    private func refresh(_ indices: [Int], manual: Bool = false) {
        guard !model.fetching else { return }
        let now = Date()
        let due = indices.filter { index in
            let state = model.states[index]
            // Manual refresh skips the schedule, never the backoff after an error (e.g. HTTP 429),
            // and never asks again within 10 seconds.
            if manual { return state.error == nil ? (state.updated.map { now.timeIntervalSince($0) > 10 } ?? true) : now >= state.nextRefresh }
            return now >= state.nextRefresh
        }
        guard !due.isEmpty else { return }
        let needPlan = Set(due.filter { model.states[$0].plan == nil })
        model.fetching = true
        DispatchQueue.global(qos: .utility).async {
            var results: [Int: Result<(Usage, String?), Error>] = [:]
            for index in due {
                let account = Accounts.all[index]
                results[index] = Result { try account.fetch(needPlan: needPlan.contains(index)) }
            }
            DispatchQueue.main.async {
                for (index, result) in results {
                    var state = self.model.states[index]
                    let key = Accounts.all[index].key
                    switch result {
                    case .success(let (usage, plan)):
                        state.usage = usage; state.updated = Date(); state.error = nil; state.failures = 0
                        state.nextRefresh = Date().addingTimeInterval(index == self.account ? Self.selectedEvery : Self.othersEvery)
                        UserDefaults.standard.set(try? JSONEncoder().encode(usage), forKey: "usage." + key)
                        UserDefaults.standard.set(state.updated, forKey: "updated." + key)
                        if let plan = plan { state.plan = plan; UserDefaults.standard.set(plan, forKey: "plan." + key) }
                    case .failure(let error):
                        state.error = error.localizedDescription; state.failures += 1
                        state.nextRefresh = Date().addingTimeInterval(min(1800, 60 * pow(2, Double(min(state.failures - 1, 5)))))
                    }
                    self.model.states[index] = state
                }
                self.model.fetching = false
                self.model.now = Date()
                self.render()
            }
        }
    }
    private func render() {
        let state = model.states[account]
        let letter = Accounts.all[account].letter
        let label = state.usage?.label(stale: state.stale, prefix: letter) ?? (state.error == nil ? letter + "…" : letter + "!")
        status.button?.title = ""
        status.button?.imagePosition = .imageOnly
        status.button?.image = BarArt.image(tag: letter.trimmingCharacters(in: .whitespaces), color: Look.nsColor(account),
                                            usage: state.usage, stale: state.stale, failed: state.error != nil)
        status.button?.toolTip = "\(Accounts.all[account].name) · 5-hour / weekly remaining" + (state.stale ? " · Last reading" : "")
        status.button?.setAccessibilityLabel("\(Accounts.all[account].name) usage: " + label)
    }
    @objc private func clicked() {
        guard let button = status.button else { return }
        if let window = detached {
            // A detached popover cannot be shown at the bar again, so start a fresh one.
            let wasOpen = window.isVisible
            window.close(); detached = nil; popover = makePopover()
            if wasOpen { return }
        }
        if popover.isShown { popover.performClose(nil); return }
        model.now = Date()
        // Opening the panel is the only time accounts not in the menu bar are checked.
        refresh(Array(Accounts.all.indices))
        NSApp.activate(ignoringOtherApps: true)
        popover.contentSize = popover.contentViewController?.view.fittingSize ?? popover.contentSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
        popover.appearance = NSAppearance(named: .aqua)   // light, to match the white panel
        popover.contentViewController = NSHostingController(rootView: Panel(model: model))
        return popover
    }
    /// Dragging the panel away from the menu bar detaches it into a window that can be moved anywhere.
    private var detached: NSWindow?
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }
    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        let hosting = NSHostingView(rootView: Panel(model: model))
        let size = hosting.fittingSize
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white
        window.contentView = hosting
        detached = window
        return window
    }
    private func switchTo(_ index: Int) {
        guard index != account else { return }
        model.selected = index
        UserDefaults.standard.set(index, forKey: "account")
        render()
        refresh([index])
    }
}

if CommandLine.arguments.contains("--self-test") {
    let json = #"{"five_hour":{"utilization":63,"resets_at":"2026-10-07T04:50:00.169441+00:00"},"seven_day":{"utilization":32,"resets_at":"2026-10-12T02:00:00.169511+00:00"}}"#
    let sample = try JSONDecoder().decode(Usage.self, from: Data(json.utf8))
    precondition(sample.five_hour?.remaining == 37 && sample.seven_day?.remaining == 68)
    precondition(sample.five_hour?.reset != nil && sample.seven_day?.reset != nil)
    precondition(sample.label().hasPrefix("C37%·") && sample.label().hasSuffix("/68%·12"))
    precondition(sample.label(stale: true).hasPrefix("C~"))
    precondition(LimitWindow(utilization: 130, resets_at: nil).remaining == 0)
    precondition(LimitWindow(utilization: -1, resets_at: nil).remaining == 100)
    precondition(LimitWindow(utilization: nil, resets_at: nil).remaining == nil)
    precondition(Profile(["account": ["has_claude_pro": true], "organization": ["organization_type": "claude_team"]]).plan == "Team")
    precondition(Profile(["account": ["has_claude_pro": true]]).plan == "Pro")
    let (codex, codexPlan) = try Fetcher.codexUsage(Data(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":15.0,"reset_at":1794000000},"secondary_window":{"used_percent":40}}}"#.utf8))
    precondition(codex.five_hour?.remaining == 85 && codex.seven_day?.remaining == 60 && codex.five_hour?.reset != nil && codexPlan.plan == "Plus")
    precondition(Look.resetText(Date().addingTimeInterval(2 * 3600 + 5 * 60 + 30), now: Date())!.hasPrefix("Resets 2h 5m"))
    precondition(Look.resetText(Date().addingTimeInterval(3 * 86400 + 3600 + 30), now: Date())!.hasPrefix("Resets 3d 1h"))
    let config = try Accounts.parse(Data(#"{"accounts":[{"name":"Claude Work","tag":"C1","type":"claude","profile":"Claude","plan":"Max 5x"},{"name":"Claude Home","tag":"C2","type":"claude","profile":"Claude Account 2"},{"name":"Codex","tag":"CX","type":"codex"},{"name":"Antigravity","tag":"AG","type":"antigravity"}]}"#.utf8))
    precondition(config.map { $0.tag } == ["C1", "C2", "CX", "AG"] && config[1].folder == "Claude Account 2" && config[0].plan == "Max 5x")
    precondition(config.filter { $0.isClaude }.count == 2 && config[2].symbol != nil)
    precondition((try? Accounts.parse(Data(#"{"accounts":[{"name":"X","tag":"X","type":"gpt"}]}"#.utf8))) == nil)
    precondition(Accounts.detected.first?.folder == "Claude")
    let (gemini, _) = try Fetcher.antigravityUsage(Data(#"{"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.5620155,"resetTime":"2026-11-21T14:17:37Z"},{"bucketId":"gemini-5h","window":"5h","remainingFraction":1,"resetTime":"2026-11-17T19:34:52Z"}]},{"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.1},{"bucketId":"3p-5h","window":"5h","remainingFraction":0.2}]}]}}"#.utf8))
    precondition(gemini.seven_day?.remaining == 56 && gemini.five_hour?.remaining == 100 && gemini.seven_day?.reset != nil)
    var states = Array(repeating: AccountState(), count: config.count)
    states[0].usage = sample                                                                                      // headroom 37
    states[1].usage = try JSONDecoder().decode(Usage.self, from: Data(#"{"five_hour":{"utilization":10},"seven_day":{"utilization":20}}"#.utf8))  // 80
    states[2].usage = try JSONDecoder().decode(Usage.self, from: Data(#"{"five_hour":{"utilization":0},"seven_day":{"utilization":0}}"#.utf8))   // Codex: ignored
    precondition(Model.best(states, config) == 1)
    states[1].error = "x"
    precondition(Model.best(states, config) == 0)
    print("PASS: bar art, percentages, reset timestamps, label, stale state, bounds, plan, Codex parse, reset text, accounts, best account")
} else if let index = CommandLine.arguments.firstIndex(of: "--render"), index + 1 < CommandLine.arguments.count {
    // Preview the menu bar art as a PNG (no network): --render out.png
    let json = #"{"five_hour":{"utilization":8,"resets_at":"2026-10-07T04:50:00+00:00"},"seven_day":{"utilization":22,"resets_at":"2026-10-12T02:00:00+00:00"}}"#
    let low = #"{"five_hour":{"utilization":93,"resets_at":"2026-10-07T04:50:00+00:00"},"seven_day":{"utilization":80,"resets_at":"2026-10-12T02:00:00+00:00"}}"#
    let rows = try [(0, json), (1, low), (3, json)].map { ($0.0, try JSONDecoder().decode(Usage.self, from: Data($0.1.utf8))) }
    let canvas = NSImage(size: NSSize(width: 220, height: 3 * 26 * 2 + 8))
    canvas.lockFocus()
    for (half, appearance) in [(0, NSAppearance(named: .aqua)!), (1, NSAppearance(named: .darkAqua)!)] {
        NSAppearance.current = appearance
        (half == 0 ? NSColor.white : NSColor(white: 0.15, alpha: 1)).setFill()
        NSRect(x: 0, y: CGFloat(half) * 82, width: 220, height: 82).fill()
        for (row, (index, usage)) in rows.enumerated() {
            BarArt.image(tag: ["C1", "C2", "C3", "CX", "AG"][index], color: Look.nsColor(index), usage: usage, stale: false, failed: false)
                .draw(at: NSPoint(x: 8, y: CGFloat(half) * 82 + 4 + CGFloat(row) * 26), from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
    canvas.unlockFocus()
    let rep = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
} else if CommandLine.arguments.contains("--check") {
    // Uses one request per account: run rarely (Claude rate-limits usage checks).
    for (index, account) in Accounts.all.enumerated() where CommandLine.arguments.count < 3 || CommandLine.arguments.contains(String(index + 1)) {
        do {
            let (usage, plan) = try account.fetch(needPlan: !account.isClaude)
            print("\(account.name): \(usage.label(prefix: account.letter)) \(plan ?? "")")
        } catch { fputs("\(account.name): \(error.localizedDescription)\n", stderr) }
    }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
