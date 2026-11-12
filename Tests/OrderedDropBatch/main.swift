import Foundation
final class Box: @unchecked Sendable { let lock = NSLock(); var urls:[URL]=[]; var failed=0; var calls=0 }
let box = Box(), done = DispatchSemaphore(value:0)
let first=URL(fileURLWithPath:"/tmp/first"), second=URL(fileURLWithPath:"/tmp/second"), third=URL(fileURLWithPath:"/tmp/third")
let batch=OrderedDropBatch(count:3,timeout:1) { urls,failed in box.lock.lock();box.urls=urls;box.failed=failed;box.calls += 1;box.lock.unlock();done.signal() }
batch.submit(third,at:2);batch.submit(first,at:0);batch.submit(nil,at:0);batch.submit(second,at:1)
precondition(done.wait(timeout:.now()+1) == .success); precondition(box.urls == [first,second,third] && box.failed == 0 && box.calls == 1)
let timeoutDone=DispatchSemaphore(value:0), timeoutBox=Box()
let timeout=OrderedDropBatch(count:3,timeout:0.05) { urls,failed in timeoutBox.lock.lock();timeoutBox.urls=urls;timeoutBox.failed=failed;timeoutBox.calls += 1;timeoutBox.lock.unlock();timeoutDone.signal() }
timeout.submit(second,at:1)
precondition(timeoutDone.wait(timeout:.now()+1) == .success)
timeout.submit(first,at:0);precondition(timeoutBox.urls == [second] && timeoutBox.failed == 2 && timeoutBox.calls == 1)
print("PASS: ordered batches handle asynchronous results, failures, timeout and late callbacks")
