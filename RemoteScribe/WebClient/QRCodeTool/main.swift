import AppKit
import CoreImage
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: RemoteScribeQRCode <url> <output.png>\n", stderr)
    exit(2)
}

let value = CommandLine.arguments[1]
let destination = URL(fileURLWithPath: CommandLine.arguments[2])

guard
    let payload = value.data(using: .utf8),
    let filter = CIFilter(name: "CIQRCodeGenerator")
else {
    fputs("Impossible de créer le QR code.\n", stderr)
    exit(1)
}

filter.setValue(payload, forKey: "inputMessage")
filter.setValue("M", forKey: "inputCorrectionLevel")

guard let qrImage = filter.outputImage else {
    fputs("Le générateur QR n’a produit aucune image.\n", stderr)
    exit(1)
}

let scale = CGAffineTransform(scaleX: 14, y: 14)
let scaled = qrImage.transformed(by: scale)
let paddedExtent = scaled.extent.insetBy(dx: -56, dy: -56)
let white = CIImage(color: CIColor.white).cropped(to: paddedExtent)
let composed = scaled.composited(over: white)
let context = CIContext(options: [.useSoftwareRenderer: false])

guard let cgImage = context.createCGImage(composed, from: paddedExtent) else {
    fputs("Impossible de convertir le QR code en PNG.\n", stderr)
    exit(1)
}

let bitmap = NSBitmapImageRep(cgImage: cgImage)
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Impossible d’encoder le QR code en PNG.\n", stderr)
    exit(1)
}

do {
    try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try png.write(to: destination, options: .atomic)
} catch {
    fputs("Impossible d’écrire le QR code : \(error.localizedDescription)\n", stderr)
    exit(1)
}

print(destination.path)
