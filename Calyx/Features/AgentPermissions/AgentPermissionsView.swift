// AgentPermissionsView.swift
// Calyx
//
// Warp-style agent permissions panel — shown in Settings sidebar.

import SwiftUI

struct AgentPermissionsView: View {
    @State private var store = AgentPermissionsStore.shared
    @State private var showAddProfile = false
    @State private var newProfileName = ""
    @State private var editingProfile: AgentPermissionProfile? = nil

    private let builtinIDs: Set<UUID> = [
        AgentPermissionProfile.balanced.id,
        AgentPermissionProfile.yolo.id,
        AgentPermissionProfile.cautious.id,
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Profile selector
                profileSection

                // Active profile permissions
                permissionsSection

                // Command allow/deny lists
                commandListsSection
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Profile Section

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Profile", icon: "person.crop.circle")

            VStack(spacing: 4) {
                ForEach(store.profiles) { profile in
                    ProfileRowView(
                        profile: profile,
                        isActive: profile.id == store.activeProfileID,
                        isBuiltin: builtinIDs.contains(profile.id),
                        onSelect: { store.setActiveProfile(profile.id) },
                        onEdit: { editingProfile = profile },
                        onDelete: { store.deleteProfile(id: profile.id) }
                    )
                }
            }

            Button {
                newProfileName = ""
                showAddProfile = true
            } label: {
                Label("New Profile", systemImage: "plus.circle")
                    .font(.system(size: 11, design: .rounded))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .sheet(isPresented: $showAddProfile) {
            addProfileSheet
        }
        .sheet(item: $editingProfile) { profile in
            EditProfileSheet(profile: profile) { updated in
                store.updateProfile(updated)
                editingProfile = nil
            } onCancel: {
                editingProfile = nil
            }
        }
    }

    private var addProfileSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Profile").font(.system(size: 15, weight: .semibold, design: .rounded))
            TextField("Profile name", text: $newProfileName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { showAddProfile = false }.buttonStyle(.bordered)
                Spacer()
                Button("Create") {
                    let p = AgentPermissionProfile(name: newProfileName.isEmpty ? "Custom" : newProfileName)
                    store.addProfile(p)
                    store.setActiveProfile(p.id)
                    showAddProfile = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    // MARK: - Permissions Section

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Permissions — \(store.activeProfile.name)", icon: "lock.shield")

            VStack(spacing: 4) {
                ForEach(AgentActionCategory.allCases, id: \.rawValue) { category in
                    PermissionRowView(
                        category: category,
                        level: store.activeProfile.level(for: category),
                        isEditable: !builtinIDs.contains(store.activeProfileID),
                        onChange: { newLevel in
                            var updated = store.activeProfile
                            updated.setLevel(newLevel, for: category)
                            store.updateProfile(updated)
                        }
                    )
                }
            }

            if builtinIDs.contains(store.activeProfileID) {
                Text("Built-in profiles are read-only. Duplicate to customize.")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Command Lists Section

    private var commandListsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Auto-accept Commands", icon: "checkmark.circle")
            Text("Commands matching these prefixes always run without approval in agent mode.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
            Text("Configured via the safe-command list in ComposeOverlayController.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Helper

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }
}

// MARK: - Profile Row

private struct ProfileRowView: View {
    let profile: AgentPermissionProfile
    let isActive: Bool
    let isBuiltin: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.4))
                    Text(profile.name)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular, design: .rounded))
                    if isBuiltin {
                        Text("built-in")
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.1), in: Capsule())
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isBuiltin {
                Button(action: onEdit) {
                    Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(isActive ? Color.accentColor.opacity(0.08) : Color.white.opacity(0.04))
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isActive ? Color.accentColor.opacity(0.25) : Color.clear, lineWidth: 1))
    }
}

// MARK: - Permission Row

private struct PermissionRowView: View {
    let category: AgentActionCategory
    let level: AgentAutonomyLevel
    let isEditable: Bool
    let onChange: (AgentAutonomyLevel) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: category.icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(category.displayName)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                Text(category.description)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            if isEditable {
                Picker("", selection: Binding(get: { level }, set: onChange)) {
                    ForEach(AgentAutonomyLevel.allCases, id: \.rawValue) { l in
                        Text(l.displayName).tag(l)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.system(size: 10))
                .frame(width: 130)
            } else {
                levelBadge(level)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func levelBadge(_ level: AgentAutonomyLevel) -> some View {
        let color: Color = {
            switch level {
            case .alwaysAllow: return .green
            case .agentDecides: return .blue
            case .alwaysAsk: return .orange
            case .never: return .red
            }
        }()
        return Text(level.displayName)
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Edit Profile Sheet

private struct EditProfileSheet: View {
    @State var profile: AgentPermissionProfile
    let onSave: (AgentPermissionProfile) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Profile").font(.system(size: 15, weight: .semibold, design: .rounded))

            HStack {
                Text("Name").font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                TextField("Profile name", text: $profile.name).textFieldStyle(.roundedBorder)
            }

            VStack(spacing: 4) {
                ForEach(AgentActionCategory.allCases, id: \.rawValue) { category in
                    PermissionRowView(
                        category: category,
                        level: profile.level(for: category),
                        isEditable: true,
                        onChange: { profile.setLevel($0, for: category) }
                    )
                }
            }

            HStack {
                Button("Cancel", action: onCancel).buttonStyle(.bordered)
                Spacer()
                Button("Save") { onSave(profile) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
