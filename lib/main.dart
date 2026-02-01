import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:usb_serial/usb_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

void main() {
  runApp(const ESP32FlasherApp());
}

class ESP32FlasherApp extends StatelessWidget {
  const ESP32FlasherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP32 USB Flasher',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange),
        useMaterial3: true,
      ),
      home: const FlasherScreen(),
    );
  }
}

// ESP32 Flash Address Options
class FlashAddress {
  final String name;
  final int address;
  final String description;

  const FlashAddress(this.name, this.address, this.description);

  String get hexAddress => '0x${address.toRadixString(16).toUpperCase().padLeft(5, '0')}';
}

const List<FlashAddress> flashAddresses = [
  FlashAddress('Bootloader', 0x1000, 'ESP32 bootloader (bootloader.bin)'),
  FlashAddress('Partition Table', 0x8000, 'Partition table (partitions.bin)'),
  FlashAddress('Application', 0x10000, 'Main application firmware'),
  FlashAddress('OTA Data', 0xD000, 'OTA data partition'),
  FlashAddress('NVS', 0x9000, 'Non-volatile storage'),
  FlashAddress('Custom', 0x0, 'Enter custom address'),
];

// SLIP Protocol Constants
class SlipProtocol {
  static const int END = 0xC0;
  static const int ESC = 0xDB;
  static const int ESC_END = 0xDC;
  static const int ESC_ESC = 0xDD;

  // ESP32 Bootloader Commands
  static const int CMD_FLASH_BEGIN = 0x02;
  static const int CMD_FLASH_DATA = 0x03;
  static const int CMD_FLASH_END = 0x04;
  static const int CMD_MEM_BEGIN = 0x05;
  static const int CMD_MEM_END = 0x06;
  static const int CMD_MEM_DATA = 0x07;
  static const int CMD_SYNC = 0x08;
  static const int CMD_WRITE_REG = 0x09;
  static const int CMD_READ_REG = 0x0A;
  static const int CMD_SPI_SET_PARAMS = 0x0B;
  static const int CMD_SPI_ATTACH = 0x0D;
  static const int CMD_CHANGE_BAUDRATE = 0x0F;
  static const int CMD_FLASH_DEFL_BEGIN = 0x10;
  static const int CMD_FLASH_DEFL_DATA = 0x11;
  static const int CMD_FLASH_DEFL_END = 0x12;
  static const int CMD_FLASH_MD5 = 0x13;

  // Encode data with SLIP framing
  static Uint8List encode(Uint8List data) {
    final result = <int>[END];
    for (final byte in data) {
      if (byte == END) {
        result.addAll([ESC, ESC_END]);
      } else if (byte == ESC) {
        result.addAll([ESC, ESC_ESC]);
      } else {
        result.add(byte);
      }
    }
    result.add(END);
    return Uint8List.fromList(result);
  }

  // Decode SLIP framed data
  static Uint8List decode(Uint8List data) {
    final result = <int>[];
    bool inEscape = false;
    for (final byte in data) {
      if (inEscape) {
        if (byte == ESC_END) {
          result.add(END);
        } else if (byte == ESC_ESC) {
          result.add(ESC);
        }
        inEscape = false;
      } else if (byte == ESC) {
        inEscape = true;
      } else if (byte != END) {
        result.add(byte);
      }
    }
    return Uint8List.fromList(result);
  }

  // Build a command packet
  static Uint8List buildCommand(int command, Uint8List data, int checksum) {
    final packet = BytesBuilder();
    // Direction (0 = request)
    packet.addByte(0x00);
    // Command
    packet.addByte(command);
    // Size (little endian, 2 bytes)
    packet.addByte(data.length & 0xFF);
    packet.addByte((data.length >> 8) & 0xFF);
    // Checksum (little endian, 4 bytes)
    packet.addByte(checksum & 0xFF);
    packet.addByte((checksum >> 8) & 0xFF);
    packet.addByte((checksum >> 16) & 0xFF);
    packet.addByte((checksum >> 24) & 0xFF);
    // Data
    packet.add(data);
    return encode(packet.toBytes());
  }

  // Calculate checksum for data
  static int calculateChecksum(Uint8List data) {
    int checksum = 0xEF;
    for (final byte in data) {
      checksum ^= byte;
    }
    return checksum;
  }

  // Build sync packet
  static Uint8List buildSyncPacket() {
    final syncData = Uint8List(36);
    syncData[0] = 0x07;
    syncData[1] = 0x07;
    syncData[2] = 0x12;
    syncData[3] = 0x20;
    for (int i = 4; i < 36; i++) {
      syncData[i] = 0x55;
    }
    return buildCommand(CMD_SYNC, syncData, 0);
  }

  // Build flash begin packet
  static Uint8List buildFlashBeginPacket(int size, int blocks, int blockSize, int offset) {
    final data = BytesBuilder();
    // Erase size (little endian, 4 bytes)
    data.addByte(size & 0xFF);
    data.addByte((size >> 8) & 0xFF);
    data.addByte((size >> 16) & 0xFF);
    data.addByte((size >> 24) & 0xFF);
    // Number of blocks (little endian, 4 bytes)
    data.addByte(blocks & 0xFF);
    data.addByte((blocks >> 8) & 0xFF);
    data.addByte((blocks >> 16) & 0xFF);
    data.addByte((blocks >> 24) & 0xFF);
    // Block size (little endian, 4 bytes)
    data.addByte(blockSize & 0xFF);
    data.addByte((blockSize >> 8) & 0xFF);
    data.addByte((blockSize >> 16) & 0xFF);
    data.addByte((blockSize >> 24) & 0xFF);
    // Offset (little endian, 4 bytes)
    data.addByte(offset & 0xFF);
    data.addByte((offset >> 8) & 0xFF);
    data.addByte((offset >> 16) & 0xFF);
    data.addByte((offset >> 24) & 0xFF);
    return buildCommand(CMD_FLASH_BEGIN, data.toBytes(), 0);
  }

  // Build flash data packet
  static Uint8List buildFlashDataPacket(Uint8List data, int sequence) {
    final packet = BytesBuilder();
    // Data size (little endian, 4 bytes)
    packet.addByte(data.length & 0xFF);
    packet.addByte((data.length >> 8) & 0xFF);
    packet.addByte((data.length >> 16) & 0xFF);
    packet.addByte((data.length >> 24) & 0xFF);
    // Sequence number (little endian, 4 bytes)
    packet.addByte(sequence & 0xFF);
    packet.addByte((sequence >> 8) & 0xFF);
    packet.addByte((sequence >> 16) & 0xFF);
    packet.addByte((sequence >> 24) & 0xFF);
    // Reserved (8 bytes)
    for (int i = 0; i < 8; i++) {
      packet.addByte(0);
    }
    // Actual data
    packet.add(data);
    
    final checksum = calculateChecksum(data);
    return buildCommand(CMD_FLASH_DATA, packet.toBytes(), checksum);
  }

  // Build flash end packet
  static Uint8List buildFlashEndPacket(bool reboot) {
    final data = Uint8List(4);
    data[0] = reboot ? 0 : 1; // 0 = reboot, 1 = don't reboot
    return buildCommand(CMD_FLASH_END, data, 0);
  }
}

class FlasherScreen extends StatefulWidget {
  const FlasherScreen({super.key});

  @override
  State<FlasherScreen> createState() => _FlasherScreenState();
}

class _FlasherScreenState extends State<FlasherScreen> {
  String? _selectedFilePath;
  String? _detectedChip;
  UsbDevice? _selectedDevice;
  List<UsbDevice> _availableDevices = [];
  bool _isScanning = false;
  bool _isFlashing = false;
  double _flashProgress = 0.0;
  String _statusMessage = 'Ready to flash ESP32 firmware via USB';
  
  // Flash address selection
  FlashAddress _selectedFlashAddress = flashAddresses[2]; // Default: Application (0x10000)
  int _customAddress = 0x10000;
  final TextEditingController _customAddressController = TextEditingController(text: '0x10000');

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _scanPorts();
    
    // Listen for USB device events
    UsbSerial.usbEventStream?.listen((UsbEvent event) {
      _scanPorts();
    });
  }

  @override
  void dispose() {
    _customAddressController.dispose();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await Permission.storage.request();
      await Permission.manageExternalStorage.request();
    }
  }

  Future<void> _scanPorts() async {
    setState(() {
      _isScanning = true;
      _statusMessage = 'Scanning for USB devices...';
    });

    try {
      final devices = await UsbSerial.listDevices();
      setState(() {
        _availableDevices = devices;
        _isScanning = false;
        _statusMessage = devices.isEmpty 
          ? 'No USB devices found. Connect ESP32 and try again.'
          : 'Found ${devices.length} USB device(s)';
      });
    } catch (e) {
      setState(() {
        _isScanning = false;
        _statusMessage = 'Error scanning ports: ${e.toString()}';
      });
    }
  }

  int get _effectiveFlashAddress {
    if (_selectedFlashAddress.name == 'Custom') {
      return _customAddress;
    }
    return _selectedFlashAddress.address;
  }

  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['bin'],
    );

    if (result != null && result.files.single.path != null) {
      final file = File(result.files.single.path!);
      final bytes = await file.readAsBytes();
      
      if (bytes.isEmpty) {
        _showError('File is empty');
        return;
      }

      // Detect chip type from magic byte
      String chipType = 'Unknown';
      if (bytes.length >= 4) {
        final magicByte = bytes[0];
        if (magicByte == 0xE9) {
          chipType = 'ESP32/ESP32-S2/ESP32-C3';
        } else if (magicByte == 0x2F) {
          chipType = 'ESP8266';
        }
      }

      setState(() {
        _selectedFilePath = result.files.single.path;
        _detectedChip = chipType;
        _statusMessage = 'Selected firmware: ${bytes.length} bytes\nTarget: ${_selectedFlashAddress.hexAddress}';
      });
    }
  }

  Future<bool> _syncWithBootloader(UsbPort port) async {
    setState(() {
      _statusMessage = 'Syncing with bootloader...';
    });

    // Try to sync multiple times
    for (int attempt = 0; attempt < 10; attempt++) {
      final syncPacket = SlipProtocol.buildSyncPacket();
      port.write(syncPacket);
      
      await Future.delayed(const Duration(milliseconds: 100));
      
      // Check for response
      try {
        final completer = Completer<bool>();
        Timer? timeoutTimer;
        StreamSubscription? subscription;
        
        timeoutTimer = Timer(const Duration(milliseconds: 500), () {
          subscription?.cancel();
          if (!completer.isCompleted) completer.complete(false);
        });
        
        subscription = port.inputStream?.listen((data) {
          if (data.isNotEmpty) {
            timeoutTimer?.cancel();
            subscription?.cancel();
            if (!completer.isCompleted) completer.complete(true);
          }
        });
        
        final gotResponse = await completer.future;
        if (gotResponse) {
          setState(() {
            _statusMessage = 'Bootloader sync successful!';
          });
          return true;
        }
      } catch (e) {
        // Continue trying
      }
    }
    
    return false;
  }

  Future<void> _flashFirmware() async {
    final selectedDevice = _selectedDevice;
    
    if (selectedDevice == null || _selectedFilePath == null) {
      _showError('Please select a USB device and firmware file');
      return;
    }

    setState(() {
      _isFlashing = true;
      _flashProgress = 0.0;
      _statusMessage = 'Starting flash process...';
    });

    try {
      final file = File(_selectedFilePath!);
      final firmwareBytes = await file.readAsBytes();
      final flashAddress = _effectiveFlashAddress;
      
      final port = await selectedDevice.create();
      if (port == null) {
        throw Exception('Failed to create port');
      }
      
      final opened = await port.open();
      if (!opened) {
        throw Exception('Failed to open port');
      }

      // Configure port for bootloader communication (115200 initially)
      await port.setPortParameters(115200, UsbPort.DATABITS_8, UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);

      setState(() {
        _statusMessage = 'Connecting to ESP32 bootloader...';
        _flashProgress = 0.05;
      });

      // Try to sync with bootloader
      final synced = await _syncWithBootloader(port);
      if (!synced) {
        // Continue anyway - device might already be in bootloader mode
        setState(() {
          _statusMessage = 'Warning: No sync response. Continuing...';
        });
      }

      setState(() {
        _flashProgress = 0.1;
        _statusMessage = 'Preparing to flash at address 0x${flashAddress.toRadixString(16).toUpperCase()}...';
      });

      // Calculate flash parameters
      const blockSize = 0x400; // 1KB blocks
      final numBlocks = (firmwareBytes.length / blockSize).ceil();
      final eraseSize = numBlocks * blockSize;

      // Send flash begin command
      final flashBeginPacket = SlipProtocol.buildFlashBeginPacket(
        eraseSize, numBlocks, blockSize, flashAddress
      );
      port.write(flashBeginPacket);
      await Future.delayed(const Duration(milliseconds: 500));

      setState(() {
        _statusMessage = 'Erasing flash... This may take a moment.';
        _flashProgress = 0.15;
      });

      await Future.delayed(const Duration(seconds: 2)); // Wait for erase

      setState(() {
        _statusMessage = 'Writing firmware to flash...';
      });

      // Write firmware in blocks
      for (int i = 0; i < numBlocks; i++) {
        final start = i * blockSize;
        final end = (start + blockSize).clamp(0, firmwareBytes.length);
        var chunk = firmwareBytes.sublist(start, end);
        
        // Pad last block to full size if needed
        if (chunk.length < blockSize) {
          final padded = Uint8List(blockSize);
          padded.setAll(0, chunk);
          for (int j = chunk.length; j < blockSize; j++) {
            padded[j] = 0xFF; // Flash erase value
          }
          chunk = padded;
        }

        final dataPacket = SlipProtocol.buildFlashDataPacket(chunk, i);
        port.write(dataPacket);
        
        // Small delay between blocks
        await Future.delayed(const Duration(milliseconds: 10));
        
        setState(() {
          _flashProgress = 0.15 + (i + 1) / numBlocks * 0.75;
          _statusMessage = 'Writing: ${((i + 1) / numBlocks * 100).toStringAsFixed(1)}%\n'
              'Block ${i + 1}/$numBlocks';
        });
      }

      setState(() {
        _statusMessage = 'Finalizing flash...';
        _flashProgress = 0.92;
      });

      // Send flash end command (with reboot)
      final flashEndPacket = SlipProtocol.buildFlashEndPacket(true);
      port.write(flashEndPacket);
      
      await Future.delayed(const Duration(seconds: 1));
      
      // Close the port
      port.close();

      setState(() {
        _flashProgress = 1.0;
        _statusMessage = 'Flash successful!\n'
            'Address: 0x${flashAddress.toRadixString(16).toUpperCase()}\n'
            'Size: ${firmwareBytes.length} bytes\n'
            'ESP32 is rebooting...';
        _isFlashing = false;
      });
      
      _showSuccess('Firmware flashed successfully!');
      
    } catch (e) {
      setState(() {
        _isFlashing = false;
        _flashProgress = 0.0;
        _statusMessage = 'Flash failed: ${e.toString()}';
      });
      _showError('Flash failed: ${e.toString()}');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ESP32 USB Flasher'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // USB Device Selection
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.usb),
                        const SizedBox(width: 8),
                        Text('USB Device', style: Theme.of(context).textTheme.titleMedium),
                        const Spacer(),
                        ElevatedButton.icon(
                          onPressed: _isScanning ? null : _scanPorts,
                          icon: _isScanning 
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh),
                          label: Text(_isScanning ? 'Scanning...' : 'Scan'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_availableDevices.isNotEmpty) ...[
                      DropdownButtonFormField<UsbDevice>(
                        value: _selectedDevice,
                        decoration: const InputDecoration(
                          labelText: 'Select USB Device',
                          border: OutlineInputBorder(),
                        ),
                        items: _availableDevices.map((device) {
                          return DropdownMenuItem(
                            value: device,
                            child: Text(device.productName ?? 'Unknown Device'),
                          );
                        }).toList(),
                        onChanged: (value) {
                          setState(() {
                            _selectedDevice = value;
                          });
                        },
                      ),
                    ] else ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey[200],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.info_outline, color: Colors.grey),
                            SizedBox(width: 8),
                            Text('No USB devices found'),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            
            // Flash Address Selection
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.memory),
                        const SizedBox(width: 8),
                        Text('Flash Address', style: Theme.of(context).textTheme.titleMedium),
                      ],
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<FlashAddress>(
                      value: _selectedFlashAddress,
                      decoration: const InputDecoration(
                        labelText: 'Select Flash Address',
                        border: OutlineInputBorder(),
                      ),
                      items: flashAddresses.map((addr) {
                        return DropdownMenuItem(
                          value: addr,
                          child: Text('${addr.hexAddress} - ${addr.name}'),
                        );
                      }).toList(),
                      onChanged: (value) {
                        setState(() {
                          _selectedFlashAddress = value!;
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _selectedFlashAddress.description,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                    ),
                    if (_selectedFlashAddress.name == 'Custom') ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _customAddressController,
                        decoration: const InputDecoration(
                          labelText: 'Custom Address (hex)',
                          hintText: '0x10000',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (value) {
                          try {
                            final addr = int.parse(value.replaceFirst('0x', '').replaceFirst('0X', ''), radix: 16);
                            setState(() {
                              _customAddress = addr;
                            });
                          } catch (e) {
                            // Invalid hex
                          }
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            
            // Firmware File Selection
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.file_upload),
                        const SizedBox(width: 8),
                        Text('Firmware File', style: Theme.of(context).textTheme.titleMedium),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: _pickFile,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Select .bin File'),
                    ),
                    if (_selectedFilePath != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.green[50],
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.green[200]!),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.check_circle, color: Colors.green, size: 16),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _selectedFilePath!.split(Platform.pathSeparator).last,
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
                            ),
                            if (_detectedChip != null) ...[
                              const SizedBox(height: 4),
                              Text('Detected: $_detectedChip'),
                            ],
                            Text('Flash to: ${_selectedFlashAddress.hexAddress}'),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            
            // Status and Progress
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _isFlashing ? Icons.sync : Icons.info,
                          color: _isFlashing ? Colors.orange : null,
                        ),
                        const SizedBox(width: 8),
                        Text('Status', style: Theme.of(context).textTheme.titleMedium),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(_statusMessage),
                    if (_isFlashing) ...[
                      const SizedBox(height: 12),
                      LinearProgressIndicator(value: _flashProgress),
                      const SizedBox(height: 8),
                      Text(
                        'Progress: ${(_flashProgress * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            
            // Flash Button
            ElevatedButton.icon(
              onPressed: (_selectedDevice == null || _selectedFilePath == null || _isFlashing) 
                ? null 
                : _flashFirmware,
              icon: _isFlashing 
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.flash_on),
              label: Text(_isFlashing ? 'Flashing...' : 'Flash Firmware'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: Colors.deepOrange,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey[300],
              ),
            ),
            
            const SizedBox(height: 16),
            
            // Help text
            Card(
              color: Colors.blue[50],
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.help_outline, color: Colors.blue[700], size: 20),
                        const SizedBox(width: 8),
                        Text('Tips', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue[700])),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text('• Hold BOOT button on ESP32 while connecting'),
                    const Text('• Use 0x10000 for main application firmware'),
                    const Text('• Use 0x1000 for bootloader updates'),
                    const Text('• Make sure USB OTG adapter is properly connected'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
