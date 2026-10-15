//
//  ContentView.swift
//  PTouchBridge
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: PrintController
    @State private var testText = "Hello from iOS"

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    statusRow
                    if let preview = controller.preview {
                        Image(uiImage: preview)
                            .interpolation(.none)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 80)
                            .border(Color.secondary)
                    }
                }

                Section {
                    if controller.printers.isEmpty {
                        Text("No printer connected")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(controller.printers, id: \.connectionID) { printer in
                        VStack(alignment: .leading) {
                            Text(printer.name)
                            Text("\(printer.modelNumber) · \(printer.serialNumber)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Pair a printer…") { controller.pairPrinter() }
                } header: {
                    Text("Printer")
                } footer: {
                    Text("Switch the PT-P910BT on. Once paired it connects by itself whenever it is on.")
                }

                Section("Test") {
                    TextField("Label text", text: $testText, axis: .vertical)
                    Button("Print test label") {
                        let lines = testText.components(separatedBy: "\n")
                        controller.submit(PrintRequest(content: .text(lines)))
                    }
                    .disabled(testText.isEmpty)
                }

                Section("From a web page") {
                    Text("ptouchbridge://print?text=Hello&x-success=https://example.com/done")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("P-Touch Bridge")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch controller.state {
        case .idle:
            Label("Waiting for a print request", systemImage: "printer")
        case .working(let what):
            HStack {
                ProgressView()
                Text(what)
            }
        case .done(let what):
            Label(what, systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .failed(let what):
            Label(what, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }
}
