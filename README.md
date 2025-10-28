# multipla-poc

Create an iOS application using the MultipeerConnectivity framework for local peer-to-peer communication.

This repository contains a small proof-of-concept (PoC) showing a host (streamer) — viewer pair. The host app captures camera frames, compresses them to JPEG (PoC), and sends them to connected viewers using Multipeer Connectivity. Devices pair locally (nearby) and then exchange video frames over the peer-to-peer connection.

Files added in this PoC:

- `Sources/MultipeerManager.swift` — lightweight wrapper around MCSession, MCNearbyServiceAdvertiser and MCNearbyServiceBrowser, plus delegate callbacks and a send(data:) helper.
- `Sources/HostViewController.swift` — captures camera video using AVFoundation, compresses frames to JPEG, and sends frames to connected peers.
- `Sources/ViewerViewController.swift` — receives image data and displays frames in a UIImageView.

Quick notes and how to use

1. This repo doesn't include a full Xcode project. To try the PoC:
	- Create a new iOS project in Xcode (App, Swift, iOS target).
	- Add the three Swift files from `Sources/` into the project.
	- Set a ViewController to be `HostViewController` on one device and `ViewerViewController` on the other, or add a small UI to choose role.
	- In your project's `Info.plist` add `NSCameraUsageDescription` with a user-facing message (e.g., "Camera is used to stream video to a nearby peer").

2. Build and run on real devices (MultipeerConnectivity between simulators is limited and camera capture requires hardware).

3. The current PoC sends JPEG frames and uses `unreliable` mode for lower latency — this is simple and works for small demos but is not efficient for production-quality video.

Improvements and next steps

- Use VideoToolbox (VTCompressionSession) to H.264-encode frames and send via MCSession streams for better bandwidth and smoother playback.
- Add a simple pairing UI instead of auto-accepting invites.
- Add timestamp/frame sequencing and basic reordering/decoding on the viewer side.
- Consider using `MCSession.send(_:toPeers:with:)` with `.unreliable` for lower-latency image frames and `.reliable` for control messages.

If you'd like, I can:
- generate a complete Xcode project skeleton (plist, storyboard/SwiftUI entry, app delegate) so you can open and run immediately, or
- replace JPEG sending with a VTCompressionSession H.264 streamer (more involved, but gives much better performance).

Project skeleton added

I added a minimal SwiftUI app entry and support files into this repository so you can open it directly in Xcode and run on device (you still need to create an Xcode project that includes these files, or let me generate a full `.xcodeproj` if you want). Files added:

- `Sources/MultiplaApp.swift` — SwiftUI @main entry
- `Sources/ContentView.swift` — simple role chooser (Host / Viewer)
- `Sources/HostViewController.swift` — Host: captures camera and encodes with VideoToolbox H.264 and streams via Multipeer streams
- `Sources/ViewerViewController.swift` — Viewer: receives stream bytes, decodes via VideoToolbox and displays frames
- `Sources/MultipeerManager.swift` — updated to support MCSession streams and stream data callbacks
- `Info.plist` — minimal plist with `NSCameraUsageDescription`
- `Base.lproj/LaunchScreen.storyboard` — minimal launch screen storyboard

Notes:
- This PoC now implements an H.264 encoding + streaming path using `VTCompressionSession` and MCSession streams. The Host starts an OutputStream to the connected peer and writes length-prefixed NAL data. The Viewer parses incoming length-prefixed packets, builds a CMFormatDescription from SPS/PPS, and uses `VTDecompressionSession` to decode frames.
- This is a proof-of-concept: the VideoToolbox paths are low-level and may need additional tuning (bitrate, keyframe interval, handling partial packets across stream reads). Run on real devices.

If you want, I can now generate a complete `.xcodeproj` for you and wire these files in, or I can refine encoder settings and improve packetization/robustness (e.g., add RTP-like framing, sequence numbers, SPS/PPS retransmit, jitter buffer). Which should I do next?