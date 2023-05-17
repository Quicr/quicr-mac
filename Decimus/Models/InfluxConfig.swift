import Foundation

struct InfluxConfig: Codable {

    init() {
        submit = false
        url = "http://relay.us-west-2.quicr.ctgpoc.com:8086"
        username = "admin"
        password = "ctoMedia10x"
        bucket = "Media10x"
        org = "Cisco"
        token = "cisco-cto-media10x"
        intervalSecs = 5
    }

    var submit: Bool
    var url: String
    var username: String
    var password: String
    var bucket: String
    var org: String
    var token: String
    var intervalSecs: Int
}
