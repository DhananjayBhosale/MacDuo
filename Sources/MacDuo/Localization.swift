import Foundation
import FoldCore

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
    var shortName: String { self == .english ? "EN" : "中文" }

    static var initial: AppLanguage {
        if let saved = UserDefaults.standard.string(forKey: "language"),
           let language = AppLanguage(rawValue: saved) { return language }
        return Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
            ? .simplifiedChinese : .english
    }
}

enum AppLocalization {
    private static let chinese: [String: String] = [
        "Let your desktop follow the fold.": "让桌面跟随屏幕开合。",
        "Lid %.0f°": "开合 %.0f°",
        "Looking for sensor": "正在查找传感器",
        "Appearance": "外观",
        "Appearance: %@": "外观：%@",
        "Effect": "效果",
        "Effect: %@ — %@": "效果：%@ — %@",
        "Follow my lid": "跟随屏幕开合",
        "Preview angle": "预览角度",
        "Clears at": "恢复显示角度",
        "Clear when the lid is still": "屏幕静止时恢复桌面",
        "Clear after": "静止多久后恢复",
        "Move the lid to bring back the effect.": "移动屏幕即可再次显示效果。",
        "Perspective": "透视",
        "Softness": "柔化",
        "Shadow": "阴影",
        "Checking…": "正在检查…",
        "Pause Mac Duo": "暂停 Mac Duo",
        "Enable Mac Duo": "启用 Mac Duo",
        "Testing…": "正在测试…",
        "Test desktop · 8 sec": "测试桌面 · 8 秒",
        "Replay": "回放",
        "Open Screen Recording settings": "打开屏幕录制设置",
        "Replaying": "正在回放",
        "Live preview": "实时预览",
        "Manual preview": "手动预览",
        "to pause": "暂停",
        "anywhere": "全局可用",
        "Reduce Motion on": "已开启减弱动态效果",
        "On your Mac only": "仅在本机处理",
        "Language": "语言",
        "System": "跟随系统",
        "Light": "浅色",
        "Dark": "深色",
        "Duo": "Duo",
        "Roll": "卷轴",
        "Shutter": "百叶窗",
        "Flex": "弯曲",
        "Iris": "光圈",
        "The desktop swells around the hinge as the lid closes.": "合盖时，桌面围绕转轴放大并消失。",
        "The desktop curls into a roll that travels down to the hinge.": "桌面卷成卷轴并向下移动至转轴。",
        "Four rigid panels telescope behind each other into the hinge.": "四块面板依次收叠至转轴。",
        "One bowing flexible display collapses toward the hinge.": "柔性画面弯曲并收拢至转轴。",
        "Eight overlapping blades close an aperture above the hinge.": "八片重叠叶片在转轴上方闭合光圈。",
        "Preview is ready. Enable Mac Duo to use your desktop.": "预览已就绪。启用 Mac Duo 后即可应用到桌面。",
        "Lid sensor unavailable. Use the preview or reconnect the sensor.": "屏幕角度传感器不可用。请使用预览或重新连接传感器。",
        "Lid is still. Move it to animate again.": "屏幕已静止。移动屏幕即可再次显示动画。",
        "Following your lid. Close it gently to see the effect.": "正在跟随屏幕。轻轻合盖即可查看效果。",
        "This Mac does not have a supported Metal GPU.": "这台 Mac 没有受支持的 Metal GPU。",
        "No working lid angle sensor was found. The preview still works.": "未找到可用的屏幕角度传感器，但仍可使用预览。",
        "Checking screen access…": "正在检查屏幕访问权限…",
        "Screen access was not accepted. Allow the Mac Duo copy in Applications, then quit and reopen it. If its permission was already on for an older build, remove that old entry and add the current app.": "未获得屏幕访问权限。请允许“应用程序”中的 Mac Duo，然后退出并重新打开。如果旧版本已经获得权限，请先移除旧记录，再添加当前应用。",
        "Paused. Your desktop is clear.": "已暂停，桌面已恢复。",
        "Eight-second desktop test. Press Esc to stop.": "正在进行 8 秒桌面测试。按 Esc 停止。",
        "Testing the overlay with generated artwork. Esc stops the test.": "正在用生成的画面测试覆盖层。按 Esc 停止。",
        "Synthetic overlay test completed.": "模拟覆盖层测试已完成。",
        "Desktop test finished. Following your lid.": "桌面测试已完成，正在跟随屏幕。",
        "Waiting for the lid sensor. Your desktop is clear.": "正在等待屏幕角度传感器，桌面已恢复。",
        "Mac Duo needs an active, unmirrored built-in display.": "Mac Duo 需要处于启用状态且未镜像的内置显示器。",
        "Could not register Esc. Close other keyboard utilities and try again.": "无法注册 Esc 键。请关闭其他键盘工具后重试。",
        "Stopped with the keyboard shortcut. Your desktop is clear.": "已通过键盘快捷键停止，桌面已恢复。",
        "Global pause shortcut unavailable. Esc will remain available during the effect.": "全局暂停快捷键不可用。显示效果时仍可使用 Esc。",
        "Mac Duo — your desktop follows your lid": "Mac Duo — 让桌面跟随屏幕开合",
        "Lid angle: %.0f°": "屏幕开合角度：%.0f°",
        "Sensor unavailable": "传感器不可用",
        "Open Mac Duo…": "打开 Mac Duo…",
        "Test desktop for 8 seconds": "测试桌面 8 秒",
        "Quit Mac Duo": "退出 Mac Duo"
    ]

    private static let chinesePrefixes: [(String, String)] = [
        ("Capture stopped: ", "桌面捕获已停止："),
        ("Could not enable screen capture: ", "无法启用屏幕捕获："),
        ("Cannot capture the desktop: ", "无法捕获桌面：")
    ]

    static func text(_ key: String, language: AppLanguage) -> String {
        language == .simplifiedChinese ? chinese[key] ?? key : key
    }

    static func format(_ key: String, language: AppLanguage, _ arguments: CVarArg...) -> String {
        String(format: text(key, language: language), arguments: arguments)
    }

    static func dynamic(_ english: String, language: AppLanguage) -> String {
        guard language == .simplifiedChinese else { return english }
        if let translation = chinese[english] { return translation }
        for (prefix, translatedPrefix) in chinesePrefixes where english.hasPrefix(prefix) {
            return translatedPrefix + english.dropFirst(prefix.count)
        }
        return english
    }
}

extension FoldEffect {
    func localizedTitle(_ language: AppLanguage) -> String {
        AppLocalization.text(title, language: language)
    }

    func localizedSummary(_ language: AppLanguage) -> String {
        AppLocalization.text(summary, language: language)
    }
}
