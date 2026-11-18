import AppKit
import Carbon
import SwiftUI

/// 메뉴의 키 동등 처리와 별도로, 활성 시뮬레이터 창에서 층 이동 키를 받는다.
struct SimulatorFloorKeyboardShortcuts: NSViewRepresentable {
    let selectFloor: @MainActor (Int) -> Bool

    func makeNSView(context: Context) -> KeyboardView {
        let view = KeyboardView()
        view.selectFloor = selectFloor
        return view
    }

    func updateNSView(_ view: KeyboardView, context: Context) {
        view.selectFloor = selectFloor
    }

    static func dismantleNSView(_ view: KeyboardView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class KeyboardView: NSView {
        var selectFloor: (@MainActor (Int) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // AppKit local event monitors always run on the main thread.
                let handled = MainActor.assumeIsolated {
                    guard let self, let window = self.window,
                          window.isKeyWindow, event.window === window,
                          window.attachedSheet == nil,
                          event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                          let number = Self.floorNumber(for: event) else { return false }
                    // 처리한 키를 메뉴에 다시 전달하지 않아 층 이동이 중복 실행되지 않는다.
                    return self.selectFloor?(number) == true
                }
                return handled ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private static func floorNumber(for event: NSEvent) -> Int? {
            if let characters = event.charactersIgnoringModifiers,
               let number = Int(characters), (1...9).contains(number) { return number }
            // 다른 입력 소스에서도 숫자 행·숫자 패드의 동일한 물리 키를 지원한다.
            switch Int(event.keyCode) {
            case kVK_ANSI_1, kVK_ANSI_Keypad1: return 1
            case kVK_ANSI_2, kVK_ANSI_Keypad2: return 2
            case kVK_ANSI_3, kVK_ANSI_Keypad3: return 3
            case kVK_ANSI_4, kVK_ANSI_Keypad4: return 4
            case kVK_ANSI_5, kVK_ANSI_Keypad5: return 5
            case kVK_ANSI_6, kVK_ANSI_Keypad6: return 6
            case kVK_ANSI_7, kVK_ANSI_Keypad7: return 7
            case kVK_ANSI_8, kVK_ANSI_Keypad8: return 8
            case kVK_ANSI_9, kVK_ANSI_Keypad9: return 9
            default: return nil
            }
        }
    }
}
