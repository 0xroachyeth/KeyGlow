import SwiftUI
import AppKit
import AVFoundation
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

// MARK: - Effects

enum Effect: String, CaseIterable, Identifiable {
    case breathe = "Breathe", heartbeat = "Heartbeat", strobe = "Strobe", candle = "Candle"
    case ocean = "Ocean", lightning = "Storm", music = "Music", typing = "Typing", morse = "Morse"
    var id: String { rawValue }
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
        case .music: "Reacts to sound from the mic"
        case .typing: "Flashes on every keystroke"
        case .morse: "Blinks your message in Morse code"
        }
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
    @Published var effect: Effect? = nil
    @Published var speed: Double = 1.0
    @Published var minLevel: Double = 0.0
    @Published var maxLevel: Double = 1.0
    @Published var morseText: String = "hello world" { didSet { morseCache = morseUnits(morseText) } }
    @Published var status: String = ""
    @Published var preview: Double = 0

    let light = Backlight()
    private var timer: Timer?
    private var t: Double = 0
    private var last = Date()

    // effect state
    private var candle = 0.6, candleTarget = 0.6
    private var flash = 0.0, nextStrike = 1.0, strikesLeft = 0
    private var typeGlow = 0.0
    private var keyMonitor: Any?
    private var audio: AVAudioEngine?
    private var micLevel: Double = 0, micSmoothed: Double = 0, micPeak: Double = 0.05
    private lazy var morseCache = morseUnits(morseText)

    init() {
        if !light.available { status = "Keyboard backlight API not found on this Mac." }
    }

    func toggle(_ e: Effect) {
        if effect == e { stop() } else { start(e) }
    }

    func start(_ e: Effect) {
        stopInputs()
        effect = e
        status = ""
        t = 0
        light.begin()
        if e == .music { startMic() }
        if e == .typing { startKeys() }
        if timer == nil {
            last = Date()
            let tm = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(tm, forMode: .common)
            timer = tm
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        stopInputs()
        effect = nil
        preview = 0
        light.end()
    }

    private func stopInputs() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        audio?.inputNode.removeTap(onBus: 0); audio?.stop(); audio = nil
    }

    private func tick() {
        let now = Date()
        let dt = min(0.1, now.timeIntervalSince(last))
        last = now
        t += dt * speed
        guard let e = effect else { return }
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
            micSmoothed = micLevel > micSmoothed ? micLevel : micSmoothed + (micLevel - micSmoothed) * min(1, dt * 8)
            return micSmoothed
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
        }
    }

    // MARK: inputs

    private func startKeys() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            status = "Allow KeyGlow in System Settings → Privacy & Security → Accessibility, then pick Typing again."
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.typeGlow = 1 }
        }
    }

    private func startMic() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                guard ok else {
                    self.status = "Allow microphone access in System Settings → Privacy & Security → Microphone."
                    return
                }
                guard self.effect == .music else { return }
                self.beginAudio()
            }
        }
    }

    private func beginAudio() {
        let eng = AVAudioEngine()
        let input = eng.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = Double(sqrt(sum / Float(max(n, 1))))
            DispatchQueue.main.async {
                guard let self else { return }
                // adaptive gain: track a slowly decaying peak
                self.micPeak = max(rms, self.micPeak * 0.995, 0.01)
                let x = min(1, rms / self.micPeak)
                self.micLevel = pow(x, 1.5)
            }
        }
        do { try eng.start(); audio = eng }
        catch { status = "Couldn't start the microphone: \(error.localizedDescription)" }
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
                // live preview of current level
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.15 + 0.85 * engine.preview))
                    .frame(width: 44, height: 10)
                    .shadow(color: .white.opacity(engine.preview * 0.8), radius: 6)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.4)))
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Effect.allCases) { e in
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
            }

            if let e = engine.effect {
                Text(e.hint).font(.caption).foregroundStyle(.secondary)
            }

            if engine.effect == .morse {
                TextField("Message", text: $engine.morseText).textFieldStyle(.roundedBorder)
            }

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

            if !engine.status.isEmpty {
                Text(engine.status).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Button("Stop") { engine.stop() }.disabled(engine.effect == nil)
                Spacer()
                Button("Quit") { engine.stop(); NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    func labeled<C: View>(_ title: String, _ value: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title).font(.caption); Spacer(); Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            c()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onQuit: (() -> Void)?
    func applicationWillTerminate(_ n: Notification) { onQuit?() }
}

@main
struct KeyGlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var engine = Engine()

    var body: some Scene {
        MenuBarExtra {
            PanelView(engine: engine)
                .onAppear { delegate.onQuit = { [engine] in MainActor.assumeIsolated { engine.stop() } } }
        } label: {
            Image(systemName: engine.effect == nil ? "keyboard" : "keyboard.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
