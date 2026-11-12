import Foundation
import SwiftUI
import UIKit

// MARK: - 滚动模式
enum ScrollMode: String, Codable, CaseIterable {
    case constant   // 匀速
    case voice      // AI 跟读

    var title: String {
        switch self {
        case .constant: return "匀速滚动"
        case .voice: return "AI跟读"
        }
    }
}

// MARK: - 口播稿
struct Script: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String = "未命名"
    var text: String = ""
    var updatedAt: Date = Date()

    var charCount: Int { text.count }
}

// MARK: - 提词样式
struct PrompterStyle: Codable {
    var fontSize: Double = 28
    var lineSpacing: Double = 1.6
    var textColorHex: String = "#FFFFFF"
    var bgColorHex: String = "#000000"
    var bgOpacity: Double = 0.7
    var boxWidthRatio: Double = 0.9     // 字幕框宽 / 屏宽
    var boxHeightRatio: Double = 0.36   // 字幕框高 / 屏高
    var boxCenterXRatio: Double = 0.5   // 字幕框中心 X / 屏宽
    var boxCenterYRatio: Double = 0.62  // 字幕框中心 Y / 屏高
    var mode: ScrollMode = .constant
    var speed: Double = 1.0             // 匀速倍速 0.2 - 5
    var voiceSpeed: Double = 1.0        // 跟读速度 0.3 - 3
    var sensitivity: Double = 5.0       // 跟读灵敏度 1 - 10
}

// MARK: - 全局数据仓库
final class AppStore: ObservableObject {
    static let maxChars = 20000

    @Published var scripts: [Script] = []
    @Published var style = PrompterStyle()

    private let dir: URL
    private var scriptsFile: URL { dir.appendingPathComponent("scripts.json") }
    private var styleFile: URL { dir.appendingPathComponent("style.json") }

    init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = base
        load()
        if scripts.isEmpty {
            scripts = [Script(title: "示例口播稿",
                              text: "大家好，欢迎来到直播间。\n\n这是一份示例口播稿，你可以点右上角「编辑」把内容换成自己的。\n\n说话的时候字幕会跟着滚，停一下它就停住。")]
        }
    }

    func load() {
        if let d = try? Data(contentsOf: scriptsFile),
           let list = try? JSONDecoder().decode([Script].self, from: d) {
            scripts = list
        }
        if let d = try? Data(contentsOf: styleFile),
           let s = try? JSONDecoder().decode(PrompterStyle.self, from: d) {
            style = s
        }
    }

    func saveScripts() {
        if let d = try? JSONEncoder().encode(scripts) {
            try? d.write(to: scriptsFile, options: .atomic)
        }
    }

    func saveStyle() {
        if let d = try? JSONEncoder().encode(style) {
            try? d.write(to: styleFile, options: .atomic)
        }
    }

    func add(_ script: Script) {
        scripts.insert(script, at: 0)
        saveScripts()
    }

    func update(_ script: Script) {
        if let i = scripts.firstIndex(where: { $0.id == script.id }) {
            scripts[i] = script
        }
        saveScripts()
    }

    func delete(id: UUID) {
        scripts.removeAll { $0.id == id }
        saveScripts()
    }

    func script(id: UUID) -> Script? {
        scripts.first { $0.id == id }
    }
}

// MARK: - 颜色工具
extension Color {
    init(hex: String) {
        let ui = UIColor(hex: hex)
        self.init(uiColor: ui)
    }
}

extension UIColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else {
            self.init(white: 1, alpha: 1)
            return
        }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255.0,
                  green: CGFloat((v >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(v & 0xFF) / 255.0,
                  alpha: 1)
    }
}
