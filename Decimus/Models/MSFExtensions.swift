// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import MSF

extension MSF.Track {
    /// Build a quality profile string matching the format parsed by `CodecFactoryImpl.makeCodecConfig`.
    /// e.g. "h264,width=1920,height=1080,fps=30,br=4000" or "opus,br=24"
    var qualityProfile: String {
        var codec = self.codec
        if codec == "avc1" {
            codec = "h264"
        }
        var parts = [codec ?? "unknown"]
        if let width { parts.append("width=\(width)") }
        if let height { parts.append("height=\(height)") }
        if let framerate { parts.append("fps=\(Int(framerate))") }
        if let bitrate { parts.append("br=\(bitrate / 1000)") }
        return parts.joined(separator: ",")
    }

    /// Convert this track to a manifest `Profile`, using the given namespace and name.
    func toProfile(namespace: [String]) -> Profile {
        .init(qualityProfile: self.qualityProfile,
              expiry: [5000, 5000],
              priorities: [0, 1],
              namespace: namespace,
              name: self.name)
    }
}

extension [MSF.Track] {
    /// Find the catalog track matching an incoming publish by track name.
    func findMatch(name: String) -> MSF.Track? {
        first { $0.name == name }
    }
}

extension MSF.Catalog {
    /// Convert this catalog into `ManifestPublication`s, grouped by namespace prefix.
    /// The `localParticipantId` is appended as the last namespace tuple for publications.
    func toPublications(localParticipantId: String) -> [ManifestPublication] {
        // Group tracks by their namespace prefix (without participant ID).
        var publications: [String: ManifestPublication] = [:]
        var profiles: [String: [Profile]] = [:]

        for track in tracks {
            guard let namespace = track.namespace else { continue }
            var tuples = namespace.tuples
            // Pop remote participant, replace with local.
            _ = tuples.popLast()
            tuples.append(localParticipantId)

            let key = tuples.joined()
            let mediaType = track.name

            if publications[key] == nil {
                publications[key] = .init(mediaType: mediaType,
                                          sourceName: key,
                                          sourceID: key,
                                          label: key,
                                          profileSet: .init(type: mediaType, profiles: []))
                profiles[key] = []
            }
            profiles[key]?.append(track.toProfile(namespace: tuples))
        }

        return publications.map { key, pub in
            .init(mediaType: pub.mediaType,
                  sourceName: pub.sourceName,
                  sourceID: pub.sourceID,
                  label: pub.label,
                  profileSet: .init(type: pub.mediaType,
                                    profiles: profiles[key] ?? []))
        }
    }
}
