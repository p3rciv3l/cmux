import Bonsplit

extension KeyboardShortcutSettings {
    static let tilingActions = Action.allCases.filter { $0.tilingAction != nil }
}

extension KeyboardShortcutSettings.Action {
    /// Maps every tiling control to the workspace's shared mutation path.
    var tilingAction: PaneTilingAction? {
        switch self {
        case .tilingTile: return .tile
        case .tilingMonocle: return .monocle
        case .tilingToggleLayout: return .toggleLayout
        case .tilingFocusNext: return .focusNext
        case .tilingFocusPrevious: return .focusPrevious
        case .tilingMoveNext: return .moveNext
        case .tilingMovePrevious: return .movePrevious
        case .tilingPromote: return .promote
        case .tilingIncreaseMasterCount: return .increaseMasterCount
        case .tilingDecreaseMasterCount: return .decreaseMasterCount
        case .tilingIncreaseMasterRatio: return .increaseMasterRatio
        case .tilingDecreaseMasterRatio: return .decreaseMasterRatio
        case .tilingManual: return .manual
        default: return nil
        }
    }

    var tilingCommandID: String { "palette.\(rawValue)" }
}
