import SwiftUI
import UIKit

/// Bridges commands that need user input (SET /P, PAUSE, CHOICE, NOTEPAD) with the UI.
@MainActor
final class InputPrompt: ObservableObject {
    static let shared = InputPrompt()

    @Published var question: String? = nil
    @Published var editorTitle = ""
    @Published var editorText = ""
    @Published var editorOpen = false

    private var answer: CheckedContinuation<String, Never>?
    private var editor: CheckedContinuation<String?, Never>?

    static func ask(_ q: String) async -> String {
        await withCheckedContinuation { cont in
            shared.answer?.resume(returning: "")
            shared.answer = cont
            shared.question = q
        }
    }

    func respond(_ text: String) {
        question = nil
        let a = answer
        answer = nil
        a?.resume(returning: text)
    }

    static func edit(title: String, text: String) async -> String? {
        await withCheckedContinuation { cont in
            shared.editor = cont
            shared.editorTitle = title
            shared.editorText = text
            shared.editorOpen = true
        }
    }

    func finishEditing(save: Bool) {
        editorOpen = false
        let e = editor
        editor = nil
        e?.resume(returning: save ? editorText : nil)
    }

    func cancelAll() {
        if answer != nil { respond("") }
        if editor != nil { finishEditing(save: false) }
    }
}

struct EditorSheet: View {
    @ObservedObject var prompt = InputPrompt.shared
    var body: some View {
        NavigationView {
            TextEditor(text: $prompt.editorText)
                .font(.system(size: 13, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(4)
                .navigationTitle(prompt.editorTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { prompt.finishEditing(save: false) } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { prompt.finishEditing(save: true) } }
                }
        }
        .interactiveDismissDisabled()
    }
}

enum ShareSheet {
    @MainActor static func present(_ url: URL) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = root.view
        vc.popoverPresentationController?.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
        var top = root
        while let p = top.presentedViewController { top = p }
        top.present(vc, animated: true)
    }
}
