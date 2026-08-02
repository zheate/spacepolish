import Darwin
import Foundation

package final class SingleInstanceLock {
    private var descriptor: Int32
    let fileURL: URL

    private init(descriptor: Int32, fileURL: URL) {
        self.descriptor = descriptor
        self.fileURL = fileURL
    }

    package static func acquire(
        fileURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.spacepolish.mac.instance.lock")
    ) -> SingleInstanceLock? {
        let descriptor = open(
            fileURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return SingleInstanceLock(descriptor: descriptor, fileURL: fileURL)
    }

    package func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}
