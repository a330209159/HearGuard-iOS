import SwiftUI

@MainActor
public struct ContentView: View {
    @StateObject private var audio = iOSAudioEngine()
    @StateObject private var store = SessionStore()

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Compact Top Clinical Status Bar
                HStack(spacing: 8) {
                    Image(systemName: "ear.badge.waveform")
                        .font(.headline)
                        .foregroundColor(.cyan)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("HearGuard 测听")
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                        Text("125Hz→8000Hz 双耳曲线")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.72))
                    }

                    Spacer()

                    // Live Headphone & Volume Pill
                    HStack(spacing: 5) {
                        Circle()
                            .fill(audio.isHeadphonesConnected ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(audio.isHeadphonesConnected ? "耳机 \(Int((audio.systemVolume * 100).rounded()))%" : "请戴耳机")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.14))
                    .cornerRadius(99)

                    // Emergency Mute Button
                    Button {
                        store.stopAutomatedAudiometry(audio: audio)
                        audio.stopAllAudio()
                        store.showToast("已静音并停止当前给声")
                    } label: {
                        Image(systemName: "speaker.slash.fill")
                            .font(.caption.bold())
                            .padding(7)
                            .background(Color.red.opacity(0.85))
                            .foregroundColor(.white)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("紧急静音")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Color(red: 0.06, green: 0.09, blue: 0.16))

                // Main 5-Tab Interface
                TabView(selection: $store.selectedTab) {
                    PrepCalibrationView(audio: audio, store: store)
                        .tabItem {
                            Label("准备校准", systemImage: "headphones")
                        }
                        .tag(0)

                    PureToneTestView(audio: audio, store: store)
                        .tabItem {
                            Label("测听(低→高)", systemImage: "waveform.path")
                        }
                        .tag(1)

                    ReportAnalysisView(audio: audio, store: store)
                        .tabItem {
                            Label("双耳听力图", systemImage: "chart.xyaxis.line")
                        }
                        .tag(2)

                    HistoryAndTinnitusView(audio: audio, store: store)
                        .tabItem {
                            Label("耳鸣与档案", systemImage: "clock.arrow.circlepath")
                        }
                        .tag(3)

                    ResearchGuideView()
                        .tabItem {
                            Label("研究指南", systemImage: "book.closed")
                        }
                        .tag(4)
                }
            }

            // Floating Toast Notification
            if let toast = store.toastMessage {
                Text(toast)
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(red: 0.08, green: 0.12, blue: 0.22).opacity(0.95))
                    .cornerRadius(99)
                    .shadow(radius: 8)
                    .padding(.bottom, 62)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.2), value: store.toastMessage)
            }
        }
        .onAppear {
            store.syncAudioEngineFromSettings(audio)
            audio.refreshAudioRouteInfo()
        }
    }
}
