import SwiftUI
import Combine

private final class KeybotPreferencesModel: ObservableObject {
    @Published var selectedID: UUID?
    @Published var editingMapping: KeyMapping?
    @Published var showingResetAlert = false
    @Published var showingExclusions = false
}

struct KeybotPreferencesView: View {
    @ObservedObject private var store = KeybotConfigStore.shared
    @StateObject private var vm = KeybotPreferencesModel()

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            mappingList
            bottomBar
        }
        .frame(minWidth: 620, minHeight: 440)
        .sheet(item: $vm.editingMapping) { m in
            MappingEditView(mapping: m) { saved in
                if store.mappings.contains(where: { $0.id == saved.id }) {
                    if let idx = store.mappings.firstIndex(where: { $0.id == saved.id }) {
                        store.mappings[idx] = saved
                    }
                } else {
                    store.mappings.append(saved)
                    vm.selectedID = saved.id
                }
            }
        }
        .sheet(isPresented: $vm.showingExclusions) {
            KeybotGlobalExclusionsView()
        }
        .alert("Restore Defaults?", isPresented: $vm.showingResetAlert) {
            Button("Restore", role: .destructive) { store.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all custom rules and restore the built-in default mappings.")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Image(systemName: "keyboard")
                .foregroundStyle(.secondary)
            Text("键位映射 (Keybot)")
                .font(.headline)
            Spacer()
            Toggle(
                "启用键位映射",
                isOn: Binding(
                    get: { store.globalSettings.isEnabled },
                    set: { KeybotEventTap.shared.setEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - List

    private var mappingList: some View {
        List(selection: $vm.selectedID) {
            ForEach(store.mappings) { mapping in
                KeybotMappingRowView(mapping: mapping, isSelected: vm.selectedID == mapping.id)
                    .tag(mapping.id)
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            }
            .onMove { store.mappings.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { store.mappings.remove(atOffsets: $0) }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .onDoubleClick {
            if let id = vm.selectedID, let m = store.mappings.first(where: { $0.id == id }) {
                beginEdit(m)
            }
        }
        .contextMenu(forSelectionType: UUID.self, menu: { ids in
            if let id = ids.first, let m = store.mappings.first(where: { $0.id == id }) {
                Button("Edit…") { beginEdit(m) }
                Divider()
                Button("Delete", role: .destructive) {
                    store.mappings.removeAll { $0.id == id }
                    vm.selectedID = nil
                }
            }
        })
    }

    // MARK: - Bottom Bar (Finder-style)

    private var bottomBar: some View {
        HStack(spacing: 0) {
            // Grouped +/- buttons
            HStack(spacing: 0) {
                Button { addNew() } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Add rule")

                Divider().frame(height: 14)

                Button { deleteSelected() } label: {
                    Image(systemName: "minus")
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(vm.selectedID == nil)
                .help("Delete selected rule")
            }
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
            )

            Divider().frame(height: 14).padding(.horizontal, 6)

            Button { editSelected() } label: {
                Image(systemName: "pencil")
                    .frame(width: 28, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(vm.selectedID == nil)
            .help("Edit rule")

            Spacer()

            Button("Excluded Apps…") { vm.showingExclusions = true }
                .buttonStyle(.borderless)
                .foregroundStyle(store.globalSettings.excludedBundleIDs.isEmpty ? .secondary : Color.orange)

            Divider().frame(height: 14).padding(.horizontal, 6)

            Button("Restore Defaults") { vm.showingResetAlert = true }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Actions

    private func addNew() {
        vm.editingMapping = KeyMapping(
            name: "New Rule",
            trigger: KeyTrigger(keyCode: 0, modifiers: [.control]),
            action: .remap(keyCode: 0, modifiers: [.command])
        )
    }

    private func editSelected() {
        guard let id = vm.selectedID, let m = store.mappings.first(where: { $0.id == id }) else { return }
        beginEdit(m)
    }

    private func beginEdit(_ m: KeyMapping) {
        vm.editingMapping = m
    }

    private func deleteSelected() {
        guard let id = vm.selectedID else { return }
        store.mappings.removeAll { $0.id == id }
        vm.selectedID = nil
    }
}

// MARK: - Row

private struct KeybotMappingRowView: View {
    @ObservedObject private var store = KeybotConfigStore.shared
    let mapping: KeyMapping
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(mapping.trigger.displayString)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .foregroundStyle(isSelected ? Color.white : (mapping.enabled ? Color.primary : Color.secondary))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background { badgeBackground }
                .frame(minWidth: 52, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(mapping.name)
                    .font(.body)
                    .foregroundStyle(mapping.enabled ? Color.primary : Color.secondary)

                Text(mapping.action.displayString)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }

            Spacer(minLength: 8)

            conditionBadge

            Toggle("", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .opacity(mapping.enabled ? 1 : 0.55)
    }

    @ViewBuilder
    private var badgeBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.2))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
                )
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.textBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 1.5, x: 0, y: 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
                )
        }
    }

    @ViewBuilder
    private var conditionBadge: some View {
        switch mapping.condition {
        case .all:
            Text("All Apps")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        case .only(let ids) where ids.isEmpty:
            Text("No Apps")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        case .only(let ids):
            Text("\(ids.count) app\(ids.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(Color(NSColor.controlAccentColor))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color(NSColor.controlAccentColor).opacity(0.12)))
        case .except(let ids) where ids.isEmpty:
            Text("All Apps")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        case .except(let ids):
            Text("Except \(ids.count)")
                .font(.caption)
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.orange.opacity(0.12)))
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { mapping.enabled },
            set: { val in
                if let idx = store.mappings.firstIndex(where: { $0.id == mapping.id }) {
                    store.mappings[idx].enabled = val
                }
            }
        )
    }
}

// MARK: - Global Exclusions Sheet

private final class KeybotExclusionsModel: ObservableObject {
    @Published var text: String = ""
}

private struct KeybotGlobalExclusionsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = KeybotConfigStore.shared
    @StateObject private var vm = KeybotExclusionsModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "nosign")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Excluded Apps")
                        .font(.headline)
                    Text("All remapping rules are skipped for these apps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Bundle IDs (one per line)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $vm.text)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 140)
                        .padding(4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
                        )

                    if vm.text.isEmpty {
                        Text("e.g.\ncom.apple.Terminal\ncom.googlecode.iterm2")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Color(NSColor.placeholderTextColor))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
            }
            .padding(20)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            vm.text = store.globalSettings.excludedBundleIDs.joined(separator: "\n")
        }
    }

    private func save() {
        let ids = vm.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        store.globalSettings.excludedBundleIDs = ids
        dismiss()
    }
}
