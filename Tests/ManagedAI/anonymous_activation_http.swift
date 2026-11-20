import Foundation
final class MemoryAnonymousStore: DeviceRenewalStore {
 var state: DeviceRenewalState?
 func load() throws -> DeviceRenewalState? { state }
 func save(_ state: DeviceRenewalState) throws { self.state = state }
}
@main struct Test {
 static func main() async throws {
  let store=MemoryAnonymousStore()
  let transport=try DeviceRenewalTransport(endpoint:URL(string:CommandLine.arguments[1])!,allowLoopback:true)
  let first=DeviceRenewalCoordinator(store:store)
  do { try await first.activateAnonymous(using:transport); fatalError("expected disconnected response") } catch {}
  guard let pending=store.state, pending.pendingAnonymous == true else { fatalError("identity not persisted") }
  let resumed=DeviceRenewalCoordinator(store:store)
  let lease=try await resumed.acquire(endpoint:transport.endpoint,allowLoopbackForTesting:true,autoActivateAnonymous:true)
  guard let committed=store.state, committed.pendingAnonymous == nil, committed.device == pending.device, committed.access == pending.access else { fatalError("identity changed") }
  guard lease.token == committed.access else { fatalError("lease used wrong identity") }
  await resumed.release(lease)
  let next=try await resumed.acquire(endpoint:transport.endpoint,allowLoopbackForTesting:true,autoActivateAnonymous:true)
  await resumed.release(next)
  print("PASS anonymous response loss and restart")
 }
}
