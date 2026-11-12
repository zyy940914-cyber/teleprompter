import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import UIKit
import QuartzCore

/// 承载 AVSampleBufferDisplayLayer 的宿主视图（放在提词页里一个 1x1 的小位置即可）
final class VideoLayerHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// 静音播放器：让 App 在后台（悬浮时）保持运行
final class SilentAudio {
    private var player: AVAudioPlayer?

    func start() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            if player == nil {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence.wav")
                if !FileManager.default.fileExists(atPath: url.path) {
                    try Self.makeSilenceWav().write(to: url)
                }
                let p = try AVAudioPlayer(contentsOf: url)
                p.numberOfLoops = -1
                p.volume = 0
                p.prepareToPlay()
                player = p
            }
            player?.play()
        } catch {
            // 静音保活失败不影响主要功能
        }
    }

    func stop() {
        player?.stop()
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

/// 画中画悬浮渲染器：把滚动字幕实时画成视频帧，交给系统的画中画窗口显示
final class PiPRenderer: NSObject, ObservableObject {
    @Published var isActive = false

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var pip: AVPictureInPictureController?
    private var timebase: CMTimebase?
    private var textImage: CGImage?
    private var textImageHeight: CGFloat = 1
    private var canvasSize = CGSize(width: 720, height: 960)
    private var scale: CGFloat = 2
    private var bgColor: UIColor = .black
    private var bgAlpha: CGFloat = 0.7
    private var pool: CVPixelBufferPool?
    private var tickLink: CADisplayLink?
    private var lastOffset: CGFloat = -1
    private let silent = SilentAudio()
    private weak var engine: PrompterEngine?

    // MARK: 准备文字图层
    func prepare(text: String, style: PrompterStyle, boxSize: CGSize) {
        canvasSize = CGSize(width: 720, height: 960)
        scale = canvasSize.width / max(boxSize.width, 1)

        let fontPx = max(CGFloat(style.fontSize) * scale, 12)
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = CGFloat(style.lineSpacing)
        para.lineBreakMode = .byWordWrapping
        let sidePad = fontPx * 0.6
        let textWidth = canvasSize.width - sidePad * 2

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
        let textHeight = ceil(rect.height)
        let padTop = canvasSize.height * 0.45
        let padBottom = canvasSize.height * 0.8
        let totalH = ceil(padTop + textHeight + padBottom)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasSize.width, height: totalH), format: format)
        let image = renderer.image { _ in
            attr.draw(with: CGRect(x: sidePad, y: padTop, width: textWidth, height: textHeight),
                      options: [.usesLineFragmentOrigin, .usesFontLeading],
                      context: nil)
        }
        textImage = image.cgImage
        textImageHeight = totalH
        bgColor = UIColor(hex: style.bgColorHex)
        bgAlpha = CGFloat(style.bgOpacity)
        pool = nil
    }

    // MARK: 启动悬浮
    func start(hostView: UIView, engine: PrompterEngine) {
        self.engine = engine
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            return
        }

        // 把 displayLayer 挂到宿主视图上
        if displayLayer.superlayer == nil {
            displayLayer.frame = hostView.bounds
            hostView.layer.addSublayer(displayLayer)
        }
        setupTimebase()
        render(offsetPoints: engine.offset)

        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer,
                                                               playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        // 隐藏快进/快退按钮，悬浮窗上少挡字幕
        controller.requiresLinearPlayback = true
        pip = controller
        controller.startPictureInPicture()

        silent.start()
        let link = CADisplayLink(target: self, selector: #selector(onTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        tickLink = link
    }

    func stop() {
        tickLink?.invalidate()
        tickLink = nil
        pip?.stopPictureInPicture()
        pip = nil
        silent.stop()
        isActive = false
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

    @objc private func onTick() {
        guard let engine else { return }
        if abs(engine.offset - lastOffset) < 0.2 { return }
        lastOffset = engine.offset
        render(offsetPoints: engine.offset)
    }

    // MARK: 画一帧
    func render(offsetPoints: CGFloat) {
        guard let image = textImage else { return }
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
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return
        }
        ctx.setFillColor(bgColor.withAlphaComponent(bgAlpha).cgColor)
        ctx.fill(CGRect(origin: .zero, size: canvasSize))

        ctx.saveGState()
        ctx.translateBy(x: 0, y: canvasSize.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0,
                                   y: -(offsetPoints * scale),
                                   width: canvasSize.width,
                                   height: textImageHeight))
        ctx.restoreGState()

        enqueue(buffer)
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
        isActive = true
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
        tickLink?.invalidate()
        tickLink = nil
    }
}

// MARK: - 画中画播放代理（系统要求实现）
extension PiPRenderer: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    setPlaying playing: Bool) {
        if playing {
            engine?.start()
        } else {
            engine?.pause()
        }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        !(engine?.isPlaying ?? false)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        // 系统会按窗口大小等比缩放，无需额外处理
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
