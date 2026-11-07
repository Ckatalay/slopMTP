import SwiftUI

/// Square game artwork with a generated placeholder while loading or when offline.
struct CoverArtView: View {
    let titleID: TitleID?
    let name: String
    var cornerRadius: CGFloat = 12

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                placeholder
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        }
        .task(id: titleID) { await load() }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        let hue = Double(abs(name.hashValue % 360)) / 360
        return LinearGradient(
            colors: [Color(hue: hue, saturation: 0.55, brightness: 0.55), Color(hue: hue + 0.08, saturation: 0.65, brightness: 0.3)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay {
            Text(initials)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var initials: String {
        let words = name.split { !$0.isLetter && !$0.isNumber }.prefix(2)
        return words.compactMap(\.first).map(String.init).joined().uppercased()
    }

    private func load() async {
        guard let titleID, let url = TitleDatabase.shared.iconURL(for: titleID) else { return }
        let loaded = await CoverArtCache.shared.image(for: url, key: titleID.applicationID.description)
        withAnimation(.easeOut(duration: 0.2)) { image = loaded }
    }
}
