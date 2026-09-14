//
//  FireplaceAudioController.swift
//  tinyFire
//
//  Hybrid hearth ambience:
//  - Seamless recorded campfire loop (CC0) as the bed
//  - Sparse procedural wood pops layered on top
//  Heat scales bed gain / crackle density; mutes when flame is hidden.
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class FireplaceAudioController: ObservableObject {
    private static let enabledKey = "sound.enabled"
    private static let volumeKey = "sound.volume"
    private static let loopResource = "campfire_loop"
    private static let loopExt = "caf"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            applyTargets()
        }
    }

    /// Master loudness 0…1 (user-facing).
    @Published var volume: Double {
        didSet {
            let clamped = min(1, max(0, volume))
            if clamped != volume {
                volume = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.volumeKey)
            applyTargets()
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let bedEQ = AVAudioUnitEQ(numberOfBands: 1)
    private var crackleNode: AVAudioSourceNode?
    private var loopBuffer: AVAudioPCMBuffer?
    private var started = false
    private var loopScheduled = false

    private let crackleState = CrackleRenderState()
    private var lastSnapshot = FireSnapshot.extinguished
    private var panelAudible = true

    /// Smoothed bed gain applied on the audio thread via player.volume.
    private var displayedBedGain: Float = 0

    init() {
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        if UserDefaults.standard.object(forKey: Self.volumeKey) == nil {
            volume = 0.48
        } else {
            volume = min(1, max(0, UserDefaults.standard.double(forKey: Self.volumeKey)))
        }
    }

    func start() {
        guard !started else {
            applyTargets()
            return
        }
        started = true
        installGraph()
        applyTargets()
        do {
            try engine.start()
            startLoopIfNeeded()
        } catch {
            started = false
        }
    }

    func stop() {
        player.stop()
        loopScheduled = false
        engine.stop()
        if let crackleNode {
            engine.detach(crackleNode)
            self.crackleNode = nil
        }
        if engine.attachedNodes.contains(player) {
            engine.detach(player)
        }
        if engine.attachedNodes.contains(bedEQ) {
            engine.detach(bedEQ)
        }
        started = false
    }

    func sync(snapshot: FireSnapshot, panelVisible: Bool) {
        lastSnapshot = snapshot
        panelAudible = panelVisible
        applyTargets()
        if !engine.isRunning, started {
            try? engine.start()
            startLoopIfNeeded()
        }
    }

    private func installGraph() {
        let main = engine.mainMixerNode
        let sampleRate = 44_100.0
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        // Low-shelf / lowpass feel: darker when cool, more open when hot.
        bedEQ.bands[0].filterType = .lowPass
        bedEQ.bands[0].frequency = 4_800
        bedEQ.bands[0].bandwidth = 0.8
        bedEQ.bands[0].gain = 0
        bedEQ.bands[0].bypass = false
        bedEQ.globalGain = 0

        engine.attach(player)
        engine.attach(bedEQ)
        engine.connect(player, to: bedEQ, format: mono)
        engine.connect(bedEQ, to: main, format: mono)

        loopBuffer = Self.loadLoopBuffer(format: mono)

        let shared = crackleState
        let node = AVAudioSourceNode(format: mono) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let buf = abl.first?.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            shared.render(into: buf, frameCount: Int(frameCount))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: main, format: mono)
        crackleNode = node

        player.volume = 0
        main.outputVolume = 1
    }

    private func startLoopIfNeeded() {
        guard let buffer = loopBuffer, !loopScheduled else { return }
        player.scheduleBuffer(buffer, at: nil, options: [.loops])
        if !player.isPlaying {
            player.play()
        }
        loopScheduled = true
    }

    private func applyTargets() {
        let heat = Self.heat(for: lastSnapshot)
        let master = (isEnabled && panelAudible) ? Float(volume) : 0

        // Recorded bed carries most of the character.
        let bed = master * (0.22 + heat * 0.78)
        // Extra pops stay sparse — loop already crackles.
        let tickGap = max(2.4, 14.0 - heat * 10.5)
        let popBias = 0.05 + heat * 0.12
        let activity = heat

        // Open the lowpass as the fire grows (cooler = darker / quieter highs).
        let cutoff = 1_600 + heat * 5_200
        bedEQ.bands[0].frequency = cutoff

        displayedBedGain += (bed - displayedBedGain) * 0.35
        player.volume = displayedBedGain

        crackleState.setTargets(
            crackleGain: master * (0.10 + heat * 0.28),
            tickGapSeconds: tickGap,
            popBias: popBias,
            activity: activity
        )

        if started, engine.isRunning {
            startLoopIfNeeded()
            if master > 0.001, !player.isPlaying {
                player.play()
            }
        }
    }

    private static func heat(for snap: FireSnapshot) -> Float {
        switch snap.phase {
        case .unlit, .out:
            return 0
        case .ember:
            return Float(0.08 + snap.emberHeat * 0.18)
        case .flame:
            let i = max(0, min(1, snap.intensity))
            return Float(0.18 + pow(i, 0.65) * 0.82)
        }
    }

    private static func loadLoopBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: loopResource, withExtension: loopExt) else {
            return nil
        }
        do {
            let file = try AVAudioFile(forReading: url)
            let frameCount = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
                return nil
            }
            try file.read(into: buffer)

            // Convert to engine mono format if needed.
            if file.processingFormat == format {
                return buffer
            }
            guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
                  let converted = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(
                        Double(frameCount) * format.sampleRate / file.processingFormat.sampleRate
                    ) + 32
                  )
            else {
                return buffer
            }
            var error: NSError?
            var supplied = false
            converter.convert(to: converted, error: &error) { _, outStatus in
                if supplied {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return buffer
            }
            return error == nil ? converted : buffer
        } catch {
            return nil
        }
    }
}

// MARK: - Sparse procedural crackles (audio thread)

private final class CrackleRenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var targetGain: Float = 0
    private var targetTickGap: Float = 5
    private var targetPopBias: Float = 0.1
    private var targetActivity: Float = 0

    private var crackleGain: Float = 0
    private var tickGap: Float = 5
    private var popBias: Float = 0.1
    private var activity: Float = 0

    private var samplesUntilEvent: Int = 36_000
    private var followUpsLeft: Int = 0
    private var voices: [CrackleVoice] = [CrackleVoice(), CrackleVoice(), CrackleVoice()]
    private var rngState: UInt64 = 0xC0FF_EE42_F1A5_BEEF

    func setTargets(crackleGain: Float, tickGapSeconds: Float, popBias: Float, activity: Float) {
        lock.lock()
        targetGain = crackleGain
        targetTickGap = tickGapSeconds
        targetPopBias = popBias
        targetActivity = activity
        lock.unlock()
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        lock.lock()
        let tgGain = targetGain
        let tgGap = targetTickGap
        let tgPop = targetPopBias
        let tgAct = targetActivity
        lock.unlock()

        let smooth: Float = 1.0 - expf(-1.0 / (0.05 * 44_100))

        for i in 0..<frameCount {
            crackleGain += (tgGain - crackleGain) * smooth
            tickGap += (tgGap - tickGap) * smooth
            popBias += (tgPop - popBias) * smooth
            activity += (tgAct - activity) * smooth

            let white = nextWhite()

            if activity > 0.02, crackleGain > 0.001 {
                samplesUntilEvent -= 1
                if samplesUntilEvent <= 0 {
                    triggerCrackle(isFollowUp: followUpsLeft > 0)
                    if followUpsLeft > 0 {
                        followUpsLeft -= 1
                        samplesUntilEvent = Int(18_000 + nextFloat() * 22_000)
                    } else {
                        scheduleNextGap()
                        if nextFloat() < 0.08 + activity * 0.06 {
                            followUpsLeft = 1
                        }
                    }
                }
            } else {
                samplesUntilEvent = max(samplesUntilEvent, 40_000)
                followUpsLeft = 0
            }

            var crackle: Float = 0
            for v in 0..<voices.count {
                crackle += voices[v].tick(white: white)
            }

            var sample = crackle * crackleGain
            sample = tanhf(sample * 1.05)
            buffer[i] = sample
        }
    }

    private func scheduleNextGap() {
        let mean = max(2.2, tickGap)
        let u = max(0.0001, nextFloat())
        let seconds = -logf(u) * mean
        let clamped = min(18.0, max(1.4, seconds))
        samplesUntilEvent = Int(clamped * 44_100)
    }

    private func triggerCrackle(isFollowUp: Bool) {
        guard let idx = voices.firstIndex(where: { !$0.active })
                ?? voices.indices.min(by: { voices[$0].env < voices[$1].env })
        else { return }

        let bigPop = !isFollowUp && nextFloat() < popBias
        if bigPop {
            voices[idx].trigger(
                amplitude: 0.48 + nextFloat() * 0.32,
                decay: 0.991 + nextFloat() * 0.004,
                brightness: 0.30 + nextFloat() * 0.16,
                thump: 0.45 + nextFloat() * 0.28
            )
        } else {
            voices[idx].trigger(
                amplitude: 0.26 + nextFloat() * 0.28,
                decay: 0.970 + nextFloat() * 0.016,
                brightness: 0.36 + nextFloat() * 0.20,
                thump: 0.18 + nextFloat() * 0.20
            )
        }
    }

    private func nextWhite() -> Float {
        nextFloat() * 2 - 1
    }

    private func nextFloat() -> Float {
        rngState ^= rngState >> 12
        rngState ^= rngState << 25
        rngState ^= rngState >> 27
        let r = rngState &* 0x2545F4914F6CDD1D
        return Float(r >> 40) / Float(1 << 24)
    }
}

private struct CrackleVoice {
    var active = false
    var env: Float = 0
    var decay: Float = 0.97
    var brightness: Float = 0.7
    var thump: Float = 0
    var hp: Float = 0
    var lp: Float = 0
    var amp: Float = 0

    mutating func trigger(amplitude: Float, decay: Float, brightness: Float, thump: Float) {
        active = true
        env = 1
        self.decay = decay
        self.brightness = brightness
        self.thump = thump
        amp = amplitude
        hp = 0
        lp = 0
    }

    mutating func tick(white: Float) -> Float {
        guard active else { return 0 }
        env *= decay
        if env < 0.001 {
            active = false
            env = 0
            return 0
        }

        let one: Float = 1
        let shaped: Float = white * brightness + (one - brightness) * lp
        lp = lp * 0.84 + white * 0.16
        let prev: Float = hp
        hp = shaped
        let high: Float = (hp - prev * 0.72) * 0.85
        let body: Float = lp * (0.70 + thump * 1.1)
        let attack: Float = env > 0.8 ? 1.15 : 1.0
        return (high * 1.05 + body) * env * amp * attack
    }
}
