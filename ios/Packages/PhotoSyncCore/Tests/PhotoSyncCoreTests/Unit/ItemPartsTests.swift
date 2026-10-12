// Diagnostics summary: the part list of an item turns into one plain line, and unknown sizes stay visible.
import Testing
import PhotoSyncCore

@Suite struct ItemPartsTests {
    @Test func noPartsSaysSo() {
        #expect(ItemParts.summary([]) == "No stored parts found")
    }

    @Test func onePartShowsCountAndSize() {
        let part = PartRecord(kind: "photo", filename: "IMG_0001.HEIC", format: "public.heic", bytes: 2_097_152)
        #expect(ItemParts.summary([part]) == "1 part, 2.0 MB")
    }

    @Test func totalsAddUpAcrossParts() {
        let parts = [
            PartRecord(kind: "photo", filename: "a.HEIC", format: "public.heic", bytes: 1_048_576),
            PartRecord(kind: "pairedVideo", filename: "a.MOV", format: "com.apple.quicktime-movie", bytes: 3_145_728),
        ]
        #expect(ItemParts.summary(parts) == "2 parts, 4.0 MB")
    }

    @Test func unknownSizeIsNotCountedAsZeroBytes() {
        let parts = [
            PartRecord(kind: "photo", filename: "a.HEIC", format: "public.heic", bytes: 1_048_576),
            PartRecord(kind: "video", filename: "b.MOV", format: "com.apple.quicktime-movie", bytes: nil),
        ]
        #expect(ItemParts.summary(parts) == "2 parts, 1.0 MB plus 1 part of unknown size")
    }

    @Test func smallSizesStayInBytes() {
        #expect(ItemParts.formatBytes(512) == "512 B")
        #expect(ItemParts.formatBytes(0) == "0 B")
    }
}
