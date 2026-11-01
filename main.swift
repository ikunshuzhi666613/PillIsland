import Cocoa
import QuartzCore
import CoreImage
import Accelerate
import ScreenCaptureKit

// MARK: - Now playing model

struct NowPlayingTrack {
    let title: String
    let artist: String
    let playing: Bool
    let duration: Double
    let elapsed: Double
    var artwork: CGImage?
    let artworkToken: String
    let identifier: String
    let bundleIdentifier: String
    let processIdentifier: pid_t
    let capturedAt: Date?
}

// MARK: - Now playing monitor (Streams MediaRemote via the BSD-licensed adapter)

final class NowPlayingMonitor {
    var onChange: ((NowPlayingTrack?) -> Void)?

    private var process: Process?
    private var buffer = Data()
    private var running = false
    private var restartWorkItem: DispatchWorkItem?

    private var lastIdentifier = ""
    private var lastArtwork: CGImage?
    private var lastArtworkToken = ""

    func start() {
        guard !running else { return }
        guard let resources = Bundle.main.resourceURL else { return }

        killStaleAdapters()

        let dir = resources.appendingPathComponent("MediaRemoteAdapter")
        let script = dir.appendingPathComponent("mediaremote-adapter.pl").path
        let framework = dir.appendingPathComponent("MediaRemoteAdapter.framework").path
        let client = dir.appendingPathComponent("MediaRemoteAdapterTestClient").path
        guard FileManager.default.fileExists(atPath: script) else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = [script, framework, client, "stream", "--no-diff", "--debounce=150"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.append(data)
        }

        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.process = nil
                if self.running { self.scheduleRestart() }
            }
        }

        do {
            try task.run()
        } catch {
            scheduleRestart()
            return
        }

        process = task
        running = true
    }

    func stop() {
        running = false
        restartWorkItem?.cancel()
        restartWorkItem = nil
        process?.terminate()
        process = nil
    }

    private func scheduleRestart() {
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.running else { return }
            self.start()
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Removes adapters orphaned by a previous (force-killed) instance.
    private func killStaleAdapters() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "PillIsland.app/Contents/Resources/MediaRemoteAdapter/mediaremote-adapter.pl"]
        try? task.run()
        task.waitUntilExit()
    }

    private func append(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            handle(line: line)
        }
    }

    private func handle(line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }

        let payload: [String: Any]
        if let inner = object["payload"] as? [String: Any] {
            payload = inner
        } else {
            payload = object
        }

        guard !payload.isEmpty else {
            emit(nil)
            return
        }

        var title = ((payload["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var artist = ((payload["artist"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            if artist.isEmpty {
                title = "正在播放"
            } else {
                title = artist
                artist = ""
            }
        }

        let rate = payload["playbackRate"] as? Double
        let explicit = payload["playing"] as? Bool
        let playing = (explicit ?? true) && ((rate ?? 1) > 0.001)
        let identifier = "\((payload["uniqueIdentifier"] as? String) ?? "")|\(title)|\(artist)" 
        let duration = (payload["duration"] as? Double) ?? 0
        let elapsed = (payload["elapsedTime"] as? Double) ?? 0

        var artwork: CGImage? = nil
        var artworkToken = ""
        if let encoded = payload["artworkData"] as? String, !encoded.isEmpty {
            artworkToken = "\(encoded.count)-\(encoded.prefix(24))-\(encoded.suffix(12))"
            if artworkToken == lastArtworkToken, let cached = lastArtwork {
                artwork = cached
            } else if let data = Data(base64Encoded: encoded),
                      let image = NSImage(data: data),
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                artwork = cgImage
                lastArtwork = cgImage
                lastArtworkToken = artworkToken
            }
        }
        lastIdentifier = identifier

        let bundleIdentifier = (payload["bundleIdentifier"] as? String) ?? ""
        let processIdentifier = pid_t((payload["processIdentifier"] as? Int) ?? 0)
        let capturedAt = (payload["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let track = NowPlayingTrack(title: title,
                                    artist: artist,
                                    playing: playing,
                                    duration: duration,
                                    elapsed: elapsed,
                                    artwork: artwork,
                                    artworkToken: artworkToken,
                                    identifier: identifier,
                                    bundleIdentifier: bundleIdentifier,
                                    processIdentifier: processIdentifier,
                                    capturedAt: capturedAt)
        emit(track)
    }

    private func emit(_ track: NowPlayingTrack?) {
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(track)
        }
    }
}

// MARK: - System audio meter

final class AudioMeter: NSObject, SCStreamOutput {
    var onLevels: (([CGFloat]) -> Void)?

    private var stream: SCStream?
    private var started = false
    private let queue = DispatchQueue(label: "com.lanyuan.pillisland.audio")
    private var fftSetup: FFTSetup?
    private let fftLog2n: vDSP_Length = 10
    private let fftSize = 1024
    private var window: [Float] = []
    private var smoothed = [CGFloat](repeating: 0, count: 6)
    private var runningPeak: CGFloat = 0.3
    private var loggedFormat = false
    private var audioCallbackCount = 0

    var targetBundleID: String? {
        didSet {
            if targetBundleID != oldValue { restart() }
        }
    }

    private func restart() {
        stream?.stopCapture { _ in }
        stream = nil
        started = false
        start()
    }

    func start() {
        guard !started else { return }
        guard let bundle = targetBundleID else { return }
        started = true

        if fftSetup == nil { fftSetup = vDSP_create_fftsetup(fftLog2n, FFTRadix(kFFTRadix2)) }
        if window.isEmpty {
            window = [Float](repeating: 0, count: fftSize)
            vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        }

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self = self else { return }
            if let error = error {
                _ = error
                return
            }
            guard let display = content?.displays.first else { return }
            guard let app = content?.applications.first(where: { $0.bundleIdentifier == bundle }) else {
                self.started = false
                return
            }

            let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
            config.showsCursor = false
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            do {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
            } catch {
                _ = error
                return
            }
            stream.startCapture { _ in }
            self.stream = stream

        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        audioCallbackCount += 1

        var needed = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &needed,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil)
        guard status == noErr, needed > 0 else {
            return
        }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed,
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let listPointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer,
            bufferListSize: needed,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == noErr else {
            return
        }

        let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
        guard let first = buffers.first, let data = first.mData else {
            return
        }
        let sampleCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        guard sampleCount > 256 else {
            return
        }
        let samples = data.bindMemory(to: Float.self, capacity: sampleCount)

        let levels = analyze(samples, count: sampleCount)
        if audioCallbackCount % 30 == 1 {
        }
        DispatchQueue.main.async { [weak self] in
            self?.onLevels?(levels)
        }
    }

    private func analyze(_ samples: UnsafePointer<Float>, count: Int) -> [CGFloat] {
        guard let setup = fftSetup else { return smoothed }

        let n = fftSize
        var input = [Float](repeating: 0, count: n)
        let take = min(count, n)
        vDSP_vmul(samples, 1, window, 1, &input, 1, vDSP_Length(take))

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var magnitudes = [Float](repeating: 0, count: n / 2)

        input.withUnsafeBufferPointer { buffer in
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    buffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(n / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, fftLog2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
                }
            }
        }

        // Log-spaced bands over the audible range.
        var bands = [CGFloat](repeating: 0, count: 6)
        let minBin = 2
        let maxBin = n / 2 - 1
        for band in 0..<6 {
            let low = Double(minBin) * pow(Double(maxBin) / Double(minBin), Double(band) / 6.0)
            let high = Double(minBin) * pow(Double(maxBin) / Double(minBin), Double(band + 1) / 6.0)
            let start = max(minBin, Int(low))
            let end = min(maxBin, max(start + 1, Int(high)))
            var peak: Float = 0
            for bin in start..<end { peak = max(peak, magnitudes[bin]) }
            let db = 20 * log10(max(peak / Float(n), 0.000001))
            bands[band] = CGFloat(max(0, min(1, (db + 60) / 45)))
        }

        // Auto gain: keep the bars using the full range even for quiet audio.
        let currentPeak = bands.max() ?? 0
        runningPeak = max(currentPeak, runningPeak * 0.995)
        let normalizer = max(0.22, runningPeak)
        for i in 0..<6 {
            bands[i] = min(1, bands[i] / normalizer)
        }

        // smooth
        for i in 0..<6 {
            let target = bands[i]
            smoothed[i] = target > smoothed[i]
                ? smoothed[i] + (target - smoothed[i]) * 0.95
                : smoothed[i] + (target - smoothed[i]) * 0.30
        }
        return smoothed
    }
}

// MARK: - Pill view

final class PillView: NSView {
    private let pill = CALayer()
    private let siriContainer = CALayer()
    private var siriOrbits: [CALayer] = []
    private var siriSpecs: [(radius: CGFloat, size: CGFloat)] = []

    private let artStage = CALayer()
    private let dimOverlay = CALayer()
    private let artworkLayer = CALayer()
    private let titleLayer = CATextLayer()
    private let artistLayer = CATextLayer()
    private var equalizer: [CALayer] = []
    private var barBase: [CGFloat] = []
    private var tintIdentifier = ""
    private var lastArtworkToken = ""
    private var lastPlaybackState = true
    private var barsOn = false
    private var lastRawElapsed: Double = -1
    private var lastRawElapsedAt = Date()
    private var silentByWatchdog = false
    private var audioLevels: [CGFloat]?
    private var quietTicks = 0
    private var audioEverWorked = false
    private var hasArtworkForTrack = false
    private var tintFromArtwork = false
    private let blurOverlay = CALayer()
    private let ciContext = CIContext()
    private var currentBlurredArtwork: CGImage?
    private var blurTimer: Timer?
    private var tintColor = NSColor(white: 0.92, alpha: 1)

    private let progressTrack = CALayer()
    private let progressFill = CALayer()
    private let elapsedLabel = CATextLayer()
    private let remainingLabel = CATextLayer()

    private var controls: [CALayer] = []
    private var controlFrames: [CGRect] = []
    private let controlCommands = [5, 2, 4]

    var onCommand: ((Int) -> Void)?
    var onNeedSync: (() -> Void)?
    var onSeek: ((Double) -> Void)?

    private var hovered = false
    private var dormant = false
    private var dormancyWork: DispatchWorkItem?
    private var track: NowPlayingTrack?
    private var collapseWorkItem: DispatchWorkItem?
    private var progressTimer: Timer?

    private var seeking = false
    private var seekFraction: CGFloat = 0
    private var progressFrame: CGRect = .zero
    private var baseElapsed: Double = 0
    private var baseDate = Date()
    private var lastTrackID = ""
    private var lastPlaying = false
    private var resyncBlockedUntil = Date.distantPast

    private let pillHeight: CGFloat = 26
    private let idleWidth: CGFloat = 48
    private let compactWidth: CGFloat = 112
    private let siriWidth: CGFloat = 200
    private let cardWidth: CGFloat = 300
    private let cardHeight: CGFloat = 155

    private enum Mode { case idle, siri, compact, card }

    private var mode: Mode {
        if track != nil && !dormant { return hovered ? .card : .compact }
        return .idle
    }

    private var modeSize: CGSize {
        switch mode {
        case .idle: return CGSize(width: idleWidth, height: pillHeight)
        case .siri: return CGSize(width: siriWidth, height: pillHeight)
        case .compact: return CGSize(width: compactWidth, height: pillHeight)
        case .card: return CGSize(width: cardWidth, height: cardHeight)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        pill.backgroundColor = NSColor(calibratedWhite: 0.02, alpha: 1.0).cgColor
        pill.cornerRadius = pillHeight / 2
        pill.cornerCurve = .continuous
        pill.masksToBounds = true
        pill.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        pill.position = CGPoint(x: bounds.midX, y: bounds.maxY - pillHeight / 2)
        pill.bounds = CGRect(x: 0, y: 0, width: idleWidth, height: pillHeight)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 500.0
        pill.sublayerTransform = perspective
        layer?.addSublayer(pill)

        siriContainer.masksToBounds = true
        siriContainer.cornerRadius = pillHeight / 2
        siriContainer.opacity = 0
        pill.addSublayer(siriContainer)
        setupSiri()

        artStage.cornerCurve = .continuous
        artStage.masksToBounds = true
        artStage.opacity = 0
        pill.addSublayer(artStage)

        artworkLayer.contentsGravity = .resizeAspectFill
        artworkLayer.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1.0).cgColor
        artworkLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        artStage.addSublayer(artworkLayer)

        blurOverlay.contentsGravity = .resizeAspectFill
        blurOverlay.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        blurOverlay.opacity = 0
        artStage.addSublayer(blurOverlay)

        dimOverlay.backgroundColor = NSColor.black.cgColor
        dimOverlay.opacity = 0
        artStage.addSublayer(dimOverlay)

        prepareText(titleLayer, alignment: .left)
        prepareText(artistLayer, alignment: .left)
        titleLayer.opacity = 0
        artistLayer.opacity = 0
        pill.addSublayer(titleLayer)
        pill.addSublayer(artistLayer)

        for _ in 0..<6 {
            let bar = CALayer()
            bar.backgroundColor = NSColor(white: 1.0, alpha: 0.9).cgColor
            bar.cornerRadius = 0.75
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.bounds = CGRect(x: 0, y: 0, width: 1.5, height: 10)
            bar.opacity = 0
            pill.addSublayer(bar)
            equalizer.append(bar)
        }

        progressTrack.backgroundColor = NSColor(white: 1.0, alpha: 0.22).cgColor
        progressTrack.cornerRadius = 2.5
        progressTrack.opacity = 0
        pill.addSublayer(progressTrack)

        progressFill.backgroundColor = NSColor(white: 0.88, alpha: 1.0).cgColor
        progressFill.cornerRadius = 2.5
        progressFill.opacity = 0
        pill.addSublayer(progressFill)

        prepareText(elapsedLabel, alignment: .left)
        prepareText(remainingLabel, alignment: .right)
        elapsedLabel.opacity = 0
        remainingLabel.opacity = 0
        pill.addSublayer(elapsedLabel)
        pill.addSublayer(remainingLabel)

        let controlNames = ["backward.fill", "pause.fill", "forward.fill"]
        for (index, name) in controlNames.enumerated() {
            let isMiddle = (index == 1)
            let button = CALayer()
            button.contents = symbolImage(name, pointSize: isMiddle ? 30 : 26)
            button.contentsGravity = .resizeAspect
            let box: CGFloat = isMiddle ? 36 : 30
            button.bounds = CGRect(x: 0, y: 0, width: box, height: box)
            button.opacity = 0
            pill.addSublayer(button)
            controls.append(button)
            controlFrames.append(.zero)
        }

        // Pre-lay-out the card state so the very first expansion has no
        // stray frame animations pulling content out of (0, 0).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutCard()
        CATransaction.commit()

        layoutContents(animated: false)

        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.updateEqualizerBars()
            if self.mode == .card, !self.seeking {
                self.updateProgressUI()
            }
        }
        if let timer = progressTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        progressTimer?.invalidate()
    }

    // MARK: Siri glow

    private func setupSiri() {
        let palette: [NSColor] = [.systemPink, .systemPurple, .systemBlue, .systemTeal]
        let specs: [(radius: CGFloat, size: CGFloat, duration: Double, clockwise: Bool)] = [
            (12, 46, 4.2, true), (9, 40, 5.6, false), (14, 52, 6.8, true), (7, 34, 3.6, false)
        ]

        for (index, color) in palette.enumerated() {
            let spec = specs[index]
            let orbit = CALayer()
            orbit.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            orbit.opacity = 0.9

            let blob = CAGradientLayer()
            blob.type = .radial
            blob.colors = [color.withAlphaComponent(0.85).cgColor,
                           color.withAlphaComponent(0.35).cgColor,
                           color.withAlphaComponent(0.0).cgColor]
            blob.locations = [0.0, 0.55, 1.0]
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1.0, y: 1.0)
            orbit.addSublayer(blob)

            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0.0
            spin.toValue = (spec.clockwise ? 1.0 : -1.0) * 2.0 * Double.pi
            spin.duration = spec.duration
            spin.repeatCount = .infinity
            orbit.add(spin, forKey: "spin")

            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 0.82
            pulse.toValue = 1.18
            pulse.duration = 1.4 + Double(index) * 0.35
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            blob.add(pulse, forKey: "pulse")

            siriContainer.addSublayer(orbit)
            siriOrbits.append(orbit)
            siriSpecs.append((spec.radius, spec.size))
        }
    }

    private func layoutSiri(width: CGFloat) {
        siriContainer.bounds = CGRect(x: 0, y: 0, width: width, height: pillHeight)
        siriContainer.position = CGPoint(x: width / 2, y: pillHeight / 2)
        for (index, orbit) in siriOrbits.enumerated() {
            let spec = siriSpecs[index]
            orbit.bounds = CGRect(x: 0, y: 0, width: width, height: pillHeight)
            orbit.position = CGPoint(x: width / 2, y: pillHeight / 2)
            orbit.sublayers?.first?.frame = CGRect(x: width / 2 + spec.radius - spec.size / 2,
                                                   y: pillHeight / 2 - spec.size / 2,
                                                   width: spec.size, height: spec.size)
        }
    }

    // MARK: Helpers

    private func prepareText(_ layer: CATextLayer, alignment: CATextLayerAlignmentMode) {
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.alignmentMode = alignment
        layer.isWrapped = false
        layer.truncationMode = .none
    }

    private func fitted(_ text: String, font: NSFont, width: CGFloat) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        if (text as NSString).size(withAttributes: attributes).width <= width {
            return text
        }
        var characters = Array(text)
        while !characters.isEmpty {
            characters.removeLast()
            let candidate = String(characters) + "…"
            if (candidate as NSString).size(withAttributes: attributes).width <= width {
                return candidate
            }
        }
        return "…"
    }

    private func symbolImage(_ name: String, pointSize: CGFloat) -> CGImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            NSColor.white.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        return tinted.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func averageColor(of image: CGImage) -> NSColor? {
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: 1, height: 1,
                                          bitsPerComponent: 8, bytesPerRow: 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }

        let color = NSColor(srgbRed: CGFloat(pixel[0]) / 255,
                            green: CGFloat(pixel[1]) / 255,
                            blue: CGFloat(pixel[2]) / 255,
                            alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(hue: hue,
                       saturation: max(0.45, min(1, saturation)),
                       brightness: max(0.72, min(1, brightness)),
                       alpha: 1)
    }

    private func applyBarColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in equalizer {
            bar.backgroundColor = tintColor.cgColor
        }
        CATransaction.commit()
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func currentElapsed() -> Double {
        guard let t = track else { return 0 }
        var value = baseElapsed
        if t.playing {
            value += Date().timeIntervalSince(baseDate)
        }
        return min(t.duration, max(0, value))
    }

    private func progressFraction() -> CGFloat {
        guard let t = track, t.duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, currentElapsed() / t.duration)))
    }

    // MARK: Track updates

    func apply(track newTrack: NowPlayingTrack?) {
        let previousMode = mode

        if let t = newTrack {
            // Keep the local clock authoritative; only re-sync on a real
            // change or a large drift, never on every metadata push.
            let estimate = currentElapsed()
            let changedTrack = (t.identifier != lastTrackID)
            let changedPlayback = (t.playing != lastPlaying)
            let drifted = abs(t.elapsed - estimate) > 2.0
            let bogusZero = t.elapsed < 0.5 && estimate > 3 && !changedTrack
            if !bogusZero && (changedTrack || changedPlayback || (drifted && Date() > resyncBlockedUntil)) {
                let atEnd = t.duration > 0 && t.elapsed >= t.duration - 0.5
                baseElapsed = (changedTrack && atEnd) ? 0 : t.elapsed
                // The reported elapsed belongs to the payload's timestamp, not
                // to "now"; anchoring there keeps the bar actually live.
                if let captured = t.capturedAt,
                   abs(Date().timeIntervalSince(captured)) < 30 {
                    baseDate = captured
                } else {
                    baseDate = Date()
                }
            }
            lastTrackID = t.identifier
            lastPlaying = t.playing
        }

        if let t = newTrack, t.elapsed != lastRawElapsed {
            lastRawElapsed = t.elapsed
            lastRawElapsedAt = Date()
            silentByWatchdog = false
        }

        track = newTrack
        if newTrack == nil {
            hovered = false
            updateEqualizerBars()
        } else if let t = newTrack {
            updateMusicLayers(t)
        }

        if let t = newTrack {
            if t.playing {
                cancelDormancy()
            } else if dormancyWork == nil {
                // Only start the 5s countdown once; progress pushes must not
                // keep resetting it.
                scheduleDormancy()
            }
        } else {
            cancelDormancy()
        }

        let newMode = mode
        if newMode != previousMode {
            // Only a real state change re-lays-out and re-fades the content;
            // a plain track/time update must never blink the island.
            syncWindow()
            layoutContents(animated: true, spring: newMode == .card)
            updateVisibility(animated: true)
        } else if newMode == .card {
            updateProgressUI()
        }
    }

    private func updateMusicLayers(_ t: NowPlayingTrack) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let artistAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor(white: 1.0, alpha: 0.55)
        ]

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        titleLayer.string = NSAttributedString(string: fitted(t.title, font: NSFont.systemFont(ofSize: 14, weight: .semibold), width: 150), attributes: titleAttrs)
        artistLayer.string = NSAttributedString(string: fitted(t.artist, font: NSFont.systemFont(ofSize: 11.5, weight: .regular), width: 150), attributes: artistAttrs)
        controls[1].contents = symbolImage(t.playing ? "pause.fill" : "play.fill", pointSize: 30)
        CATransaction.commit()

        if t.artworkToken != lastArtworkToken {
            lastArtworkToken = t.artworkToken
            hasArtworkForTrack = (t.artwork != nil)
            if let artwork = t.artwork {
                flipArtwork(to: artwork)
            } else {
                setPlaceholderArtwork()
            }
        } else if !hasArtworkForTrack, let artwork = t.artwork {
            // Cover art often arrives one update after the title.
            hasArtworkForTrack = true
            flipArtwork(to: artwork)
        }

        if let artwork = t.artwork {
            if !tintFromArtwork || t.artworkToken != tintIdentifier {
                tintIdentifier = t.identifier
                tintFromArtwork = true
                if let tint = averageColor(of: artwork) {
                    tintColor = tint
                    applyBarColor()
                }
            }
        } else if t.artworkToken != tintIdentifier {
            tintIdentifier = t.artworkToken
            tintFromArtwork = false
            tintColor = NSColor(white: 0.92, alpha: 1)
            applyBarColor()
        }

        updateEqualizerBars()
        updateArtworkPlaybackState(t.playing)
        updateProgressUI()
    }

    private func setPlaceholderArtwork() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artworkLayer.contents = symbolImage("music.note", pointSize: 20)
        artworkLayer.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1.0).cgColor
        blurOverlay.contents = nil
        currentBlurredArtwork = nil
        CATransaction.commit()
    }

    private func blurredImage(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return ciContext.createCGImage(output, from: input.extent)
    }

    private func startBlurRamp(total: TimeInterval) {
        blurTimer?.invalidate()
        let began = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let progress = min(1.0, Date().timeIntervalSince(began) / total)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.blurOverlay.opacity = Float(sin(Double.pi * progress))
            CATransaction.commit()
            if progress >= 1 {
                timer.invalidate()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.blurOverlay.opacity = 0
                CATransaction.commit()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        blurTimer = timer
    }


    private func flipArtwork(to image: CGImage) {
        let half = 0.30
        let newBlurred = blurredImage(image, radius: 16)
        blurOverlay.removeAnimation(forKey: "flipIn")
        blurOverlay.removeAnimation(forKey: "flipOut")
        blurOverlay.contents = currentBlurredArtwork
        currentBlurredArtwork = newBlurred
        startBlurRamp(total: half * 2)
        artworkLayer.removeAnimation(forKey: "flipOut")

        let out = CABasicAnimation(keyPath: "transform.rotation.y")
        out.fromValue = 0.0
        out.toValue = -Double.pi / 2
        out.duration = half
        out.timingFunction = CAMediaTimingFunction(name: .easeIn)
        out.fillMode = .forwards
        out.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setAnimationDuration(half)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self = self else { return }
            self.artworkLayer.removeAnimation(forKey: "flipOut")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.artworkLayer.contents = image
            self.artworkLayer.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1.0).cgColor
            self.blurOverlay.contents = self.currentBlurredArtwork
            CATransaction.commit()

            let incoming = CABasicAnimation(keyPath: "transform.rotation.y")
            incoming.fromValue = Double.pi / 2
            incoming.toValue = 0.0
            incoming.duration = half
            incoming.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.artworkLayer.add(incoming, forKey: "flipIn")
            self.blurOverlay.add(incoming, forKey: "flipIn")
        }
        artworkLayer.add(out, forKey: "flipOut")
        blurOverlay.add(out, forKey: "flipOut")
        CATransaction.commit()
    }

    private func updateArtworkPlaybackState(_ playing: Bool) {
        guard playing != lastPlaybackState else { return }
        lastPlaybackState = playing

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.30)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        let scale: CGFloat = playing ? 1.0 : 0.88
        artStage.transform = CATransform3DMakeScale(scale, scale, 1)
        dimOverlay.opacity = playing ? 0.0 : 0.45
        CATransaction.commit()
    }

    private func timeAttributed(_ text: String) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor(white: 1.0, alpha: 0.5)
        ]
        return NSAttributedString(string: text, attributes: attrs)
    }

    func resyncElapsed(_ elapsed: Double) {
        guard let t = track, elapsed >= 0 else { return }
        // A freshly opened player sometimes reports 0 even though it has been
        // playing for a while; do not let that reset the bar to the start.
        if elapsed < 0.5 && currentElapsed() > 3 { return }
        baseElapsed = min(elapsed, t.duration)
        baseDate = Date()
        updateProgressUI()
    }

    private func updateProgressUI() {
        guard let t = track else { return }
        let fraction = seeking ? seekFraction : progressFraction()
        let elapsed = seeking ? Double(seekFraction) * t.duration : currentElapsed()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressFill.frame = CGRect(x: 52, y: 60, width: max(0, 196 * fraction), height: 5)
        elapsedLabel.string = timeAttributed(timeString(elapsed))
        remainingLabel.string = timeAttributed("-" + timeString(max(0, t.duration - elapsed)))
        CATransaction.commit()
    }

    func setAudioLevels(_ levels: [CGFloat]) {
        let peak = levels.max() ?? 0
        if peak < 0.02 {
            quietTicks += 1
        } else {
            quietTicks = 0
            audioEverWorked = true
        }

        if !audioEverWorked && quietTicks > 80 {
            // Give up on the live meter and fall back to the decorative bounce.
            if audioLevels != nil {
                audioLevels = nil
                barsOn = false
                updateEqualizerBars()
            }
            return
        }

        audioLevels = levels
        guard barsOn else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in equalizer.enumerated() {
            let level = max(0, min(1, levels.indices.contains(index) ? levels[index] : 0))
            let boosted = pow(level, 0.42)
            let scale = max(0.15, min(1.85, 0.15 + 1.75 * boosted))
            bar.transform = CATransform3DMakeScale(1, scale, 1)
        }
        CATransaction.commit()
    }

    private func updateEqualizerBars() {
        let active = (track?.playing == true) && !dormant
        guard active != barsOn else { return }
        barsOn = active
        setEqualizerActive(active)
    }

    private func setEqualizerActive(_ active: Bool) {
        for (index, bar) in equalizer.enumerated() {
            bar.removeAnimation(forKey: "bounce")
            let base = barBase.indices.contains(index) ? max(1, barBase[index]) : 10
            if active {
                bar.transform = CATransform3DIdentity
                if audioLevels != nil { continue }
                let animation = CABasicAnimation(keyPath: "transform.scale.y")
                animation.fromValue = 0.22
                animation.toValue = 1.0
                animation.duration = 0.34 + Double(index % 4) * 0.09
                animation.autoreverses = true
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animation.timeOffset = Double(index) * 0.13
                bar.add(animation, forKey: "bounce")
            } else {
                // Paused: a calm flat line, still at full opacity.
                bar.transform = CATransform3DMakeScale(1, min(1, 2.0 / base), 1)
            }
        }
    }

    // MARK: Layout

    private func layoutContents(animated: Bool, spring: Bool = false) {
        let size = modeSize

        CATransaction.begin()
        if animated {
            if spring {
                CATransaction.setAnimationDuration(0.44)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.34, 1.20, 0.56, 1.0))
            } else {
                CATransaction.setAnimationDuration(0.30)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.40, 0.0, 0.60, 1.0))
            }
        } else {
            CATransaction.setDisableActions(true)
        }

        pill.bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        pill.cornerRadius = (mode == .card) ? 26 : size.height / 2
        pill.position = CGPoint(x: bounds.midX, y: bounds.maxY - size.height / 2)

        switch mode {
        case .card: layoutCard()
        case .compact: layoutCompact()
        case .siri: layoutSiri(width: size.width)
        case .idle: break
        }

        CATransaction.commit()
    }

    private func layoutCompact() {
        artStage.cornerRadius = 6
        artStage.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
        artStage.position = CGPoint(x: 14, y: 13)
        let small = CGRect(origin: .zero, size: artStage.bounds.size)
        artworkLayer.frame = small
        blurOverlay.frame = small
        dimOverlay.frame = small
        let compactHeights: [CGFloat] = [3, 6, 9, 11, 9, 6]
        barBase = compactHeights
        for (index, bar) in equalizer.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: 1.5, height: compactHeights[index])
            bar.position = CGPoint(x: compactWidth - 10 - CGFloat(5 - index) * 3.2, y: 13)
        }
    }

    private func layoutCard() {
        artStage.cornerRadius = 12
        artStage.bounds = CGRect(x: 0, y: 0, width: 54, height: 54)
        artStage.position = CGPoint(x: 43, y: 116)
        let large = CGRect(origin: .zero, size: artStage.bounds.size)
        artworkLayer.frame = large
        blurOverlay.frame = large
        dimOverlay.frame = large
        titleLayer.frame = CGRect(x: 82, y: 105, width: 156, height: 18)
        artistLayer.frame = CGRect(x: 82, y: 89, width: 156, height: 14)

        let cardHeights: [CGFloat] = [8, 11, 14, 14, 11, 8]
        barBase = cardHeights
        for (index, bar) in equalizer.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: 1.5, height: cardHeights[index])
            bar.position = CGPoint(x: 276 - CGFloat(5 - index) * 3.6, y: 118)
        }

        progressTrack.frame = CGRect(x: 52, y: 60, width: 196, height: 5)
        progressFrame = CGRect(x: 46, y: 52, width: 208, height: 20)
        elapsedLabel.frame = CGRect(x: 16, y: 56, width: 36, height: 15)
        remainingLabel.frame = CGRect(x: 248, y: 56, width: 42, height: 15)
        updateProgressUI()

        let slots: [CGFloat] = [78, 150, 222]
        for (index, button) in controls.enumerated() {
            let w = button.bounds.width
            let h = button.bounds.height
            button.position = CGPoint(x: slots[index], y: 28)
            controlFrames[index] = CGRect(x: slots[index] - w / 2, y: 28 - h / 2, width: w, height: h)
        }
    }

    private func updateVisibility(animated: Bool) {
        let hasTrack = track != nil
        let isCard = (mode == .card)

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.16 : 0)
        if !animated { CATransaction.setDisableActions(true) }

        siriContainer.opacity = (mode == .siri) ? 1.0 : 0.0
        for bar in equalizer {
            bar.opacity = (hasTrack && !dormant) ? 1.0 : 0.0
        }
        artStage.opacity = (hasTrack && !isCard && !dormant) ? 1.0 : 0.0

        CATransaction.commit()

        CATransaction.begin()
        if isCard {
            CATransaction.setAnimationDuration(0.14)
            artStage.opacity = 1
            titleLayer.opacity = 1
            artistLayer.opacity = 1
            progressTrack.opacity = 1
            progressFill.opacity = 1
            elapsedLabel.opacity = 1
            remainingLabel.opacity = 1
            for button in controls { button.opacity = 1 }
        } else {
            CATransaction.setDisableActions(true)
            titleLayer.opacity = 0
            artistLayer.opacity = 0
            progressTrack.opacity = 0
            progressFill.opacity = 0
            elapsedLabel.opacity = 0
            remainingLabel.opacity = 0
            for button in controls { button.opacity = 0 }
        }
        blurOverlay.opacity = 0
        CATransaction.commit()
    }



    // MARK: Hover

    private var desiredWindowHeight: CGFloat {
        mode == .card ? cardHeight + 8 : pillHeight
    }

    private var pillFrame: CGRect {
        let size = modeSize
        return CGRect(x: bounds.midX - size.width / 2,
                      y: bounds.maxY - size.height,
                      width: size.width,
                      height: size.height)
    }

    private func scheduleDormancy() {
        dormancyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let t = self.track, !t.playing else { return }
            self.dormant = true
            self.hovered = false
            self.syncWindow()
            self.layoutContents(animated: true)
            self.updateVisibility(animated: true)
        }
        dormancyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
    }

    private func cancelDormancy() {
        dormancyWork?.cancel()
        dormancyWork = nil
        dormant = false
    }



    private func setHovered(_ value: Bool) {
        // Idle island no longer reacts to hover; only playback expands it.
        guard track != nil, !dormant else { return }
        guard value != hovered else { return }
        hovered = value
        if value, track != nil { onNeedSync?() }
        syncWindow()
        layoutContents(animated: true, spring: true)
        updateVisibility(animated: true)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHovered(pillFrame.contains(point))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHovered(pillFrame.contains(point))
    }

    override func mouseExited(with event: NSEvent) {
        if let window = window, window.frame.contains(NSEvent.mouseLocation) {
            return
        }
        setHovered(false)
    }

    // MARK: Window sizing

    private func syncWindow() {
        guard let window = window else { return }
        let target = desiredWindowHeight
        let current = window.frame.height
        guard abs(target - current) > 0.5 else { return }

        if target > current {
            resizeWindow(to: target)
        } else {
            collapseWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.resizeWindow(to: self.desiredWindowHeight)
                self.layoutContents(animated: false)
                self.window?.displayIfNeeded()
            }
            collapseWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.52, execute: work)
        }
    }

    private func resizeWindow(to height: CGFloat) {
        guard let window = window, let screen = window.screen ?? NSScreen.main else { return }
        let topGap: CGFloat = 5
        var frame = window.frame
        frame.size.height = height
        frame.origin.x = screen.frame.midX - frame.width / 2
        frame.origin.y = screen.frame.maxY - topGap - height
        window.setFrame(frame, display: false)
    }

    // MARK: Clicks

    override func mouseDown(with event: NSEvent) {
        guard track != nil, mode == .card else { return }
        let point = convert(event.locationInWindow, from: nil)
        let frame = pillFrame
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)

        for (index, controlFrame) in controlFrames.enumerated() where controlFrame.insetBy(dx: -6, dy: -6).contains(local) {
            onCommand?(controlCommands[index])
            return
        }

        if progressFrame.contains(local) {
            seeking = true
            seekFraction = min(1, max(0, (local.x - 52) / 196))
            updateProgressUI()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard seeking, let t = track else { return }
        let point = convert(event.locationInWindow, from: nil)
        let frame = pillFrame
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        _ = t
        seekFraction = min(1, max(0, (local.x - 52) / 196))
        updateProgressUI()
    }

    override func mouseUp(with event: NSEvent) {
        guard seeking else { return }
        guard let t = track else {
            seeking = false
            updateProgressUI()
            return
        }
        seeking = false
        let current = currentElapsed()
        var target = Double(seekFraction) * t.duration
        // NetEase ignores seeks shorter than ~1.5s; nudge a tiny jump so it lands.
        if target != current, abs(target - current) < 1.5 {
            let direction: Double = target > current ? 1 : -1
            target = min(t.duration, max(0, current + direction * 1.5))
        }
        baseElapsed = target
        baseDate = Date()
        resyncBlockedUntil = Date().addingTimeInterval(2.0)
        updateProgressUI()
        onSeek?(target)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var statusItem: NSStatusItem?
    private let monitor = NowPlayingMonitor()
    private let audioMeter = AudioMeter()
    private weak var pillView: PillView?
    private var lastTrack: NowPlayingTrack?
    private let commandQueue = DispatchQueue(label: "com.lanyuan.pillisland.media-commands")
    private var signalSources: [DispatchSourceSignal] = []

    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 26
    private let topGap: CGFloat = 5

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let rect = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        let panel = NSPanel(contentRect: rect,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true

        // The window changes height while expanding, but the island lives on a
        // fixed-height stage pinned to the window's top edge, so it never moves.
        let container = NSView(frame: rect)
        let pill = PillView(frame: NSRect(x: 0, y: rect.height - 163, width: rect.width, height: 163))
        pill.autoresizingMask = [.minYMargin]
        pill.onCommand = { [weak self] command in
            self?.sendMediaCommand(command)
        }
        pill.onSeek = { [weak self] seconds in
            self?.sendSeek(seconds)
        }
        pill.onNeedSync = { [weak self] in
            self?.refreshElapsed()
        }
        self.pillView = pill
        container.addSubview(pill)
        panel.contentView = container
        self.panel = panel

        positionPanel()
        panel.orderFrontRegardless()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                self?.reattachPanelToAllSpaces()
            }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            self?.positionPanel()
        }

        setupStatusItem()
        installSignalHandlers()

        monitor.onChange = { [weak pill, weak self] track in
            pill?.apply(track: track)
            self?.lastTrack = track
            self?.audioMeter.targetBundleID = track?.bundleIdentifier
        }
        monitor.start()

        audioMeter.onLevels = { [weak pill] levels in
            pill?.setAudioLevels(levels)
        }
        audioMeter.start()
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.monitor.stop()
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }

    private func sendMediaCommand(_ command: Int) {
        runAdapter(["send", String(command)])
    }

    private func refreshElapsed() {
        commandQueue.async { [weak self] in
            guard let self = self, let elapsed = self.nowPlayingElapsed() else { return }
            DispatchQueue.main.async {
                self.pillView?.resyncElapsed(elapsed)
            }
        }
    }

    private func sendSeek(_ seconds: Double) {
        let micros = Int(seconds * 1_000_000)
        commandQueue.async { [weak self] in
            guard let self = self else { return }
            for _ in 0..<3 {
                _ = self.runAdapterSync(["seek", String(micros)])
                Thread.sleep(forTimeInterval: 0.28)
                if let elapsed = self.nowPlayingElapsed(), abs(elapsed - seconds) < 1.6 {
                    return
                }
            }
        }
    }

    private func nowPlayingElapsed() -> Double? {
        let (_, output) = runAdapterSync(["get"])
        guard let data = output.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let elapsed = object["elapsedTime"] as? Double else { return nil }
        if let stamp = object["timestamp"] as? String,
           let captured = ISO8601DateFormatter().date(from: stamp) {
            let delta = Date().timeIntervalSince(captured)
            if delta > -1 && delta < 30 { return elapsed + delta }
        }
        return elapsed
    }

    @discardableResult
    private func runAdapterSync(_ arguments: [String]) -> (Int32, String) {
        guard let resources = Bundle.main.resourceURL else { return (-1, "") }
        let dir = resources.appendingPathComponent("MediaRemoteAdapter")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = [dir.appendingPathComponent("mediaremote-adapter.pl").path,
                          dir.appendingPathComponent("MediaRemoteAdapter.framework").path,
                          dir.appendingPathComponent("MediaRemoteAdapterTestClient").path] + arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func runAdapter(_ arguments: [String]) {
        guard let resources = Bundle.main.resourceURL else { return }
        let dir = resources.appendingPathComponent("MediaRemoteAdapter")
        let script = dir.appendingPathComponent("mediaremote-adapter.pl").path
        let framework = dir.appendingPathComponent("MediaRemoteAdapter.framework").path
        let client = dir.appendingPathComponent("MediaRemoteAdapterTestClient").path

        commandQueue.async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            task.arguments = [script, framework, client] + arguments
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                return
            }
        }
    }

    private func reattachPanelToAllSpaces() {
        guard let panel = panel else { return }

        // Re-apply the behaviour after a Space change without ordering the
        // panel out, so there is no visible gap.
        panel.collectionBehavior = []

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let panel = self.panel else { return }
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            panel.setIsVisible(true)
            panel.orderFrontRegardless()
            panel.contentView?.needsDisplay = true
        }
    }

    private func positionPanel() {
        guard let panel = panel else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = panel.frame.size
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - topGap - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "capsule", accessibilityDescription: "Pill")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示 / 隐藏药丸", action: #selector(togglePanel), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出药丸", action: #selector(quit), keyEquivalent: "q"))
        for entry in menu.items {
            entry.target = self
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel() {
        guard let panel = panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            positionPanel()
            panel.orderFrontRegardless()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
