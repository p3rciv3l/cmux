import Foundation
import Testing
@testable import CmuxSettings

@Suite("Stored shortcut JSON compatibility")
struct StoredShortcutJSONTests {
    @Test
    func duplicateWorkspaceBindingCanBeConfiguredAndUnbound() throws {
        let action = try #require(ShortcutAction(rawValue: "duplicateWorkspace"))
        #expect(action.defaultShortcut == StoredShortcut(first: ShortcutStroke(key: "d", control: true)))
        #expect(StoredShortcut.decodeFromJSON(try rawJSON(#""cmd+alt+n""#)) ==
                StoredShortcut(first: ShortcutStroke(key: "n", command: true, option: true)))
        #expect(StoredShortcut.decodeFromJSON(try rawJSON("null")) == .unbound)
    }

    @Test
    func tilingDefaultsAreBoundAndDoNotOverlapAnyOtherShortcut() throws {
        let actions = ShortcutAction.allCases.filter { $0.rawValue.hasPrefix("tiling") }
        #expect(actions.count == 13)
        for action in actions {
            let shortcut = try #require(action.defaultShortcut)
            #expect(shortcut != .unbound)
            for other in ShortcutAction.allCases where other != action {
                #expect(shortcut != other.defaultShortcut, "\(action.rawValue) overlaps \(other.rawValue)")
            }
        }
    }

    @Test(arguments: [
        (#""cmd+ctrl+t""#, StoredShortcut(first: ShortcutStroke(key: "t", command: true, control: true))),
        (#"["ctrl+b", "return"]"#, StoredShortcut(first: ShortcutStroke(key: "b", control: true), second: ShortcutStroke(key: "\r"))),
        (#"["cmd+t"]"#, StoredShortcut(first: ShortcutStroke(key: "t", command: true))),
        (#""space""#, StoredShortcut(first: ShortcutStroke(key: "space"))),
        (#"" ""#, StoredShortcut(first: ShortcutStroke(key: "space"))),
        (#""j""#, StoredShortcut(first: ShortcutStroke(key: "j"))),
    ])
    func readsDocumentedBindingForms(json: String, expected: StoredShortcut) throws {
        let raw = try rawJSON(json)
        #expect(StoredShortcut.decodeFromJSON(raw) == expected)
    }

    @Test(arguments: ["null", #""""#, #""none""#, #""clear""#, #""unbound""#, #""disabled""#, #"" NONE ""#, #""  ""#, "[]", #"["none"]"#])
    func readsExplicitUnbinding(json: String) throws {
        let raw = try rawJSON(json)
        #expect(StoredShortcut.decodeFromJSON(raw) == .unbound)
    }

    @Test(arguments: [
        ("command+option+control+shift+ArrowLeft", "←"),
        ("⌘+⌥+⌃+⇧+rightarrow", "→"),
        ("cmd+alt+ctl+shift+uparrow", "↑"),
        ("cmd+opt+ctrl+shift+down", "↓"),
        ("cmd+opt+ctrl+shift+enter", "\r"),
        ("cmd+opt+ctrl+shift+tab", "\t"),
        ("cmd+opt+ctrl+shift+<space>", "space"),
        ("cmd+opt+ctrl+shift+comma", ","),
        ("cmd+opt+ctrl+shift+dot", "."),
        ("cmd+opt+ctrl+shift+backslash", "\\"),
        ("cmd+opt+ctrl+shift+apostrophe", "'"),
        ("cmd+opt+ctrl+shift+grave", "`"),
        ("cmd+opt+ctrl+shift+hyphen", "-"),
        ("cmd+opt+ctrl+shift+plus", "="),
        ("cmd+opt+ctrl+shift+openbracket", "["),
        ("cmd+opt+ctrl+shift+closebracket", "]"),
        ("cmd+opt+ctrl+shift+mediavolumeup", "media.volumeUp"),
        ("cmd+opt+ctrl+shift+brightnessdown", "media.brightnessDown"),
        ("cmd+opt+ctrl+shift+media.playpause", "media.playPause"),
        ("cmd+opt+ctrl+shift+previoustrack", "media.previous"),
        ("cmd+opt+ctrl+shift+F20", "f20"),
    ])
    func readsExistingAppAliases(config: String, key: String) {
        #expect(StoredShortcut.decodeFromJSON(config) == StoredShortcut(
            first: ShortcutStroke(key: key, command: true, shift: true, option: true, control: true)
        ))
    }

    @Test func preservesExistingRecorderObjectsAndPhysicalKeys() throws {
        let shortcut = StoredShortcut(
            first: ShortcutStroke(key: "t", command: true, option: true, keyCode: 17),
            second: ShortcutStroke(key: "\r", shift: true, keyCode: 36)
        )
        #expect(StoredShortcut.decodeFromJSON(shortcut.encodeForJSON()) == shortcut)
        #expect(StoredShortcut.decodeFromUserDefaults(shortcut.encodeForUserDefaults()) == shortcut)
        let sparse = try rawJSON(#"{"first":{"key":"t","command":true,"keyCode":17},"second":{"key":"return"}}"#)
        #expect(StoredShortcut.decodeFromJSON(sparse) == StoredShortcut(
            first: ShortcutStroke(key: "t", command: true, keyCode: 17),
            second: ShortcutStroke(key: "return")
        ))
    }

    @Test(arguments: ["true", "42", "{}", #""cmd+""#, #""bogus+t""#, #""cmd+F21""#, #"["ctrl+b","t","x"]"#, #"["ctrl+b",false]"#, #"{"first":{"key":"t","command":true},"second":42}"#, #"{"first":{"key":"t","command":true,"keyCode":65536}}"#])
    func rejectsMalformedBindings(json: String) throws {
        let raw = try rawJSON(json)
        #expect(StoredShortcut.decodeFromJSON(raw) == nil)
    }

    @Test(arguments: [#""j""#, #"["j", "k"]"#, #"{"first":{"key":"j"}}"#])
    func sharedDecoderKeepsActionSpecificFirstStrokePolicy(json: String) throws {
        let raw = try rawJSON(json)
        #expect(StoredShortcut.decodeConfiguration(raw) == nil)
        #expect(StoredShortcut.decodeConfiguration(raw, allowBareFirstStroke: true)?.first.key == "j")
    }

    @Test(arguments: [#""space""#, #"["space", "j"]"#, #"{"first":{"key":"space"}}"#])
    func sharedDecoderPreservesBareSpaceException(json: String) throws {
        let raw = try rawJSON(json)
        #expect(StoredShortcut.decodeConfiguration(raw)?.first.key == "space")
    }

    @Test(arguments: [
        "tilingTile", "tilingMonocle", "tilingToggleLayout", "tilingFocusNext", "tilingFocusPrevious",
        "tilingMoveNext", "tilingMovePrevious", "tilingPromote", "tilingIncreaseMasterCount",
        "tilingDecreaseMasterCount", "tilingIncreaseMasterRatio", "tilingDecreaseMasterRatio", "tilingManual",
    ])
    func settingsMutationPreservesAllDocumentedAndUnknownOverrides(actionID: String) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shortcut-json-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("cmux.json")
        let objectShortcut = StoredShortcut(first: ShortcutStroke(key: "x", command: true, keyCode: 7))
        let initial: [String: Any] = [
            "app": ["language": "ja"],
            "shortcuts": [
                "when": ["tilingTile": "paneCount > 1"],
                "bindings": [
                    "tilingTile": "cmd+ctrl+t",
                    "tilingMonocle": ["ctrl+b", "m"],
                    "tilingManual": NSNull(),
                    "newSurface": "cmd+t",
                    "closeTab": objectShortcut.encodeForJSON(),
                    "futureActionNotInThisVersion": ["ctrl+b", "z"],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: initial).write(to: fileURL)
        let catalog = SettingCatalog()
        let store = JSONConfigStore(fileURL: fileURL)
        var expected: [String: StoredShortcut] = [
            "tilingTile": StoredShortcut(first: ShortcutStroke(key: "t", command: true, control: true)),
            "tilingMonocle": StoredShortcut(first: ShortcutStroke(key: "b", control: true), second: ShortcutStroke(key: "m")),
            "tilingManual": .unbound,
            "newSurface": StoredShortcut(first: ShortcutStroke(key: "t", command: true)),
            "closeTab": objectShortcut,
            "futureActionNotInThisVersion": StoredShortcut(first: ShortcutStroke(key: "b", control: true), second: ShortcutStroke(key: "z")),
        ]
        var recorded = await store.value(for: catalog.shortcuts.bindings)
        #expect(recorded == expected)
        #expect(store.snapshotValue(for: catalog.shortcuts.bindings) == expected)

        // This is the Settings recorder's actual read/modify/write path, including
        // keys that the current action catalog does not recognize.
        let replacement = StoredShortcut(first: ShortcutStroke(key: "y", command: true, control: true, keyCode: 16))
        recorded[actionID] = replacement
        try await store.set(recorded, for: catalog.shortcuts.bindings)
        expected[actionID] = replacement

        let reopened = JSONConfigStore(fileURL: fileURL)
        #expect(await reopened.value(for: catalog.shortcuts.bindings) == expected)
        #expect(reopened.snapshotValue(for: catalog.shortcuts.bindings) == expected)
        let persisted = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        #expect((persisted["app"] as? [String: String]) == ["language": "ja"])
        let shortcuts = try #require(persisted["shortcuts"] as? [String: Any])
        #expect((shortcuts["when"] as? [String: String]) == ["tilingTile": "paneCount > 1"])
    }

    private func rawJSON(_ json: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
    }
}
