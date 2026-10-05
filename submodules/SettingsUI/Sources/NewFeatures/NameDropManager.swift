import Foundation
import UIKit
import MultipeerConnectivity
import Display
import AccountContext
import TelegramCore
import SwiftSignalKit

// NameDrop transport.
//
// iOS does not expose a public "AirDrop for third-party payloads" API.
// AirDrop itself runs on top of AWDL (Apple Wireless Direct Link) + Bluetooth LE
// discovery with Wi-Fi direct transfer. The public framework that gives
// third-party apps the same class of transport is MultipeerConnectivity
// (Bonjour over BLE + Wi-Fi, peer-to-peer, encrypted MCSession).
// That is what NameDrop uses here: proximity-triggered P2P share of a small
// profile payload. Bringing two iPhones close together keeps them in
// BLE/Wi-Fi range, so discovery fires exactly in the NameDrop gesture moment.
//
// Service type must be <= 15 chars, lowercase letters/numbers/hyphen.
private let nameDropServiceType = "tg-namedrop"

public final class NameDropManager: NSObject {
    public static let shared = NameDropManager()

    public var onDidReceive: ((NameDropPayload) -> Void)?

    private let queue = DispatchQueue(label: "namedrop.manager", qos: .utility)
    private var peerId: MCPeerID
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var advertisingPayload: NameDropPayload?
    private var isBrowsing = false
    private weak var boundContext: AccountContext?
    private var openChatDisposable = MetaDisposable()
    private var lastReceiveByKey: [String: Date] = [:]
    private var settingsObserver: NSObjectProtocol?

    private override init() {
        let suffix = String(abs(UUID().uuidString.hashValue % 9000) + 1000)
        let deviceName = String(UIDevice.current.name.prefix(12))
        let name = deviceName + "#\(suffix)"
        self.peerId = MCPeerID(displayName: name)
        super.init()
        self.settingsObserver = NotificationCenter.default.addObserver(forName: NameDropSettingsStore.didChangeNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.refreshTransport()
        })
    }

    deinit {
        if let observer = self.settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API used by UI

    public func bind(context: AccountContext) {
        self.queue.async { [weak self] in
            self?.boundContext = context
            DispatchQueue.main.async { [weak self] in
                self?.refreshTransport()
            }
        }
    }

    /// Arms the AirDrop-like receiver: binds the account context (used to open
    /// chats) and installs the default top-banner presenter if none is set.
    /// Safe to call from any screen; idempotent.
    public func ensureReceiver(with context: AccountContext) {
        self.bind(context: context)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.onDidReceive == nil {
                self.onDidReceive = { payload in
                    NameDropOverlay.shared.onAddChat = { [weak self] received in
                        self?.openChat(with: received)
                    }
                    NameDropOverlay.shared.show(payload: payload)
                }
            }
        }
    }

    public var isEnabled: Bool {
        return NameDropSettingsStore.shared.get().enabled
    }

    /// Call when the user opens/closes their own profile.
    /// Advertising runs only while `payload != nil` and the toggle is ON,
    /// so the profile is shared only from the own-profile screen.
    public func setAdvertisingPayload(_ payload: NameDropPayload?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self else { return }
                self.advertisingPayload = payload
                DispatchQueue.main.async { [weak self] in
                    self?.refreshTransport()
                }
            }
        }
    }

    public func makeOwnPayload(context: AccountContext, fullName: String, username: String?) -> NameDropPayload {
        let settings = NameDropSettingsStore.shared.get()
        let cleanUsername: String?
        if let username, !username.isEmpty {
            cleanUsername = username
        } else {
            cleanUsername = nil
        }
        return NameDropPayload(
            version: 1,
            peerId: context.account.peerId.toInt64(),
            fullName: fullName,
            username: cleanUsername,
            backgroundEmoji: settings.backgroundEmoji,
            backgroundColorHex: settings.backgroundColorHex,
            avatarDataBase64: nil
        )
    }

    // MARK: - Transport

    private func refreshTransport() {
        let enabled = NameDropSettingsStore.shared.get().enabled
        if enabled {
            self.ensureSession()
            self.startBrowsingIfNeeded()
        } else {
            self.stopBrowsing()
            self.stopAdvertising()
            return
        }
        if self.advertisingPayload != nil {
            self.startAdvertisingIfNeeded()
        } else {
            self.stopAdvertising()
        }
    }

    private func ensureSession() {
        if self.session == nil {
            let session = MCSession(peer: self.peerId, securityIdentity: nil, encryptionPreference: .required)
            session.delegate = self
            self.session = session
        }
    }

    private func startAdvertisingIfNeeded() {
        guard self.advertiser == nil else { return }
        self.ensureSession()
        let advertiser = MCNearbyServiceAdvertiser(peer: self.peerId, discoveryInfo: ["namedrop": "1"], serviceType: nameDropServiceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
    }

    private func stopAdvertising() {
        if let advertiser = self.advertiser {
            advertiser.stopAdvertisingPeer()
            advertiser.delegate = nil
            self.advertiser = nil
        }
    }

    private func startBrowsingIfNeeded() {
        guard !self.isBrowsing else { return }
        self.ensureSession()
        let browser = MCNearbyServiceBrowser(peer: self.peerId, serviceType: nameDropServiceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
        self.isBrowsing = true
    }

    private func stopBrowsing() {
        if let browser = self.browser {
            browser.stopBrowsingForPeers()
            browser.delegate = nil
            self.browser = nil
        }
        self.isBrowsing = false
    }

    private func sendCurrentPayload(to peer: MCPeerID) {
        guard let payload = self.advertisingPayload else { return }
        guard let session = self.session else { return }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        // Small profile payload (< 5 KB without avatar). Safe for MCSession send.
        do {
            try session.send(data, toPeers: [peer], with: .reliable)
        } catch {
            // Browsing side will retry on next discovery; ignore transient errors.
        }
    }

    private func handleIncomingData(_ data: Data, from peer: MCPeerID) {
        guard let payload = try? JSONDecoder().decode(NameDropPayload.self, from: data) else { return }
        guard payload.version == 1 else { return }
        let name = payload.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        // De-dup: ignore repeats of the same sender within 20 seconds
        // (Multipeer can reconnect several times while phones stay together).
        let key = "\(payload.peerId)#\(payload.fullName)"
        let now = Date()
        if let last = self.lastReceiveByKey[key], now.timeIntervalSince(last) < 20.0 {
            return
        }
        self.lastReceiveByKey[key] = now

        DispatchQueue.main.async { [weak self] in
            self?.onDidReceive?(payload)
        }
    }

    // MARK: - Open chat ("Add Chat")

    public func openChat(with payload: NameDropPayload) {
        guard let context = self.boundContext else { return }
        let sharedContext = context.sharedContext

        func navigate(with peer: EnginePeer) {
            guard let navigationController = sharedContext.mainWindow?.viewController as? NavigationController else { return }
            sharedContext.navigateToChatController(NavigateToChatControllerParams(
                navigationController: navigationController,
                context: context,
                chatLocation: .peer(peer)
            ))
        }

        if let username = payload.username, !username.isEmpty {
            self.openChatDisposable.set((context.engine.peers.resolvePeerByName(name: username, referrer: nil)
            |> deliverOnMainQueue).start(next: { result in
                guard case let .result(peer) = result, let peer else { return }
                navigate(with: peer)
            }))
        } else {
            // No username: try to open by peer id if the peer is already known locally.
            let peerId = EnginePeer.Id(payload.peerId)
            self.openChatDisposable.set((context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
            |> deliverOnMainQueue).start(next: { peer in
                guard let peer else { return }
                navigate(with: peer)
            }))
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension NameDropManager: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Accept every NameDrop invitation while the toggle is ON and we are
        // advertising our own profile. The payload goes out on `peer:didChangeState:`
        // once the encrypted session is connected.
        let shouldAccept = self.isEnabled && self.advertisingPayload != nil
        if shouldAccept {
            self.ensureSession()
            invitationHandler(true, self.session)
        } else {
            invitationHandler(false, nil)
        }
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension NameDropManager: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard self.isEnabled else { return }
        guard let session = self.session else { return }
        // Invite with a short timeout; the advertiser auto-accepts (see above)
        // and then pushes the profile payload over the encrypted session.
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 12)
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
    }

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
    }
}

// MARK: - MCSessionDelegate

extension NameDropManager: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        if state == .connected {
            // We connected both as browser and as advertiser. Only the side
            // that is currently advertising an own profile sends.
            self.sendCurrentPayload(to: peerID)
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        self.handleIncomingData(data, from: peerID)
    }

    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
    }

    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
    }

    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
    }
}
