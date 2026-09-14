import Bonsplit
import Foundation

enum CmuxSurfaceTabBarBuiltInAction: String, Codable, Sendable, CaseIterable, Hashable {
    case newWorkspace = "cmux.newWorkspace"
    case cloudVM = "cmux.cloudvm"
    case newTerminal = "cmux.newTerminal"
    case newBrowser = "cmux.newBrowser"
    case splitRight = "cmux.splitRight"
    case splitDown = "cmux.splitDown"
    case moveTabLeft = "cmux.moveTabLeft"
    case moveTabRight = "cmux.moveTabRight"
    case moveTabUp = "cmux.moveTabUp"
    case moveTabDown = "cmux.moveTabDown"

    init?(configID: String) {
        switch configID {
        case "cmux.newWorkspace", "newWorkspace":
            self = .newWorkspace
        case "cmux.cloudvm", "cmux.cloudVM", "cloudVM", "cloudvm",
             "cmux.newCloudVM", "cmux.newCloudVm", "newCloudVM", "newCloudVm",
             "cmux.startCloudVM", "cmux.startCloudVm", "startCloudVM", "startCloudVm":
            self = .cloudVM
        case "cmux.newTerminal", "newTerminal":
            self = .newTerminal
        case "cmux.newBrowser", "newBrowser":
            self = .newBrowser
        case "cmux.splitRight", "splitRight":
            self = .splitRight
        case "cmux.splitDown", "splitDown":
            self = .splitDown
        case "cmux.moveTabLeft", "moveTabLeft":
            self = .moveTabLeft
        case "cmux.moveTabRight", "moveTabRight":
            self = .moveTabRight
        case "cmux.moveTabUp", "moveTabUp":
            self = .moveTabUp
        case "cmux.moveTabDown", "moveTabDown":
            self = .moveTabDown
        default:
            return nil
        }
    }

    var configID: String {
        rawValue
    }

    var defaultIcon: String {
        switch self {
        case .newWorkspace:
            return "plus.square"
        case .cloudVM:
            return "cloud"
        case .newTerminal:
            return "terminal"
        case .newBrowser:
            return "globe"
        case .splitRight:
            return "square.split.2x1"
        case .splitDown:
            return "square.split.1x2"
        case .moveTabLeft:
            return "arrow.left.square"
        case .moveTabRight:
            return "arrow.right.square"
        case .moveTabUp:
            return "arrow.up.square"
        case .moveTabDown:
            return "arrow.down.square"
        }
    }

    var bonsplitAction: BonsplitConfiguration.SplitActionButton.Action? {
        switch self {
        case .newWorkspace, .cloudVM:
            return nil
        case .newTerminal:
            return .newTerminal
        case .newBrowser:
            return .newBrowser
        case .splitRight:
            return .splitRight
        case .splitDown:
            return .splitDown
        case .moveTabLeft, .moveTabRight, .moveTabUp, .moveTabDown:
            return nil
        }
    }
}
