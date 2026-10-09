import Foundation

// Package the standard PNG representations into an ICNS container.
// No image re-encoding or external dependencies are needed here.
func length(_ value: Int) -> Data {
    var value = UInt32(value).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("Usage: build-icon <iconset> <output.icns>") }
let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
let entries: [(String, String, Int)] = [
    ("icp4", "icon_16x16.png", 16), ("ic11", "icon_16x16@2x.png", 32),
    ("icp5", "icon_32x32.png", 32), ("ic12", "icon_32x32@2x.png", 64),
    ("ic07", "icon_128x128.png", 128), ("ic13", "icon_128x128@2x.png", 256),
    ("ic08", "icon_256x256.png", 256), ("ic14", "icon_256x256@2x.png", 512),
    ("ic09", "icon_512x512.png", 512), ("ic10", "icon_512x512@2x.png", 1024)
]
var contents = Data()
for (type, filename, size) in entries {
    let png = try Data(contentsOf: root.appendingPathComponent(filename))
    guard png.count > 24, Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10] else { fatalError("Invalid PNG: \(filename)") }
    let width = png[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    let height = png[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard width == size && height == size else { fatalError("Unexpected icon dimensions: \(filename)") }
    contents.append(Data(type.utf8)); contents.append(length(png.count + 8)); contents.append(png)
}
var file = Data("icns".utf8)
file.append(length(contents.count + 8)); file.append(contents)
try file.write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
