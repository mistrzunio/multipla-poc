import Foundation
import MultipeerConnectivity
import UIKit

protocol MultipeerManagerDelegate: AnyObject {
    func multipeerManager(_ manager: MultipeerManager, didReceive data: Data, from peerID: MCPeerID)
    func multipeerManager(_ manager: MultipeerManager, peerChanged state: MCSessionState, peerID: MCPeerID)
    /// Called when stream bytes are received from a peer (streaming path)
    func multipeerManager(_ manager: MultipeerManager, didReceiveStreamData data: Data, from peerID: MCPeerID)
}

final class MultipeerManager: NSObject {
    private let serviceType: String
    private(set) var myPeerID: MCPeerID
    private(set) var session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    // map peerID.displayName -> OutputStream when we start streams to peers
    private var outgoingStreams: [String: OutputStream] = [:]

    weak var delegate: MultipeerManagerDelegate?

    init(serviceType: String = "multipla-poc") {
        self.serviceType = serviceType
        self.myPeerID = MCPeerID(displayName: UIDevice.current.name)
        self.session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        self.session.delegate = self
    }

    // Start advertising (host)
    func startAdvertising() {
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: serviceType)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
    }

    func stopAdvertising() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
    }

    // Start browsing (viewer)
    func startBrowsing() {
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
    }

    func stopBrowsing() {
        browser?.stopBrowsingForPeers()
        browser = nil
    }

    // Invite peer (from browser's foundPeer callback)
    func invite(peer: MCPeerID, context: Data? = nil, timeout: TimeInterval = 30) {
        browser?.invitePeer(peer, to: session, withContext: context, timeout: timeout)
    }

    // Start a stream to a given peer. Returns the OutputStream (or nil on failure).
    func startStream(withName name: String, to peer: MCPeerID) -> OutputStream? {
        do {
            let stream = try session.startStream(withName: name, toPeer: peer)
            // store by peer name
            outgoingStreams[peer.displayName] = stream
            stream.schedule(in: .current, forMode: .default)
            stream.open()
            return stream
        } catch {
            NSLog("Failed to start stream to \(peer.displayName): \(error)")
            return nil
        }
    }

    // Write bytes to the output stream for a peer (if available)
    func writeStreamData(_ data: Data, to peer: MCPeerID) {
        guard let stream = outgoingStreams[peer.displayName] else { return }
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            var bytesRemaining = ptr.count
            var offset = 0
            while bytesRemaining > 0 {
                let written = stream.write(ptr.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self), maxLength: bytesRemaining)
                if written <= 0 { break }
                bytesRemaining -= written
                offset += written
            }
        }
    }

    // Send data to connected peers
    func send(data: Data, reliably: Bool = true) throws {
        guard !session.connectedPeers.isEmpty else { return }
        let mode: MCSessionSendDataMode = reliably ? .reliable : .unreliable
        try session.send(data, toPeers: session.connectedPeers, with: mode)
    }
}

// MARK: - MCSessionDelegate
extension MultipeerManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.multipeerManager(self, peerChanged: state, peerID: peerID)
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.multipeerManager(self, didReceive: data, from: peerID)
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // Read stream asynchronously on a background queue and forward data to delegate
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            stream.open()
            let bufferSize = 16 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer {
                buffer.deallocate()
                stream.close()
            }

            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read > 0, let self = self {
                    let data = Data(bytes: buffer, count: read)
                    DispatchQueue.main.async {
                        self.delegate?.multipeerManager(self, didReceiveStreamData: data, from: peerID)
                    }
                } else {
                    break
                }
            }
        }
    }

    // Not used in this PoC
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate
extension MultipeerManager: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Automatically accept invitations for PoC. In real app, present UI to accept.
        invitationHandler(true, self.session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        NSLog("Advertiser failed: \(error)")
    }
}

// MARK: - MCNearbyServiceBrowserDelegate
extension MultipeerManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        // Auto-invite discovered peers (PoC). In production, show UI.
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        // handle lost peer if needed
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        NSLog("Browser failed: \(error)")
    }
}
