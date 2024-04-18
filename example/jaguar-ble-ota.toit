import ble show *
import log
import system.firmware as firmware
import system.firmware show FirmwareMapping

logger ::= log.Logger log.DEBUG_LEVEL log.DefaultTarget --name="ble"

service/LocalService? := ?
peripheral/Peripheral? := ?

TOIT-BLE-FIRMWARE-SERVICE-UUID ::= BleUuid "7017"
COMMAND-CHARAC-UUID     ::= BleUuid "7018" 
FIRMWARE-CHARAC-UUID    ::= BleUuid "7019"
CRC32-CHARAC-UUID       ::= BleUuid "701A" 
FILELENGTH-CHARAC-UUID  ::= BleUuid "701B"
PACKET-COUNT-CHARAC-UUID  ::= BleUuid "701D"

PAKET-SIZE := 500

main:
  adapter := Adapter
  adapter.set-preferred-mtu PAKET-SIZE
  central := adapter.central

  address := find-with-service central TOIT-BLE-FIRMWARE-SERVICE-UUID 3
  remote_device := central.connect address
  services := remote_device.discover_services [TOIT-BLE-FIRMWARE-SERVICE-UUID]
  master_ble/RemoteService := services.first

  file-length-charac/RemoteCharacteristic? := null
  crc32-charac/RemoteCharacteristic? := null
  firmware-charac/RemoteCharacteristic? := null
  command-charac/RemoteCharacteristic? := null
  packet-count-charac/RemoteCharacteristic? := null

  characteristics := master_ble.discover_characteristics []
  characteristics.do: | characteristic/RemoteCharacteristic |
    if characteristic.uuid == FILELENGTH-CHARAC-UUID:
      file-length-charac = characteristic
    else if characteristic.uuid == CRC32-CHARAC-UUID:
      crc32-charac = characteristic
    else if characteristic.uuid == FIRMWARE-CHARAC-UUID:
      firmware-charac = characteristic
    else if characteristic.uuid == COMMAND-CHARAC-UUID:
      command-charac = characteristic
    else if characteristic.uuid == PACKET-COUNT-CHARAC-UUID:
      packet-count-charac = characteristic

  firmware.map:  | firmware-mapping/FirmwareMapping |
    firmware-length := firmware-mapping.size
    packet-count := firmware-length / PAKET-SIZE
    logger.debug "write Firmwarelength: $firmware-length bytes ($packet-count packets)"
    file-length-charac.write "$firmware-length".to-byte-array
    logger.debug "Write crc32"
    crc32-charac.write #[0x01, 0x00, 0x00]
    // crc32-charac.write "1".to-byte-array
    packet-count-charac.subscribe
    logger.debug "Write command"
    command-charac.write "1".to-byte-array
    logger.debug "Write firmware"

    chunk := ByteArray PAKET-SIZE
    done := false
    send-packets := 0
    packet/int := 0
    while true:
      packet = int.parse (packet-count-charac.wait-for-notification).to-string
      logger.debug "Received packet request: $packet"
      if packet > packet-count:
        firmware-charac.write #[]
      from := packet * PAKET-SIZE
      done = false
      while not done:
        exception := catch:
          to := min (from + PAKET-SIZE) firmware-length
          firmware-mapping.copy from to --into=chunk
          logger.debug "Writing chunk from $from to $to size $chunk.size ($send-packets)"
          firmware-charac.write chunk
          send-packets++
          done = true
        if exception:
          logger.error "Error occured while writing firmware chunk: $exception"
    
    logger.debug "Firmware written"

find-with-service central/Central service/BleUuid duration/int=3:
  central.scan --duration=(Duration --s=duration): | device/RemoteScannedDevice |
    if device.data.service_classes.contains service:
        logger.debug "Found device with service $service: $device"
        return device.address
  throw "no device found"