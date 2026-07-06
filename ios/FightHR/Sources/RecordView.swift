import SwiftUI
import AVFoundation

struct RecordView: View {
    @EnvironmentObject var hr: HeartRateMonitor
    @EnvironmentObject var store: Store
    @EnvironmentObject var engine: SessionEngine
    @Environment(\.dismiss) private var dismiss
    @StateObject private var rec = VideoRecorder()

    private var zone: Int { Zones.zoneOf(hr.bpm, store.profile) }

    var body: some View {
        ZStack {
            CameraPreview(session: rec.session).ignoresSafeArea()

            VStack {
                // live overlay preview (matches what gets burned in)
                HStack {
                    Text("\(hr.bpm > 0 ? "\(hr.bpm)" : "--") BPM   \(hr.bpm > 0 && zone >= 0 ? Theme.zoneNames[zone] : "—")")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.black.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
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
            rec.overlayProvider = { (hr.bpm, Zones.zoneOf(hr.bpm, store.profile)) }
            if !hr.status.isLive { hr.connect() }
            requestCameraThenConfigure()
        }
        .onDisappear {
            // A running training session still wants the screen awake.
            UIApplication.shared.isIdleTimerDisabled = engine.running
            rec.stopSession()
        }
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
