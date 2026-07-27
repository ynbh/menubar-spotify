import Foundation

extension SpotifyStore {
    func toggleLyrics() {
        isLyricsPresented.toggle()
        if isLyricsPresented {
            Task { await loadLyricsForCurrentTrack() }
        }
    }

    func loadLyricsForCurrentTrack() async {
        guard let track = playback?.item else {
            lyrics = nil
            lyricsStatus = "No song playing."
            return
        }

        if lyrics?.trackID == track.id || pendingLyricsTrackID == track.id {
            return
        }

        lyricsRequestID += 1
        let requestID = lyricsRequestID
        await runBusy {
            pendingLyricsTrackID = track.id
            defer {
                if pendingLyricsTrackID == track.id {
                    pendingLyricsTrackID = nil
                }
            }
            lyricsStatus = "Loading lyrics..."
            if let cached = cache.lyrics(for: track.id) {
                guard requestID == lyricsRequestID else { return }
                applyLyrics(cached, for: track.id)
            } else {
                let fetchedLyrics = try await lyricsProvider.lyrics(for: track)
                cache.storeLyrics(fetchedLyrics, for: track.id)
                guard requestID == lyricsRequestID else { return }
                applyLyrics(fetchedLyrics, for: track.id)
            }
            if lyrics?.trackID == track.id {
                lyricsStatus = lyrics?.isEmpty == true ? "Lyrics unavailable for this song." : ""
            }
        }
    }


    func prefetchLyrics(for track: SpotifyTrack) {
        guard cache.lyrics(for: track.id) == nil else {
            return
        }

        Task {
            do {
                let fetchedLyrics = try await lyricsProvider.lyrics(for: track)
                cache.storeLyrics(fetchedLyrics, for: track.id)
                if isLyricsPresented {
                    applyLyrics(fetchedLyrics, for: track.id)
                }
            } catch {
                if isLyricsPresented, playback?.item?.id == track.id {
                    lyricsStatus = error.localizedDescription
                }
            }
        }
    }

    private func applyLyrics(_ result: LyricsResult, for trackID: String) {
        guard playback?.item?.id == trackID else {
            return
        }
        lyrics = result
    }

}
