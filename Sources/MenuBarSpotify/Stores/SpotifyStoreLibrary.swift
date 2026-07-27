import Foundation

extension SpotifyStore {
    func search() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            await loadRecentTracks()
            return
        }

        searchRequestID += 1
        let requestID = searchRequestID
        await runBusy {
            if let cached = cache.searchResults(for: query) {
                guard requestID == searchRequestID,
                      query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return
                }
                searchResults = cached
            } else {
                let results = try await self.apiClient.searchTracks(query: query)
                cache.storeSearchResults(results, for: query)
                guard requestID == searchRequestID,
                      query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return
                }
                searchResults = results
            }
            errorMessage = ""
        }
    }

    func clearSearch() async {
        searchRequestID += 1
        searchQuery = ""
        searchResults = []
        await loadRecentTracks()
    }

    func loadRecentTracks() async {
        await runBusy("load recent tracks") {
            if let cached = cache.recentTracks() {
                recentTracks = cached.deduplicatedByTrackID()
            } else {
                recentTracks = try await self.apiClient.recentlyPlayedTracks()
                cache.storeRecentTracks(recentTracks)
            }
            AppLog.event("recent tracks loaded", metadata: ["count": recentTracks.count])
        }
    }

    func loadPlaylists() async {
        isLoadingPlaylists = playlists.isEmpty
        defer { isLoadingPlaylists = false }

        await runBusy("load playlists") {
            let likedSongs = await self.likedSongsPlaylist()

            if let cached = cache.playlists() {
                playlists = [likedSongs] + cached
            } else {
                let spotifyPlaylists = try await self.apiClient.playlists()
                playlists = [likedSongs] + spotifyPlaylists
                cache.storePlaylists(spotifyPlaylists)
            }
            AppLog.event("playlists loaded", metadata: ["count": playlists.count])
        }
    }

    func openPlaylist(_ playlist: SpotifyPlaylist) async {
        playlistOpenRequestID += 1
        playlistPageRequestID += 1
        let requestID = playlistOpenRequestID
        selectedPlaylist = playlist
        playlistTracksNextPath = nil
        playlistTracksHasMore = false
        isLoadingPlaylistTracks = true

        if let cached = cache.playlistTracks(for: playlist.id) {
            guard requestID == playlistOpenRequestID,
                  selectedPlaylist?.id == playlist.id else {
                return
            }
            playlistTracks = cached
            isLoadingPlaylistTracks = false
            return
        }

        await runBusy {
            let page = try await self.tracksPage(for: playlist)
            guard requestID == playlistOpenRequestID,
                  selectedPlaylist?.id == playlist.id else {
                return
            }
            playlistTracks = page.tracks
            playlistTracksNextPath = page.nextPath
            playlistTracksHasMore = page.nextPath != nil
            if page.nextPath == nil {
                cache.storePlaylistTracks(playlistTracks, for: playlist.id)
            }
        }
        if requestID == playlistOpenRequestID {
            isLoadingPlaylistTracks = false
        }
    }

    func closePlaylist() {
        playlistOpenRequestID += 1
        playlistPageRequestID += 1
        selectedPlaylist = nil
        playlistTracks = []
        playlistTracksNextPath = nil
        playlistTracksHasMore = false
        isLoadingPlaylistTracks = false
    }

    func deleteSelectedPlaylist() async {
        guard let playlist = selectedPlaylist else {
            return
        }
        guard !playlist.isLikedSongs else {
            closePlaylist()
            return
        }

        playlists.removeAll { $0.id == playlist.id }
        closePlaylist()
        cache.removePlaylist(id: playlist.id)

        await runBusy {
            try await self.apiClient.deletePlaylist(id: playlist.id)
            self.errorMessage = ""
        }
    }

    func loadMorePlaylistTracks() async {
        guard let playlist = selectedPlaylist,
              let nextPath = playlistTracksNextPath,
              !isLoadingMorePlaylistTracks else {
            return
        }

        playlistPageRequestID += 1
        let requestID = playlistPageRequestID
        isLoadingMorePlaylistTracks = true
        defer { isLoadingMorePlaylistTracks = false }

        do {
            let page = try await self.tracksPage(for: playlist, startingAt: nextPath)
            guard requestID == playlistPageRequestID,
                  selectedPlaylist?.id == playlist.id,
                  playlistTracksNextPath == nextPath else {
                return
            }
            playlistTracks.append(contentsOf: page.tracks)
            playlistTracksNextPath = page.nextPath
            playlistTracksHasMore = page.nextPath != nil
            if page.nextPath == nil {
                cache.storePlaylistTracks(playlistTracks, for: playlist.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }


    private func tracksPage(for playlist: SpotifyPlaylist, startingAt path: String? = nil) async throws -> PlaylistTracksPage {
        if playlist.isLikedSongs {
            return try await apiClient.savedTracksPage(startingAt: path)
        }
        return try await apiClient.playlistTracksPage(playlistID: playlist.id, startingAt: path)
    }

    private func likedSongsPlaylist() async -> SpotifyPlaylist {
        do {
            let summary = try await apiClient.savedTracksSummary()
            return SpotifyPlaylist.likedSongs(total: summary.total)
        } catch {
            AppLog.error("liked songs summary failed", error)
            return SpotifyPlaylist.likedSongs(total: 0)
        }
    }

}
