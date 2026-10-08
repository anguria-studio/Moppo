import SwiftUI

struct PhotoAccessGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Photos and iCloud").font(.headline)
            Text("With iCloud Photos enabled, deletion affects the linked library and other devices that use it.")
            Text("Deleted photos move to Recently Deleted. Storage is not released immediately. Use Photos to review recovery and permanent deletion.")
            Text("Scans and the photo grid use local previews first. They can download missing previews from iCloud.")
            Text("Opening a photo preview can download the full-resolution original. This uses network data and local storage.")
            Text("Photo downloads are on by default. Change this in Settings > Advanced. Changes apply to new requests; active requests can finish.")
                .foregroundStyle(.secondary)
            Text("With downloads off, scans skip unavailable previews. Full-resolution previews require a local original.")
                .foregroundStyle(.secondary)
        }
    }
}
