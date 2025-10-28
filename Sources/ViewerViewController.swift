import UIKit

final class ViewerViewController: UIViewController {
    private let multipeer = MultipeerManager()
    private let imageView = UIImageView()

    // Decoder
    private var formatDescription: CMFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var sps: Data?
    private var pps: Data?

    private var streamBuffer = Data()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupImageView()
        setupMultipeer()
    }

    private func setupImageView() {
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        view.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupMultipeer() {
        multipeer.delegate = self
        // Viewer browses for hosts and will auto-invite / accept in this PoC
        multipeer.startBrowsing()
    }

    deinit {
        multipeer.stopBrowsing()
    }
}

extension ViewerViewController: MultipeerManagerDelegate {
    func multipeerManager(_ manager: MultipeerManager, didReceive data: Data, from peerID: MCPeerID) {
        // Legacy data path (JPEG) - keep for compatibility
        if let image = UIImage(data: data) {
            DispatchQueue.main.async { [weak self] in
                self?.imageView.image = image
            }
        }
    }

    func multipeerManager(_ manager: MultipeerManager, peerChanged state: MCSessionState, peerID: MCPeerID) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                print("Connected to host: \(peerID.displayName)")
            case .connecting:
                print("Connecting to host: \(peerID.displayName)")
            case .notConnected:
                print("Disconnected from host: \(peerID.displayName)")
            @unknown default:
                break
            }
        }
    }

    func multipeerManager(_ manager: MultipeerManager, didReceiveStreamData data: Data, from peerID: MCPeerID) {
        // Append to buffer and process length-prefixed packets
        streamBuffer.append(data)

        while streamBuffer.count >= 4 {
            // Read 4-byte length
            let lenData = streamBuffer.subdata(in: 0..<4)
            let len = Int(UInt32(bigEndian: lenData.withUnsafeBytes { $0.load(as: UInt32.self) }))
            if streamBuffer.count >= 4 + len {
                let nal = streamBuffer.subdata(in: 4..<(4+len))
                streamBuffer.removeSubrange(0..<(4+len))

                // If we don't have format description yet, the first packets can be SPS/PPS combined
                if formatDescription == nil {
                    // Try to parse first two NALs as SPS/PPS
                    if nal.starts(with: [0x67]) || nal.starts(with: [0x27]) {
                        sps = nal
                        continue
                    } else if nal.starts(with: [0x68]) || nal.starts(with: [0x28]) {
                        pps = nal
                        if let sps = sps, let pps = pps {
                            let parameterSets = [sps, pps]
                            parameterSets.withUnsafeBufferPointer { ptr -> Void in
                                let psPointers = UnsafeMutablePointer<UnsafePointer<UInt8>?>.allocate(capacity: 2)
                                let psSizes = UnsafeMutablePointer<Int>.allocate(capacity: 2)
                                for i in 0..<2 {
                                    ptr[i].withUnsafeBytes { (bb: UnsafeRawBufferPointer) in
                                        psPointers[i] = bb.bindMemory(to: UInt8.self).baseAddress
                                        psSizes[i] = bb.count
                                    }
                                }
                                var formatDesc: CMFormatDescription?
                                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                                                                                                   parameterSetCount: 2,
                                                                                                   parameterSetPointers: psPointers,
                                                                                                   parameterSetSizes: psSizes,
                                                                                                   nalUnitHeaderLength: 4,
                                                                                                   formatDescriptionOut: &formatDesc)
                                psPointers.deallocate(); psSizes.deallocate()
                                if status == noErr, let fd = formatDesc {
                                    formatDescription = fd
                                    createDecompressionSession()
                                }
                            }
                        }
                        continue
                    }
                }

                // If we have a format description and decompression session, feed nal prefixed with 4-byte length as required
                if let _ = formatDescription {
                    decodeNALUnit(nal)
                }
            } else {
                break // wait for more data
            }
        }
    }

    private func createDecompressionSession() {
        guard let fd = formatDescription else { return }
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: decompressionOutputCallback, decompressionOutputRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                  formatDescription: fd,
                                                  decoderSpecification: nil,
                                                  imageBufferAttributes: nil,
                                                  outputCallback: &callback,
                                                  decompressionSessionOut: &session)
        if status == noErr {
            decompressionSession = session
        } else {
            print("Failed to create decompression session: \(status)")
        }
    }

    private func decodeNALUnit(_ nal: Data) {
        // Convert NAL to AVCC format (already length-prefixed) and create CMBlockBuffer
        var length = UInt32(nal.count).bigEndian
        var packet = Data()
        packet.append(Data(bytes: &length, count: 4))
        packet.append(nal)

        var block: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                        memoryBlock: UnsafeMutableRawPointer(mutating: (packet as NSData).bytes),
                                                        blockLength: packet.count,
                                                        blockAllocator: kCFAllocatorNull,
                                                        customBlockSource: nil,
                                                        offsetToData: 0,
                                                        dataLength: packet.count,
                                                        flags: 0,
                                                        blockBufferOut: &block)
        if status != kCMBlockBufferNoErr {
            print("CMBlockBufferCreate failed: \(status)")
            return
        }

        var sampleBuffer: CMSampleBuffer?
        if let block = block, let fd = formatDescription {
            let sampleSizes: [Int] = [packet.count]
            let createStatus = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                                         dataBuffer: block,
                                                         formatDescription: fd,
                                                         sampleCount: 1,
                                                         sampleTimingEntryCount: 0,
                                                         sampleTimingArray: nil,
                                                         sampleSizeEntryCount: 1,
                                                         sampleSizeArray: sampleSizes,
                                                         sampleBufferOut: &sampleBuffer)
            if createStatus == noErr, let sb = sampleBuffer, let session = decompressionSession {
                let flagsOut = UnsafeMutablePointer<VTDecodeInfoFlags>.allocate(capacity: 1)
                defer { flagsOut.deallocate() }
                let decodeStatus = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], frameRefcon: nil, infoFlagsOut: flagsOut)
                if decodeStatus != noErr {
                    print("VTDecompressionSessionDecodeFrame failed: \(decodeStatus)")
                }
            }
        }
    }
}

private func decompressionOutputCallback(decompressionOutputRefCon: UnsafeMutableRawPointer?,
                                         sourceFrameRefCon: UnsafeMutableRawPointer?,
                                         status: OSStatus,
                                         infoFlags: VTDecodeInfoFlags,
                                         imageBuffer: CVImageBuffer?,
                                         presentationTimeStamp: CMTime,
                                         presentationDuration: CMTime) -> Void {
    guard status == noErr, let img = imageBuffer else { return }
    let viewer: ViewerViewController = Unmanaged.fromOpaque(decompressionOutputRefCon!).takeUnretainedValue()
    // Create UIImage from CVImageBuffer
    let ciImage = CIImage(cvImageBuffer: img)
    let context = CIContext(options: nil)
    if let cgImage = context.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(img), height: CVPixelBufferGetHeight(img))) {
        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
        DispatchQueue.main.async {
            viewer.imageView.image = uiImage
        }
    }
}
}
