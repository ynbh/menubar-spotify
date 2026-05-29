import SwiftUI

struct AccountBarView: View {
    let store: SpotifyStore

    var body: some View {
        HStack(spacing: 10) {
            PlaybackDeviceButton(store: store)

            if store.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            Button {
                Task { await store.refreshSession() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .help("Refresh Spotify Session")

            Button {
                store.signOut()
            } label: {
                Image(systemName: "person.crop.circle.badge.xmark")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .help("Sign Out")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }
}

private struct PlaybackDeviceButton: View {
    let store: SpotifyStore
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
            Task { await store.loadDevices() }
        } label: {
            Image(systemName: state.icon)
                .foregroundStyle(state.color)
        }
        .buttonStyle(.plain)
        .font(.callout.weight(.semibold))
        .help(helpText)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            DevicePickerView(store: store)
                .frame(width: 260)
                .padding(12)
        }
    }

    private var state: PlaybackDeviceState {
        guard let webPlaybackDeviceID = store.webPlaybackDeviceID else {
            if store.webPlaybackStatus != "Starting player..." {
                return .error
            }
            return .starting
        }

        if store.playbackDeviceID == webPlaybackDeviceID {
            return .menuBarActive
        }
        return .otherDeviceActive
    }

    private var helpText: String {
        if !store.errorMessage.isEmpty {
            return store.errorMessage
        }
        if store.webPlaybackDeviceID != nil {
            return currentDeviceName ?? store.webPlaybackStatus
        }
        return store.webPlaybackStatus
    }

    private var currentDeviceName: String? {
        if store.playbackDeviceID == store.webPlaybackDeviceID {
            return "MenuBar Spotify"
        }
        return store.devices.first { $0.id == store.playbackDeviceID }?.name ?? store.playback?.device?.name
    }
}

private struct DevicePickerView: View {
    let store: SpotifyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Playback Device")
                    .font(.headline)

                Spacer()

                Button {
                    Task { await store.loadDevices() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh Devices")
            }

            VStack(spacing: 2) {
                if let webPlaybackDevice = webPlaybackDevice {
                    DeviceRow(
                        title: "MenuBar Spotify",
                        subtitle: "This app",
                        isSelected: store.playbackDeviceID == webPlaybackDevice
                    ) {
                        Task {
                            await store.selectDevice(
                                SpotifyDevice(
                                    id: webPlaybackDevice,
                                    name: "MenuBar Spotify",
                                    type: "Computer",
                                    isActive: store.selectedDeviceID == webPlaybackDevice,
                                    isRestricted: false
                                )
                            )
                        }
                    }
                }

                ForEach(Array(visibleDevices.enumerated()), id: \.offset) { _, device in
                    DeviceRow(
                        title: device.name,
                        subtitle: device.type,
                        isSelected: device.id == store.playbackDeviceID
                    ) {
                        Task { await store.selectDevice(device) }
                    }
                    .disabled(device.id == nil || device.isRestricted)
                }

                if store.devices.isEmpty, store.webPlaybackDeviceID == nil {
                    Text("No devices found.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private var webPlaybackDevice: String? {
        store.webPlaybackDeviceID
    }

    private var visibleDevices: [SpotifyDevice] {
        var devices = store.devices
        if let playbackDevice = store.playback?.device,
           !devices.contains(where: { $0.matches(playbackDevice) }) {
            devices.insert(playbackDevice, at: 0)
        }

        var seen = Set<String>()
        return devices.filter { device in
            if let id = device.id, id == store.webPlaybackDeviceID {
                return false
            }

            return seen.insert(device.pickerIdentity).inserted
        }
    }
}

private struct DeviceRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.green : Color.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension SpotifyDevice {
    var pickerIdentity: String {
        id ?? "\(name)|\(type)"
    }

    func matches(_ other: SpotifyDevice) -> Bool {
        if let id, let otherID = other.id {
            return id == otherID
        }
        return name == other.name && type == other.type
    }
}

private enum PlaybackDeviceState {
    case starting
    case menuBarActive
    case otherDeviceActive
    case error

    var icon: String {
        switch self {
        case .starting:
            "hifispeaker"
        case .menuBarActive, .otherDeviceActive:
            "hifispeaker.fill"
        case .error:
            "hifispeaker.badge.exclamationmark"
        }
    }

    var color: Color {
        switch self {
        case .starting, .otherDeviceActive:
            .secondary
        case .menuBarActive:
            .green
        case .error:
            .orange
        }
    }
}
