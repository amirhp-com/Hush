import AppKit
import SwiftUI

/// Window background like Terminal's: Liquid Glass, translucent colour with blur, or a solid colour.
struct WindowBackground: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        ZStack {
            WindowConfigurator(mode: settings.backgroundMode, blur: settings.backgroundBlur, opaque: settings.backgroundMode == .solid)
            switch effectiveMode {
            case .glass:
                if #available(macOS 26.0, *) {
                    GlassBackground(tint: Color(nsColor: settings.backgroundColor).opacity(max(0, settings.backgroundOpacity - 0.55)))
                }
            case .translucent:
                Color(nsColor: settings.backgroundColor).opacity(settings.backgroundOpacity)
            case .solid:
                Color(nsColor: settings.backgroundColor)
            }
        }
        .ignoresSafeArea()
    }

    private var effectiveMode: BackgroundMode {
        settings.backgroundMode == .glass && !AppSettings.hasLiquidGlass ? .translucent : settings.backgroundMode
    }
}

@available(macOS 26.0, *)
private struct GlassBackground: NSViewRepresentable {
    var tint: Color

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = 0
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.tintColor = NSColor(tint)
    }
}

/// Makes the hosting window transparent and applies the blur radius.
private struct WindowConfigurator: NSViewRepresentable {
    var mode: BackgroundMode
    var blur: Double
    var opaque: Bool

    final class Coordinator { var applied: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        let config = (mode, blur, opaque)
        DispatchQueue.main.async { Self.apply(view.window, config: config, coordinator: coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        let config = (mode, blur, opaque)
        DispatchQueue.main.async { Self.apply(view.window, config: config, coordinator: coordinator) }
    }

    private static func apply(_ window: NSWindow?, config: (BackgroundMode, Double, Bool), coordinator: Coordinator) {
        guard let window else { return }
        let key = "\(window.windowNumber)-\(config.0.rawValue)-\(Int(config.1))-\(config.2)"
        guard coordinator.applied != key else { return }
        coordinator.applied = key
        if window.isOpaque != config.2 { window.isOpaque = config.2 }
        window.backgroundColor = config.2 ? .windowBackgroundColor : .clear
        BlurRadius.set(config.0 == .translucent ? Int(config.1) : 0, on: window)
    }
}

/// Terminal-style background blur. Uses the private CoreGraphics call when available.
enum BlurRadius {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias SetBlurFn = @convention(c) (Int32, Int32, Int32) -> Int32

    private static let functions: (ConnectionFn, SetBlurFn)? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let c = dlsym(handle, "CGSDefaultConnectionForThread") ?? dlsym(handle, "CGSMainConnectionID"),
              let b = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else { return nil }
        return (unsafeBitCast(c, to: ConnectionFn.self), unsafeBitCast(b, to: SetBlurFn.self))
    }()

    static var isAvailable: Bool { functions != nil }

    static func set(_ radius: Int, on window: NSWindow) {
        guard let (connection, setBlur) = functions, window.windowNumber > 0 else { return }
        _ = setBlur(connection(), Int32(window.windowNumber), Int32(max(0, min(100, radius))))
    }
}

extension View {
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 14, fullWidth: Bool = true) -> some View {
        let sized = frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
        if #available(macOS 26.0, *) {
            sized.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            sized.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    func compatGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }

    func noFocusRing() -> some View { focusEffectDisabled() }
}
