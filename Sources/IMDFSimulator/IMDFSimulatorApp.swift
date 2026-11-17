import SwiftUI

@main
struct IMDFSimulatorApp: App {
    @State private var model = SimulatorAppModel()

    var body: some Scene {
        WindowGroup("Indoor Sensor Simulator") {
            SimulatorContentView(model: model)
                .frame(minWidth: 1_100, minHeight: 700)
                .onAppear {
                    model.loadCommandLineIMDFIfNeeded()
                }
        }
        .defaultSize(width: 1_360, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("IMDF 열기…") {
                    model.chooseIMDF()
                }
                .keyboardShortcut("o")

                Button("시나리오 열기…") {
                    model.chooseScenario()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            CommandMenu("층 이동") {
                ForEach(1...9, id: \.self) { ordinal in
                    Button("\(ordinal)층으로 이동") {
                        guard let level = model.level(forFloorNumber: ordinal) else { return }
                        model.selectLevel(level)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(ordinal))), modifiers: .command)
                    .disabled(model.level(forFloorNumber: ordinal) == nil)
                }
            }

            CommandGroup(replacing: .saveItem) {
                Button("시나리오 저장…") {
                    model.saveScenario()
                }
                .keyboardShortcut("s")
                .disabled(model.scenario == nil)
            }
        }
    }
}
