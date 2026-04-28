import AppKit

// MARK: - App metadata

enum App {
    static let version = "0.1.0"
    static let nameJapanese = "簡単"
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    let editor = Editor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsStore.bootstrap()
        buildMenu()
        editor.setup()
        NSApp.activate()
    }

    @objc func showAboutPanel(_ sender: Any?) {
        let url = URL(string: "https://voidspooks.github.io/kantan")!
        let credits = NSMutableAttributedString(
            string: "voidspooks.github.io/kantan",
            attributes: [
                .link: url,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Kantan",
            .applicationVersion: App.nameJapanese,
            .version: App.version,
            .credits: credits,
        ])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return editor.promptSaveBeforeClose() ? .terminateNow : .terminateCancel
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(
            title: "About Kantan",
            action: #selector(AppDelegate.showAboutPanel(_:)),
            keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Hide Kantan",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Quit Kantan",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // File menu
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let newItem = NSMenuItem(title: "New", action: #selector(Editor.newDocument(_:)), keyEquivalent: "n")
        newItem.target = editor
        fileMenu.addItem(newItem)
        let openItem = NSMenuItem(title: "Open…", action: #selector(Editor.openDocument(_:)), keyEquivalent: "o")
        openItem.target = editor
        fileMenu.addItem(openItem)
        let openFolderItem = NSMenuItem(title: "Open Folder…",
                                        action: #selector(Editor.openFolder(_:)),
                                        keyEquivalent: "o")
        openFolderItem.target = editor
        openFolderItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(openFolderItem)
        fileMenu.addItem(.separator())
        let saveItem = NSMenuItem(title: "Save", action: #selector(Editor.saveDocument(_:)), keyEquivalent: "s")
        saveItem.target = editor
        fileMenu.addItem(saveItem)
        let saveAsItem = NSMenuItem(title: "Save As…", action: #selector(Editor.saveDocumentAs(_:)), keyEquivalent: "S")
        saveAsItem.target = editor
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAsItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"))
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Edit menu (so standard shortcuts work via responder chain)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        let findItem = NSMenuItem(title: "Find & Replace…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        findItem.tag = Int(NSTextFinder.Action.showReplaceInterface.rawValue)
        editMenu.addItem(findItem)
        editMenu.addItem(.separator())
        let increaseItem = NSMenuItem(title: "Increase Text Size",
                                      action: #selector(Editor.increaseTextSize(_:)),
                                      keyEquivalent: "+")
        increaseItem.target = editor
        editMenu.addItem(increaseItem)
        let decreaseItem = NSMenuItem(title: "Decrease Text Size",
                                      action: #selector(Editor.decreaseTextSize(_:)),
                                      keyEquivalent: "-")
        decreaseItem.target = editor
        editMenu.addItem(decreaseItem)
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Configuration menu
        let configItem = NSMenuItem()
        let configMenu = NSMenu(title: "Configuration")
        let highlightItem = NSMenuItem(title: "Syntax Highlighting",
                                       action: #selector(Editor.toggleSyntaxHighlighting(_:)),
                                       keyEquivalent: "")
        highlightItem.target = editor
        highlightItem.state = editor.syntaxHighlightingEnabled ? .on : .off
        editor.syntaxHighlightingMenuItem = highlightItem
        configMenu.addItem(highlightItem)

        // Language submenu — populated from Syntax.allCases so adding a new
        // language only requires editing the Syntax enum.
        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let languageSubmenu = NSMenu(title: "Language")
        let activeRaw = editor.activeSyntax?.rawValue ?? -1
        for syntax in Syntax.allCases {
            let item = NSMenuItem(title: syntax.displayName,
                                  action: #selector(Editor.selectLanguage(_:)),
                                  keyEquivalent: "")
            item.target = editor
            item.tag = syntax.rawValue
            item.state = (syntax.rawValue == activeRaw) ? .on : .off
            languageSubmenu.addItem(item)
        }
        languageItem.submenu = languageSubmenu
        editor.languageMenu = languageSubmenu
        configMenu.addItem(languageItem)

        let settingsItem = NSMenuItem(title: "Settings",
                                      action: #selector(Editor.openSettings(_:)),
                                      keyEquivalent: "")
        settingsItem.target = editor
        configMenu.addItem(settingsItem)

        configMenu.addItem(.separator())
        let toggleSidebarItem = NSMenuItem(title: "Toggle Sidebar",
                                           action: #selector(Editor.toggleSidebar(_:)),
                                           keyEquivalent: "b")
        toggleSidebarItem.target = editor
        configMenu.addItem(toggleSidebarItem)
        let refreshSidebarItem = NSMenuItem(title: "Refresh Sidebar",
                                            action: #selector(Editor.refreshSidebar(_:)),
                                            keyEquivalent: "")
        refreshSidebarItem.target = editor
        configMenu.addItem(refreshSidebarItem)

        configItem.submenu = configMenu
        mainMenu.addItem(configItem)

        NSApp.mainMenu = mainMenu
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
