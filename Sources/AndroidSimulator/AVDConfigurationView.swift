import SwiftUI
import SimulatorKit

struct AVDConfigurationView: View {
    @EnvironmentObject var model: AppModel
    let request: AVDConfigurationEditRequest
    @State private var displayName: String
    @State private var memory: String
    @State private var cores: String
    @State private var width: String
    @State private var height: String
    @State private var density: String

    init(request: AVDConfigurationEditRequest) {
        self.request = request
        let values = request.document.configuration
        _displayName = State(initialValue: values.displayName)
        _memory = State(initialValue: String(values.memoryMB))
        _cores = State(initialValue: String(values.cpuCores))
        _width = State(initialValue: String(values.width))
        _height = State(initialValue: String(values.height))
        _density = State(initialValue: String(values.density))
    }

    private var configuration: AVDConfiguration? {
        func number(_ value: String) -> Int? { Int(value.trimmingCharacters(in: .whitespaces)) }
        guard let memory = number(memory), let cores = number(cores),
              let width = number(width), let height = number(height), let density = number(density) else { return nil }
        return AVDConfiguration(displayName: displayName, memoryMB: memory, cpuCores: cores,
                                width: width, height: height, density: density)
    }

    private var validationError: String? {
        guard let configuration else { return "Enter whole numbers for memory, CPU cores, and display settings." }
        return configuration.validationError
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 28)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Edit AVD Configuration").font(.title2.weight(.semibold))
                    Text("Changes apply the next time this phone starts.").foregroundStyle(.secondary)
                }
            }
            Form {
                Section("Phone") {
                    TextField("Device name", text: $displayName)
                    LabeledContent("System image", value: "Android API \(request.avd.apiLevel) · \(request.avd.architecture)")
                }
                Section("Resources") {
                    numberField("Memory", value: $memory, unit: "MB")
                    numberField("CPU cores", value: $cores, unit: "cores")
                }
                Section("Display") {
                    numberField("Width", value: $width, unit: "pixels")
                    numberField("Height", value: $height, unit: "pixels")
                    numberField("Density", value: $density, unit: "dpi")
                }
            }.formStyle(.grouped).frame(height: 350).disabled(model.isSavingConfiguration)
            if let error = model.configurationError ?? validationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Your installed apps and phone data are kept. Changing hardware settings may cause Android to cold boot.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { model.editingConfiguration = nil }
                    .keyboardShortcut(.cancelAction).disabled(model.isSavingConfiguration)
                Spacer()
                if model.isSavingConfiguration { ProgressView().controlSize(.small) }
                Button(model.isSavingConfiguration ? "Saving…" : "Save Changes") {
                    guard let configuration else { return }
                    Task { await model.saveAVDConfiguration(configuration) }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.isSavingConfiguration || validationError != nil || configuration == request.document.configuration)
            }
        }.padding(24).frame(width: 550)
            .interactiveDismissDisabled(model.isSavingConfiguration)
    }

    private func numberField(_ title: String, value: Binding<String>, unit: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField(title, text: value).labelsHidden().multilineTextAlignment(.trailing).frame(width: 85)
                Text(unit).foregroundStyle(.secondary).frame(width: 42, alignment: .leading)
            }
        }
    }
}
