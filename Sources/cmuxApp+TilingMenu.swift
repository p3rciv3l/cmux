import SwiftUI

extension cmuxApp {
    func tilingCommandMenu() -> some View {
        Menu(String(localized: "menu.view.tiling", defaultValue: "Pane Tiling")) {
            ForEach(KeyboardShortcutSettings.tilingActions) { action in
                splitCommandButton(title: action.label, shortcut: menuShortcut(for: action)) {
                    guard let tilingAction = action.tilingAction else { return }
                    _ = activeTabManager.selectedWorkspace?.performTilingAction(tilingAction)
                }
            }
        }
        .disabled(activeTabManager.selectedWorkspace == nil)
    }
}
