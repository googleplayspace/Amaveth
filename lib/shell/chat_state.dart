/// Business state comes from the four additional Web events, not DOM scraping.
class ShellChatState {
  String? currentChat;
  bool visible = false;
  bool documentReady = false;

  void resetDocument() {
    documentReady = false;
    currentChat = null;
  }

  static String? chatId(Map<String, dynamic>? params) {
    final value = params?['chatId'] ?? params?['chat_id'];
    return value is String && value.isNotEmpty ? value : null;
  }

  void event(String name, Map<String, String> params) {
    if (name == 'webReady') documentReady = true;
    if (name == 'chatOpen' && documentReady) {
      currentChat = chatId(params);
    }
    if (name == 'chatClose' &&
        (chatId(params) == null || chatId(params) == currentChat)) {
      currentChat = null;
    }
    if (name == 'logout') currentChat = null;
  }

  bool suppress(Map<String, dynamic>? data) =>
      visible &&
      documentReady &&
      currentChat != null &&
      chatId(data) == currentChat;
}
