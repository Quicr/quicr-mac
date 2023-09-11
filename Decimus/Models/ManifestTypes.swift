import Foundation

struct Manifest: Codable {
    let clientID: String
    let subscriptions: [ManifestSubscription]
    let publications: [ManifestPublication]
    let urlTemplates: [String]

    enum CodingKeys: String, CodingKey {
        case clientID = "clientId"
        case subscriptions, publications, urlTemplates
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
    let expiry: Int?
    let priorities: [Int]?
    let namespaceURL: String

    enum CodingKeys: String, CodingKey {
        case qualityProfile, expiry, priorities
        case namespaceURL = "quicrNamespaceUrl"
    }

    init(from decoder: Swift.Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        qualityProfile = try values.decode(String.self, forKey: .qualityProfile)
        expiry = try values.decodeIfPresent(Int.self, forKey: .expiry)
        priorities = try values.decodeIfPresent([Int].self, forKey: .priorities)
        namespaceURL = try values.decode(String.self, forKey: .namespaceURL)
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
