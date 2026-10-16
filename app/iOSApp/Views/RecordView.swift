import SwiftUI

/// Tap, talk, tap. The words appear as you speak; stopping sends them to the Mac.
struct RecordView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = Recorder()
    @State private var typing = false
    @State private var typed = ""
    var startImmediately = false
    var onSent: (String) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 20) {
            transcript
            Spacer(minLength: 0)
            if typing {
                typeBox
            } else {
                controls
            }
        }
        .padding()
        .navigationTitle("Thought dump")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    Task {
                        await recorder.cancel()
                        dismiss()
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(typing ? "Speak instead" : "Type instead") {
                    withAnimation { typing.toggle() }
                }
                .disabled(recorder.isRecording)
            }
        }
        .task {
            if !Recorder.canTranscribe { typing = true }
            if startImmediately && !typing { await recorder.start() }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if recorder.text.isEmpty && !typing {
                        Text(recorder.isRecording ? "Listening…" : "Say “thought dump”, or just start: list what's on your mind, one thing after another.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    } else if !typing {
                        Text("\(Text(recorder.committed))\(recorder.committed.isEmpty ? "" : " ")\(Text(recorder.volatile).foregroundStyle(.secondary))")
                            .font(.title3)
                            .animation(.default, value: recorder.text)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: recorder.text) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(maxHeight: typing ? 0 : .infinity)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if let problem = recorder.problem {
                Text(problem).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            if recorder.isRecording {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Duration.seconds(recorder.duration).formatted(.time(pattern: .minuteSecond)))
                        .font(.title2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await toggle() }
            } label: {
                ZStack {
                    Circle()
                        .fill(recorder.isRecording ? Color.red.gradient : Color.indigo.gradient)
                        .frame(width: 96, height: 96)
                    Circle()
                        .stroke(Color.red.opacity(0.35), lineWidth: 10)
                        .frame(width: 96 + CGFloat(recorder.level) * 60, height: 96 + CGFloat(recorder.level) * 60)
                        .opacity(recorder.isRecording ? 1 : 0)
                        .animation(.easeOut(duration: 0.12), value: recorder.level)
                    if recorder.isPreparing {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 160, height: 160)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorder.isRecording ? "Stop and send" : "Start recording")
            Text(recorder.isRecording ? "Tap to stop and send" : "Tap to start")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 20)
    }

    private var typeBox: some View {
        VStack(spacing: 12) {
            TextField("What's on your mind? One thing after another.", text: $typed, axis: .vertical)
                .lineLimit(6...14)
                .padding(12)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            Button {
                send(typed, duration: nil)
            } label: {
                Label("Send to my Mac", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func toggle() async {
        if recorder.isRecording {
            let duration = recorder.duration
            let text = await recorder.stop()
            if text.isEmpty {
                recorder.problem = "Didn't catch anything. Try again, or type instead."
            } else {
                send(text, duration: duration)
            }
        } else {
            await recorder.start()
        }
    }

    private func send(_ text: String, duration: Double?) {
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let clientID = model.submit(text: text, durationSeconds: duration, device: device)
        onSent(clientID)
        dismiss()
    }
}
