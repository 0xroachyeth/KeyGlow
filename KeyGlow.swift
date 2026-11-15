import SwiftUI
import AppKit
import AVFoundation
import CoreAudio
import ApplicationServices

// MARK: - Backlight (private CoreBrightness API)

final class Backlight {
    private let client: NSObject?
    private(set) var keyboardID: UInt64 = 0
    private var originalLevel: Float = 0.5
    private var originalAuto = false
    private var active = false

    private typealias GetF = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias GetB = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    private typealias SetBQ = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool
    private typealias SetFade = @convention(c) (AnyObject, Selector, Float, Int32, Bool, UInt64) -> Bool

    var available: Bool { client != nil }

    init() {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { client = nil; return }
        let c = cls.init()
        client = c
        let ids = (c.perform(Selector(("copyKeyboardBacklightIDs")))?.takeRetainedValue() as? [NSNumber]) ?? []
        let builtIn = ids.first { callB("isKeyboardBuiltIn:", $0.uint64Value) }
        keyboardID = (builtIn ?? ids.first)?.uint64Value ?? 1
    }

    private func imp<T>(_ name: String, _ t: T.Type) -> (T, Selector)? {
        guard let c = client else { return nil }
        let sel = Selector((name))
        guard c.responds(to: sel) else { return nil }
        return (unsafeBitCast(c.method(for: sel), to: t), sel)
    }
    private func callB(_ name: String, _ id: UInt64) -> Bool {
        guard let (f, s) = imp(name, GetB.self) else { return false }
        return f(client!, s, id)
    }
    private func setFlag(_ name: String, _ on: Bool) {
        guard let (f, s) = imp(name, SetBQ.self) else { return }
        _ = f(client!, s, on, keyboardID)
    }

    var level: Float {
        guard let (f, s) = imp("brightnessForKeyboard:", GetF.self) else { return 0 }
        return f(client!, s, keyboardID)
    }

    func set(_ v: Float, commit: Bool = false) {
        guard let (f, s) = imp("setBrightness:fadeSpeed:commit:forKeyboard:", SetFade.self) else { return }
        _ = f(client!, s, max(0, min(1, v)), 0, commit, keyboardID)
    }

    func begin() {
        guard !active else { return }
        active = true
        originalLevel = level
        originalAuto = callB("isAutoBrightnessEnabledForKeyboard:", keyboardID)
        setFlag("enableAutoBrightness:forKeyboard:", false)
        setFlag("suspendIdleDimming:forKeyboard:", true)
    }

    func end() {
        guard active else { return }
        active = false
        set(originalLevel, commit: true)
        setFlag("suspendIdleDimming:forKeyboard:", false)
        if originalAuto { setFlag("enableAutoBrightness:forKeyboard:", true) }
    }
}

// MARK: - Audio capture

typealias LevelHandler = @Sendable (Double) -> Void

/// Microphone loudness.
final class MicCapture {
    private var engine: AVAudioEngine?

    func start(onLevel: @escaping LevelHandler) throws {
        let eng = AVAudioEngine()
        let input = eng.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            onLevel(Double(sqrt(sum / Float(max(n, 1)))))
        }
        try eng.start()
        engine = eng
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}

struct AudioError: LocalizedError {
    let step: String, code: OSStatus
    var errorDescription: String? { "\(step) failed (\(code))" }
}

/// Loudness of everything the Mac is playing, via a Core Audio process tap (macOS 14.2+).
/// Only asks for "System Audio Recording" permission, not screen recording.
@available(macOS 14.2, *)
final class SystemAudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "keyglow.system-audio", qos: .userInteractive)

    func start(onLevel: @escaping LevelHandler) throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "KeyGlow"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        try check("Creating audio tap", AudioHardwareCreateProcessTap(desc, &tapID))

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "KeyGlow Listener",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        try check("Creating listener device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        try check("Attaching listener", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            var sum: Float = 0
            var count = 0
            for b in buffers {
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                for i in 0..<n { sum += p[i] * p[i] }
                count += n
            }
            if count > 0 { onLevel(Double(sqrt(sum / Float(count)))) }
        })
        try check("Starting listener", AudioDeviceStart(aggregateID, procID))
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let p = procID { AudioDeviceDestroyIOProcID(aggregateID, p) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private func check(_ step: String, _ status: OSStatus) throws {
        if status != noErr { stop(); throw AudioError(step: step, code: status) }
    }

    private static func defaultOutputUID() throws -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        if err != noErr { throw AudioError(step: "Finding speakers", code: err) }
        addr.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        err = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid)
        guard err == noErr, let uid else { throw AudioError(step: "Reading speaker ID", code: err) }
        return uid.takeRetainedValue() as String
    }
}

// MARK: - Effects

enum Effect: String, CaseIterable, Identifiable {
    case breathe = "Breathe", heartbeat = "Heartbeat", strobe = "Strobe", candle = "Candle"
    case ocean = "Ocean", lightning = "Storm", music = "Music", typing = "Typing", morse = "Morse"
    case reflex = "Reflex"
    var id: String { rawValue }
    static let grid: [Effect] = allCases.filter { $0 != .reflex }

    var symbol: String {
        switch self {
        case .breathe: "wind"
        case .heartbeat: "heart.fill"
        case .strobe: "bolt.fill"
        case .candle: "flame.fill"
        case .ocean: "water.waves"
        case .lightning: "cloud.bolt.rain.fill"
        case .music: "waveform"
        case .typing: "keyboard"
        case .morse: "ellipsis.message.fill"
        case .reflex: "timer"
        }
    }
    var hint: String {
        switch self {
        case .breathe: "Slow, calm fade in and out"
        case .heartbeat: "Lub-dub pulse"
        case .strobe: "Hard on/off flashing"
        case .candle: "Warm, random flicker"
        case .ocean: "Rolling layered waves"
        case .lightning: "Dark with sudden flashes"
        case .music: "Pulses to the beat"
        case .typing: "Flashes on every keystroke"
        case .morse: "Blinks your message in Morse code"
        case .reflex: "Press any key the moment your keyboard lights up"
        }
    }
}

enum MusicSource: String, CaseIterable, Identifiable {
    case system = "Mac audio", mic = "Microphone"
    var id: String { rawValue }
}

/// One-shot light patterns that can be triggered from anywhere with a keyglow:// link.
enum AlertPattern {
    /// Keyframes of (seconds, level), linearly interpolated.
    static func frames(_ name: String, times: Int) -> [(Double, Double)]? {
        switch name {
        case "done", "success": return [(0, 0), (0.18, 1), (0.5, 0), (0.62, 0), (0.8, 1), (1.4, 0), (1.6, 0)]
        case "attention", "notify": return blinks(3, on: 0.25, off: 0.25)
        case "error", "fail", "failure": return blinks(8, on: 0.05, off: 0.07)
        case "flash": return blinks(max(1, min(times, 30)), on: 0.12, off: 0.15)
        default: return nil
        }
    }
    static func blinks(_ n: Int, on: Double, off: Double) -> [(Double, Double)] {
        var f: [(Double, Double)] = [(0, 0)]
        var t = 0.0
        for _ in 0..<n {
            f += [(t, 1), (t + on, 1), (t + on, 0), (t + on + off, 0)]
            t += on + off
        }
        return f
    }
    static func value(_ f: [(Double, Double)], at x: Double) -> Double? {
        guard let last = f.last, x <= last.0 else { return nil }
        for i in 1..<f.count where x <= f[i].0 {
            let (t0, v0) = f[i - 1], (t1, v1) = f[i]
            return t1 == t0 ? v1 : v0 + (v1 - v0) * (x - t0) / (t1 - t0)
        }
        return f[0].1
    }
}

let morseTable: [Character: String] = [
    "a": ".-", "b": "-...", "c": "-.-.", "d": "-..", "e": ".", "f": "..-.", "g": "--.", "h": "....",
    "i": "..", "j": ".---", "k": "-.-", "l": ".-..", "m": "--", "n": "-.", "o": "---", "p": ".--.",
    "q": "--.-", "r": ".-.", "s": "...", "t": "-", "u": "..-", "v": "...-", "w": ".--", "x": "-..-",
    "y": "-.--", "z": "--..", "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-",
    "5": ".....", "6": "-....", "7": "--...", "8": "---..", "9": "----.",
]

/// Converts text to a list of on/off durations in Morse "units".
func morseUnits(_ text: String) -> [(on: Bool, units: Int)] {
    var out: [(Bool, Int)] = []
    for word in text.lowercased().split(separator: " ") {
        for ch in word {
            guard let code = morseTable[ch] else { continue }
            for sym in code {
                out.append((true, sym == "." ? 1 : 3))
                out.append((false, 1))
            }
            out.append((false, 2)) // letter gap (3 total)
        }
        out.append((false, 4)) // word gap (7 total)
    }
    return out
}

// MARK: - Engine

@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    @Published var effect: Effect? = nil
    @Published var speed: Double = 1.0
    @Published var minLevel: Double = 0.0
    @Published var maxLevel: Double = 1.0
    @Published var morseText: String = "hello world" { didSet { morseCache = morseUnits(morseText) } }
    @Published var musicSource: MusicSource = .system { didSet { if effect == .music { startMusic() } } }
    @Published var status: String = ""
    @Published var preview: Double = 0
    @Published var copied = false

    // reflex game
    @Published var gameText = ""
    @Published var gameDetail = ""
    @Published var bestMs: Int = UserDefaults.standard.integer(forKey: "bestReflexMs")
    private enum Phase { case idle, waiting(Double), go(Double), result(Double), early(Double) }
    private var phase: Phase = .idle
    private var recent: [Int] = []

    let light = Backlight()
    private var timer: Timer?
    private var t: Double = 0
    private var last = Date()
    private var alert: (frames: [(Double, Double)], start: Double)?

    // effect state
    private var candle = 0.6, candleTarget = 0.6
    private var flash = 0.0, nextStrike = 1.0, strikesLeft = 0
    private var typeGlow = 0.0
    private var keyMonitors: [Any] = []
    private var mic: MicCapture?
    private var systemAudio: AnyObject?
    private var audioLevel = 0.0, audioSmoothed = 0.0, audioPeak = 0.05, lastSound = 0.0
    private lazy var morseCache = morseUnits(morseText)

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    init() {
        if !light.available { status = "Keyboard backlight API not found on this Mac." }
    }

    // MARK: control

    func toggle(_ e: Effect) {
        if effect == e { stop() } else { start(e) }
    }

    func start(_ e: Effect) {
        stopInputs()
        effect = e
        status = ""
        t = 0
        switch e {
        case .music: startMusic()
        case .typing: startTyping()
        case .reflex: startGame()
        default: break
        }
        ensureRunning()
    }

    func stop() {
        stopInputs()
        effect = nil
        if alert == nil { shutdown() }
    }

    func quit() {
        stopInputs()
        effect = nil
        alert = nil
        shutdown()
    }

    /// Plays a one-shot pattern on top of whatever is running, then goes back to it.
    func trigger(_ name: String, times: Int = 3) {
        guard let f = AlertPattern.frames(name, times: times) else { return }
        alert = (f, now)
        ensureRunning()
    }

    /// keyglow://done · attention · error · flash?times=5 · morse?text=sos · effect/candle · stop
    func handle(url: URL) {
        guard url.scheme == "keyglow", let cmd = url.host?.lowercased() else { return }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let param = { (k: String) in q.first { $0.name == k }?.value }
        switch cmd {
        case "stop": stop()
        case "effect", "start":
            let name = url.pathComponents.dropFirst().first ?? param("name") ?? ""
            if let e = Effect.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) { start(e) }
        case "morse":
            if let text = param("text"), !text.isEmpty { morseText = text }
            start(.morse)
        default:
            trigger(cmd, times: Int(param("times") ?? "") ?? 3)
        }
    }

    private func ensureRunning() {
        light.begin()
        guard timer == nil else { return }
        last = Date()
        let tm = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }

    private func shutdown() {
        timer?.invalidate(); timer = nil
        preview = 0
        light.end()
    }

    private func stopInputs() {
        keyMonitors.forEach { NSEvent.removeMonitor($0) }
        keyMonitors = []
        stopAudio()
        phase = .idle
    }

    // MARK: animation

    private func tick() {
        let date = Date()
        let dt = min(0.1, date.timeIntervalSince(last))
        last = date
        t += dt * speed

        if let a = alert {
            if let v = AlertPattern.value(a.frames, at: now - a.start) {
                preview = v
                light.set(Float(v))
                return
            }
            alert = nil
            if effect == nil { shutdown(); return }
        }
        guard let e = effect else { shutdown(); return }
        let v = max(0, min(1, value(e, dt: dt)))
        preview = v
        light.set(Float(minLevel + (maxLevel - minLevel) * v))
    }

    private func value(_ e: Effect, dt: Double) -> Double {
        switch e {
        case .breathe:
            let x = (1 - cos(t * 2 * .pi / 4.0)) / 2
            return x * x * (3 - 2 * x)
        case .heartbeat:
            let p = t.truncatingRemainder(dividingBy: 1.2)
            let bump = { (c: Double, w: Double) in exp(-pow((p - c) / w, 2)) }
            return max(bump(0.10, 0.05), 0.7 * bump(0.32, 0.06))
        case .strobe:
            return (t * 8).truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : 0
        case .candle:
            if Double.random(in: 0...1) < 0.08 * speed { candleTarget = .random(in: 0.35...1.0) }
            candle += (candleTarget - candle) * min(1, dt * 12)
            return candle + .random(in: -0.04...0.04)
        case .ocean:
            let w = 0.5 * sin(t * 0.9) + 0.3 * sin(t * 1.7 + 1.3) + 0.2 * sin(t * 3.1 + 0.4)
            return 0.5 + 0.5 * w
        case .lightning:
            nextStrike -= dt * speed
            if nextStrike <= 0 {
                flash = .random(in: 0.7...1)
                if strikesLeft > 0 { strikesLeft -= 1; nextStrike = .random(in: 0.06...0.15) }
                else { strikesLeft = Int.random(in: 0...2); nextStrike = .random(in: 1.5...5) }
            }
            flash *= exp(-dt * 9)
            return 0.04 + flash
        case .music:
            // fast attack, speed-controlled release
            let release = min(1, dt * 10 * speed)
            audioSmoothed = audioLevel > audioSmoothed ? audioLevel : audioSmoothed + (audioLevel - audioSmoothed) * release
            if musicSource == .system, now - lastSound > 4 {
                status = "No sound yet. Play some music. If it stays dark, allow KeyGlow under System Settings → Privacy & Security → Screen & System Audio Recording."
            }
            return audioSmoothed
        case .typing:
            typeGlow *= exp(-dt * 4 * speed)
            return 0.05 + typeGlow
        case .morse:
            let unit = 0.12
            let total = morseCache.reduce(0) { $0 + $1.units }
            guard total > 0 else { return 0 }
            var pos = Int(t / unit) % total
            for seg in morseCache {
                if pos < seg.units { return seg.on ? 1 : 0 }
                pos -= seg.units
            }
            return 0
        case .reflex:
            return gameValue()
        }
    }

    // MARK: keys

    /// Global monitor works while other apps are focused (needs Accessibility);
    /// local monitor catches keys while the KeyGlow panel itself is focused.
    private func monitorKeys(swallowLocal: Bool, _ onKey: @escaping (NSEvent) -> Void) {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { e in
            MainActor.assumeIsolated { onKey(e) }
        }) { keyMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in
            MainActor.assumeIsolated { onKey(e) }
            return swallowLocal ? nil : e
        }) { keyMonitors.append(l) }
    }

    private func startTyping() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            status = "Allow KeyGlow in System Settings → Privacy & Security → Accessibility, then pick Typing again."
        }
        monitorKeys(swallowLocal: false) { [weak self] _ in self?.typeGlow = 1 }
    }

    // MARK: reflex game

    private func startGame() {
        recent = []
        gameText = "Get ready…"
        gameDetail = "Look at your keyboard. Press any key the instant it lights up."
        if !AXIsProcessTrusted() {
            status = "Keep this panel open while you play, or allow KeyGlow under Privacy & Security → Accessibility to play with it closed."
        }
        monitorKeys(swallowLocal: true) { [weak self] e in
            guard !e.isARepeat else { return }
            self?.gameKey(at: e.timestamp)
        }
        phase = .result(now + 1.0)
    }

    private func gameValue() -> Double {
        let n = now
        switch phase {
        case .idle:
            phase = .waiting(n + .random(in: 1.5...5.0))
            gameText = "Wait for it…"
            return 0
        case .waiting(let until):
            if n >= until { phase = .go(n); gameText = "NOW!"; return 1 }
            return 0
        case .go(let at):
            if n - at > 2 {
                gameText = "Too slow!"
                gameDetail = "Wake up! 😴"
                phase = .result(n + 1.5)
                return 0
            }
            return 1
        case .result(let until):
            if n >= until { phase = .idle }
            return 0
        case .early(let until):
            if n >= until { phase = .idle }
            return (n * 12).truncatingRemainder(dividingBy: 1) < 0.5 ? 0.6 : 0
        }
    }

    private func gameKey(at ts: Double) {
        switch phase {
        case .waiting:
            gameText = "Too early!"
            gameDetail = "Wait for the keyboard to light up."
            phase = .early(now + 1.2)
        case .go(let at):
            let ms = Int(((ts - at) * 1000).rounded())
            guard ms >= 0 else { return }
            recent = Array((recent + [ms]).suffix(5))
            let avg = recent.reduce(0, +) / recent.count
            gameText = "\(ms) ms"
            if bestMs == 0 || ms < bestMs {
                bestMs = ms
                UserDefaults.standard.set(ms, forKey: "bestReflexMs")
                gameDetail = "🏆 New best!"
            } else {
                gameDetail = recent.count > 1 ? "Average of last \(recent.count): \(avg) ms" : ""
            }
            phase = .result(now + 1.6)
        default:
            break
        }
    }

    // MARK: music

    private func startMusic() {
        stopAudio()
        status = ""
        audioPeak = 0.05
        lastSound = now
        let handler: LevelHandler = { rms in
            DispatchQueue.main.async { MainActor.assumeIsolated { Engine.shared.receive(rms) } }
        }
        switch musicSource {
        case .system:
            guard #available(macOS 14.2, *) else {
                status = "Mac audio needs macOS 14.2 or later. Using the microphone instead."
                musicSource = .mic
                return
            }
            let cap = SystemAudioCapture()
            do { try cap.start(onLevel: handler); systemAudio = cap }
            catch { status = "Couldn't listen to Mac audio: \(error.localizedDescription)" }
        case .mic:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let engine = Engine.shared
                        guard engine.effect == .music, engine.musicSource == .mic else { return }
                        guard ok else {
                            engine.status = "Allow microphone access in System Settings → Privacy & Security → Microphone."
                            return
                        }
                        let m = MicCapture()
                        do { try m.start(onLevel: handler); engine.mic = m }
                        catch { engine.status = "Couldn't start the microphone: \(error.localizedDescription)" }
                    }
                }
            }
        }
    }

    private func receive(_ rms: Double) {
        guard effect == .music else { return }
        if rms > 0.003 {
            lastSound = now
            if status.hasPrefix("No sound yet") { status = "" }
        }
        // adaptive gain: follow a slowly decaying peak so quiet and loud songs both pop
        audioPeak = max(rms, audioPeak * 0.997, 0.01)
        let x = rms < 0.002 ? 0 : min(1, rms / audioPeak)
        audioLevel = pow(x, 2.2)
    }

    private func stopAudio() {
        mic?.stop(); mic = nil
        if #available(macOS 14.2, *) { (systemAudio as? SystemAudioCapture)?.stop() }
        systemAudio = nil
        audioLevel = 0; audioSmoothed = 0
    }
}

// MARK: - UI

struct PanelView: View {
    @ObservedObject var engine: Engine
    let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("KeyGlow").font(.headline)
                Spacer()
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.15 + 0.85 * engine.preview))
                    .frame(width: 44, height: 10)
                    .shadow(color: .white.opacity(engine.preview * 0.8), radius: 6)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.4)))
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Effect.grid) { e in tile(e) }
            }

            Button { engine.toggle(.reflex) } label: {
                Label(engine.effect == .reflex ? "Stop Reflex Game" : "Play Reflex Game", systemImage: "timer")
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(engine.effect == .reflex ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.12)))
                    .foregroundStyle(engine.effect == .reflex ? .white : .primary)
            }
            .buttonStyle(.plain)

            if engine.effect == .reflex {
                gameBox
            } else if let e = engine.effect {
                Text(e.hint).font(.caption).foregroundStyle(.secondary)
            }

            if engine.effect == .music {
                Picker("Listen to", selection: $engine.musicSource) {
                    ForEach(MusicSource.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if engine.effect == .morse {
                TextField("Message", text: $engine.morseText).textFieldStyle(.roundedBorder)
            }

            if engine.effect != .reflex {
                labeled("Speed", String(format: "%.1f×", engine.speed)) {
                    Slider(value: $engine.speed, in: 0.25...3)
                }
                labeled("Dimmest", "\(Int(engine.minLevel * 100))%") {
                    Slider(value: $engine.minLevel, in: 0...1) { _ in
                        if engine.minLevel > engine.maxLevel { engine.maxLevel = engine.minLevel }
                    }
                }
                labeled("Brightest", "\(Int(engine.maxLevel * 100))%") {
                    Slider(value: $engine.maxLevel, in: 0...1) { _ in
                        if engine.maxLevel < engine.minLevel { engine.minLevel = engine.maxLevel }
                    }
                }
            }

            if !engine.status.isEmpty {
                Text(engine.status).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            alertsSection
            Divider()

            HStack {
                Button("Stop") { engine.stop() }.disabled(engine.effect == nil)
                Spacer()
                Button("Quit") { engine.quit(); NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 310)
    }

    func tile(_ e: Effect) -> some View {
        Button { engine.toggle(e) } label: {
            VStack(spacing: 4) {
                Image(systemName: e.symbol).font(.system(size: 18))
                Text(e.rawValue).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(engine.effect == e ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.12)))
            .foregroundStyle(engine.effect == e ? .white : .primary)
        }
        .buttonStyle(.plain)
        .help(e.hint)
    }

    var gameBox: some View {
        VStack(spacing: 4) {
            Text(engine.gameText)
                .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
            Text(engine.gameDetail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text(engine.bestMs > 0 ? "Best: \(engine.bestMs) ms" : "No best time yet")
                .font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    var alertsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Alerts").font(.caption.weight(.semibold))
            HStack(spacing: 6) {
                Button("✅ Done") { engine.trigger("done") }
                Button("👀 Attention") { engine.trigger("attention") }
                Button("❌ Error") { engine.trigger("error") }
            }
            .controlSize(.small)
            HStack {
                Text("Trigger from anywhere: open -g keyglow://done")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button(engine.copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("open -g keyglow://done", forType: .string)
                    engine.copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { engine.copied = false }
                }
                .controlSize(.mini)
            }
        }
    }

    func labeled<C: View>(_ title: String, _ value: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title).font(.caption); Spacer(); Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            c()
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ n: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: s) else { return }
        MainActor.assumeIsolated { Engine.shared.handle(url: url) }
    }

    func applicationWillTerminate(_ n: Notification) {
        MainActor.assumeIsolated { Engine.shared.quit() }
    }
}

@main
struct KeyGlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var engine = Engine.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView(engine: engine)
        } label: {
            Image(systemName: engine.effect == nil ? "keyboard" : "keyboard.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
