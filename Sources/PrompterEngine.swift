import SwiftUI
import QuartzCore

/// 滚动引擎：匀速模式按速度推进；AI 跟读模式追向「已经读到的位置」
final class PrompterEngine: ObservableObject {
    @Published var offset: CGFloat = 0
    @Published var isPlaying = false
    @Published var progress: Double = 0

    var maxOffset: CGFloat = 1
    var speed: Double = 1
    var mode: ScrollMode = .constant

    /// 语音跟读的目标位置（由识别结果换算而来）
    var followTarget: CGFloat?

    private var link: CADisplayLink?
    private var lastTime: CFTimeInterval = 0
    private let basePointsPerSecond: Double = 60

    func start() {
        guard !isPlaying else { return }
        isPlaying = true
        lastTime = 0
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func pause() {
        isPlaying = false
        link?.invalidate()
        link = nil
    }

    func toggle() {
        isPlaying ? pause() : start()
    }

    func reset() {
        offset = 0
        progress = 0
        followTarget = nil
    }

    func seek(toProgress p: Double) {
        offset = maxOffset * CGFloat(min(max(p, 0), 1))
        progress = maxOffset > 0 ? Double(offset / maxOffset) : 0
        if mode == .voice { followTarget = offset }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastTime == 0 { lastTime = now }
        let dt = min(now - lastTime, 0.1)
        lastTime = now

        if mode == .voice {
            // 追向识别到的位置：离得远走得快、离得近走得慢，看起来像"字幕跟着我走"
            if let target = followTarget {
                let diff = target - offset
                if abs(diff) < 1.0 {
                    offset = target
                } else {
                    let maxStep = CGFloat((120.0 + abs(Double(diff)) * 6.0) * dt)
                    let step = min(abs(diff), maxStep)
                    offset += diff > 0 ? step : -step
                }
            }
        } else {
            offset += CGFloat(basePointsPerSecond * speed * dt)
        }

        if offset < 0 { offset = 0 }
        if offset >= maxOffset {
            offset = maxOffset
            if mode == .constant { pause() }
        }
        progress = maxOffset > 0 ? Double(offset / maxOffset) : 0
    }
}
