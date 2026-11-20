import Foundation
@main struct Test {
    static func main() throws {
        do {
            _ = try DeviceRenewalTransport(endpoint: URL(string: "http://127.0.0.1:4321/v1/devices/renew")!, allowLoopback: true)
            fatalError("Release accepted a local HTTP service")
        } catch DeviceRenewalTransport.Failure.endpoint {}
        _ = try DeviceRenewalTransport(endpoint: URL(string: "https://service.example.org/v1/devices/renew")!)
        print("PASS Release refuses loopback HTTP")
    }
}
