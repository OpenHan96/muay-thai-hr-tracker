import SwiftUI
import AVFoundation

struct RecordView: View {
    @EnvironmentObject var hr: HeartRateMonitor
    @EnvironmentObject var store: Store
    @EnvironmentObject var engine: SessionEngine
    @Environment(\.dismiss) private var dismiss
    @StateObject private var rec = VideoRecorder()

    private var zone: Int { Zones.zoneOf(hr.bpm, store.profile) }
    private var liveHR: Bool { hr.bpm > 0 && hr.isFresh }

    var body: some View {
        ZStack {
            CameraPreview(session: rec.session).ignoresSafeArea()

            VStack {
                // live overlay preview (matches what gets burned in)
                HStack {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in hrBadge }
                    Spacer()
                }
                .padding()

                // HR connection status — tap to (re)connect without leaving the camera
                HStack {
                    Button {
                        if !hr.status.isLive { hr.connect() }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(hr.status.isLive ? Theme.good : Color.gray)
                                .frame(width: 8, height: 8)
                            Text(hr.status.isLive ? hr.status.label : "\(hr.status.label) — tap to connect")
                                .font(.caption).bold()
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.black.opacity(0.35))
                        .clipShape(Capsule())
                    }
                    Spacer()
                }
                .padding(.horizontal)

                Spacer()

                if let msg = rec.savedMessage {
                    Text(msg).foregroundStyle(.white).padding(8)
                        .background(.black.opacity(0.5)).clipShape(Capsule())
                }

                HStack {
                    Button(rec.isRecording ? "Stop" : "Close") {
                        if rec.isRecording {
                            rec.finish()          // save first; user closes after seeing the message
                        } else {
                            rec.stopSession()
                            dismiss()
                        }
                    }
                    .foregroundStyle(.white).padding()
                    Spacer()
                    if rec.isRecording {
                        Text(fmtTime(rec.elapsed)).foregroundStyle(.white).monospacedDigit().bold()
                        Spacer()
                    }
                    Button { rec.toggle() } label: {
                        Circle().fill(rec.isRecording ? Color.white : Theme.accent)
                            .frame(width: 64, height: 64)
                            .overlay(rec.isRecording
                                ? AnyView(RoundedRectangle(cornerRadius: 4).fill(Theme.accent).frame(width: 24, height: 24))
                                : AnyView(EmptyView()))
                            .overlay(Circle().stroke(.white, lineWidth: 4))
                    }
                    .disabled(!rec.ready)
                    Spacer()
                    Color.clear.frame(width: 60)   // balance the Close button
                }
                .padding(.bottom, 24)
            }
        }
        .background(.black)
        .onAppear {
            // Keep the screen awake — auto-lock kills the camera session and
            // was silently ending recordings.
            UIApplication.shared.isIdleTimerDisabled = true
            let monitor = hr, s = store
            rec.overlayProvider = { [weak monitor, weak s] in
                // Stale signal burns in "--"/NO SIGNAL, never a frozen number.
                guard let monitor, let s, monitor.bpm > 0, monitor.isFresh else { return (0, -1) }
                return (monitor.bpm, Zones.zoneOf(monitor.bpm, s.profile))
            }
            if !hr.status.isLive { hr.connect() }
            requestCameraThenConfigure()
        }
        .onDisappear {
            // A running training session still wants the screen awake.
            UIApplication.shared.isIdleTimerDisabled = engine.running
            rec.stopSession()
        }
    }

    /// SwiftUI twin of the badge VideoRecorder burns into the video.
    private var hrBadge: some View {
        let live = liveHR
        let z = live ? zone : -1
        let inZone = live && z >= 0
        let darkText = z == 2 || z == 3
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(live ? Theme.accent : .white.opacity(0.35))
                Text(live ? "\(hr.bpm)" : "--")
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                Text("BPM")
                    .font(.system(size: 12, weight: .bold)).tracking(3)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Text(VideoRecorder.pillLabel(bpm: live ? hr.bpm : 0, zone: z))
                .font(.system(size: 12, weight: .heavy)).tracking(1.5)
                .foregroundStyle(inZone ? (darkText ? Theme.bg : .white) : .white.opacity(0.7))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(inZone ? Theme.zoneColors[z] : Color.white.opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(12)
        .background(.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func requestCameraThenConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: rec.configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                if ok {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in rec.configure() }
                }
            }
        default: break   // denied — preview stays black; user can fix in Settings
        }
    }
}

/// Hosts the live camera preview layer.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.videoPreviewLayer.session = session
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
