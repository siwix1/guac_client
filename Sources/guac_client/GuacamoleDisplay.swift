import AppKit
import CoreGraphics
import Foundation

@MainActor
final class GuacamoleDisplay {
    private(set) var width: Int = 1024
    private(set) var height: Int = 768

    // Layer management: layer 0 is the default display, negative indices are buffers
    private var layers: [Int: CGContext] = [:]

    // Layer properties for visible layers (index > 0)
    private var layerProperties: [Int: LayerProperties] = [:]

    // Active image streams: streamIndex -> StreamState
    private var streams: [Int: ImageStream] = [:]

    // Cursor state
    private(set) var cursorImage: NSImage?
    private(set) var cursorHotspot: CGPoint = .zero

    // Callback when display updates
    var onDisplayUpdate: (() -> Void)?

    private struct LayerProperties {
        var parentIndex: Int = 0
        var x: Int = 0
        var y: Int = 0
        var z: Int = 0
        var opacity: Double = 1.0
    }

    private struct ImageStream {
        var mimeType: String
        var compositeOp: Int32
        var layerIndex: Int
        var x: Int
        var y: Int
        var data: Data
    }

    func getDisplayImage() -> CGImage? {
        return getLayer(0)?.makeImage()
    }

    // MARK: - Instruction handling

    func handleInstruction(_ instruction: GuacInstruction, tunnel: GuacamoleTunnel) {
        switch instruction.opcode {
        case "size":
            handleSize(instruction.args)
        case "img":
            handleImg(instruction.args, tunnel: tunnel)
        case "blob":
            handleBlob(instruction.args)
        case "end":
            handleEnd(instruction.args)
        case "rect":
            handleRect(instruction.args)
        case "cfill":
            handleCfill(instruction.args)
        case "copy":
            handleCopy(instruction.args)
        case "cursor":
            handleCursor(instruction.args)
        case "sync":
            handleSync(instruction.args, tunnel: tunnel)
        case "dispose":
            handleDispose(instruction.args)
        case "move":
            handleMove(instruction.args)
        case "shade":
            handleShade(instruction.args)
        case "png", "jpeg":
            handleLegacyImage(instruction)
        case "audio":
            handleAudio(instruction.args, tunnel: tunnel)
        case "video":
            handleVideo(instruction.args, tunnel: tunnel)
        case "disconnect":
            break
        case "nop":
            break
        default:
            break
        }
    }

    // MARK: - Layer management

    private func getLayer(_ index: Int) -> CGContext? {
        if let ctx = layers[index] { return ctx }
        let w = max(width, 1)
        let h = max(height, 1)
        return createLayer(index, width: w, height: h)
    }

    @discardableResult
    private func createLayer(_ index: Int, width: Int, height: Int) -> CGContext? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Flip to top-left origin so all drawing matches Guacamole's coordinate system
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        layers[index] = ctx
        return ctx
    }

    // MARK: - Instruction handlers

    private func handleSize(_ args: [String]) {
        guard args.count >= 3,
              let layerIndex = Int(args[0]),
              let w = Int(args[1]),
              let h = Int(args[2]) else { return }

        if layerIndex == 0 {
            width = w
            height = h
        }


        // Recreate the layer at the new size, preserving old content if possible
        let oldCtx = layers[layerIndex]
        let oldImage = oldCtx?.makeImage()
        createLayer(layerIndex, width: w, height: h)

        if let oldImage, let newCtx = layers[layerIndex] {
            // Draw the old content into the new (flipped) context at top-left
            newCtx.saveGState()
            newCtx.translateBy(x: 0, y: CGFloat(oldImage.height))
            newCtx.scaleBy(x: 1, y: -1)
            newCtx.draw(oldImage, in: CGRect(x: 0, y: 0, width: oldImage.width, height: oldImage.height))
            newCtx.restoreGState()
        }
    }

    private func handleImg(_ args: [String], tunnel: GuacamoleTunnel) {
        // img,STREAM,MASK,LAYER,MIMETYPE,X,Y
        guard args.count >= 6,
              let streamIndex = Int(args[0]),
              let mask = Int32(args[1]),
              let layerIndex = Int(args[2]),
              let x = Int(args[4]),
              let y = Int(args[5]) else { return }

        let mimeType = args[3]
        streams[streamIndex] = ImageStream(
            mimeType: mimeType,
            compositeOp: mask,
            layerIndex: layerIndex,
            x: x,
            y: y,
            data: Data()
        )

        // Acknowledge the stream
        tunnel.send(GuacProtocolEncoder.ack(streamIndex: args[0], message: "OK", status: 0))
    }

    private func handleBlob(_ args: [String]) {
        guard args.count >= 2,
              let streamIndex = Int(args[0]) else { return }

        let base64String = args[1]
        if let decoded = Data(base64Encoded: base64String) {
            streams[streamIndex]?.data.append(decoded)
        }
    }

    private func handleEnd(_ args: [String]) {
        guard args.count >= 1,
              let streamIndex = Int(args[0]),
              let stream = streams.removeValue(forKey: streamIndex) else { return }

        drawImage(data: stream.data, mimeType: stream.mimeType,
                  layerIndex: stream.layerIndex, x: stream.x, y: stream.y)
    }

    private func handleRect(_ args: [String]) {
        // rect,LAYER,X,Y,WIDTH,HEIGHT
        guard args.count >= 5,
              let layerIndex = Int(args[0]),
              let x = Int(args[1]),
              let y = Int(args[2]),
              let w = Int(args[3]),
              let h = Int(args[4]) else { return }

        guard let ctx = getLayer(layerIndex) else { return }
        ctx.addRect(CGRect(x: x, y: y, width: w, height: h))
    }

    private func handleCfill(_ args: [String]) {
        // cfill,MASK,LAYER,R,G,B,A
        guard args.count >= 7,
              let layerIndex = Int(args[1]),
              let r = Int(args[2]),
              let g = Int(args[3]),
              let b = Int(args[4]),
              let a = Int(args[5]) else { return }

        guard let ctx = getLayer(layerIndex) else { return }
        ctx.setFillColor(red: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0,
                         blue: CGFloat(b) / 255.0, alpha: CGFloat(a) / 255.0)
        ctx.fillPath()
    }

    private func handleCopy(_ args: [String]) {
        // copy,SRCLAYER,SRCX,SRCY,SRCWIDTH,SRCHEIGHT,MASK,DSTLAYER,DSTX,DSTY
        guard args.count >= 9,
              let srcLayerIndex = Int(args[0]),
              let srcX = Int(args[1]),
              let srcY = Int(args[2]),
              let srcW = Int(args[3]),
              let srcH = Int(args[4]),
              let dstLayerIndex = Int(args[6]),
              let dstX = Int(args[7]),
              let dstY = Int(args[8]) else { return }

        guard let srcCtx = getLayer(srcLayerIndex),
              let dstCtx = getLayer(dstLayerIndex) else { return }

        guard let srcImage = srcCtx.makeImage() else { return }

        // Extract the source region into a temporary non-flipped context,
        // then draw it as an image into the destination (like drawImage does).
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let tmpCtx = CGContext(
            data: nil, width: srcW, height: srcH,
            bitsPerComponent: 8, bytesPerRow: srcW * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        // Draw the full source image offset so the desired region lands at (0,0).
        // tmpCtx is NOT flipped, and srcImage raw has Guac-top at pixel-bottom.
        // So Guac coordinate srcY maps to raw pixel (height - srcY).
        // We want raw rows [height-srcY-srcH ... height-srcY] to appear in tmpCtx.
        // tmpCtx.draw places image row0 at rect bottom, so the raw image's top (Guac bottom)
        // goes to the bottom of the draw rect.
        let rawSrcY = srcImage.height - srcY - srcH
        tmpCtx.draw(srcImage, in: CGRect(x: -srcX, y: -rawSrcY,
                                          width: srcImage.width, height: srcImage.height))

        guard let regionImage = tmpCtx.makeImage() else { return }

        // Now draw this into destination using the same pattern as drawImage
        dstCtx.saveGState()
        dstCtx.translateBy(x: CGFloat(dstX), y: CGFloat(dstY))
        dstCtx.translateBy(x: 0, y: CGFloat(srcH))
        dstCtx.scaleBy(x: 1, y: -1)
        dstCtx.draw(regionImage, in: CGRect(x: 0, y: 0, width: srcW, height: srcH))
        dstCtx.restoreGState()
    }

    private func handleMove(_ args: [String]) {
        // move,LAYER,PARENT,X,Y,Z
        guard args.count >= 5,
              let layerIndex = Int(args[0]),
              let parentIndex = Int(args[1]),
              let x = Int(args[2]),
              let y = Int(args[3]),
              let z = Int(args[4]) else { return }

        var props = layerProperties[layerIndex] ?? LayerProperties()
        props.parentIndex = parentIndex
        props.x = x
        props.y = y
        props.z = z
        layerProperties[layerIndex] = props
    }

    private func handleShade(_ args: [String]) {
        // shade,LAYER,OPACITY
        guard args.count >= 2,
              let layerIndex = Int(args[0]),
              let opacity = Int(args[1]) else { return }

        var props = layerProperties[layerIndex] ?? LayerProperties()
        props.opacity = Double(opacity) / 255.0
        layerProperties[layerIndex] = props
    }

    private func handleCursor(_ args: [String]) {
        // cursor,HOTSPOT_X,HOTSPOT_Y,SRCLAYER,SRCX,SRCY,SRCWIDTH,SRCHEIGHT
        guard args.count >= 7,
              let hotX = Int(args[0]),
              let hotY = Int(args[1]),
              let srcLayerIndex = Int(args[2]),
              let srcX = Int(args[3]),
              let srcY = Int(args[4]),
              let srcW = Int(args[5]),
              let srcH = Int(args[6]) else { return }

        guard let srcCtx = getLayer(srcLayerIndex),
              let srcImage = srcCtx.makeImage() else { return }

        // Raw bitmap: Guacamole Y=0 is at bottom of buffer due to flipped context
        let rawSrcY = srcImage.height - srcY - srcH
        let srcRect = CGRect(x: srcX, y: rawSrcY, width: srcW, height: srcH)
        if let cropped = srcImage.cropping(to: srcRect) {
            cursorImage = NSImage(cgImage: cropped, size: NSSize(width: srcW, height: srcH))
            cursorHotspot = CGPoint(x: hotX, y: hotY)
        }
    }

    private func handleSync(_ args: [String], tunnel: GuacamoleTunnel) {
        guard args.count >= 1 else { return }
        let timestamp = args[0]

        // Acknowledge the frame
        tunnel.send(GuacProtocolEncoder.sync(timestamp: timestamp))

        // Notify display update
        onDisplayUpdate?()
    }

    private func handleAudio(_ args: [String], tunnel: GuacamoleTunnel) {
        guard args.count >= 1 else { return }
        tunnel.send(GuacProtocolEncoder.ack(streamIndex: args[0], message: "NOT SUPPORTED", status: 0x0100))
    }

    private func handleVideo(_ args: [String], tunnel: GuacamoleTunnel) {
        guard args.count >= 1 else { return }
        tunnel.send(GuacProtocolEncoder.ack(streamIndex: args[0], message: "NOT SUPPORTED", status: 0x0100))
    }

    private func handleDispose(_ args: [String]) {
        guard args.count >= 1, let layerIndex = Int(args[0]) else { return }
        layers.removeValue(forKey: layerIndex)
        layerProperties.removeValue(forKey: layerIndex)
    }

    private func handleLegacyImage(_ instruction: GuacInstruction) {
        guard instruction.args.count >= 5,
              let layerIndex = Int(instruction.args[1]),
              let x = Int(instruction.args[2]),
              let y = Int(instruction.args[3]) else { return }

        let base64 = instruction.args[4]
        if let data = Data(base64Encoded: base64) {
            drawImage(data: data, mimeType: "image/\(instruction.opcode)",
                      layerIndex: layerIndex, x: x, y: y)
        }
    }

    // MARK: - Drawing

    private func drawImage(data: Data, mimeType: String, layerIndex: Int, x: Int, y: Int) {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = getLayer(layerIndex) else { return }

        let imgW = cgImage.width
        let imgH = cgImage.height

        ctx.saveGState()
        // Move to the tile position, then locally un-flip for image drawing
        ctx.translateBy(x: CGFloat(x), y: CGFloat(y))
        ctx.translateBy(x: 0, y: CGFloat(imgH))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: imgW, height: imgH))
        ctx.restoreGState()
    }
}
