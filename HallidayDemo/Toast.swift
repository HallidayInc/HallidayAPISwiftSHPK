import Observation
import SwiftUI

struct LoggedError: Identifiable {
    let id = UUID()
    let message: String
    let origin: String
    let date: Date
}

@MainActor
@Observable
final class Toast {
    static let shared = Toast()
    private static let historyLimit = 100

    private(set) var message: String?
    private(set) var note: String?
    private(set) var history: [LoggedError] = []
    @ObservationIgnored private var dismissal: Task<Void, Never>?
    @ObservationIgnored private var noteDismissal: Task<Void, Never>?

    // Confirmations are transient and deliberately kept out of the error history.
    static func copy(_ value: String, label: String) {
        UIPasteboard.general.string = value
        shared.note = "\(label) copied"
        shared.noteDismissal?.cancel()
        shared.noteDismissal = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            shared.note = nil
        }
    }

    // #fileID is "HallidayDemo/SendFlow.swift"; only the file name is worth showing.
    static func origin(_ file: String, _ line: Int) -> String {
        "\(file.split(separator: "/").last.map(String.init) ?? file):\(line)"
    }

    func show(_ message: String, file: String = #fileID, line: Int = #line) {
        let origin = Self.origin(file, line)
        self.message = "\(message)\n\(origin)"
        history.insert(LoggedError(message: message, origin: origin, date: .now), at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        dismissal?.cancel()
        dismissal = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self.message = nil
        }
    }

    // The call site is forwarded so the log points at whoever caught the error, not at this file.
    func report(_ error: Error, file: String = #fileID, line: Int = #line) {
        if let error = error as? LocalizedError, let description = error.errorDescription {
            show(description, file: file, line: line)
        } else {
            show(String(describing: error), file: file, line: line)
        }
    }

    func dismiss() {
        dismissal?.cancel()
        message = nil
    }
}

struct ToastOverlay: View {
    private let toast = Toast.shared

    var body: some View {
        VStack(spacing: 8) {
            if let note = toast.note {
                Text(note)
                    .haffer(13, .regular)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.85), in: .capsule)
            }
            if let message = toast.message {
                Text(message)
                    .haffer(13, .regular)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.red.opacity(0.92), in: .rect(cornerRadius: 10))
                    .onTapGesture { toast.dismiss() }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

extension View {
    func toasts() -> some View {
        overlay(alignment: .bottom) { ToastOverlay() }
    }
}
