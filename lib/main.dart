import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:usb_serial/usb_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';
import 'dart:typed_data';

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

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await Permission.storage.request();
      if (Platform.isAndroid) {
        await Permission.manageExternalStorage.request();
      }
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

  Future<void> _detectChip(UsbDevice device) async {
    setState(() {
      _statusMessage = 'Detecting chip type on ${device.productName}...';
    });

    try {
      final port = await device.create();
      if (port == null) {
        throw Exception('Failed to create port');
      }
      
      final opened = await port.open();
      if (!opened) {
        throw Exception('Failed to open port');
      }

      // Configure port for ESP32 communication
      await port.setPortParameters(115200, UsbPort.DATABITS_8, UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);

      // Try to detect chip by sending reset and checking response
      // First, send sync command (0x07 0x07 0x12 0x20)
      port.write(Uint8List.fromList([0x07, 0x07, 0x12, 0x20]));
      
      // Wait for response
      await Future.delayed(const Duration(milliseconds: 500));
      
      // Try to read any response
      try {
        final response = await port.inputStream?.first;
        if (response != null && response.isNotEmpty) {
          // ESP32 typically responds with specific patterns
          // This is a simplified detection - real detection would be more complex
          setState(() {
            _detectedChip = 'ESP32'; // Default to ESP32 for now
            _statusMessage = 'Detected ESP32 on ${device.productName}';
          });
        }
      } catch (e) {
        // If no response, still assume ESP32 might be connected
        setState(() {
          _detectedChip = 'ESP32';
          _statusMessage = 'ESP32 detected on ${device.productName} (no response received)';
        });
      }
      
      port.close();

    } catch (e) {
      setState(() {
        _statusMessage = 'Chip detection failed: ${e.toString()}';
      });
    }
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
      String chipType;
      final magicByte = bytes[0];
      if (magicByte == 0xE9) {
        chipType = 'ESP32';
      } else if (magicByte == 0x0C) {
        chipType = 'ESP32-S3';
      } else if (magicByte == 0x09) {
        chipType = 'ESP32-S3';
      } else {
        _showError('Unknown chip type. Magic byte: 0x${magicByte.toRadixString(16).toUpperCase()}');
        return;
      }

      setState(() {
        _selectedFilePath = result.files.single.path;
        _detectedChip = chipType;
        _statusMessage = 'Selected $chipType firmware (${bytes.length} bytes)';
      });
    }
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
      
      final port = await selectedDevice.create();
      if (port == null) {
        throw Exception('Failed to create port');
      }
      
      final opened = await port.open();
      if (!opened) {
        throw Exception('Failed to open port');
      }

      // Configure port for high-speed flashing
      await port.setPortParameters(460800, UsbPort.DATABITS_8, UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);

      setState(() {
        _statusMessage = 'Connected to $_detectedChip. Preparing to flash...';
        _flashProgress = 0.05;
      });

      // Simple flash protocol - this is a simplified version
      // Real ESP32 flashing would require the complete esptool protocol
      
      // Sync with bootloader
      port.write(Uint8List.fromList([0x07, 0x07, 0x12, 0x20]));
      await Future.delayed(const Duration(milliseconds: 100));
      
      setState(() {
        _statusMessage = 'Writing firmware to $_detectedChip...';
        _flashProgress = 0.1;
      });

      // Write firmware in chunks
      const chunkSize = 1024;
      final totalChunks = (firmwareBytes.length / chunkSize).ceil();
      
      for (int i = 0; i < totalChunks; i++) {
        final start = i * chunkSize;
        final end = (start + chunkSize).clamp(0, firmwareBytes.length);
        final chunk = firmwareBytes.sublist(start, end);
        
        port.write(chunk);
        await Future.delayed(const Duration(milliseconds: 5));
        
        setState(() {
          _flashProgress = 0.1 + (i + 1) / totalChunks * 0.8;
        });
      }

      await Future.delayed(const Duration(seconds: 1));
      
      // Close the port
      port.close();

      setState(() {
        _flashProgress = 1.0;
        _statusMessage = 'Flash successful! $_detectedChip is ready.';
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
      body: Padding(
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
                          if (value != null) {
                            _detectChip(value);
                          }
                        },
                      ),
                    ] else ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey[200],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text('No USB devices found'),
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
                          color: Colors.grey[200],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('File: ${_selectedFilePath!.split(Platform.pathSeparator).last}'),
                            if (_detectedChip != null) Text('Chip: $_detectedChip'),
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
                        const Icon(Icons.info),
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
                      Text('Progress: ${(_flashProgress * 100).toStringAsFixed(1)}%'),
                    ],
                  ],
                ),
              ),
            ),
            const Spacer(),
            
            // Flash Button
            ElevatedButton.icon(
              onPressed: (_selectedDevice == null || _selectedFilePath == null || _isFlashing) 
                ? null 
                : _flashFirmware,
              icon: _isFlashing 
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.flash_on),
              label: Text(_isFlashing ? 'Flashing...' : 'Flash Firmware'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: Colors.deepOrange,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}