import CoreBluetooth
import Foundation

// === Match your ESP32 sketch ===
let SERVICE_UUID = CBUUID(string: "12345678-1234-1234-1234-1234567890ab")
let CHARACTERISTIC_UUID = CBUUID(string: "abcdefab-1234-1234-1234-abcdefabcdef")

final class BLEFloatSender: NSObject {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var floatChar: CBCharacteristic?

    override init() {
        super.init()
        self.central = CBCentralManager(delegate: self, queue: nil)
    }

    private func start() {
        // If you want to target by name: use scan with no filter and check in didDiscover
        central.scanForPeripherals(withServices: [SERVICE_UUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        print("Finding ESP32")
    }

    func send(f0: Float, f1: Float) {
        guard let p = peripheral, let ch = floatChar else {
            print("Not connected")
            return
        }
        var arr: [Float] = [f0, f1]  // little-endian on iOS/ESP32
        let data = Data(bytes: &arr, count: MemoryLayout<Float>.size * arr.count)
        p.writeValue(data, for: ch, type: .withResponse)
    }
}

extension BLEFloatSender: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            start()
        default:
            print("Bluetooth not ready")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        // Optional: filter by name
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        print("Discovered: \(name)")
        // Connect to the first device advertising our service
        self.peripheral = peripheral
        self.peripheral?.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected, discovering services")
        peripheral.discoverServices([SERVICE_UUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Failed to connect: \(error?.localizedDescription ?? "unknown")")
        // You could restart scanning here if you want.
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("Disconnected: \(error?.localizedDescription ?? "no error")")
        // Optionally auto-reconnect:
        self.peripheral = nil
        self.floatChar = nil
        start()
    }
}

extension BLEFloatSender: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { print("Service discovery error: \(error)"); return }
        guard let services = peripheral.services else { return }
        for s in services where s.uuid == SERVICE_UUID {
            print("Service found. Discovering characteristic…")
            peripheral.discoverCharacteristics([CHARACTERISTIC_UUID], for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error = error { print("Char discovery error: \(error)"); return }
        guard let chars = service.characteristics else { return }
        for c in chars where c.uuid == CHARACTERISTIC_UUID {
            self.floatChar = c
            print("Float characteristic ready.")
            // (Optional) Do an immediate test write:
            // send(f0: 1.23, f1: 4.56, f2: 7.89)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            print("Write failed: \(error.localizedDescription)")
        } else {
            print("Write OK")
        }
    }
}
