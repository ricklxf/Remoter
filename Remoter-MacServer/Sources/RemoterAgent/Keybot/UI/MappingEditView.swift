import SwiftUI
import Combine

private final class MappingEditModel: ObservableObject {
    let originalID: UUID
    let originalEnabled: Bool
    let originalUseSyntheticRepost: Bool

    @Published var name: String
    @Published var trigger: KeyTrigger
    @Published var actionType: MappingEditView.ActionType
    @Published var targetKeyCode: Int
    @Published var targetModifiers: [ModifierKey]
    @Published var conditionType: MappingEditView.ConditionType
    @Published var bundleIDsText: String
    @Published var requireTextSelection: Bool

    init(mapping: KeyMapping) {
        self.originalID = mapping.id
        self.originalEnabled = mapping.enabled
        self.originalUseSyntheticRepost = mapping.useSyntheticRepost
        self.name = mapping.name
        self.trigger = mapping.trigger
        self.requireTextSelection = mapping.requireTextSelection

        switch mapping.action {
        case .lockAndSleep:
            self.actionType = .lockAndSleep
            self.targetKeyCode = 0
            self.targetModifiers = []
        case .remap(let kc, let mods):
            self.actionType = .remap
            self.targetKeyCode = kc
            self.targetModifiers = mods
        }

        switch mapping.condition {
        case .all:
            self.conditionType = .all
            self.bundleIDsText = ""
        case .only(let ids):
            self.conditionType = .only
            self.bundleIDsText = ids.joined(separator: "\n")
        case .except(let ids):
            self.conditionType = .except
            self.bundleIDsText = ids.joined(separator: "\n")
        }
    }
}

struct MappingEditView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (KeyMapping) -> Void

    @StateObject private var vm: MappingEditModel

    enum ActionType: String, CaseIterable {
        case remap = "Remap Key"
        case lockAndSleep = "Lock & Sleep"
    }

    enum ConditionType: String, CaseIterable {
        case all = "All Apps"
        case only = "Specific Apps"
        case except = "Except Apps"
    }

    init(mapping: KeyMapping, onSave: @escaping (KeyMapping) -> Void) {
        self.onSave = onSave
        _vm = StateObject(wrappedValue: MappingEditModel(mapping: mapping))
    }

    private var targetTrigger: Binding<KeyTrigger> {
        Binding(
            get: { KeyTrigger(keyCode: vm.targetKeyCode, modifiers: vm.targetModifiers) },
            set: { vm.targetKeyCode = $0.keyCode; vm.targetModifiers = $0.modifiers }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "keyboard")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(vm.name.isEmpty ? "New Rule" : vm.name)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    // Name
                    settingSection(title: "Rule Name") {
                        TextField("Name", text: $vm.name)
                            .textFieldStyle(.plain)
                            .font(.body)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
                            )
                    }

                    // Trigger
                    settingSection(title: "Trigger Key") {
                        KeyRecorderView(trigger: $vm.trigger)
                    }

                    // Action
                    settingSection(title: "Action") {
                        VStack(spacing: 8) {
                            Picker("", selection: $vm.actionType) {
                                ForEach(ActionType.allCases, id: \.self) {
                                    Text($0.rawValue).tag($0)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            if vm.actionType == .remap {
                                KeyRecorderView(trigger: targetTrigger)

                                Toggle("Only if text is selected", isOn: $vm.requireTextSelection)
                                    .toggleStyle(.checkbox)
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    // Condition
                    settingSection(title: "Scope") {
                        VStack(spacing: 8) {
                            Picker("", selection: $vm.conditionType) {
                                ForEach(ConditionType.allCases, id: \.self) {
                                    Text($0.rawValue).tag($0)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            if vm.conditionType == .only || vm.conditionType == .except {
                                ZStack(alignment: .topLeading) {
                                    TextEditor(text: $vm.bundleIDsText)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(height: 80)
                                        .padding(4)
                                        .background(Color(NSColor.controlBackgroundColor))
                                        .clipShape(RoundedRectangle(cornerRadius: 7))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 7)
                                                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
                                        )

                                    if vm.bundleIDsText.isEmpty {
                                        Text("One Bundle ID per line\ne.g. com.apple.finder")
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundStyle(Color(NSColor.placeholderTextColor))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 12)
                                            .allowsHitTesting(false)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            // Buttons
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func settingSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        let action: MappingAction = vm.actionType == .lockAndSleep
            ? .lockAndSleep
            : .remap(keyCode: vm.targetKeyCode, modifiers: vm.targetModifiers)

        let condition: AppCondition
        let ids = vm.bundleIDsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        switch vm.conditionType {
        case .all:    condition = .all
        case .only:   condition = .only(ids)
        case .except: condition = .except(ids)
        }

        onSave(KeyMapping(
            id: vm.originalID,
            name: vm.name.trimmingCharacters(in: .whitespaces),
            enabled: vm.originalEnabled,
            trigger: vm.trigger,
            action: action,
            condition: condition,
            requireTextSelection: vm.actionType == .remap && vm.requireTextSelection,
            useSyntheticRepost: vm.originalUseSyntheticRepost
        ))
        dismiss()
    }
}
