import SwiftUI
import UIKit

struct PrompterView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let script: Script

    @StateObject private var engine = PrompterEngine()
    @StateObject private var speech = SpeechFollower()
    @StateObject private var pip = PiPRenderer()

    @State private var hostView: UIView?
    @State private var showSettings = false
    @State private var showControls = true
    @State private var dragBase: CGPoint?
    @State private var floatAlert = false
    @State private var floatAlertMessage = ""
    @State private var floatStage = 0            // 0 空闲 / 1 带麦克风尝试 / 2 无麦克风尝试
    @State private var lastBoxSize: CGSize = .zero

    @State private var scriptMap: ScriptMap?
    @State private var mapKey = ""

    var body: some View {
        GeometryReader { geo in
            let screen = geo.size
            let boxSize = CGSize(width: max(screen.width * store.style.boxWidthRatio, 140),
                                 height: max(screen.height * store.style.boxHeightRatio, 110))
            let layout = TextLayout.make(text: script.text, style: store.style, boxSize: boxSize)
            let maxOffset = max(layout.totalHeight - boxSize.height, 1)

            ZStack {
                Color(hex: "#1c1620").ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                    }

                // ===== 可拖动字幕框 =====
                ZStack(alignment: .topLeading) {
                    TextLabel(attributed: layout.attributed, width: layout.width)
                        .frame(width: layout.width, height: layout.textHeight, alignment: .topLeading)
                        .offset(x: (boxSize.width - layout.width) / 2,
                                y: layout.topPad - engine.offset)
                }
                .frame(width: boxSize.width, height: boxSize.height, alignment: .topLeading)
                .background(Color(hex: store.style.bgColorHex).opacity(store.style.bgOpacity))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(dragBase == nil ? 0.12 : 0.6),
                                style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                )
                .position(x: screen.width * store.style.boxCenterXRatio,
                          y: screen.height * store.style.boxCenterYRatio)
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if dragBase == nil {
                                dragBase = CGPoint(x: store.style.boxCenterXRatio,
                                                   y: store.style.boxCenterYRatio)
                            }
                            guard let base = dragBase else { return }
                            let nx = base.x + value.translation.width / screen.width
                            let ny = base.y + value.translation.height / screen.height
                            store.style.boxCenterXRatio = min(max(nx, 0.05), 0.95)
                            store.style.boxCenterYRatio = min(max(ny, 0.05), 0.95)
                        }
                        .onEnded { _ in
                            dragBase = nil
                            store.saveStyle()
                        }
                )

                // 画中画宿主：必须真的占一块和字幕框一样大的面积，系统才认为画面"可见"。
                // 用 0.01 透明度叠在上面，肉眼看不见，但系统认定它是显示中的画面。
                LayerHost(view: $hostView)
                    .frame(width: boxSize.width, height: boxSize.height)
                    .opacity(0.01)
                    .position(x: screen.width * store.style.boxCenterXRatio,
                              y: screen.height * store.style.boxCenterYRatio)
                    .allowsHitTesting(false)

                // ===== 顶部状态 =====
                VStack(spacing: 8) {
                    HStack {
                        if showControls {
                            Button {
                                closeAll()
                                dismiss()
                            } label: {
                                Label("返回", systemImage: "chevron.left")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                            .foregroundColor(.white)
                        }
                        Spacer()
                        if pip.isActive {
                            Text("悬浮中")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.purple.opacity(0.85), in: Capsule())
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.horizontal, 14)

                    if store.style.mode == .voice && showControls {
                        VStack(spacing: 3) {
                            Text("🎤 \(speech.status) · 读到 \(Int(engine.progress * 100))%")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.white)
                            if !speech.heard.isEmpty {
                                Text(speech.heard.suffix(18))
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.45), in: Capsule())
                    }
                    Spacer()
                }
                .padding(.top, 8)

                // ===== 底部控制条 =====
                if showControls {
                    VStack(spacing: 0) {
                        Spacer()
                        controlsPanel(boxSize: boxSize, layout: layout, maxOffset: maxOffset)
                    }
                    .transition(.move(edge: .bottom))
                }
            }
            .onAppear {
                engine.maxOffset = maxOffset
                syncEngine()
            }
            .onChange(of: maxOffset) { newValue in engine.maxOffset = newValue }
            .onChange(of: store.style.mode) { _ in syncEngine() }
            .onChange(of: speech.matchedCharIndex) { idx in
                guard let map = scriptMap else { return }
                let y = map.y(forCharacter: idx)
                let target = layout.topPad + y - boxSize.height * 0.3
                engine.followTarget = min(max(target, 0), maxOffset)
            }
            .onReceive(NotificationCenter.default.publisher(for: .audioInterruptionEnded)) { _ in
                if store.style.mode == .voice && engine.isPlaying { speech.start() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pipStartFailed)) { _ in
                handleFloatFailure()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pipDidStart)) { _ in
                if floatStage == 2 && store.style.mode == .voice {
                    floatAlertMessage = """
                    悬浮已经开了 ✅

                    但为了让它能浮起来，AI 跟读这次先关掉了：抖音正在直播、麦克风被抖音占着，两个一起用画中画就起不来。

                    · 悬浮状态下 → 用「匀速滚动」
                    · 想用「AI 跟读」→ 别悬浮，用第二台手机/平板看提词
                    """
                    floatAlert = true
                }
                floatStage = 0
            }
        }
        .statusBarHidden(true)
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environmentObject(store)
                .onDisappear {
                    store.saveStyle()
                    syncEngine()
                    scriptMap = nil   // 样式变了，重新生成位置映射
                }
        }
        .alert("悬浮窗口没有弹出来", isPresented: $floatAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(floatAlertMessage)
        }
        .alert("语音跟读提示", isPresented: Binding(
            get: { speech.permissionProblem != nil },
            set: { if !$0 { speech.permissionProblem = nil } }
        )) {
            Button("知道了", role: .cancel) { speech.permissionProblem = nil }
        } message: {
            Text(speech.permissionProblem ?? "")
        }
        .onDisappear { closeAll() }
    }

    // MARK: 控制条
    private func controlsPanel(boxSize: CGSize, layout: TextLayout, maxOffset: CGFloat) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("进度")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
                Slider(value: Binding(
                    get: { engine.progress },
                    set: { engine.seek(toProgress: $0) }
                ), in: 0...1)
                .tint(Color(hex: "#e8598a"))
                Text("\(Int(engine.progress * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 38, alignment: .trailing)
            }

            HStack(spacing: 10) {
                Text(store.style.mode == .voice ? "跟读" : "倍速")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 40, alignment: .leading)
                if store.style.mode == .voice {
                    Slider(value: Binding(
                        get: { store.style.voiceSpeed },
                        set: { store.style.voiceSpeed = $0 }
                    ), in: 0.3...3.0, step: 0.1)
                    .tint(Color(hex: "#e8598a"))
                    Text(String(format: "%.1fx", store.style.voiceSpeed))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.white.opacity(0.8))
                        .frame(width: 38, alignment: .trailing)
                } else {
                    Slider(value: Binding(
                        get: { store.style.speed },
                        set: { store.style.speed = $0 }
                    ), in: 0.2...5.0, step: 0.1)
                    .tint(Color(hex: "#e8598a"))
                    Text(String(format: "%.1fx", store.style.speed))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.white.opacity(0.8))
                        .frame(width: 38, alignment: .trailing)
                }
            }

            HStack(spacing: 8) {
                modeButton(.constant, icon: "tortoise.fill")
                modeButton(.voice, icon: "mic.fill")
            }

            if store.style.mode == .voice {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.caption2)
                        .foregroundColor(.green)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.15))
                            Capsule()
                                .fill(LinearGradient(colors: [.green, .yellow, .red],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: g.size.width * min(max(speech.level, 0), 1))
                        }
                    }
                    .frame(height: 6)
                    Button {
                        speech.realign(back: 40)
                    } label: {
                        Text("重新对齐")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.15), in: Capsule())
                            .foregroundColor(.white)
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    togglePlay(layout: layout, boxSize: boxSize, maxOffset: maxOffset)
                } label: {
                    Label(engine.isPlaying ? "暂停" : "开始",
                          systemImage: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(hex: "#e8598a"), in: RoundedRectangle(cornerRadius: 12))
                        .foregroundColor(.white)
                }

                Button {
                    showSettings = true
                } label: {
                    Label("样式", systemImage: "textformat.size")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                        .foregroundColor(.white)
                }
            }

            Button {
                toggleFloat(boxSize: boxSize, layout: layout, maxOffset: maxOffset)
            } label: {
                Label(pip.isActive ? "关闭悬浮" : "悬浮到抖音上方",
                      systemImage: pip.isActive ? "pip.exit" : "pip.enter")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        LinearGradient(colors: [Color(hex: "#7048e8"), Color(hex: "#e8598a")],
                                       startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .foregroundColor(.white)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func modeButton(_ mode: ScrollMode, icon: String) -> some View {
        Button {
            store.style.mode = mode
            store.saveStyle()
            syncEngine()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption)
                Text(mode == .constant ? "匀速滚动" : "AI跟读").font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(store.style.mode == mode ? Color(hex: "#e8598a") : Color.white.opacity(0.12))
            )
            .foregroundColor(.white)
        }
    }

    // MARK: 逻辑
    private func syncEngine() {
        engine.mode = store.style.mode
        engine.speed = store.style.speed
        if store.style.mode != .voice {
            speech.stop()
        }
    }

    private func togglePlay(layout: TextLayout, boxSize: CGSize, maxOffset: CGFloat) {
        if engine.isPlaying {
            engine.pause()
            speech.stop()
            return
        }
        if store.style.mode == .voice {
            prepareMapIfNeeded(layout: layout)
            speech.prepare(text: script.text)
            speech.start()
        }
        engine.start()
    }

    private func prepareMapIfNeeded(layout: TextLayout) {
        let key = "\(store.style.fontSize)-\(store.style.lineSpacing)-\(Int(layout.width))"
        guard scriptMap == nil || mapKey != key else { return }
        scriptMap = ScriptMap(attributed: layout.attributed, width: layout.width)
        mapKey = key
    }

    private func toggleFloat(boxSize: CGSize, layout: TextLayout, maxOffset: CGFloat) {
        if pip.isActive {
            pip.stop()
            floatStage = 0
            if store.style.mode == .voice { speech.start() }
            return
        }
        lastBoxSize = boxSize
        let wantsVoice = store.style.mode == .voice
        if wantsVoice { prepareMapIfNeeded(layout: layout) }
        floatStage = wantsVoice ? 1 : 2
        startFloatAttempt(boxSize: boxSize, keepMic: wantsVoice)
    }

    private func startFloatAttempt(boxSize: CGSize, keepMic: Bool) {
        guard let host = hostView else { return }
        if !keepMic { speech.stop() }
        pip.prepare(text: script.text, style: store.style, boxSize: boxSize)
        engine.start()
        pip.start(hostView: host, engine: engine, keepMicrophone: keepMic)
    }

    /// 第一轮（带麦克风）失败 → 关掉 AI 跟读、换成纯播放再看一次；还失败才弹窗
    private func handleFloatFailure() {
        if floatStage == 1 {
            floatStage = 2
            speech.stop()
            pip.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                startFloatAttempt(boxSize: lastBoxSize, keepMic: false)
            }
            return
        }
        floatStage = 0
        pip.stop()
        let reason = pip.lastError ?? "系统没有允许画中画启动"
        floatAlertMessage = """
        \(reason)

        先确认这两项，再退出 App 重新打开重试：
        · 设置 → 通用 → 画中画 → 「自动开启画中画」是开的
        · 设置 → 隐私与安全性 → 开发者模式 是开的
        """
        floatAlert = true
    }

    private func closeAll() {
        speech.stop()
        engine.pause()
        pip.stop()
    }
}

// MARK: - 样式设置面板
struct SettingsSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private let textColors = ["#FFFFFF", "#FFE066", "#7FD89B", "#74C0FC", "#FFA8A8", "#2B2430"]
    private let bgColors = ["#000000", "#1C1620", "#2B2430", "#E8598A", "#1971C2", "#2F9E44"]

    var body: some View {
        NavigationView {
            Form {
                Section("字体") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("字体大小")
                            Spacer()
                            Text("\(Int(store.style.fontSize))px").foregroundColor(.secondary)
                        }
                        Slider(value: $store.style.fontSize, in: 14...72, step: 1)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("行间距")
                            Spacer()
                            Text(String(format: "%.1f", store.style.lineSpacing)).foregroundColor(.secondary)
                        }
                        Slider(value: $store.style.lineSpacing, in: 1.0...3.0, step: 0.1)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("字体颜色")
                        colorRow(colors: textColors, selected: store.style.textColorHex) { hex in
                            store.style.textColorHex = hex
                        }
                        ColorPicker("自定义颜色",
                                    selection: Binding(
                                        get: { Color(hex: store.style.textColorHex) },
                                        set: { store.style.textColorHex = $0.toHex() }
                                    ),
                                    supportsOpacity: false)
                    }
                }

                Section("字幕背景框") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("背景颜色")
                        colorRow(colors: bgColors, selected: store.style.bgColorHex) { hex in
                            store.style.bgColorHex = hex
                        }
                        ColorPicker("自定义颜色",
                                    selection: Binding(
                                        get: { Color(hex: store.style.bgColorHex) },
                                        set: { store.style.bgColorHex = $0.toHex() }
                                    ),
                                    supportsOpacity: false)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("透明度")
                            Spacer()
                            Text("\(Int(store.style.bgOpacity * 100))%").foregroundColor(.secondary)
                        }
                        Slider(value: $store.style.bgOpacity, in: 0...1, step: 0.01)
                        Text("0% 完全透明，直播画面不会看到底色")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("框宽度")
                            Spacer()
                            Text("\(Int(store.style.boxWidthRatio * 100))%").foregroundColor(.secondary)
                        }
                        Slider(value: $store.style.boxWidthRatio, in: 0.4...1.0, step: 0.01)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("框高度")
                            Spacer()
                            Text("\(Int(store.style.boxHeightRatio * 100))%").foregroundColor(.secondary)
                        }
                        Slider(value: $store.style.boxHeightRatio, in: 0.15...0.9, step: 0.01)
                    }
                    Text("位置：回到提词页，用手指按住字幕框拖动；悬浮小窗本身也能拖动、双指缩放")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Section("AI 跟读") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("跟读用实时语音识别：你说到哪，字幕走到哪——语速快慢、停顿都能跟住，不念就不动。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("偶尔跟不上时点提词页的「重新对齐」即可。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("字体与背景")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        store.saveStyle()
                        dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func colorRow(colors: [String], selected: String, onPick: @escaping (String) -> Void) -> some View {
        HStack(spacing: 10) {
            ForEach(colors, id: \.self) { hex in
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Circle().stroke(Color.primary.opacity(selected.lowercased() == hex.lowercased() ? 0.9 : 0.15),
                                        lineWidth: selected.lowercased() == hex.lowercased() ? 2.5 : 1)
                    )
                    .onTapGesture { onPick(hex) }
            }
            Spacer()
        }
    }
}

// MARK: - Color → Hex
extension Color {
    func toHex() -> String {
        let ui = UIColor(self)
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}
