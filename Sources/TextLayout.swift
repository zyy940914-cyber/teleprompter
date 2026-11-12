import SwiftUI
import UIKit

// MARK: - 文字排版计算（屏幕与画中画共用同一套参数，保证两边看起来一致）
struct TextLayout {
    let attributed: NSAttributedString
    let width: CGFloat
    let textHeight: CGFloat
    let topPad: CGFloat
    let bottomPad: CGFloat

    var totalHeight: CGFloat { topPad + textHeight + bottomPad }

    static func make(text: String, style: PrompterStyle, boxSize: CGSize) -> TextLayout {
        let font = UIFont.systemFont(ofSize: CGFloat(style.fontSize), weight: .semibold)
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = CGFloat(style.lineSpacing)
        para.lineBreakMode = .byWordWrapping
        let sidePad = CGFloat(style.fontSize) * 0.6
        let width = max(boxSize.width - sidePad * 2, 40)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(hex: style.textColorHex),
            .paragraphStyle: para
        ]
        let body = text.isEmpty ? " " : text
        let attr = NSAttributedString(string: body, attributes: attrs)
        let rect = attr.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading],
                                     context: nil)
        return TextLayout(attributed: attr,
                          width: width,
                          textHeight: ceil(rect.height),
                          topPad: boxSize.height * 0.5,
                          bottomPad: boxSize.height * 0.8)
    }
}

// MARK: - 屏幕上的字幕文字（用 UILabel 保证排版与排版计算一致）
struct TextLabel: UIViewRepresentable {
    let attributed: NSAttributedString
    let width: CGFloat

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.backgroundColor = .clear
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.attributedText = attributed
        label.preferredMaxLayoutWidth = width
    }
}
