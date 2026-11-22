import SwiftUI
import UIKit

/// Persisted user preferences.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var username: String { didSet { d.set(username, forKey: "username") } }
    @Published var fgHex: String { didSet { d.set(fgHex, forKey: "fgHex") } }
    @Published var bgHex: String { didSet { d.set(bgHex, forKey: "bgHex") } }
    @Published var fontSize: Double { didSet { d.set(fontSize, forKey: "fontSize") } }
    @Published var showKeyBar: Bool { didSet { d.set(showKeyBar, forKey: "showKeyBar") } }

    init() {
        username = AppSettings.clean(d.string(forKey: "username") ?? "t0rant")
        fgHex = d.string(forKey: "fgHex") ?? "#CCCCCC"
        bgHex = d.string(forKey: "bgHex") ?? "#000000"
        fontSize = d.object(forKey: "fontSize") as? Double ?? 13
        showKeyBar = d.object(forKey: "showKeyBar") as? Bool ?? true
    }

    var fgColor: Color { Color(hex: fgHex) ?? Color(white: 0.8) }
    var bgColor: Color { Color(hex: bgHex) ?? .black }

    /// Windows-safe user folder name.
    static func clean(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "\\/:*?\"<>| ")
        let c = s.components(separatedBy: bad).joined()
        return c.isEmpty ? "t0rant" : String(c.prefix(32))
    }

    static let themes: [(String, String, String)] = [
        ("Classic CMD", "#CCCCCC", "#000000"), ("Matrix", "#00FF41", "#000000"), ("PowerShell", "#EEEDF0", "#012456"),
        ("Amber", "#FFB000", "#1A1200"), ("Hacker Blue", "#5FD7FF", "#0A0F1A"), ("Solarized", "#839496", "#002B36"),
        ("Dracula", "#F8F8F2", "#282A36"), ("Paper", "#202020", "#F5F5F0"), ("Blood", "#FF3B3B", "#0D0000"),
    ]
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    var hexString: String {
        let c = UIColor(self).cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0]
        let r = Int((c.count > 0 ? c[0] : 0) * 255), g = Int((c.count > 1 ? c[1] : 0) * 255), b = Int((c.count > 2 ? c[2] : 0) * 255)
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}

struct SettingsView: View {
    @EnvironmentObject var shell: Shell
    @ObservedObject var s = AppSettings.shared
    @State private var nameDraft = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        TextField("User name", text: $nameDraft)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit(applyName)
                        Button("Apply", action: applyName).disabled(AppSettings.clean(nameDraft) == s.username)
                    }
                } header: { Text("User") } footer: {
                    Text("Used for %USERNAME%, whoami and your home folder C:\\Users\\\(AppSettings.clean(nameDraft)). Files in the old home folder stay where they are.")
                }

                Section("Theme") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(AppSettings.themes, id: \.0) { t in
                                Button { s.fgHex = t.1; s.bgHex = t.2; shell.applySettings() } label: {
                                    VStack(spacing: 4) {
                                        Text("C:\\>_").font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(Color(hex: t.1)).frame(width: 74, height: 44)
                                            .background(Color(hex: t.2)).cornerRadius(6)
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(s.fgHex == t.1 && s.bgHex == t.2 ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: 2))
                                        Text(t.0).font(.caption2).foregroundColor(.primary)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }.padding(.vertical, 4)
                    }
                    ColorPicker("Text color", selection: Binding(get: { s.fgColor }, set: { s.fgHex = $0.hexString; shell.applySettings() }), supportsOpacity: false)
                    ColorPicker("Background color", selection: Binding(get: { s.bgColor }, set: { s.bgHex = $0.hexString; shell.applySettings() }), supportsOpacity: false)
                }

                Section("Display") {
                    Stepper("Font size: \(Int(s.fontSize))", value: $s.fontSize, in: 9...24)
                    Toggle("Show shortcut key bar", isOn: $s.showKeyBar)
                    Text("\(shell.promptText)dir")
                        .font(.system(size: CGFloat(s.fontSize), design: .monospaced))
                        .foregroundColor(s.fgColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8).background(s.bgColor).cornerRadius(6)
                }

                Section("About") {
                    InfoRow("Version", "1.0")
                    InfoRow("Python", "3.13 (embedded)")
                    InfoRow("Storage", "Files app › t0rant › C")
                    Button("Reset to defaults", role: .destructive) {
                        s.fgHex = "#CCCCCC"; s.bgHex = "#000000"; s.fontSize = 13; s.showKeyBar = true
                        shell.applySettings()
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear { nameDraft = s.username }
        }
        .navigationViewStyle(.stack)
    }

    func applyName() {
        let n = AppSettings.clean(nameDraft)
        nameDraft = n
        guard n != s.username else { return }
        s.username = n
        shell.applySettings()
        shell.print("User name changed to \(n). Home is now C:\\Users\\\(n)")
    }
}

/// iOS 15-compatible replacement for LabeledContent.
struct InfoRow: View {
    let title: String, value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
    var body: some View {
        HStack { Text(title); Spacer(); Text(value).foregroundColor(.secondary) }
    }
}

extension View {
    /// Small sheet on iOS 16+, normal sheet on iOS 15.
    @ViewBuilder func compactSheet() -> some View {
        if #available(iOS 16.0, *) { self.presentationDetents([.height(200)]) } else { self }
    }
}
