import CoreBluetooth
import SwiftUI
import UIKit

@main
struct OrbitCubeApp: App {
    @StateObject private var remote = CubeRemote()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section("Bluetooth") {
                        Text(remote.message)
                            .foregroundStyle(.secondary)
                        if remote.connecting || remote.status != nil {
                            Button("Disconnect", action: remote.disconnect)
                        } else {
                            Button(remote.scanning ? "Looking for cubes…" : "Find Cube",
                                   action: remote.findCubes)
                                .disabled(!remote.bluetoothReady || remote.scanning)
                            ForEach(remote.cubes, id: \.identifier) { cube in
                                Button {
                                    remote.connect(cube)
                                } label: {
                                    Label(cube.name ?? "Orbit Cube", systemImage: "cube")
                                }
                            }
                        }
                    }
                    if let status = remote.status {
                        Section("Orbit Clip") {
                            LabeledContent("Commander", value: parkLabel(status.park))
                            LabeledContent("Clip", value: clipLabel(status.clip))
                            if status.clip == .closed {
                                Button("Open Orbit Clip") { remote.setClip(open: true) }
                                    .disabled(remote.busy || status.park != .ready)
                            } else {
                                Button("Close Orbit Clip") { remote.setClip(open: false) }
                                    .disabled(remote.busy)
                            }
                        }
                        if status.clip != .closed {
                            Section("Send a Video") {
                                LabeledContent("Password") {
                                    Text(status.password).monospaced()
                                }
                                Button("Copy Wi-Fi Password") {
                                    UIPasteboard.general.string = status.password
                                }
                                Text("Join the Wi-Fi shown on your display (TITA-Clip or Orbit-Clip), then return here.")
                                    .foregroundStyle(.secondary)
                                ClipVideoPicker(parked: status.park == .ready)
                                Link("Open in Safari", destination: URL(string: "http://192.168.9.1")!)
                            }
                        }
                    }
                }
                .navigationTitle("Orbit Cube")
            }
        }
    }

    private func parkLabel(_ park: CubeStatus.Park) -> String {
        switch park {
        case .ready: return "Parked and ready"
        case .waitingForData: return "Waiting for live data"
        case .needsPark: return "Park and stop"
        }
    }

    private func clipLabel(_ clip: CubeStatus.Clip) -> String {
        switch clip {
        case .closed: return "Closed"
        case .ready: return "Wi-Fi ready"
        case .playing: return "Playing"
        }
    }
}
