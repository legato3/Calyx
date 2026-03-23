// ContextView.swift
// Calyx
//
// Sidebar panel showing the active project's CLAUDE.md and Claude Code memory files.

import SwiftUI

struct ContextView: View {
    let pwd: String?

    @State private var vm = ContextViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if pwd == nil {
                    noPwdView
                } else {
                    claudeMDSection
                    memorySection
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .onAppear { vm.resolveAndLoad(pwd: pwd) }
        .onChange(of: pwd) { _, newPwd in vm.resolveAndLoad(pwd: newPwd) }
    }

    // MARK: - No PWD placeholder

    private var noPwdView: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Open a terminal tab to view\nproject context.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - CLAUDE.md

    private var claudeMDSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("CLAUDE.md", systemImage: "doc.text")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            if let path = vm.claudeMDPath {
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("No CLAUDE.md found in project hierarchy.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            TextEditor(text: $vm.claudeMDContent)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 120, maxHeight: 300)
                .scrollContentBackground(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

            HStack(spacing: 8) {
                if let msg = vm.saveMessage {
                    Text(msg)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if vm.claudeMDPath == nil {
                    Button("Create CLAUDE.md") { vm.createCLAUDEMD(pwd: pwd) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("Save") { vm.saveCLAUDEMD() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(vm.isSaving)
                }
            }
        }
    }

    // MARK: - Memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Memory (\(vm.memoryFiles.count))", systemImage: "brain")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            if vm.memoryFiles.isEmpty {
                Text("No memory files for this project.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 4) {
                    ForEach(vm.memoryFiles, id: \.path) { file in
                        MemoryFileRow(file: file)
                    }
                }
            }
        }
    }
}

// MARK: - MemoryFileRow

private struct MemoryFileRow: View {
    let file: ContextViewModel.MemoryFile

    @State private var isExpanded = false
    @State private var content = ""

    private var displayName: String {
        file.name.hasSuffix(".md") ? String(file.name.dropLast(3)) : file.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(displayName)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(isExpanded ? .degrees(90) : .zero)
                        .animation(.easeInOut(duration: 0.15), value: isExpanded)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            if isExpanded {
                Text(content.isEmpty ? "(empty)" : content)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .textSelection(.enabled)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }

    private func toggle() {
        if isExpanded {
            isExpanded = false
        } else {
            content = (try? String(contentsOfFile: file.path, encoding: .utf8)) ?? ""
            isExpanded = true
        }
    }
}

// MARK: - ContextViewModel

@Observable
@MainActor
final class ContextViewModel {
    struct MemoryFile {
        let name: String
        let path: String
    }

    var claudeMDPath: String? = nil
    var claudeMDContent: String = ""
    var memoryFiles: [MemoryFile] = []
    var isSaving = false
    var saveMessage: String? = nil

    private var watchSource: DispatchSourceFileSystemObject?
    private var memWatchSource: DispatchSourceFileSystemObject?
    private var fileDebounce: DispatchWorkItem?
    private var memDebounce: DispatchWorkItem?

    func resolveAndLoad(pwd: String?) {
        stopWatching()
        guard let pwd else {
            claudeMDPath = nil
            claudeMDContent = ""
            memoryFiles = []
            return
        }
        claudeMDPath = findCLAUDEMD(from: pwd)
        claudeMDContent = claudeMDPath
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        loadMemoryFiles(pwd: pwd)
        startWatching(pwd: pwd)
    }

    func saveCLAUDEMD() {
        guard let path = claudeMDPath else { return }
        isSaving = true
        do {
            try claudeMDContent.write(toFile: path, atomically: true, encoding: .utf8)
            setTemporaryMessage("Saved")
        } catch {
            setTemporaryMessage("Save failed")
        }
        isSaving = false
    }

    func createCLAUDEMD(pwd: String?) {
        guard let pwd else { return }
        let path = pwd + "/CLAUDE.md"
        do {
            try claudeMDContent.write(toFile: path, atomically: true, encoding: .utf8)
            claudeMDPath = path
            setTemporaryMessage("Created")
        } catch {
            setTemporaryMessage("Failed to create")
        }
    }

    // MARK: - Private

    private func findCLAUDEMD(from startPath: String) -> String? {
        var current = startPath
        let fm = FileManager.default
        while true {
            let candidate = current + "/CLAUDE.md"
            if fm.fileExists(atPath: candidate) { return candidate }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty || parent == "/" { break }
            current = parent
        }
        return nil
    }

    private func loadMemoryFiles(pwd: String) {
        let hash = pwd.replacingOccurrences(of: "/", with: "-")
        let dir = NSHomeDirectory() + "/.claude/projects/\(hash)/memory"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            memoryFiles = []
            return
        }
        memoryFiles = contents
            .filter { $0.hasSuffix(".md") }
            .sorted()
            .map { MemoryFile(name: $0, path: dir + "/" + $0) }
    }

    private func startWatching(pwd: String) {
        if let path = claudeMDPath {
            let fd = open(path, O_EVTONLY)
            if fd >= 0 {
                let src = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd, eventMask: [.write, .delete], queue: .main
                )
                src.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.fileDebounce?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        Task.detached(priority: .utility) {
                            let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                            await MainActor.run { [weak self] in self?.claudeMDContent = content }
                        }
                    }
                    self.fileDebounce = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                }
                src.setCancelHandler { close(fd) }
                src.resume()
                watchSource = src
            }
        }

        let hash = pwd.replacingOccurrences(of: "/", with: "-")
        let memDir = NSHomeDirectory() + "/.claude/projects/\(hash)/memory"
        let fd = open(memDir, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .link], queue: .main
            )
            src.setEventHandler { [weak self] in
                guard let self else { return }
                self.memDebounce?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.loadMemoryFiles(pwd: pwd) }
                self.memDebounce = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            memWatchSource = src
        }
    }

    private func stopWatching() {
        watchSource?.cancel()
        watchSource = nil
        memWatchSource?.cancel()
        memWatchSource = nil
        fileDebounce?.cancel()
        fileDebounce = nil
        memDebounce?.cancel()
        memDebounce = nil
    }

    private func setTemporaryMessage(_ msg: String) {
        saveMessage = msg
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if saveMessage == msg { saveMessage = nil }
        }
    }
}
