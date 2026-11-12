#if os(macOS)
import CoreAudio
#else
import AVFoundation
#endif
import Foundation
import Observation

/// A CoreAudio output device.
public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    public enum Transport: String, Hashable, Sendable {
        case builtIn, usb, bluetooth, airPlay, hdmi, displayPort, thunderbolt, virtual, aggregate, other
    }

    /// Stable CoreAudio UID; what `AVPlayer.audioOutputDeviceUniqueID` takes.
    public var uid: String
    public var name: String
    public var transport: Transport

    public var id: String { uid }

    public init(uid: String, name: String, transport: Transport) {
        self.uid = uid
        self.name = name
        self.transport = transport
    }
}

/// A change in audio routing that should pause playback, like macOS does for headphones.
public enum AudioRouteLoss: Hashable, Sendable {
    /// A device that was in use disappeared (AirPods disconnected, USB DAC unplugged).
    case deviceRemoved(AudioOutputDevice)
    /// Headphones were unplugged from the built-in jack.
    case headphonesUnplugged
}

#if os(macOS)
/// Lists output devices and reports when they appear and disappear. Event-driven via CoreAudio
/// property listeners; nothing polls.
@MainActor
@Observable
public final class AudioOutputMonitor {
    public private(set) var devices: [AudioOutputDevice] = []
    public private(set) var defaultDeviceUID: String?

    /// Called with the device UIDs that disappeared and the default output before the change.
    @ObservationIgnored public var onDevicesRemoved: (@MainActor (_ removed: [AudioOutputDevice], _ previousDefaultUID: String?) -> Void)?
    /// Called when the built-in output switches from headphones to speakers.
    @ObservationIgnored public var onHeadphonesUnplugged: (@MainActor () -> Void)?
    /// Called after any change in the device list or default device.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var systemListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var dataSourceListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var dataSourceDevice: AudioObjectID?
    @ObservationIgnored private var lastDataSource: UInt32?

    private static let headphonesDataSource: UInt32 = 0x6864_706E // 'hdpn'

    public init() {}

    public func device(uid: String) -> AudioOutputDevice? { devices.first { $0.uid == uid } }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        refresh(notify: false)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh(notify: true) }
        }
        systemListener = listener
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }

    public func stop() {
        guard isRunning, let systemListener else { return }
        isRunning = false
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, systemListener)
        }
        self.systemListener = nil
        watchDataSource(of: nil)
    }

    /// Re-read devices. Public so the Settings UI can refresh on appear.
    public func refresh() { refresh(notify: true) }

    private func refresh(notify: Bool) {
        let previous = devices
        let previousDefault = defaultDeviceUID
        let defaultID = Self.defaultOutputDeviceID()
        devices = Self.outputDeviceIDs().compactMap(Self.describe)
        defaultDeviceUID = defaultID.flatMap { Self.string($0, kAudioDevicePropertyDeviceUID) }
        watchDataSource(of: defaultID)

        guard notify else { return }
        let current = Set(devices.map(\.uid))
        let removed = previous.filter { !current.contains($0.uid) }
        if !removed.isEmpty { onDevicesRemoved?(removed, previousDefault) }
        if previous != devices || previousDefault != defaultDeviceUID { onChange?() }
    }

    /// Built-in outputs switch "data source" between speakers and headphones instead of adding a device.
    private func watchDataSource(of device: AudioObjectID?) {
        guard device != dataSourceDevice else { return }
        var address = Self.address(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        if let old = dataSourceDevice, let dataSourceListener {
            AudioObjectRemovePropertyListenerBlock(old, &address, .main, dataSourceListener)
        }
        dataSourceDevice = nil
        dataSourceListener = nil
        lastDataSource = nil
        guard let device, AudioObjectHasProperty(device, &address) else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.dataSourceChanged() }
        }
        if AudioObjectAddPropertyListenerBlock(device, &address, .main, listener) == noErr {
            dataSourceDevice = device
            dataSourceListener = listener
            lastDataSource = Self.uint32(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        }
    }

    private func dataSourceChanged() {
        guard let device = dataSourceDevice else { return }
        let source = Self.uint32(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        defer { lastDataSource = source }
        if lastDataSource == Self.headphonesDataSource, source != Self.headphonesDataSource {
            onHeadphonesUnplugged?()
        }
    }

    // MARK: CoreAudio helpers

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDeviceID() -> AudioObjectID? {
        guard let id = uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice), id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func outputDeviceIDs() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasOutputStreams)
    }

    private static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func describe(_ device: AudioObjectID) -> AudioOutputDevice? {
        guard let uid = string(device, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = string(device, kAudioObjectPropertyName) ?? uid
        // CoreAudio's private aggregate for the default device isn't something to pick.
        if name.hasPrefix("CADefaultDeviceAggregate") { return nil }
        return AudioOutputDevice(uid: uid, name: name, transport: transport(device))
    }

    private static func transport(_ device: AudioObjectID) -> AudioOutputDevice.Transport {
        switch uint32(device, kAudioDevicePropertyTransportType) {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeAirPlay: .airPlay
        case kAudioDeviceTransportTypeHDMI: .hdmi
        case kAudioDeviceTransportTypeDisplayPort: .displayPort
        case kAudioDeviceTransportTypeThunderbolt: .thunderbolt
        case kAudioDeviceTransportTypeVirtual: .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: .aggregate
        default: .other
        }
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
#else

/// The iOS side: the current `AVAudioSession` route as the device list, and a headphones/AirPods-gone callback when
/// the route loses its output (`.oldDeviceUnavailable`), which is when iOS apps are expected to pause.
/// Event-driven through `routeChangeNotification`; nothing polls.
@MainActor
@Observable
public final class AudioOutputMonitor {
    public private(set) var devices: [AudioOutputDevice] = []
    public private(set) var defaultDeviceUID: String?

    @ObservationIgnored public var onDevicesRemoved: (@MainActor (_ removed: [AudioOutputDevice], _ previousDefaultUID: String?) -> Void)?
    /// Called when headphones, AirPods or another personal output went away and audio fell back to the speaker.
    @ObservationIgnored public var onHeadphonesUnplugged: (@MainActor () -> Void)?
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private var observer: NSObjectProtocol?

    public init() {}

    public func device(uid: String) -> AudioOutputDevice? { devices.first { $0.uid == uid } }

    /// The output audio is going to right now (the first one in the route).
    public var currentDevice: AudioOutputDevice? { devices.first }

    public func start() {
        guard observer == nil else { return }
        refresh(notify: false)
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated { self?.routeChanged(reason: reason) }
        }
    }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    public func refresh() { refresh(notify: true) }

    private func routeChanged(reason: AVAudioSession.RouteChangeReason?) {
        let previous = devices
        refresh(notify: true)
        guard reason == .oldDeviceUnavailable else { return }
        let current = Set(devices.map(\.uid))
        let removed = previous.filter { !current.contains($0.uid) }
        if !removed.isEmpty { onDevicesRemoved?(removed, previous.first?.uid) }
        onHeadphonesUnplugged?()
    }

    private func refresh(notify: Bool) {
        let previous = devices
        devices = AVAudioSession.sharedInstance().currentRoute.outputs.map(Self.describe)
        defaultDeviceUID = devices.first?.uid
        if notify, previous != devices { onChange?() }
    }

    private static func describe(_ port: AVAudioSessionPortDescription) -> AudioOutputDevice {
        AudioOutputDevice(uid: port.uid, name: port.portName, transport: transport(port.portType))
    }

    private static func transport(_ type: AVAudioSession.Port) -> AudioOutputDevice.Transport {
        switch type {
        case .builtInSpeaker, .builtInReceiver, .headphones, .lineOut: .builtIn
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: .bluetooth
        case .airPlay: .airPlay
        case .usbAudio: .usb
        case .HDMI: .hdmi
        default: .other
        }
    }
}

#endif
