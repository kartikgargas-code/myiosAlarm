import XCTest
@testable import AlarmClock

@MainActor
final class PlaylistBackupTests: XCTestCase {
    func testRestoreOverFirstFolderAndReconnectMissingSecondFolder() throws {
        let songs = (0..<143).map { ImportedSound(name: "Track \($0)", fileName: "\($0).mp3") }
        let ids = songs.map(\.id)
        let names = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0.fileName) })
        let backedUp = Playlist(name: "Morning", soundIDs: ids, selectedSoundIDs: Array(ids.dropLast()))
        let local = Playlist(name: "Morning", soundIDs: Array(ids.prefix(123)))
        let partial = SoundLibrary.restoredPlaylist(backedUp, existing: local, names: names,
                                                   available: Array(songs.prefix(123)))
        XCTAssertEqual(partial.id, local.id)
        XCTAssertEqual(partial.soundIDs, local.soundIDs)
        XCTAssertEqual(partial.missingSongs.map(\.fileName), songs.suffix(20).map(\.fileName))
        XCTAssertEqual(partial.missingSongs.last?.wasSelected, false)

        let saved = try JSONDecoder().decode(Playlist.self, from: JSONEncoder().encode(partial))
        let full = SoundLibrary.restoredPlaylist(saved, existing: partial, names: names, available: songs)
        XCTAssertEqual(full.soundIDs, ids)
        XCTAssertEqual(full.selectedSoundIDs, backedUp.selectedSoundIDs)
        XCTAssertTrue(full.missingSongs.isEmpty)

        let fresh = SoundLibrary.restoredPlaylist(backedUp, existing: nil, names: names, available: [])
        XCTAssertEqual(fresh.missingSongs.map(\.fileName), songs.map(\.fileName))
        XCTAssertEqual(fresh.id, backedUp.id)
    }
}
