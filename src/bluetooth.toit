import log
import ble show BleUuid LocalCharacteristic Adapter AdvertisementData LocalService Peripheral
import ble show BLE_CONNECT_MODE_UNDIRECTIONAL
import monitor show Channel
import reader

import .jaguar

DEVICE-SERVICE-UUID     ::= BleUuid "7017" //Custom Base UUID Toit
COMMAND-CHARAC-UUID     ::= BleUuid "7018" 
FIRMWARE-CHARAC-UUID    ::= BleUuid "7019"
CRC32-CHARAC-UUID       ::= BleUuid "701A" 
FILELENGTH-CHARAC-UUID  ::= BleUuid "701B"
STATE-CHARAC-UUID       ::= BleUuid "701C"

class EndpointBle implements Endpoint:
  logger/log.Logger

  peripheral/Peripheral? := null
  command-charac/LocalCharacteristic? := null
  firmware-charac/LocalCharacteristic? := null
  crc32-charac/LocalCharacteristic? := null
  file-length-charac/LocalCharacteristic? := null
  state-charac/LocalCharacteristic? := null

  state-channel/Channel := ?
  process-channel/Channel := ?

  crc32 := null
  file-length/int := 0

  constructor --logger/log.Logger:
    this.logger = logger.with-name "ble"
    state-channel = Channel 1
    process-channel = Channel 1

  run device/Device:
    try:
      run-ble-service device.name
      logger.info "running Jaguar device '$device.name' (id: '$device.id') on Bluetooth"
      validate-firmware --reason="bluetooth service started"

      logger.info "Waiting for Bluetooth inputs"

      Task.group --required=1 [
        :: crc32-task,
        :: file-length-task,
        :: command-receiver-task,
        :: state-task,
        :: ble-handler-task
      ]
    finally:
      peripheral.stop-advertise

  ble-handler-task:
    while true:
      payload/Payload := process-channel.receive
      logger.info "Received payload: $payload.to-string"
      if payload.type == Payload.TYPE-COMMAND:
        command := int.parse payload.data.to-string
        if command == 1:
          if not crc32:
            set-state "CRC32 missing"
            continue
          else if file-length == 0:
            set-state "File length missing"
            continue
          set-state "Downloading"
          install-firmware file-length (BleReader firmware-charac file-length)
          firmware-is-upgrade-pending = true
          set-state "Done"
      else if payload.type == Payload.TYPE-CRC32:
        crc32 = payload.data
        logger.info "Received CRC32"
      else if payload.type == Payload.TYPE-FILE-LENGTH:
        file-length = int.parse payload.data.to-string
        logger.info "Received File Length: $file-length"

  run-ble-service device-name:
    adapter := Adapter 
    adapter.set_preferred_mtu 128
    peripheral = adapter.peripheral
    service := peripheral.add_service DEVICE_SERVICE_UUID

    firmware-charac = service.add-write-only-characteristic FIRMWARE-CHARAC-UUID
    command-charac = service.add-write-only-characteristic COMMAND-CHARAC-UUID
    crc32-charac = service.add-write-only-characteristic CRC32-CHARAC-UUID
    file-length-charac = service.add-write-only-characteristic FILELENGTH-CHARAC-UUID
    state-charac = service.add-notification-characteristic STATE-CHARAC-UUID

    service.deploy
    peripheral.start-advertise --connection_mode=BLE_CONNECT_MODE_UNDIRECTIONAL
      AdvertisementData
        --name=device-name
        --check_size=false 
        --connectable=true
        --service_classes=[DEVICE_SERVICE_UUID]

    logger.info "Jaguar BLE running as $device-name"
    set-state "Ready"

  state-task:
    while true:
      state := state-channel.receive
      this.logger.info "State: $state"
      state-charac.write state

  command-receiver-task:
    while true:
      payload := Payload Payload.TYPE-COMMAND command-charac.read
      process-channel.send payload

  file-length-task:
    while true:
      payload := Payload Payload.TYPE-FILE-LENGTH file-length-charac.read
      process-channel.send payload

  crc32-task:
    while true:
      payload := Payload Payload.TYPE-CRC32 crc32-charac.read
      process-channel.send payload

  set-state state/string:
    state-channel.send state.to-byte-array

  name -> string:
    return "BLE"

class BleReader implements reader.Reader:

  firmware-charac/LocalCharacteristic := ?
  file-length/int := ?
  received-data-length := 0

  constructor .firmware-charac/LocalCharacteristic .file-length/int:

  read:
    if received-data-length == file-length:
      return false
    paket := firmware-charac.read //blocking wait for byte paket
    received-data-length += paket.size
    return paket


class Payload:
  static TYPE-COMMAND ::= 0
  static TYPE-CRC32 ::= 1
  static TYPE-FILE-LENGTH ::= 2

  type/int
  data/ByteArray

  constructor .type/int .data/any:

  to-string:
    return "Type: $type, Data: $data"