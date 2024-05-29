import CoreMedia

protocol VideoUtilities {
    func depacketize(_ data: Data,
                     format: inout CMFormatDescription?,
                     copy: Bool,
                     seiCallback: (Data) -> Void) throws -> [CMBlockBuffer]?
}
