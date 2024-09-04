// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

struct InfluxConfig: Codable {
    var submit: Bool  = false
    var granular: Bool = false
    var realtime: Bool = false
    var url: String = "http://metrics.m10x.ctgpoc.com:8086"
    var username: String = "admin"
    var password: String = "ctoMedia10x"
    var bucket: String = "Media10x"
    var org: String = "Cisco"
    var token: String = "cisco-cto-media10x"
    var intervalSecs: Int = 5
}
