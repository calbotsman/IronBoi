import Accelerate
import AVFoundation

/// Your voice, measured the way orb-lab measures it
/// (~/AgentBOB/orb-lab/src/engine/features.ts), so the coach's body reacts
/// to the same things: loudness on a dB scale, a peak envelope, voice
/// activity with hysteresis, and syllable onsets from positive spectral flux.
/// Same constants, same 2048-point Blackman FFT with no smoothing, same
/// |X|/N magnitude scale as a Web Audio AnalyserNode.
///
/// Runs on the audio tap's thread. Not thread-safe; one instance per tap.
final class MicAnalyzer {
    private static let size = 2048
    private static let hop = 1024
    private let floorDb: Float = -62, ceilDb: Float = -14
    private let vadOn: Float = 0.22, vadOff: Float = 0.12, vadHang = 0.28
    private let onsetSensitivity: Float = 1.6

    private var ring = [Float](repeating: 0, count: MicAnalyzer.size)
    private let window = vDSP.window(ofType: Float.self, usingSequence: .blackman,
                                     count: MicAnalyzer.size, isHalfWindow: false)
    private let fft = vDSP.FFT(log2n: 11, radix: .radix2, ofType: DSPSplitComplex.self)!
    private var real = [Float](repeating: 0, count: MicAnalyzer.size / 2)
    private var imag = [Float](repeating: 0, count: MicAnalyzer.size / 2)
    private var magnitude = [Float](repeating: 0, count: MicAnalyzer.size / 2)
    private var previousMagnitude = [Float](repeating: 0, count: MicAnalyzer.size / 2)
    private var pending: [Float] = []

    private var clock: Double = 0
    private var fluxAverage: Float = 0
    private var lastOnset: Double = -1
    private var lastActive: Double = -1
    private var reading = VoiceReading()

    /// Feeds a tap buffer, analysing every 1024 samples (~21 ms at 48 kHz —
    /// about orb-lab's once-per-frame cadence) however large iOS makes it.
    func process(_ buffer: AVAudioPCMBuffer, into meter: VoiceMeter) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let sampleRate = Float(buffer.format.sampleRate)
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
        while pending.count >= Self.hop {
            ring.removeFirst(Self.hop)
            ring.append(contentsOf: pending.prefix(Self.hop))
            pending.removeFirst(Self.hop)
            analyse(dt: Float(Self.hop) / sampleRate, sampleRate: sampleRate)
            meter.set(reading)
        }
    }

    func reset() {
        ring = [Float](repeating: 0, count: Self.size)
        previousMagnitude = [Float](repeating: 0, count: Self.size / 2)
        pending.removeAll()
        fluxAverage = 0
        reading = VoiceReading()
    }

    private func analyse(dt: Float, sampleRate: Float) {
        clock += Double(dt)
        let now = clock

        // Loudness
        let rms = sqrt(vDSP.meanSquare(ring))
        let db = 20 * log10(rms + 1e-9)
        let raw = clamp((db - floorDb) / (ceilDb - floorDb))
        reading.level = ease(reading.level, raw, raw > reading.level ? 0.5 : 0.18, dt)
        if raw > reading.peak {
            reading.peak += (raw - reading.peak) * 0.6
        } else {
            reading.peak *= pow(0.93, dt * 60)
        }

        // Spectrum: windowed real FFT → |X| / N
        let windowed = vDSP.multiply(ring, window)
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.size / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                magnitude.withUnsafeMutableBufferPointer { mag in
                    vDSP_zvabs(&split, 1, mag.baseAddress!, 1, vDSP_Length(Self.size / 2))
                }
            }
        }
        // vDSP's real FFT is 2× the DFT; Web Audio reports |X| / N.
        vDSP.multiply(1 / Float(2 * Self.size), magnitude, result: &magnitude)

        let binHz = sampleRate / Float(Self.size)

        // Bands → the body's 2/3/7 lobes (orb-lab's bandLevel, by Hz)
        func band(_ lo: Float, _ hi: Float) -> Float {
            let a = max(1, Int((lo / binHz).rounded())), b = min(magnitude.count, Int((hi / binHz).rounded()))
            guard b > a else { return 0 }
            var sum: Float = 0
            for i in a..<b { sum += 20 * log10(magnitude[i] + 1e-9) }
            return clamp((sum / Float(b - a) - (floorDb - 35)) / 50)
        }
        reading.bands.x = ease(reading.bands.x, band(80, 300), 0.3, dt)
        reading.bands.y = ease(reading.bands.y, band(300, 2000), 0.25, dt)
        reading.bands.z = ease(reading.bands.z, band(2000, 8000), 0.2, dt)

        // Syllable onsets: positive spectral flux, 100 Hz – 4 kHz
        let low = max(1, Int((100 / binHz).rounded()))
        let high = min(magnitude.count, Int((4000 / binHz).rounded()))
        var flux: Float = 0
        for i in low..<high {
            let rise = magnitude[i] - previousMagnitude[i]
            if rise > 0 { flux += rise }
        }
        previousMagnitude = magnitude
        let isOnset = flux > fluxAverage * onsetSensitivity + 0.002
            && raw > vadOff && now - lastOnset > 0.09
        fluxAverage = ease(fluxAverage, flux, 0.05, dt)
        if isOnset {
            lastOnset = now
            reading.onsets += 1
        }

        // Voice activity with hysteresis
        if reading.level > vadOn {
            reading.active = true
            lastActive = now
        } else if reading.level > vadOff {
            if reading.active { lastActive = now }
        } else if reading.active, now - lastActive > vadHang {
            reading.active = false
        }
        reading.presence = ease(reading.presence, reading.active ? 1 : 0, reading.active ? 0.2 : 0.06, dt)
    }

    private func clamp(_ v: Float) -> Float { min(max(v, 0), 1) }

    /// orb-lab's frame-rate-independent smoothing; k is per 60 fps frame.
    private func ease(_ current: Float, _ target: Float, _ k: Float, _ dt: Float) -> Float {
        current + (target - current) * (1 - pow(1 - k, dt * 60))
    }
}
