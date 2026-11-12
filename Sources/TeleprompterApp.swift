import SwiftUI
import AVFoundation

@main
struct TeleprompterApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onAppear {
                    // 允许在后台继续运行（悬浮提词时需要）
                    try? AVAudioSession.sharedInstance().setCategory(.playback,
                                                                     mode: .default,
                                                                     options: [.mixWithOthers])
                    try? AVAudioSession.sharedInstance().setActive(true)
                }
        }
    }
}
