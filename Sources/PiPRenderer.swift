import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import UIKit
import QuartzCore

/// 承载 AVSampleBufferDisplayLayer 的宿主视图（要真的在界面上占一块面积，系统才认为画面"可见"）
final class VideoLayerHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// 静音播放器：让 App 在后台（悬浮时）保持运行
final class SilentAudio {
    private var player: AVAudioPlayer?

    /// keepMicrophone = true 时用「播放+录音」（AI 跟读要用麦克风），否则只用「播放」
    func start(keepMicrophone: Bool) {
        let s = AVAudioSession.sharedInstance()
        do {
            if keepMicrophone {
                try s.setCategory(.playAndRecord, mode: .default,
                                  options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            } else {
                try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try s.setActive(true)
        } catch {
            // 退一步：至少保证能出声（悬浮窗要求有声会话）
            try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? s.setActive(true)
        }

        if player == nil {
            if let url = Self.ensureSilenceFile() {
                let p = try? AVAudioPlayer(contentsOf: url)
                p?.numberOfLoops = -1
                p?.volume = 0
                p?.prepareToPlay()
                player = p
            }
        }
        player?.play()
    }

    func stop() {
        player?.stop()
    }

    private static func ensureSilenceFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            do { try makeSilenceWav().write(to: url) } catch { return nil }
        }
        return url
    }

    /// 200ms 空白 WAV
    private static func makeSilenceWav() -> Data {
        let sampleRate = 44100
        let channels = 1
        let bits = 16
        let frames = sampleRate / 5
        let dataSize = frames * channels * bits / 8

        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }

        str("RIFF"); u32(UInt32(36 + dataSize)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * channels * bits / 8))
        u16(UInt16(channels * bits / 8)); u16(UInt16(bits))
        str("data"); u32(UInt32(dataSize))
        d.append(Data(repeating: 0, count: dataSize))
        return d
    }
}

extension Notification.Name {
    /// 悬浮窗真的弹出来了
    static let pipDidStart = Notification.Name("pipDidStart")
    /// 悬浮窗没能弹出来（附带原因）
    static let pipStartFailed = Notification.Name("pipStartFailed")
}

/// 画中画悬浮渲染器：把滚动字幕实时画成视频帧，交给系统画中画窗口显示
final class PiPRenderer: NSObject, ObservableObject {
    @Published var isActive = false
    @Published var lastError: String?

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var pip: AVPictureInPictureController?
    private var timebase: CMTimebase?
    private var tickLink: CADisplayLink?
    private var waitTimer: Timer?
    private var waitTicks = 0
    private let silent = SilentAudio()
    private weak var engine: PrompterEngine?

    // 文字布局（prepare 时算好）
    private var attrText: NSAttributedString?
    private var sidePad: CGFloat = 0
    private var textWidth: CGFloat = 720
    private var textHeight: CGFloat = 0
    private var padTop: CGFloat = 0
    private var fullHeight: CGFloat = 0

    private var canvasSize = CGSize(width: 720, height: 960)
    private var scale: CGFloat = 2
    private var bgColor: UIColor = .black
    private var bgAlpha: CGFloat = 0.7
    private var pool: CVPixelBufferPool?

    /// 分块渲染：长稿子也不会一次性吃掉几百兆内存
    private let tileHeight: CGFloat = 1024
    private var tiles: [Int: CGImage] = [:]
    private let maxTiles = 12

    // MARK: 准备文字
    func prepare(text: String, style: PrompterStyle, boxSize: CGSize) {
        canvasSize = CGSize(width: 720, height: 960)
        scale = canvasSize.width / max(boxSize.width, 1)

        let fontPx = max(CGFloat(style.fontSize) * scale, 12)
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = max(CGFloat(style.lineSpacing), 0.8)
        para.lineBreakMode = .byWordWrapping
        sidePad = fontPx * 0.6
        textWidth = canvasSize.width - sidePad * 2

        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = fontPx * 0.12
        shadow.shadowOffset = CGSize(width: 0, height: fontPx * 0.05)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontPx, weight: .semibold),
            .foregroundColor: UIColor(hex: style.textColorHex),
            .paragraphStyle: para,
            .shadow: shadow
        ]
        let body = text.isEmpty ? " " : text
        let attr = NSAttributedString(string: body, attributes: attrs)
        let rect = attr.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading],
                                     context: nil)

        attrText = attr
        textHeight = ceil(rect.height)
        padTop = canvasSize.height * 0.45
        fullHeight = ceil(padTop + textHeight + canvasSize.height * 0.8)

        bgColor = UIColor(hex: style.bgColorHex)
        bgAlpha = CGFloat(style.bgOpacity)
        tiles.removeAll()
        pool = nil
    }

    // MARK: 启动悬浮
    func start(hostView: UIView, engine: PrompterEngine, keepMicrophone: Bool) {
        self.engine = engine
        lastError = nil
        waitTicks = 0

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            lastError = "这台 iPhone 不支持画中画悬浮"
            postFailed()
            return
        }

        // 1) 宿主图层：必须真的挂在界面上、有正常尺寸，系统才认为画面可见
        attachLayer(hostView)
        setupTimebase()

        // 2) 音频会话先就位（顺序很关键：会话没配好，画中画会被直接拒绝）
        silent.start(keepMicrophone: keepMicrophone)

        // 3) 先让画面持续出帧，再谈启动
        startFramePump()
        render(offsetPoints: engine.offset)

        // 4) 建控制器
        makeController()

        // 5) 等系统"准备好了"再启动，而不是立刻蛮干
        beginWaiting()
    }

    func stop() {
        waitTimer?.invalidate()
        waitTimer = nil
        tickLink?.invalidate()
        tickLink = nil
        if pip?.isPictureInPictureActive == true {
            pip?.stopPictureInPicture()
        }
        pip?.delegate = nil
        pip = nil
        silent.stop()
        isActive = false
    }

    private func attachLayer(_ hostView: UIView) {
        if displayLayer.superlayer !== hostView.layer {
            displayLayer.removeFromSuperlayer()
            hostView.layer.addSublayer(displayLayer)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = hostView.bounds
        displayLayer.videoGravity = .resizeAspect
        CATransaction.commit()
    }

    private func setupTimebase() {
        guard timebase == nil else { return }
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                        sourceClock: CMClockGetHostTimeClock(),
                                        timebaseOut: &tb)
        if let tb {
            CMTimebaseSetTime(tb, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(tb, rate: 1.0)
            displayLayer.controlTimebase = tb
            timebase = tb
        }
    }

    private func makeController() {
        if let old = pip {
            old.delegate = nil
            if old.isPictureInPictureActive { old.stopPictureInPicture() }
        }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer,
                                                               playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self
        c.canStartPictureInPictureAutomaticallyFromInline = true
        // 隐藏快进/快退按钮，悬浮窗上少挡字幕
        c.requiresLinearPlayback = true
        pip = c
    }

    /// 轮询 isPictureInPicturePossible，变成 true 才真正启动
    private func beginWaiting() {
        waitTimer?.invalidate()
        waitTicks = 0
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.waitTicks += 1
            guard let c = self.pip else { t.invalidate(); return }
            if c.isPictureInPictureActive {
                t.invalidate()
                return
            }
            if c.isPictureInPicturePossible {
                t.invalidate()
                self.render(offsetPoints: self.engine?.offset ?? 0)
                c.startPictureInPicture()
                return
            }
            if self.waitTicks > 24 {   // 3.6 秒还没 ready
                t.invalidate()
                if self.lastError == nil {
                    self.lastError = "系统一直没把它当成「正在播放的视频」，画中画被拒绝"
                }
                self.postFailed()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        waitTimer = timer
    }

    private func postFailed() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .pipStartFailed, object: self)
        }
    }

    // MARK: 持续出帧
    private func startFramePump() {
        tickLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(onTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        tickLink = link
    }

    @objc private func onTick() {
        guard pip != nil, let engine else { return }
        render(offsetPoints: engine.offset)
    }

    // MARK: 画一帧
    func render(offsetPoints: CGFloat) {
        guard let attrText, attrText.length > 0 else { return }
        guard let buffer = makeBuffer() else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let ctx = CGContext(data: base,
                                  width: Int(canvasSize.width),
                                  height: Int(canvasSize.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return
        }

        ctx.setFillColor(bgColor.withAlphaComponent(bgAlpha).cgColor)
        ctx.fill(CGRect(origin: .zero, size: canvasSize))

        // 画布顶边对应「文字图里的第 visTop 像素」
        let visTop = padTop + offsetPoints * scale
        let canvasH = canvasSize.height
        let firstTile = max(Int(floor(visTop / tileHeight)), 0)
        let lastTile = Int(floor((visTop + canvasH) / tileHeight))

        if firstTile <= lastTile {
            for i in firstTile...lastTile {
                guard let img = tile(i) else { continue }
                let imgH = CGFloat(img.height)
                let visualY = CGFloat(i) * tileHeight - visTop   // 相对画布顶部
                // CG 原点是左下角，换算过去
                let cgY = canvasH - (visualY + imgH)
                ctx.draw(img, in: CGRect(x: 0, y: cgY, width: canvasSize.width, height: imgH))
            }
        }

        enqueue(buffer)
    }

    /// 取第 i 块文字图（按需生成 + 缓存）
    private func tile(_ i: Int) -> CGImage? {
        if let cached = tiles[i] { return cached }
        guard let attrText else { return nil }
        let y0 = CGFloat(i) * tileHeight
        guard y0 < fullHeight else { return nil }
        let h = min(tileHeight, fullHeight - y0)
        guard h > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasSize.width, height: h), format: format)
        let image = renderer.image { _ in
            attrText.draw(with: CGRect(x: sidePad, y: padTop - y0, width: textWidth, height: textHeight),
                          options: [.usesLineFragmentOrigin, .usesFontLeading],
                          context: nil)
        }.cgImage

        guard let image else { return nil }
        tiles[i] = image
        if tiles.count > maxTiles { evictTiles(around: i) }
        return image
    }

    private func evictTiles(around current: Int) {
        let sorted = tiles.keys.sorted { abs($0 - current) > abs($1 - current) }
        for key in sorted where tiles.count > maxTiles - 3 {
            tiles.removeValue(forKey: key)
        }
    }

    private func makeBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(canvasSize.width),
                kCVPixelBufferHeightKey as String: Int(canvasSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        return pb
    }

    private func enqueue(_ buffer: CVPixelBuffer) {
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: buffer,
                                                     formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: buffer,
                                                 formatDescription: format,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        if let sample {
            if displayLayer.status == .failed {
                displayLayer.flush()
            }
            displayLayer.enqueue(sample)
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension PiPRenderer: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        waitTimer?.invalidate()
        waitTimer = nil
        isActive = true
        NotificationCenter.default.post(name: .pipDidStart, object: self)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = false
        tickLink?.invalidate()
        tickLink = nil
        silent.stop()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        isActive = false
        let ns = error as NSError
        lastError = "系统拒绝启动画中画（错误码 \(ns.code)）"
        postFailed()
    }
}

// MARK: - 画中画播放代理（系统要求实现）
extension PiPRenderer: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    setPlaying playing: Bool) {
        if playing { engine?.start() } else { engine?.pause() }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // 直播式无限时长：系统不会显示进度条
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        // 我们是在持续出帧的实时画面，对系统而言始终"在播"
        false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        // 系统按窗口大小等比缩放，无需处理
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
