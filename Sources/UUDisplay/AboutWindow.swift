import AppKit
import SwiftUI

private final class AboutModel: ObservableObject {
    @Published var debugLabels = DebugLabels.enabled
}

private struct AboutView: View {
    @ObservedObject var model: AboutModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("UU远程伴侣 · RustDesk 支持版").font(.title.bold())
            Text("改善 Mac 版 UU远程和 RustDesk 的显示体验，按预配置尺寸提供高清虚拟屏。")
            Text("原作者：AoyamaShou · MIT 许可证").foregroundStyle(.secondary)
            HStack {
                Link("本版本源码", destination: URL(string: "https://github.com/imink/UUyc-companion")!)
                Link("原项目与作者", destination: URL(string: "https://github.com/aoyamashou/UUyc-companion")!)
            }
            Divider()
            Text("开源致谢").font(.headline)
            Link("FreeDisplay · huberdf · MIT · 虚拟屏接口声明",
                 destination: URL(string: "https://github.com/huberdf/FreeDisplay")!)
            Link("PermissionFlow · 小弟调调 · MIT · 授权引导",
                 destination: URL(string: "https://github.com/jaywcjlove/PermissionFlow")!)
            Link("TourKit · Ram Patra · MIT · 功能介绍页",
                 destination: URL(string: "https://github.com/rampatra/TourKit")!)
            Divider()
            Toggle("显示 Debug 编号", isOn: Binding(get: { model.debugLabels }, set: {
                model.debugLabels = $0
                DebugLabels.setEnabled($0)
            }))
            Text("编号对照表保存在配置目录 ui-labels.txt；窗口前缀 S 设置、P 权限、T 功能介绍。")
                .font(.caption).foregroundStyle(.secondary)
            Text("本应用与 UU远程、RustDesk 及其开发商无关联。使用 macOS 私有显示接口，远程前请保存重要工作。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 520)
    }
}

enum AboutPage {
    private static let model = AboutModel()
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingView(rootView: AboutView(model: model))
            let created = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
            created.title = "关于 UU远程伴侣"
            created.contentView = host
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func render(to url: URL) {
        let view = NSHostingView(rootView: AboutView(model: model))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Log.info("无法渲染关于窗口")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        do {
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                Log.info("无法编码关于窗口图片")
                return
            }
            try data.write(to: url)
        } catch { Log.info("无法保存关于窗口图片：\(error.localizedDescription)") }
    }

    static func setUpDebugLabels() {
        DebugLabels.fileURL = ConfigStore.dir.appendingPathComponent("ui-labels.txt")
        DebugLabels.windowPrefix = { window in
            if window.className.contains("TourKit") { return "T" }
            if window.title.contains("权限") || window.title.contains("授权") { return "P" }
            if window.title.contains("设置") { return "S" }
            return nil
        }
        DebugLabels.start()
    }
}

enum DebugLabels {
    static var fileURL: URL?
    static var windowPrefix: (NSWindow) -> String? = { _ in nil }
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "debugLabelsEnabled") }
    private static var timer: Timer?
    private static var labels: [NSTextField] = []
    private static var previousMapping = ""
    private static var menuMapping: [String] = []

    static func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "debugLabelsEnabled")
        refresh()
    }

    static func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in refresh() }
    }

    static func decorate(_ menu: NSMenu) {
        guard enabled else { return }
        var index = 0
        menuMapping = []
        for item in menu.items where !item.isSeparatorItem {
            index += 1
            menuMapping.append("M\(index)\t\(item.title)")
            item.title = "[M\(index)] \(item.title)"
        }
    }

    private static func refresh() {
        labels.forEach { $0.removeFromSuperview() }
        labels = []
        guard enabled else { return }
        var mapping = menuMapping
        for window in NSApp.windows {
            guard window.isVisible, let prefix = windowPrefix(window), let root = window.contentView else { continue }
            var index = 0
            var visited = Set<ObjectIdentifier>()
            func visit(_ element: any NSAccessibilityProtocol, depth: Int = 0) {
                guard depth < 40, visited.insert(ObjectIdentifier(element)).inserted else { return }
                let roles: Set<NSAccessibility.Role> = [.button, .checkBox, .popUpButton, .textField,
                                                        .comboBox, .radioButton, .link, .slider]
                if let role = element.accessibilityRole(), roles.contains(role) {
                    index += 1
                    let id = "\(prefix)\(index)"
                    mapping.append("\(id)\t\(element.accessibilityLabel() ?? role.rawValue)")
                    let label = DebugBadge(labelWithString: id)
                    label.font = .monospacedSystemFont(ofSize: 9, weight: .bold)
                    label.textColor = .systemRed
                    label.setAccessibilityElement(false)
                    label.sizeToFit()
                    let frame = window.convertFromScreen(element.accessibilityFrame())
                    label.frame.origin = root.convert(frame, from: nil).origin
                    labels.append(label)
                }
                for child in element.accessibilityChildren() ?? [] {
                    if let child = child as? any NSAccessibilityProtocol { visit(child, depth: depth + 1) }
                }
            }
            visit(root)
            labels.filter { $0.superview == nil }.forEach { root.addSubview($0) }
        }
        let text = mapping.joined(separator: "\n")
        guard text != previousMapping, let fileURL else { return }
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            previousMapping = text
        } catch { Log.info("无法保存 Debug 编号：\(error.localizedDescription)") }
    }
}

private final class DebugBadge: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
