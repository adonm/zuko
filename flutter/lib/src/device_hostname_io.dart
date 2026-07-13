import 'dart:io';

String? readDeviceHostname() {
  try {
    return Platform.localHostname;
  } on Object {
    return null;
  }
}
