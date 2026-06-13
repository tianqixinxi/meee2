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
        if let icon = loadBundledAppIcon() {
            return icon
        }

        if let icon = renderStatusBarMonogramIcon() {
            return icon
        }

        return nil
    }

    static func loadStatusBarIcon() -> NSImage? {
        if let icon = loadBundledStatusTemplateIcon() {
            return prepareStatusBarTemplateIcon(icon)
        }

        return renderStatusBarTemplateFallbackIcon()
    }

    private static func loadBundledAppIcon() -> NSImage? {
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

    private static func loadBundledStatusTemplateIcon() -> NSImage? {
        if let icon = NSImage(named: statusTemplateIconName) {
            return icon
        }

        let reps = candidateStatusTemplateIconURLs().compactMap { url -> NSBitmapImageRep? in
            guard
                let data = try? Data(contentsOf: url),
                let rep = NSBitmapImageRep(data: data)
            else {
                return nil
            }
            rep.size = statusTemplateIconSize
            return rep
        }

        guard !reps.isEmpty else { return nil }
        let image = NSImage(size: statusTemplateIconSize)
        reps.forEach { image.addRepresentation($0) }
        return image
    }

    private static func prepareStatusBarTemplateIcon(_ source: NSImage) -> NSImage {
        let icon = NSImage(size: statusTemplateIconCanvasSize)
        icon.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: statusTemplateIconDestinationRect,
            from: statusTemplateIconOpaqueRect,
            operation: .sourceOver,
            fraction: 1
        )
        icon.unlockFocus()
        icon.isTemplate = true
        icon.accessibilityDescription = "Meee2"
        return icon
    }

    private static func renderStatusBarTemplateFallbackIcon() -> NSImage? {
        let image = NSImage(size: statusTemplateIconCanvasSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.black.setFill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .bold),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ]
        ("M" as NSString).draw(
            in: NSRect(x: 0, y: 1, width: statusTemplateIconCanvasSize.width, height: statusTemplateIconCanvasSize.height),
            withAttributes: attributes
        )
        image.isTemplate = true
        image.accessibilityDescription = "Meee2"
        return image
    }

    private static func renderStatusBarMonogramIcon() -> NSImage? {
        let size = NSSize(width: 128, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 28, yRadius: 28).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 82, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        ("M" as NSString).draw(
            in: NSRect(x: 0, y: 16, width: size.width, height: 96),
            withAttributes: attributes
        )
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

    private static func candidateStatusTemplateIconURLs() -> [URL] {
        let filenames = [
            "\(statusTemplateIconName).png",
            "\(statusTemplateIconName)@2x.png",
            "\(statusTemplateIconName)@3x.png"
        ]
        var urls: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            urls.append(contentsOf: filenames.map { resourceURL.appendingPathComponent($0) })
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        urls.append(contentsOf: filenames.map { cwd.appendingPathComponent("Resources").appendingPathComponent($0) })

        var dir = executableDirectory()
        for _ in 0..<10 {
            urls.append(contentsOf: filenames.map { dir.appendingPathComponent("Resources").appendingPathComponent($0) })
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

    private static let statusTemplateIconName = "meee2StatusTemplate"
    private static let statusTemplateIconSize = NSSize(width: 22, height: 22)
    private static let statusTemplateIconCanvasSize = NSSize(width: 24, height: 18)
    private static let statusTemplateIconOpaqueRect = NSRect(x: 5, y: 8, width: 12, height: 7)
    private static let statusTemplateIconDestinationRect = NSRect(x: 1, y: 2.5, width: 22, height: 13)
}
