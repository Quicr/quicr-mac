

//enum Status {
//    case ready
//    case notReady
//    case internalError
//    case invalidParams
//    case clientConnecting
//    case disconnecting
//    case clientNotConnected
//    case clientFailedToConnect
//}
//
//struct ClientConfig {
//    let endpointId: String
//    let config: TransportConfig
//    let metricsSampleMs: UInt64
//    let connectUri: String
//}
//struct ServerSetupAttributes {}
//struct TrackNamespace {}
//enum PublishAnnounceStatus { case ok }
//struct FullTrackName: Hashable {
//    let namespace: Data
//    let name: Data
//}
//struct SubscribeAttributes {}
//struct ConnectionMetrics {}
//
//protocol QClientCallbacks {
//    func statusChanged(_ status: Status)
//    func serverSetupReceived(_ setup: ServerSetupAttributes)
//    func announceStatusChanged(namespace: TrackNamespace, status: PublishAnnounceStatus)
//    func unpublishedSubscribeReceived(name: FullTrackName, attributes: SubscribeAttributes)
//    func registerMetricsSampled(metrics: ConnectionMetrics)
//}
//
//class QClient {
//    init(config: ClientConfig) {}
//
//    func setCallbacks(callback: QClientCallbacks) {}
//
//    func connect() -> Status {
//        return .clientConnecting
//    }
//
//    func disconnect() -> Status {
//        return .disconnecting
//    }
//
//    func getAnnounceStatus(namespace: TrackNamespace) -> PublishAnnounceStatus {
//        return .ok
//    }
//
//    func publishTrack(handler: PublishTrackHandler) {
//
//    }
//
//    func unpublishTrack(handler: PublishTrackHandler) {
//
//    }
//}
