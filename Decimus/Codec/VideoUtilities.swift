// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import CoreMedia

protocol VideoUtilities {
    func depacketize(_ data: Data,
                     format: inout CMFormatDescription?,
                     copy: Bool,
                     seiCallback: (Data) -> Void) throws -> [CMBlockBuffer]?
}
