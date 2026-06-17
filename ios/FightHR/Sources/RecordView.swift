import SwiftUI
import AVFoundation

struct RecordView: View {
    @EnvironmentObject var hr: HeartRateMonitor
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var rec = VideoRecorder()

    private var zone: Int { Zones.zoneOf(hr.bpm, store.profile) }

    var body: some View {
        ZStack {
            CameraPreview(session: rec.session).ignoresSafeArea()

            VStack {
                // live overlay preview (matches what gets burned in)
                HStack {
                    if hr.bpm > 0 {
                        Text("\(hr.bpm) BPM   \(zone < 0 ? "—" : Theme.zoneNames[zone])")
                            .font(.system(size: 22, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.black.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Spacer()
                }
                .padding()

                Spacer()

                if let msg = rec.savedMessage {
                    Text(msg).foregroundStyle(.white).padding(8)
                        .background(.black.opacity(0.5)).clipShape(Capsule())
                }

                HStack {
                    Button("Close") { rec.stopSession(); dismiss() }
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
            rec.overlayProvider = { (hr.bpm, Zones.zoneOf(hr.bpm, store.profile)) }
            requestCameraThenConfigure()
        }
        .onDisappear { rec.stopSession() }
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
