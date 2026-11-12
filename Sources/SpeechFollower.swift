import AVFoundation
import Speech
import Foundation

/// 音频会话管理：关键是允许与其他 App（抖音）同时工作的配置
final class AudioSessionManager {
    static let shared = AudioSessionManager()
    private var observing = false

    /// 语音跟读用：可录音 + 与其他 App 混音（不抢占/不被抢占）
    func activateForFollowing() {
        let s = AVAudioSession.sharedInstance()
        do {
            // 用 mixWithOthers 让抖音那边的音频不被我们打断，
            // 用 allowBluetoothA2DP（而不是 allowBluetooth/HFP）避免音质下降
            try s.setCategory(.playAndRecord,
                              mode: .default,
                              options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            if #available(iOS 15.0, *) {
                // 明确用标准麦克风模式，避免系统切到"语音隔离"导致混音失效
                try? s.setMicrophoneMode(.standard)
            }
            try s.setPreferredIOBufferDuration(0.01)
            try s.setActive(true)
            setupObservers()
        } catch {
            // 退一步：至少保证能录音
            try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
            try? s.setActive(true)
        }
    }

    func activateForPlayback() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? s.setActive(true)
    }

    private func setupObservers() {
        guard !observing else { return }
        observing = true
        let c = NotificationCenter.default
        c.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            // 插拔耳机等路由变化后，系统可能重置麦克风模式，重新应用一次
            self?.activateForFollowing()
        }
        c.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .ended {
                try? AVAudioSession.sharedInstance().setActive(true)
                NotificationCenter.default.post(name: .audioInterruptionEnded, object: nil)
            }
        }
    }
}

extension Notification.Name {
    static let audioInterruptionEnded = Notification.Name("audioInterruptionEnded")
}

/// AI 跟读：实时语音识别 + 稿子里的滑动窗口匹配，把"读到哪"换算成滚动位置
final class SpeechFollower: NSObject, ObservableObject {
    @Published var status: String = "未开启"
    @Published var level: Double = 0
    @Published var heard: String = ""
    @Published var matchedCharIndex: Int = 0
    @Published var permissionProblem: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false

    private var scriptChars: [Character] = []
    private var origIndexForNorm: [Int] = []
    private var cursor = 0

    // MARK: 准备稿子
    func prepare(text: String) {
        let result = Self.normalizeWithMap(text)
        scriptChars = result.0
        origIndexForNorm = result.1
        cursor = 0
        matchedCharIndex = 0
        heard = ""
    }

    /// 把稿子归一化（去掉标点、空格、换行），并记录每个字在原文里的位置
    static func normalizeWithMap(_ text: String) -> ([Character], [Int]) {
        var chars: [Character] = []
        var map: [Int] = []
        for (i, ch) in text.enumerated() {
            if isMeaningful(ch) {
                chars.append(ch)
                map.append(i)
            }
        }
        return (chars, map)
    }

    static func normalize(_ text: String) -> String {
        String(text.filter { isMeaningful($0) })
    }

    private static func isMeaningful(_ ch: Character) -> Bool {
        if ch.isWhitespace || ch.isNewline { return false }
        return ch.isLetter || ch.isNumber
    }

    // MARK: 开始 / 停止
    func start() {
        guard !running else { return }
        status = "请求权限…"
        SFSpeechRecognizer.requestAuthorization { authStatus in
            AVAudioSession.sharedInstance().requestRecordPermission { micGranted in
                DispatchQueue.main.async {
                    guard authStatus == .authorized, micGranted else {
                        self.permissionProblem = "需要麦克风和语音识别权限。请到 设置 → 悬浮提词器 里打开「麦克风」和「语音识别」。"
                        self.status = "没有权限"
                        return
                    }
                    self.begin()
                }
            }
        }
    }

    private func begin() {
        AudioSessionManager.shared.activateForFollowing()
        guard let recognizer, recognizer.isAvailable else {
            permissionProblem = "这台手机的语音识别暂时不可用，请改用「匀速滚动」。"
            status = "识别不可用"
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true   // 尽量本地识别，快且不上传
        }
        request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.request?.append(buffer)
            // 顺便算音量，做界面上的音量条
            if let data = buffer.floatChannelData?[0] {
                let n = Int(buffer.frameLength)
                if n > 0 {
                    var sum: Double = 0
                    for i in 0..<n {
                        let v = Double(data[i])
                        sum += v * v
                    }
                    let rms = sqrt(sum / Double(n))
                    DispatchQueue.main.async { self.level = min(rms * 8, 1) }
                }
            }
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.heard = text
                    self.match(transcript: text)
                }
            }
            if error != nil {
                DispatchQueue.main.async {
                    if self.running {
                        // 识别中断（比如被别的 App 抢走）：稍后自动重启
                        self.status = "识别中断，正在重连…"
                        self.restartSoon()
                    }
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            running = true
            status = "聆听中"
        } catch {
            status = "启动失败"
            permissionProblem = "麦克风启动失败：\(error.localizedDescription)"
        }
    }

    private func restartSoon() {
        stopEngineOnly()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.running else { return }
            self.begin()
        }
    }

    private func stopEngineOnly() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    func stop() {
        running = false
        stopEngineOnly()
        status = "已停止"
        level = 0
        AudioSessionManager.shared.activateForPlayback()
    }

    /// 读错/跳读了，重新对齐到当前位置之前
    func realign(back chars: Int = 30) {
        cursor = max(0, cursor - chars)
        publish(index: cursor)
    }

    // MARK: 匹配算法（滑动窗口 + 容错）
    private func match(transcript: String) {
        let norm = Array(Self.normalize(transcript))
        guard norm.count >= 3, !scriptChars.isEmpty else { return }

        // 取识别结果最新的一小段（人刚说出来的字）
        let tailLen = min(12, norm.count)
        let tail = Array(norm.suffix(tailLen))

        let windowStart = max(0, cursor - 6)
        let windowEnd = min(scriptChars.count - 1, cursor + 100)
        guard windowEnd > windowStart else { return }

        var bestScore = 0
        var bestEnd = -1
        var i = windowStart
        while i <= windowEnd {
            var score = 0
            var k = 0
            while k < tail.count, i + k <= windowEnd, scriptChars[i + k] == tail[k] {
                score += 1
                k += 1
            }
            if score > bestScore {
                bestScore = score
                bestEnd = i + score
            }
            i += 1
        }

        // 至少连续命中 4 个字，且必须往前走（防止抖回去）
        if bestScore >= 4, bestEnd > cursor {
            cursor = bestEnd
            publish(index: cursor)
        }
    }

    private func publish(index: Int) {
        guard !origIndexForNorm.isEmpty else { return }
        let clamped = min(max(index, 0), origIndexForNorm.count - 1)
        matchedCharIndex = origIndexForNorm[clamped]
    }
}
