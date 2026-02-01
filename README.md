# ESP32 USB Flasher

A Flutter app for flashing ESP32/ESP32-S3 firmware via USB OTG on Android devices.

## Features

- 🔌 **USB Device Detection** - Automatically scan and detect USB devices
- 🎯 **Automatic Chip Identification** - Identifies ESP32 vs ESP32-S3 from firmware magic bytes
- 📁 **File Selection** - Easy .bin file selection from device storage
- ⚡ **Fast Flashing** - High-speed firmware flashing via USB
- 📊 **Progress Tracking** - Real-time progress updates and status messages
- 🛡️ **Error Handling** - Comprehensive error reporting and user feedback

## Requirements

- Android device with USB OTG support
- USB OTG adapter cable
- ESP32 or ESP32-S3 development board
- USB cable for connection

## Installation

### From APK

1. Download the latest APK from [Releases](https://github.com/yourusername/esp32-ota-app/releases)
2. Enable "Install from unknown sources" in Android settings
3. Install the APK

### Build from Source

```bash
# Clone the repository
git clone https://github.com/yourusername/esp32-ota-app.git
cd esp32-ota-app

# Install Flutter dependencies
flutter pub get

# Build APK
flutter build apk --release

# Install on connected device
flutter install
```

## Usage

1. **Connect Hardware**
   - Connect ESP32 to your Android device via USB OTG adapter
   - Make sure ESP32 is in bootloader mode (hold BOOT button while powering on)

2. **Select USB Device**
   - Tap "Scan" to detect USB devices
   - Select the detected ESP32 port from the dropdown
   - The app will attempt to auto-detect the chip type

3. **Select Firmware**
   - Tap "Select .bin File"
   - Browse to your firmware file (.bin extension)
   - The app will detect the chip type from the firmware

4. **Flash Firmware**
   - Once both device and firmware are selected, tap "Flash Firmware"
   - Monitor the progress bar and status messages
   - Wait for successful completion

## Firmware Compatibility

The app detects chip types from firmware magic bytes:
- **ESP32**: Magic byte `0xE9`
- **ESP32-S3**: Magic byte `0x0C` or `0x09`

## Permissions Required

- **USB Host**: Required for USB device communication
- **Storage Access**: Required to read firmware files from device storage

## Troubleshooting

### USB Device Not Detected
- Ensure USB OTG is enabled in device settings
- Try a different USB OTG adapter
- Check that the ESP32 is properly connected
- Some Android devices may have USB restrictions

### Flash Fails
- Make sure ESP32 is in bootloader mode
- Try reducing baud rate if connection is unstable
- Check that firmware file is compatible with your chip
- Ensure cable connections are secure

### File Selection Issues
- Grant storage permissions when prompted
- Make sure firmware files have .bin extension
- Check that files are not corrupted

## Development

### Building APK Locally

```bash
# Debug build
flutter build apk --debug

# Release build
flutter build apk --release

# App Bundle (for Play Store)
flutter build appbundle --release
```

### GitHub Actions

This project includes GitHub Actions for automatic APK building:
- Push to main/develop: Builds debug and release APKs
- Tagged releases: Creates GitHub releases with APKs
- Manual builds: Available via workflow dispatch

## Technical Details

### USB Communication
- Uses `flutter_libserialport` for USB serial communication
- Configurable baud rates (115200 for detection, 460800 for flashing)
- 8N1 serial configuration (8 data bits, no parity, 1 stop bit)

### Flash Protocol
- Simplified ESP32 flashing protocol
- Chunked firmware writing (1KB chunks)
- Basic bootloader synchronization

### Architecture
- Flutter UI with Material Design 3
- Asynchronous operations for non-blocking UI
- State management with StatefulWidget
- Error handling with user-friendly messages

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Support

If you encounter issues:
1. Check the troubleshooting section above
2. Search existing [GitHub Issues](https://github.com/yourusername/esp32-ota-app/issues)
3. Create a new issue with detailed information

## Acknowledgments

- [flutter_libserialport](https://pub.dev/packages/flutter_libserialport) for USB communication
- [file_picker](https://pub.dev/packages/file_picker) for file selection
- ESP32 community for protocol documentation