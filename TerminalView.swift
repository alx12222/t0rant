import SwiftUI

struct TerminalView: View {
    @EnvironmentObject var shell: Shell
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var ask = InputPrompt.shared
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "terminal.fill")
                Text(shell.title).font(.system(size: 13, weight: .semibold, design: .monospaced))
                Spacer()
                Button { shell.clear() } label: { Image(systemName: "trash") }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(white: 0.17))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shell.lines) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: CGFloat(settings.fontSize), design: .monospaced))
                                .foregroundColor(line.color ?? shell.fg)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        HStack(spacing: 0) {
                            Text(ask.question ?? shell.promptText)
                                .font(.system(size: CGFloat(settings.fontSize), design: .monospaced))
                                .foregroundColor(shell.fg)
                            TextField("", text: $input)
                                .font(.system(size: CGFloat(settings.fontSize), design: .monospaced))
                                .foregroundColor(shell.fg)
                                .tint(shell.fg)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focused)
                                .submitLabel(.go)
                                .onSubmit(submit)
                        }
                        .id("prompt")
                        .opacity(shell.busy && ask.question == nil ? 0 : 1)
                    }
                    .padding(8)
                }
                .onChange(of: shell.lines.count) { _ in
                    withAnimation(.none) { proxy.scrollTo("prompt", anchor: .bottom) }
                }
            }
            .background(shell.bg)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }

            if settings.showKeyBar { KeyBar(input: $input, shell: shell, submit: submit) }
        }
        .background(shell.bg.ignoresSafeArea())
        .onAppear { focused = true }
        .sheet(isPresented: $ask.editorOpen) { EditorSheet() }
    }

    func submit() {
        let cmd = input
        input = ""
        if let q = ask.question {
            shell.print(q + cmd)
            ask.respond(cmd)
        } else if !shell.busy {
            shell.submit(cmd)
        }
        focused = true
    }
}

struct KeyBar: View {
    @Binding var input: String
    @ObservedObject var shell: Shell
    var submit: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("Tab") { input = shell.complete(input) }
                key("↑") { if let h = shell.historyStep(-1) { input = h } }
                key("↓") { if let h = shell.historyStep(1) { input = h } }
                key("^C") { shell.cancel(); input = "" }
                ForEach(["\\", "|", ">", "%", "&", ":", "\"", "*", "-", "/", "."], id: \.self) { s in
                    key(s) { input += s }
                }
                key("cls") { shell.clear() }
                key("⏎") { submit() }
            }
            .padding(6)
        }
        .background(Color(white: 0.12))
    }

    func key(_ t: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(.system(size: 14, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(white: 0.25)).cornerRadius(5)
        }
    }
}
