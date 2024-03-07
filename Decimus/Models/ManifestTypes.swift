import Foundation

struct Manifest: Codable {
    let clientID: String
    let subscriptions: [ManifestSubscription]
    let publications: [ManifestPublication]

    enum CodingKeys: String, CodingKey {
        case clientID = "clientId"
        case subscriptions, publications
    }
}

struct ManifestPublication: Codable {
    let mediaType, sourceName, sourceID, label: String
    let profileSet: ProfileSet

    enum CodingKeys: String, CodingKey {
        case mediaType, sourceName
        case sourceID = "sourceId"
        case label, profileSet
    }
}

struct ManifestSubscription: Codable {
    let mediaType, sourceName, sourceID, label: String
    let profileSet: ProfileSet

    enum CodingKeys: String, CodingKey {
        case mediaType, sourceName
        case sourceID = "sourceId"
        case label, profileSet
    }
}

struct ProfileSet: Codable {
    let type: String
    let profiles: [Profile]
}

struct Profile: Codable {
    let qualityProfile: String
    let expiry: [Int]?
    let priorities: [Int]?
    let namespace: String

    enum CodingKeys: String, CodingKey {
        case qualityProfile, expiry, priorities
        case namespace = "quicrNamespace"
    }

    init(from decoder: Swift.Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        qualityProfile = try values.decode(String.self, forKey: .qualityProfile)
        expiry = try values.decodeIfPresent([Int].self, forKey: .expiry)
        priorities = try values.decodeIfPresent([Int].self, forKey: .priorities)
        namespace = try values.decode(String.self, forKey: .namespace)
    }
}

struct Conference: Codable {
    let id: UInt32
    let title, starttime: String
    let duration: Int
    let state, type: String
    let meetingurl: String
    let clientindex: Int
    let participants, invitees: [String]
}

struct Config: Codable {
    let id: UInt32
    let configProfile: String
}

struct User: Codable {
    let id, name, email: String
    let clients: [Client]
}

struct Client: Codable {
    let id, label: String
    let sendCaps: [SendCapability]
    let recvCaps: [ReceiveCapability]
}

struct ReceiveCapability: Codable {
    let mediaType, qualityProfie: String // TODO: Fix this in manifest to be "qualityProfile"
    let numStreams: Int
}

struct SendCapability: Codable {
    let mediaType, sourceID, sourceName, label: String
    let profileSet: ProfileSet

    enum CodingKeys: String, CodingKey {
        case mediaType
        case sourceID = "sourceId"
        case sourceName, label, profileSet
    }
}
