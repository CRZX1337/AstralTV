import SwiftUI


/// Portrait cutoff for the Movies hero art. The Live TV banner no longer
/// uses it: its art goes through the fit-to-box ProgramArtSlot below.
enum GuidePreviewPortraitArt {
    /// Width/height below which art counts as a portrait poster. Near-square
    /// art (sports matchup logos ~0.96) keeps the full cropped 16:9 slot.
    static let maxAspect: CGFloat = 0.8
}

/// ONE definition of the program-art slot, shared by the Live TV guide
/// preview banner (tvOS hero) and the Program Info sheet (long press, all
/// platforms).
///
/// Logan 2026-09-15 (rev 2): art KEEPS ITS OWN SHAPE. The earlier fixed box
/// was rejected: a 2:3 poster shrank to fit a landscape box (and a square one
/// on iOS), so posters read tiny next to landscape title cards. The slot is
/// now HEIGHT-LOCKED and the width follows the image aspect, so landscape art
/// renders landscape, portrait renders portrait, at the same height on both
/// surfaces. Nothing is cropped, nothing is letterboxed: the drawn box IS the
/// image shape, so the surrounding surface simply shows through.
///
/// Width is clamped to a 16:9 maximum so an ultra-wide banner cannot push the
/// copy out, and to a minimum so a freak sliver of art still reads. The 16:9
/// maximum is also what the slot RESERVES before the aspect is known, so the
/// slot never collapses and the copy column does not jump; AuthPosterImage
/// reports the decoded size (synchronously on a cache hit, so revisits do not
/// pop at all), and only then does the width settle. Height never changes, so
/// GuidePreviewArtAnchor's maxY, and the corner mini player riding it, are
/// stable throughout.
///
/// This supersedes both the fill-and-crop slot with its portrait escape hatch
/// (GuidePreviewPortraitArt.maxAspect, still used by the Movies hero) and the
/// fit-inside-a-fixed-box slot.
struct ProgramArtSlotMetrics {
    /// Locked height: the two surfaces match because they share this.
    let height: CGFloat
    /// 16:9 width, also the pre-load reservation.
    let maxWidth: CGFloat
    /// Floor for very tall art.
    let minWidth: CGFloat
    let cornerRadius: CGFloat

    init(height: CGFloat, cornerRadius: CGFloat) {
        self.height = height.rounded()
        self.maxWidth = (height * 16.0 / 9.0).rounded()
        self.minWidth = (height * 0.5).rounded()
        self.cornerRadius = cornerRadius
    }

    /// The same slot at the app-wide Text Size (Settings > Appearance).
    /// Logan 2026-09-15: the shipped sizes stay the DEFAULT, and users who
    /// want larger art raise Text Size, so the slot rides the SAME scale the
    /// type does. `TextScale.grow` is the app's one metric multiplier, so
    /// art only ever grows (85% text keeps the designed layout) and there is
    /// no second setting or duplicated factor. maxWidth and minWidth follow
    /// from the height, so true aspect and the portrait floor are preserved.
    func scaled(_ scale: CGFloat) -> ProgramArtSlotMetrics {
        guard scale > 1 else { return self }
        return ProgramArtSlotMetrics(height: TextScale.grow(height, scale),
                                     cornerRadius: TextScale.grow(cornerRadius, scale))
    }

    /// Width for a given width/height aspect, clamped.
    func width(for aspect: CGFloat?) -> CGFloat {
        guard let aspect, aspect.isFinite, aspect > 0 else { return maxWidth }
        return min(maxWidth, max(minWidth, (height * aspect).rounded()))
    }

    /// Phone/iPad sheet.
    static let slot = ProgramArtSlotMetrics(height: 130, cornerRadius: 10)
    /// The compact phone card, where the art sits beside the copy in a row.
    static let compactSlot = ProgramArtSlotMetrics(height: 104, cornerRadius: 10)
}

/// Height-locked, aspect-shaped program artwork. Reserves the 16:9 width even
/// when there is no art, so nothing shifts.
struct ProgramArtSlot: View {
    let url: URL?
    var headers: [String: String] = [:]
    var metrics: ProgramArtSlotMetrics = ProgramArtSlotMetrics.slot
    var maxPixel: CGFloat = 800
    /// Corner radius of the CARD this art sits in. Honored when Settings >
    /// Appearance > "Rounded corners on logos and artwork" is on, zeroed
    /// when it is off. Defaults to the slot's own designed radius so a
    /// caller inside a card of the same shape needs no argument; pass 0 for
    /// a container with no rounding (the tvOS guide preview strip). See
    /// `LogoCorners`.
    var containerRadius: CGFloat? = nil
    /// GUIDE surfaces: clip on Settings > Appearance > "Rounded corners in
    /// Guide view" instead of the List one (Logan 2026-09-16). The guide's
    /// program artwork - the preview banner's art, and Program Info when it
    /// was opened FROM the guide - rides the guide toggle; the same sheet
    /// reached from the Live TV list, the in-player info card, the channel
    /// picker and the multiview row stay on the List toggle. Same radius
    /// rule either way (`LogoCorners.radius`, tile test plus 25% cap).
    var usesGuideCorners: Bool = false
    /// Kept for callers that want the real bitmap size; the slot uses it
    /// itself to settle its width.
    var onImageLoaded: ((CGSize) -> Void)? = nil

    /// nil until the bitmap reports its size: width stays at the 16:9 reserve.
    @State private var aspect: CGFloat? = nil
    /// App-wide Text Size: the slot grows with it (see `scaled(_:)`).
    @Environment(\.astralTextScale) private var textScale
    /// Settings > Appearance > "Rounded corners in List view".
    @Environment(\.astralRoundedLogoCorners) private var roundedCorners
    /// Settings > Appearance > "Rounded corners in Guide view".
    @Environment(\.astralRoundedGuideCorners) private var roundedGuideCorners

    /// Whichever of the two Appearance toggles governs this surface.
    private var cornersEnabled: Bool {
        usesGuideCorners ? roundedGuideCorners : roundedCorners
    }

    /// The slot's metrics at the current Text Size. Every frame below uses
    /// these, so height, 16:9 reserve and portrait floor scale together.
    private var m: ProgramArtSlotMetrics { metrics.scaled(textScale) }

    private var width: CGFloat { m.width(for: url == nil ? nil : aspect) }

    /// The radius actually drawn: the container's (Text-Size-scaled like the
    /// rest of the slot when it falls back to the slot's own), or 0 when the
    /// Appearance toggle is off.
    private var cornerRadius: CGFloat {
        // The slot already sizes itself to the art's true aspect, so its own
        // box IS the art's bounds; the cap still guards very short art.
        LogoCorners.radius(container: containerRadius ?? m.cornerRadius,
                           imageShorterSide: min(width, m.height),
                           // The slot draws through AuthPosterImage and never
                           // sees the bitmap, so it reads the shared verdict
                           // cache; unknown program art counts as a tile,
                           // since it is opaque photography.
                           isTile: LogoTileTest.cachedVerdict(for: url) ?? true,
                           enabled: cornersEnabled)
    }

    var body: some View {
        Color.clear
            .frame(width: width, height: m.height)
            .overlay {
                if let url {
                    AuthPosterImage(url: url,
                                    headers: headers,
                                    onImageLoaded: { size in
                                        if size.width > 0, size.height > 0 {
                                            let a = size.width / size.height
                                            if aspect != a { aspect = a }
                                        }
                                        onImageLoaded?(size)
                                    },
                                    placeholder: .clear,
                                    maxPixel: maxPixel)
                        // FIT, never fill: aspect preserved, nothing cropped.
                        // Once the aspect is known the box already matches it,
                        // so there is nothing left over to letterbox.
                        .aspectRatio(contentMode: .fit)
                        .frame(width: width, height: m.height)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius,
                                                    style: .continuous))
                        .id(url)
                }
            }
            .clipped()
            // A new image re-reserves rather than keeping the old shape.
            .onChange(of: url) { _, _ in aspect = nil }
    }
}
