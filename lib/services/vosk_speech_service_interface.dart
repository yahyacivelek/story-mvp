// Conditional import: on web loads the stub (no dart:ffi), on
// native platforms loads the real Vosk implementation.
export 'vosk_speech_service_stub.dart'
    if (dart.library.ffi) 'vosk_speech_service.dart';
