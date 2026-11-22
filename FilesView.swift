import SwiftUI
import UniformTypeIdentifiers

/// File manager tab for the sandboxed C: drive.
struct FilesView: View {
    @EnvironmentObject var shell: Shell
    var body: some View {
        NavigationView {
            FolderView(comps: ["Users", shell.fs.user])
        }
        .navigationViewStyle(.stack)
    }
}

struct FolderView: View {
    @EnvironmentObject var shell: Shell
    let comps: [String]
    @State private var items: [Entry] = []
    @State private var showHidden = false
    @State private var namePrompt: NamePrompt?
    @State private var nameText = ""
    @State private var importing = false
    @State private var errorText: String?

    enum NamePrompt: Identifiable {
        case newFile, newFolder, rename(Entry)
        var id: String {
            switch self {
            case .newFile: return "file"
            case .newFolder: return "folder"
            case .rename(let e): return "rename-" + e.name
            }
        }
        var title: String {
            switch self {
            case .newFile: return "New File"
            case .newFolder: return "New Folder"
            case .rename: return "Rename"
            }
        }
    }

    var fs: VirtualFS { shell.fs }
    var dirURL: URL { fs.url(comps) }
    var title: String { comps.last ?? "C:" }

    var body: some View {
        List {
            if comps.count > 0 {
                Section {
                    NavigationLink(destination: FolderView(comps: Array(comps.dropLast()))) {
                        Label("..", systemImage: "arrow.turn.left.up")
                    }
                } footer: { Text(fs.winPath(dirURL)).font(.system(.caption, design: .monospaced)) }
            }
            ForEach(items, id: \.name) { e in
                row(e)
                    .swipeActions {
                        Button(role: .destructive) { delete(e) } label: { Label("Delete", systemImage: "trash") }
                        Button { nameText = e.name; namePrompt = .rename(e) } label: { Label("Rename", systemImage: "pencil") }.tint(.orange)
                    }
                    .contextMenu {
                        Button { nameText = e.name; namePrompt = .rename(e) } label: { Label("Rename", systemImage: "pencil") }
                        Button { duplicate(e) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button { ShareSheet.present(e.url) } label: { Label("Share / Export", systemImage: "square.and.arrow.up") }
                        Button { openInTerminal(e) } label: { Label("Open in Terminal", systemImage: "terminal") }
                        Button(role: .destructive) { delete(e) } label: { Label("Delete", systemImage: "trash") }
                    }
            }
            if items.isEmpty { Text("This folder is empty.").foregroundColor(.secondary) }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { nameText = "new.txt"; namePrompt = .newFile } label: { Label("New File", systemImage: "doc.badge.plus") }
                    Button { nameText = "New Folder"; namePrompt = .newFolder } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    Button { importing = true } label: { Label("Import from Files", systemImage: "square.and.arrow.down") }
                    Toggle("Show hidden files", isOn: $showHidden)
                } label: { Image(systemName: "plus.circle") }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: showHidden) { _ in reload() }
        .refreshable { reload() }
        .sheet(item: $namePrompt) { p in
            NavigationView {
                Form { TextField("Name", text: $nameText).autocorrectionDisabled().textInputAutocapitalization(.never) }
                    .navigationTitle(p.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { namePrompt = nil } }
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { commit(p) } }
                    }
            }
            .compactSheet()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for u in urls {
                let ok = u.startAccessingSecurityScopedResource()
                defer { if ok { u.stopAccessingSecurityScopedResource() } }
                let dest = dirURL.appendingPathComponent(u.lastPathComponent)
                try? fs.fm.removeItem(at: dest)
                do { try fs.fm.copyItem(at: u, to: dest) } catch { errorText = error.localizedDescription }
            }
            reload()
        }
        .alert("Error", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") { errorText = nil }
        } message: { Text(errorText ?? "") }
    }

    @ViewBuilder func row(_ e: Entry) -> some View {
        if e.isDir {
            NavigationLink(destination: FolderView(comps: comps + [e.name])) {
                Label(e.name, systemImage: "folder.fill").foregroundColor(.primary)
            }
        } else {
            NavigationLink(destination: FileEditorView(url: e.url)) {
                HStack {
                    Image(systemName: icon(e.name)).foregroundColor(.accentColor).frame(width: 24)
                    VStack(alignment: .leading) {
                        Text(e.name)
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(e.size), countStyle: .file)) · \(e.modified.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    func icon(_ n: String) -> String {
        switch (n as NSString).pathExtension.lowercased() {
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "bat", "cmd", "sh": return "terminal"
        case "png", "jpg", "jpeg", "gif", "heic": return "photo"
        case "zip", "tar", "gz": return "doc.zipper"
        case "json", "xml", "html", "js", "css": return "curlybraces"
        default: return "doc.text"
        }
    }

    func reload() {
        items = (fs.list(dirURL) ?? []).filter { showHidden || !$0.hidden }
            .sorted { ($0.isDir ? 0 : 1, $0.name.lowercased()) < ($1.isDir ? 0 : 1, $1.name.lowercased()) }
    }

    func commit(_ p: NamePrompt) {
        let name = nameText.trimmingCharacters(in: .whitespaces)
        namePrompt = nil
        guard !name.isEmpty, !name.contains("/") else { return }
        let target = dirURL.appendingPathComponent(name)
        do {
            switch p {
            case .newFile:
                if fs.exists(target) { throw CocoaError(.fileWriteFileExists) }
                fs.write(target, "")
            case .newFolder:
                try fs.fm.createDirectory(at: target, withIntermediateDirectories: false)
            case .rename(let e):
                try fs.fm.moveItem(at: e.url, to: target)
            }
        } catch { errorText = error.localizedDescription }
        reload()
    }

    func delete(_ e: Entry) {
        do { try fs.fm.removeItem(at: e.url) } catch { errorText = error.localizedDescription }
        reload()
    }

    func duplicate(_ e: Entry) {
        let base = (e.name as NSString).deletingPathExtension, ext = (e.name as NSString).pathExtension
        var n = 2
        var dest: URL
        repeat {
            dest = dirURL.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        } while fs.exists(dest)
        try? fs.fm.copyItem(at: e.url, to: dest)
        reload()
    }

    func openInTerminal(_ e: Entry) {
        shell.cwd = e.isDir ? comps + [e.name] : comps
        shell.print("(cwd set to \(shell.cwdPath) from Files)")
    }
}

struct FileEditorView: View {
    @EnvironmentObject var shell: Shell
    let url: URL
    @State private var text = ""
    @State private var original = ""
    @State private var binary = false
    @State private var saved = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if binary {
                VStack(spacing: 12) {
                    Image(systemName: "doc").font(.largeTitle)
                    Text("This file isn't text and can't be edited here.")
                    Button("Share / Open in…") { ShareSheet.present(url) }
                }
            } else {
                TextEditor(text: $text)
                    .font(.system(size: CGFloat(AppSettings.shared.fontSize), design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused)
                    .padding(.horizontal, 4)
            }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { ShareSheet.present(url) } label: { Image(systemName: "square.and.arrow.up") }
                if !binary {
                    Button(saved ? "Saved" : "Save") { save() }.disabled(text == original)
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
            }
        }
        .onAppear(perform: load)
        .onDisappear { if text != original && !binary { save() } }
    }

    func load() {
        guard let d = try? Data(contentsOf: url) else { return }
        if let s = String(data: d, encoding: .utf8) { text = s; original = s; binary = false }
        else { binary = true }
    }

    func save() {
        if shell.fs.write(url, text) { original = text; saved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
    }
}
