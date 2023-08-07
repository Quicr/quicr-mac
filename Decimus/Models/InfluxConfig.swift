import Foundation

struct InfluxConfig: Codable {

    init() {
        submit = false
        url = "http://metrics.m10x.ctgpoc.com:8086"
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
