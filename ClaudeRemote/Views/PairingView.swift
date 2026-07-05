import SwiftUI

struct PairingView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var relay: RelayHub

    @State private var input = ""
    @State private var failed = false
    @State private var showScanner = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    brand
                    statusCard
                    scanButton
                    pairBox
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .background(theme.screen.ignoresSafeArea())
        .fullScreenCover(isPresented: $showScanner) { scannerCover }
    }

    private var scanButton: some View {
        Button { showScanner = true } label: {
            HStack(spacing: 9) {
                Image(systemName: "qrcode.viewfinder").font(.system(size: 18, weight: .semibold))
                Text("Scan QR code").font(AppFont.sans(15, .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(theme.blurple, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var scannerCover: some View {
        ZStack {
            QRScannerView { scanned in
                if relay.add(scanned) {
                    showScanner = false   // device added — stay here so the list shows it
                } else {
                    showScanner = false
                    failed = true
                }
            }
            .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button { showScanner = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                }
                Spacer()
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.white.opacity(0.85), lineWidth: 3)
                    .frame(width: 230, height: 230)
                Spacer()
                Text("Point at the QR shown by `npm run agent`")
                    .font(AppFont.sans(13, .medium))
                    .foregroundStyle(.white)
                    .padding(.bottom, 40)
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack {
            Text("Connect a Mac")
                .font(AppFont.sans(20, .bold))
                .foregroundStyle(theme.white)
            Spacer()
            Button("Done") { dismiss() }
                .font(AppFont.sans(14, .semibold))
                .foregroundStyle(theme.sub)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var brand: some View {
        VStack(spacing: 9) {
            SignalLogoTile(size: 76)
            Text("HALX")
                .font(AppFont.sans(22, .bold))
                .foregroundStyle(theme.white)
            Text("REMOTE FOR CLAUDE CODE")
                .font(AppFont.mono(10))
                .tracking(1.5)
                .foregroundStyle(theme.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    /// All paired Macs, each independently connected — scan another QR to add one;
    /// re-scanning a Mac refreshes its key.
    @ViewBuilder
    private var statusCard: some View {
        if !relay.devices.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("PAIRED MACS")
                    .font(AppFont.sans(11, .bold))
                    .tracking(0.5)
                    .foregroundStyle(theme.faint)
                    .padding(.bottom, 8)
                ForEach(relay.devices) { device in
                    DeviceRow(
                        device: device,
                        onToggle: { on in relay.setEnabled(device.id, on) },
                        onRemove: { relay.remove(device) }
                    )
                    if device.id != relay.devices.last?.id {
                        Rectangle().fill(theme.border).frame(height: 1)
                    }
                }
            }
            .padding(14)
            .background(theme.card)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var pairBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OR PASTE MANUALLY")
                .font(AppFont.sans(11, .bold))
                .tracking(0.5)
                .foregroundStyle(theme.faint)
            Text("Run `npm run agent` on your Mac, then scan the QR above or paste the printed pairing string here.")
                .font(AppFont.sans(12.5))
                .foregroundStyle(theme.muted)
            ZStack(alignment: .topLeading) {
                if input.isEmpty {
                    Text("Paste pairing string…")
                        .font(AppFont.mono(12))
                        .foregroundStyle(theme.faint)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 12)
                }
                TextEditor(text: $input)
                    .font(AppFont.mono(12))
                    .foregroundStyle(theme.ink)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(height: 92)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .background(theme.input)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(failed ? theme.red : theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if failed {
                Text("That doesn't look like a valid pairing string.")
                    .font(AppFont.sans(11.5))
                    .foregroundStyle(theme.red)
            }

            Button {
                if relay.add(input) {
                    failed = false
                    input = ""
                } else {
                    failed = true
                }
            } label: {
                Text("Connect")
                    .font(AppFont.sans(15, .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(theme.blurple, in: RoundedRectangle(cornerRadius: 8))
                    .opacity(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

}

/// One paired Mac: status · remembered hostname · connect switch · remove.
/// Nothing connects by default — the switch is the user's explicit action.
private struct DeviceRow: View {
    @Environment(\.theme) private var theme
    let device: RelayHub.Device
    var onToggle: (Bool) -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let client = device.client {
                DeviceLiveStatus(client: client, label: device.label)
            } else {
                Circle().fill(theme.faint.opacity(0.35)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.label)
                        .font(AppFont.sans(14, .semibold))
                        .foregroundStyle(theme.muted)
                    Text("Not connected")
                        .font(AppFont.sans(11))
                        .foregroundStyle(theme.faint)
                }
            }
            Spacer(minLength: 6)
            // Button-drawn switch — a plain SwiftUI Toggle here never received taps
            // (sheet+ScrollView hit-testing quirk); Buttons demonstrably do.
            Button { onToggle(!device.enabled) } label: {
                ZStack(alignment: device.enabled ? .trailing : .leading) {
                    Capsule()
                        .fill(device.enabled ? theme.blurple : theme.input)
                        .frame(width: 46, height: 28)
                    Circle()
                        .fill(.white)
                        .frame(width: 24, height: 24)
                        .padding(2)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                }
                .animation(.easeInOut(duration: 0.15), value: device.enabled)
            }
            .buttonStyle(.plain)
            Button(action: onRemove) {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.red.opacity(0.85))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 9)
    }
}

/// Live half of a connected device row (observes the client for state + count).
private struct DeviceLiveStatus: View {
    @Environment(\.theme) private var theme
    @ObservedObject var client: RelayClient
    let label: String

    var body: some View {
        Circle().fill(dotColor).frame(width: 8, height: 8)
        VStack(alignment: .leading, spacing: 1) {
            Text(client.deviceLabel.hasPrefix("Mac ·") ? label : client.deviceLabel)
                .font(AppFont.sans(14, .semibold))
                .foregroundStyle(theme.ink)
            Text(stateText)
                .font(AppFont.sans(11))
                .foregroundStyle(theme.faint)
        }
        if client.state == .online {
            Text("\(client.sessions.count) sessions")
                .font(AppFont.mono(11))
                .foregroundStyle(theme.faint)
        }
    }

    private var stateText: String {
        switch client.state {
        case .online: return "Connected"
        case .connecting: return "Connecting…"
        case .offline: return "Offline — retrying"
        }
    }

    private var dotColor: Color {
        switch client.state {
        case .online: return theme.greenText
        case .connecting: return theme.gold
        case .offline: return theme.red
        }
    }
}
