import 'dart:async';

/// Stub implementation of [VoskSpeechService] for platforms where Vosk is
/// not supported (web, Linux desktop without native libs, etc.).
/// Always returns false from [startListening] and emits nothing.
class VoskSpeechService {
  VoskSpeechService._();
  static final VoskSpeechService instance = VoskSpeechService._();

  final StreamController<String> _wordController =
      StreamController<String>.broadcast();

  Stream<String> get wordStream => _wordController.stream;
  bool get isListening => false;

  Future<bool> startListening({String languageCode = 'en'}) async {
    return false;
  }

  Future<void> stopListening() async {}

  void dispose() {
    _wordController.close();
  }
}
