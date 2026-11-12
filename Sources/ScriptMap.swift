import UIKit

/// 把「稿子里的第 N 个字」换算成「屏幕上的纵向位置」，用于语音跟读时精确滚动
final class ScriptMap {
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer(size: .zero)
    private let textStorage: NSTextStorage
    private let characterCount: Int

    init(attributed: NSAttributedString, width: CGFloat) {
        textStorage = NSTextStorage(attributedString: attributed)
        textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)
        characterCount = max(attributed.length, 1)
    }

    func y(forCharacter index: Int) -> CGFloat {
        let idx = min(max(index, 0), characterCount - 1)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: idx, length: 1),
                                                  actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        return rect.minY
    }
}
