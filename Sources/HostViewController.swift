import UIKit
import AVFoundation
import VideoToolbox

/// HostViewController: captures camera frames and encodes them using VideoToolbox H.264 encoder
/// then streams encoded bytes to connected peers using MCSession streams (via MultipeerManager).
final class HostViewController: UIViewController {
    private let multipeer = MultipeerManager()
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()

    // VideoToolbox encoder
    private var compressionSession: VTCompressionSession?
    private var frameCount: Int64 = 0
    private var sps: Data?
    private var pps: Data?

    private var connectedPeer: MCPeerID?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupMultipeer()
        setupCaptureSession()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startCapture()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCapture()
        multipeer.stopAdvertising()
        teardownCompression()
    }

    private func setupMultipeer() {
        multipeer.delegate = self
        multipeer.startAdvertising()
    }

    private func setupCaptureSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .vga640x480

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            print("Failed to get camera input")
            return
        }

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        let queue = DispatchQueue(label: "videoOutputQueue")
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        videoOutput.alwaysDiscardsLateVideoFrames = true

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        captureSession.commitConfiguration()
    }

    private func startCapture() {
        if !captureSession.isRunning {
            captureSession.startRunning()
        }
    }

    private func stopCapture() {
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    private func setupCompression(width: Int32, height: Int32) {
        teardownCompression()

        let status = VTCompressionSessionCreate(allocator: nil,
                                                width: width,
                                                height: height,
                                                codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: nil,
                                                imageBufferAttributes: nil,
                                                compressedDataAllocator: nil,
                                                outputCallback: compressionOutputCallback,
                                                refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                                                compressionSessionOut: &compressionSession)

        guard status == noErr, let session = compressionSession else {
            print("Failed to create compression session: \(status)")
            return
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        let bitrate: Int = 500_000
        let bitrateNumber = CFNumberCreate(nil, .sInt32Type, &([Int32(bitrate)][0]))
        if let bn = bitrateNumber {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bn)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private func teardownCompression() {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
        sps = nil
        pps = nil
    }

    // Called from VideoToolbox callback
    fileprivate func gotEncodedData(_ data: Data, isKeyFrame: Bool) {
        guard let peer = connectedPeer else { return }

        // Prepend simple header: 4-byte length
        var len = UInt32(data.count).bigEndian
        var packet = Data()
        packet.append(Data(bytes: &len, count: 4))
        packet.append(data)

        multipeer.writeStreamData(packet, to: peer)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension HostViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Setup compression session based on frame size once
        if compressionSession == nil {
            let width = Int32(CVPixelBufferGetWidth(imageBuffer))
            let height = Int32(CVPixelBufferGetHeight(imageBuffer))
            setupCompression(width: width, height: height)
        }

        guard let session = compressionSession else { return }

        let pts = CMTime(value: CMTimeValue(frameCount), timescale: 30)
        var flags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(session,
                                                     imageBuffer,
                                                     pts,
                                                     CMTime.invalid,
                                                     nil,
                                                     nil,
                                                     &flags)
        if status != noErr {
            print("VTCompressionSessionEncodeFrame failed: \(status)")
        }
        frameCount += 1
    }
}

// MARK: - VideoToolbox callback
private func compressionOutputCallback(outputCallbackRefCon: UnsafeMutableRawPointer?,
                                       sourceFrameRefCon: UnsafeMutableRawPointer?,
                                       status: OSStatus,
                                       infoFlags: VTEncodeInfoFlags,
                                       sampleBuffer: CMSampleBuffer?) -> Void {
    guard status == noErr else { return }
    guard let sbuf = sampleBuffer, CMSampleBufferDataIsReady(sbuf) else { return }
    let encoder: HostViewController = Unmanaged.fromOpaque(outputCallbackRefCon!).takeUnretainedValue()

    // Check for SPS/PPS in format description
    if let format = CMSampleBufferGetFormatDescription(sbuf) {
        var spsSize: Int = 0
        var spsCount: Int = 0
        var ppsSize: Int = 0
        var ppsCount: Int = 0
        var spsPointer: UnsafePointer<UInt8>?
        var ppsPointer: UnsafePointer<UInt8>?

        if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil) == noErr,
           CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: &ppsCount, nalUnitHeaderLengthOut: nil) == noErr,
           let spsPtr = spsPointer, let ppsPtr = ppsPointer {
            encoder.sps = Data(bytes: spsPtr, count: spsSize)
            encoder.pps = Data(bytes: ppsPtr, count: ppsSize)
            // Send SPS/PPS before frames (prefixing with length as well)
            if let sps = encoder.sps, let pps = encoder.pps, let peer = encoder.connectedPeer {
                var spsLen = UInt32(sps.count).bigEndian
                var ppsLen = UInt32(pps.count).bigEndian
                var packet = Data()
                packet.append(Data(bytes: &spsLen, count: 4)); packet.append(sps)
                packet.append(Data(bytes: &ppsLen, count: 4)); packet.append(pps)
                encoder.multipeer.writeStreamData(packet, to: peer)
            }
        }
    }

    // Get encoded data (one or more NALs)
    guard let dataBuffer = CMSampleBufferGetDataBuffer(sbuf) else { return }
    var lengthAtOffset: Int = 0
    var totalLength: Int = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    if CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr, let dp = dataPointer {
        let data = Data(bytes: dp, count: totalLength)
        // Determine if keyframe
        var isKeyFrame = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) as? [[CFString: Any]], let first = attachments.first {
            let depends = first[kCMSampleAttachmentKey_NotSync] as? Bool
            isKeyFrame = !(depends ?? false)
        }
        encoder.gotEncodedData(data, isKeyFrame: isKeyFrame)
    }
}

// MARK: - Multipeer delegate
extension HostViewController: MultipeerManagerDelegate {
    func multipeerManager(_ manager: MultipeerManager, didReceive data: Data, from peerID: MCPeerID) {
        // handle control messages if needed
    }

    func multipeerManager(_ manager: MultipeerManager, peerChanged state: MCSessionState, peerID: MCPeerID) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                print("Peer connected: \(peerID.displayName)")
                self.connectedPeer = peerID
                // start stream to peer
                _ = self.multipeer.startStream(withName: "h264stream", to: peerID)
            case .connecting:
                print("Peer connecting: \(peerID.displayName)")
            case .notConnected:
                print("Peer disconnected: \(peerID.displayName)")
                if self.connectedPeer?.displayName == peerID.displayName {
                    self.connectedPeer = nil
                }
            @unknown default:
                break
            }
        }
    }

    func multipeerManager(_ manager: MultipeerManager, didReceiveStreamData data: Data, from peerID: MCPeerID) {
        // Host doesn't expect to receive stream data in this PoC
    }
}
