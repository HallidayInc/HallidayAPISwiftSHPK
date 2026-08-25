import CoreImage.CIFilterBuiltins
import SwiftUI

// White plate holding the code, with the chain's mark at the centre. Correction level H
// leaves enough redundancy for the badge to sit on top without breaking the scan.
struct QRCard: View {
    let address: String
    let chain: String
    var side: CGFloat = 232

    var body: some View {
        ZStack {
            if let code = qrCode(address) {
                Image(uiImage: code)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: side, height: side)
            }
            ChainBadge(chain: chain, size: 44)
                .padding(5)
                .background(.white, in: .rect(cornerRadius: 11))
                .overlay {
                    RoundedRectangle(cornerRadius: 11).strokeBorder(.black, lineWidth: 2)
                }
        }
        .padding(18)
        .background(.white, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18).strokeBorder(Color.hairline, lineWidth: 1)
        }
    }

    private func qrCode(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
