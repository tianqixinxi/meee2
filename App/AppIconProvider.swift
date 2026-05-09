import AppKit

enum AppIconProvider {
    static func installApplicationIcon() {
        guard let icon = loadIcon() else {
            NSLog("[AppIconProvider] AppIcon not found")
            return
        }
        NSApp.applicationIconImage = icon
        installDockTileIcon(icon)
    }

    static func installDockTileIcon() {
        guard let icon = loadIcon() ?? NSApp.applicationIconImage else {
            NSLog("[AppIconProvider] Dock AppIcon not found")
            return
        }
        NSApp.applicationIconImage = icon
        installDockTileIcon(icon)
    }

    static func loadIcon() -> NSImage? {
        if let icon = renderStatusBarSymbolIcon() {
            return icon
        }

        if let icon = NSImage(named: "AppIcon") {
            return icon
        }

        for url in candidateIconURLs() {
            if let icon = NSImage(contentsOf: url) {
                return icon
            }
        }

        return nil
    }

    private static func renderStatusBarSymbolIcon() -> NSImage? {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 82, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: .white))
        guard let symbol = NSImage(
            systemSymbolName: "brain.head.profile",
            accessibilityDescription: "meee2"
        )?.withSymbolConfiguration(symbolConfig) else {
            return nil
        }

        let size = NSSize(width: 128, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 28, yRadius: 28).fill()

        symbol.isTemplate = false
        let symbolRect = NSRect(x: 23, y: 18, width: 82, height: 88)
        symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)

        return image
    }

    private static func installDockTileIcon(_ icon: NSImage) {
        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        imageView.image = icon
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.clear.cgColor
        NSApp.dockTile.contentView = imageView
        NSApp.dockTile.display()
    }

    private static func candidateIconURLs() -> [URL] {
        var urls: [URL] = []
        if let bundleURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            urls.append(bundleURL)
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        urls.append(cwd.appendingPathComponent("Resources/AppIcon.icns"))
        urls.append(cwd.appendingPathComponent("Resources/AppIcon.source.png"))

        var dir = executableDirectory()
        for _ in 0..<10 {
            urls.append(dir.appendingPathComponent("Resources/AppIcon.icns"))
            urls.append(dir.appendingPathComponent("Resources/AppIcon.source.png"))
            dir.deleteLastPathComponent()
        }

        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return FileManager.default.fileExists(atPath: path)
        }
    }

    private static func executableDirectory() -> URL {
        let arg0 = CommandLine.arguments.first ?? ""
        if arg0.hasPrefix("/") {
            return URL(fileURLWithPath: arg0).deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(arg0)
            .standardizedFileURL
            .deletingLastPathComponent()
    }
}
