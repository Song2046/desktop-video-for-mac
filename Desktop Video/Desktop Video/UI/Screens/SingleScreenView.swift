import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// Controls for a single screen's wallpaper.
struct SingleScreenView: View {
    let screen: NSScreen
    @ObservedObject private var appState = AppState.shared

    @State private var volume: Double = 100
    @State private var stretchToFill: Bool = true
    @State private var isLocallyMuted: Bool = false
    @State private var lastVolumeBeforeMute: Double = 100
    @State private var currentFileName: String = ""
    
    // MARK: - 新增：倍速控制状态
    @State private var selectedSpeed: Float = 1.0
    private let playbackSpeeds: [Float] = [0.5, 1.0, 1.5, 2.0]
    
    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            HStack(spacing: 8) {
                Button(action: chooseMedia) { Text(L("Choose Video…")).font(.system(size: 15)) }
                Button(action: clear) { Text(L("Clear")).font(.system(size: 15)) }
                Button(action: play) { Text(L("Play")).font(.system(size: 15)) }
                Button(action: pause) { Text(L("Pause")).font(.system(size: 15)) }
                Button(action: syncAll) { Text(L("Sync same videos")).font(.system(size: 15)) }
            }
            .frame(minWidth: 400)
            
            // 2. 当前播放信息
            if !currentFileName.isEmpty {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(L("NowPlaying"))).font(.system(size: 12))
                    Text(currentFileName).font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
            }
            
            HStack(spacing: 12) {
                SliderInputRow(title: LocalizedStringKey(L("Volume")), value: $volume, range: 0...100)
                    .disabled(isMuteEffective)
                    .onChange(of: volume) { newValue in
                        let clamped = min(max(newValue, 0), 100)
                        volume = clamped
                        guard !isMuteEffective else { return }
                        SharedWallpaperWindowManager.shared.setVolume(Float(clamped / 100.0), for: screen)
                    }

                Picker("", selection: $selectedSpeed) {
                    ForEach(playbackSpeeds, id: \.self) { speed in
                        Text("\(String(format: "%.1f", speed))x").tag(speed)
                    }
                }
                .frame(width: 70)
                .labelsHidden()
                .onChange(of: selectedSpeed) { newSpeed in
                    dlog("UI: Speed changed to \(newSpeed) for \(screen.dv_localizedName)")
                    SharedWallpaperWindowManager.shared.setPlaybackSpeed(newSpeed, for: screen)
                }

                // 静音开关
                Toggle(
                    LocalizedStringKey(L("Mute")),
                    isOn: Binding(
                        get: { isMuteEffective },
                        set: { handleMuteToggle($0) }
                    )
                )
                .toggleStyle(.checkbox)
            }
            .font(.system(size: 15))
            
            ToggleRow(title: LocalizedStringKey(L("Stretch to fill")), value: $stretchToFill)
                .onChange(of: stretchToFill) { newValue in
                    updateStretch(newValue)
                }
                .font(.system(size: 15))
        }
        .frame(minWidth: 440, maxWidth: 600)
        .onAppear(perform: syncInitialState)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("WallpaperContentDidChange"))) { _ in
            refreshStateFromManager()
        }
        .onChange(of: screen.dv_displayUUID) { _ in
            dlog("screen changed; sync controls for \(screen.dv_localizedName)")
            syncInitialState()
        }
        .onChange(of: appState.isGlobalMuted) { enabled in
            dlog("observed global mute change = \(enabled) for \(screen.dv_localizedName)")
            if enabled {
                lastVolumeBeforeMute = max(volume, 0)
            } else {
                refreshStateFromManager()
            }
        }
    }

    // MARK: - Actions

    private func chooseMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            dlog("chooseMedia url=\(url.lastPathComponent)")
            if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
                if type.conforms(to: .image) {
                    SharedWallpaperWindowManager.shared.showImage(for: screen, url: url, stretch: stretchToFill)
                } else {
                    SharedWallpaperWindowManager.shared.showVideo(
                        for: screen,
                        url: url,
                        stretch: stretchToFill,
                        volume: isMuteEffective ? 0 : Float(volume / 100)
                    )

                    SharedWallpaperWindowManager.shared.setPlaybackSpeed(selectedSpeed, for: screen)
                }
            }
        }
    }
    
    private func clear() {
        dlog("clear wallpaper for \(screen.dv_localizedName)")
        SharedWallpaperWindowManager.shared.clear(for: screen)
    }
    
    private func play() {
        let sid = screen.dv_displayUUID
        dlog("play wallpaper for \(screen.dv_localizedName)")

        SharedWallpaperWindowManager.shared.players[sid]?.play()
        SharedWallpaperWindowManager.shared.players[sid]?.rate = selectedSpeed
    }
    
    private func pause() {
        let sid = screen.dv_displayUUID
        dlog("pause wallpaper for \(screen.dv_localizedName)")
        SharedWallpaperWindowManager.shared.players[sid]?.pause()
    }

    private func syncAll() {
        dlog("sync same-name videos across screens")
        SharedWallpaperWindowManager.shared.syncSameNamedVideos()
    }

    private func updateStretch(_ stretch: Bool) {
        let sid = screen.dv_displayUUID
        if let entry = SharedWallpaperWindowManager.shared.screenContent[sid] {
            switch entry.type {
            case .image:
                SharedWallpaperWindowManager.shared.showImage(for: screen, url: entry.url, stretch: stretch)
            case .video:
                SharedWallpaperWindowManager.shared.showVideo(
                    for: screen,
                    url: entry.url,
                    stretch: stretch,
                    volume: isMuteEffective ? 0 : Float(volume / 100)
                )
                 SharedWallpaperWindowManager.shared.setPlaybackSpeed(selectedSpeed, for: screen)
            }
        }
        dlog("update stretch \(stretch) for \(screen.dv_localizedName)")
    }

    private func syncInitialState() {
        refreshStateFromManager()
        dlog("sync controls for \(screen.dv_localizedName)")
    }

    private func refreshStateFromManager() {
        let sid = screen.dv_displayUUID
        
        if let player = SharedWallpaperWindowManager.shared.players[sid] {
            let newVolume = Double(player.volume * 100)
            volume = newVolume
            if newVolume > 0 {
                lastVolumeBeforeMute = newVolume
            }
            if !appState.isGlobalMuted {
                isLocallyMuted = player.volume == 0
            }
        }
        
        if let entry = SharedWallpaperWindowManager.shared.screenContent[sid] {
            stretchToFill = entry.stretch
            currentFileName = entry.url.lastPathComponent
        } else {
            currentFileName = ""
        }
        
        if let rate = SharedWallpaperWindowManager.shared.playbackRates[sid] {
            selectedSpeed = rate
        } else {
            selectedSpeed = 1.0
        }
        
        dlog("refresh state for \(screen.dv_localizedName) speed=\(selectedSpeed) file=\(currentFileName)")
    }

    private func handleMuteToggle(_ newValue: Bool) {
        if appState.isGlobalMuted {
            if !newValue {
                dlog("toggle off per-screen mute while global mute active on \(screen.dv_localizedName)")
                desktop_videoApp.applyGlobalMute(false)
                isLocallyMuted = false
            }
            return
        }

        if newValue {
            lastVolumeBeforeMute = volume
            isLocallyMuted = true
            SharedWallpaperWindowManager.shared.setVolume(0, for: screen)
            dlog("muted volume for \(screen.dv_localizedName)")
        } else {
            let clamped = min(max(lastVolumeBeforeMute, 0), 100)
            volume = clamped
            isLocallyMuted = false
            SharedWallpaperWindowManager.shared.setVolume(Float(clamped / 100.0), for: screen)
            dlog("unmuted; restore volume \(clamped) for \(screen.dv_localizedName)")
        }
    }

    private var isMuteEffective: Bool {
        appState.isGlobalMuted || isLocallyMuted
    }
}
