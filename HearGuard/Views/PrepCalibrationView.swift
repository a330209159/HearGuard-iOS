import SwiftUI

@MainActor
public struct PrepCalibrationView: View {
    @ObservedObject var audio: iOSAudioEngine
    @ObservedObject var store: SessionStore

    @State private var selectedCalibTab: Int = 0 // 0=Preset, 1=HealthyEar1k, 2=HandRub
    @State private var calibRefEar: EarSide = .right
    @State private var calibHospital1kDb: Double = 10.0
    @State private var calibRawDbfs: Double = -78.0
    @State private var handRubRawDbfs: Double = -42.0

    public init(audio: iOSAudioEngine, store: SessionStore) {
        self.audio = audio
        self.store = store
    }

    private var volumePercent: Int {
        Int((audio.systemVolume * 100.0).rounded())
    }

    private var isVolumeIdeal: Bool {
        volumePercent >= 42 && volumePercent <= 60
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Golden Window Medical Reminder
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "cross.case.fill")
                            .foregroundColor(.orange)
                        Text("突发性耳聋康复与护耳须知")
                            .font(.subheadline.bold())
                            .foregroundColor(Color(red: 0.55, green: 0.25, blue: 0.02))
                    }
                    Text("发病 72 小时至 2 周内为黄金救治窗口，请遵耳鼻喉科医嘱规范治疗。测听前请开启 iPhone「专注/勿扰模式」避免通知音惊吓患耳，并在控制中心长按音量条关闭 AirPods「空间音频」。")
                        .font(.caption)
                        .foregroundColor(Color(red: 0.45, green: 0.22, blue: 0.04))
                }
                .padding(14)
                .background(Color.orange.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.35), lineWidth: 1))
                .cornerRadius(12)

                // Step 1: Real-time iPhone Headphone & Hardware Volume Status
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("第一步：耳机连接与 iPhone 音量检查", systemImage: "headphones")
                            .font(.headline)
                        Spacer()
                        Button("刷新状态") {
                            audio.refreshAudioRouteInfo()
                        }
                        .font(.caption.bold())
                    }

                    // Headphone Status Banner
                    HStack(spacing: 10) {
                        Image(systemName: audio.isHeadphonesConnected ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundColor(audio.isHeadphonesConnected ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(audio.isHeadphonesConnected ? "耳机已就绪：\(audio.connectedPortName)" : "尚未连接耳机（当前：\(audio.connectedPortName)）")
                                .font(.subheadline.bold())
                            Text(audio.isHeadphonesConnected ? "已启用纯立体声 48kHz 双声道独立输出" : "请戴上有线或蓝牙耳机后再开始左右耳独立测听")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(audio.isHeadphonesConnected ? Color.green.opacity(0.10) : Color.red.opacity(0.10))
                    .cornerRadius(10)

                    // Live iPhone Physical Volume Bar
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("当前 iPhone 系统音量：\(volumePercent)%")
                                .font(.subheadline.bold())
                            Spacer()
                            Text(isVolumeIdeal ? "最佳校准区间 (推荐 50%)" : "请按机身侧边音量键调至 50% 左右")
                                .font(.caption.bold())
                                .foregroundColor(isVolumeIdeal ? .green : .orange)
                        }
                        ProgressView(value: Double(audio.systemVolume), total: 1.0)
                            .tint(isVolumeIdeal ? .green : .orange)
                    }
                    .padding(10)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(10)

                    // Left / Right Stereo Channel Verification
                    HStack(spacing: 12) {
                        Button {
                            audio.playChannelVerification(ear: .left)
                            store.showToast("正在播放【左耳 L】双音 — 确认仅左耳响")
                        } label: {
                            HStack {
                                Text("✕").font(.headline.weight(.heavy))
                                Text("左耳声道校验")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.blue.opacity(0.12))
                            .foregroundColor(.blue)
                            .cornerRadius(10)
                        }

                        Button {
                            audio.playChannelVerification(ear: .right)
                            store.showToast("正在播放【右耳 R】双音 — 确认仅右耳响")
                        } label: {
                            HStack {
                                Text("O").font(.headline.weight(.heavy))
                                Text("右耳声道校验")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.12))
                            .foregroundColor(.red)
                            .cornerRadius(10)
                        }
                    }

                    // Optional Ambient Room Noise Check
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("房间环境底噪快检（防空调低频嗡声掩蔽 125Hz）")
                                .font(.caption.bold())
                            if audio.isMonitoringAmbientNoise {
                                let quiet = audio.estimatedAmbientDbA <= 38
                                Text("当前估算底噪：约 \(audio.estimatedAmbientDbA) dBA — \(quiet ? "安静适宜测听" : "环境略吵，建议关风扇/空调")")
                                    .font(.caption)
                                    .foregroundColor(quiet ? .green : .orange)
                            } else {
                                Text("可选检查；开始测听时会自动关闭麦克风以保持蓝牙高清立体声")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Button(audio.isMonitoringAmbientNoise ? "停止检测" : "检测底噪") {
                            if audio.isMonitoringAmbientNoise {
                                audio.stopAmbientNoiseCheck()
                            } else {
                                audio.startAmbientNoiseCheck { msg in
                                    store.showToast(msg)
                                }
                            }
                        }
                        .font(.caption.bold())
                        .buttonStyle(.bordered)
                    }
                }
                .padding(16)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(14)

                // Step 2: Headphone Acoustic Profile & Affected Side
                VStack(alignment: .leading, spacing: 12) {
                    Label("第二步：耳机声学补偿模型与患侧设置", systemImage: "waveform.path.ecg")
                        .font(.headline)

                    ForEach(HeadphoneProfile.allCases) { prof in
                        let isSelected = (audio.headphoneProfile == prof)
                        Button {
                            audio.selectHeadphoneProfile(prof, preserveCustomCalibration: true)
                            store.updateSettingsFromAudio(audio)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(prof.name)
                                        .font(.subheadline.bold())
                                        .foregroundColor(.primary)
                                    Text(prof.subtitle)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer()
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(isSelected ? .blue : .secondary)
                                    .font(.title3)
                            }
                            .padding(11)
                            .background(isSelected ? Color.blue.opacity(0.08) : Color(UIColor.secondarySystemBackground))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1.5)
                            )
                            .cornerRadius(10)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("哪侧耳朵突聋/耳闷？（系统将自动优先测好耳以建立对照与掩蔽基准）")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        Picker("患侧选择", selection: $store.settings.affectedSide) {
                            ForEach(AffectedSidePreference.allCases) { side in
                                Text(side.label).tag(side)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: store.settings.affectedSide) { newVal in
                            if newVal == .left { calibRefEar = .right }
                            else if newVal == .right { calibRefEar = .left }
                            store.saveSettingsToDisk()
                        }
                    }
                }
                .padding(16)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(14)

                // Step 3: Acoustic Zero Calibration
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("第三步：声学零点校准", systemImage: "tuningfork")
                            .font(.headline)
                        Spacer()
                        Text(audio.calibrationMethod.label)
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.cyan.opacity(0.16))
                            .foregroundColor(.blue)
                            .cornerRadius(8)
                    }

                    Picker("校准方式", selection: $selectedCalibTab) {
                        Text("50%标准预设").tag(0)
                        Text("健耳1kHz校准(推荐)").tag(1)
                        Text("搓手声校准").tag(2)
                    }
                    .pickerStyle(.segmented)

                    if selectedCalibTab == 0 {
                        Text("保持 iPhone 音量在 50% 格位，直接采用所选耳机的 ISO 389 / EarPods 实测 RETSPL 灵敏度曲线。每次复测保持同一副耳机和 50% 音量，前后恢复对比即高度一致。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("重置为标准 50% 预设校准") {
                            audio.resetCalibrationToPreset()
                            store.updateSettingsFromAudio(audio)
                            store.showToast("已恢复标准 RETSPL 校准预设")
                        }
                        .font(.caption.bold())
                        .buttonStyle(.bordered)
                    } else if selectedCalibTab == 1 {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("单侧突聋强烈推荐：利用健康好耳在 1000 Hz 找到“刚刚能隐约听见”的临界点（或填入医院报告好耳 1000Hz 数值），一键消除耳机硬件差异。")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack {
                                Text("选择健康参考耳：").font(.caption.bold())
                                Picker("参考耳", selection: $calibRefEar) {
                                    Text("右耳 (R)").tag(EarSide.right)
                                    Text("左耳 (L)").tag(EarSide.left)
                                }
                                .pickerStyle(.segmented)
                            }

                            Stepper(value: $calibHospital1kDb, in: -5...40, step: 5) {
                                Text("参考耳医院 1000Hz 听阈：\(Int(calibHospital1kDb)) dB HL")
                                    .font(.caption.bold())
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("调节校准声大小（寻临界微弱声）：")
                                        .font(.caption)
                                    Spacer()
                                    Text("\(Int(calibRawDbfs)) dBFS")
                                        .font(.caption.monospacedDigit().bold())
                                }
                                Slider(value: $calibRawDbfs, in: -96...(-35), step: 1)
                            }

                            HStack(spacing: 10) {
                                Button("-2 dB") {
                                    calibRawDbfs = max(-96, calibRawDbfs - 2)
                                    audio.playStimulus(freq: 1000, dbHL: 10, ear: calibRefEar, waveform: .pulsed, rawDbfsOverride: calibRawDbfs)
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    audio.playStimulus(freq: 1000, dbHL: 10, ear: calibRefEar, waveform: .pulsed, rawDbfsOverride: calibRawDbfs)
                                } label: {
                                    Label("试听 1kHz 脉冲", systemImage: "play.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)

                                Button("+2 dB") {
                                    calibRawDbfs = min(-35, calibRawDbfs + 2)
                                    audio.playStimulus(freq: 1000, dbHL: 10, ear: calibRefEar, waveform: .pulsed, rawDbfsOverride: calibRawDbfs)
                                }
                                .buttonStyle(.bordered)
                            }
                            .font(.caption.bold())

                            Button {
                                audio.applyBiologicalCalibration(
                                    rawDbfs: calibRawDbfs,
                                    targetRefDbHL: calibHospital1kDb,
                                    method: .healthyEar1k
                                )
                                store.updateSettingsFromAudio(audio)
                                store.showToast("已锁定健侧耳 1000Hz 生物校准基准！")
                            } label: {
                                Text("确认刚刚可闻，锁定健侧校准基准")
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Masalski 文献生物校准：干燥双掌在鼻尖前 5cm 处轻轻快速对搓（约 55 dB SPL），微调滑块使耳机内 1000Hz 持续音与搓手声响度相等后锁定。")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack {
                                Text("匹配电平：")
                                    .font(.caption)
                                Spacer()
                                Text("\(Int(handRubRawDbfs)) dBFS")
                                    .font(.caption.monospacedDigit().bold())
                            }
                            Slider(value: $handRubRawDbfs, in: -70...(-15), step: 1)

                            HStack(spacing: 10) {
                                Button {
                                    let refEar: EarSide = store.settings.affectedSide == .left ? .right : .left
                                    audio.playStimulus(freq: 1000, dbHL: 50, ear: refEar, waveform: .continuous, rawDbfsOverride: handRubRawDbfs)
                                } label: {
                                    Label("播放对比音", systemImage: "speaker.wave.2.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)

                                Button {
                                    audio.applyBiologicalCalibration(
                                        rawDbfs: handRubRawDbfs,
                                        targetRefDbHL: 49.5,
                                        method: .handRub
                                    )
                                    store.updateSettingsFromAudio(audio)
                                    store.showToast("已锁定搓手声响度校准！")
                                } label: {
                                    Text("锁定此校准")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                            }
                            .font(.caption.bold())
                        }
                    }
                }
                .padding(16)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(14)

                // Big Proceed CTA
                Button {
                    audio.stopAmbientNoiseCheck()
                    store.selectedTab = 1
                } label: {
                    HStack {
                        Text("进入 125Hz → 8000Hz 低频往高频测听")
                            .font(.headline)
                        Image(systemName: "arrow.right.circle.fill")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
            }
            .padding(16)
        }
        .background(Color(UIColor.systemGroupedBackground))
        .onAppear {
            if store.settings.affectedSide == .left { calibRefEar = .right }
            else if store.settings.affectedSide == .right { calibRefEar = .left }
        }
    }
}
