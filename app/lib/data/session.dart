import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'models.dart';
import 'token_store.dart';

enum SessionState { loading, signedOut, signedIn }

/// Who is signed in. Restores the saved token on start and drops it when the
/// API says it is no longer valid.
class Session extends ChangeNotifier {
  Session({required this.api, required this.tokens}) {
    api.onUnauthorized = () => signOut();
  }

  final ApiClient api;
  final TokenStore tokens;

  SessionState state = SessionState.loading;
  User? user;

  Future<void> restore() async {
    final saved = await tokens.read();
    if (saved == null) {
      state = SessionState.signedOut;
      notifyListeners();
      return;
    }
    api.token = saved;
    try {
      user = await api.me();
      state = SessionState.signedIn;
    } on ApiException catch (e) {
      // Keep the token if we were only offline; drop it if it was rejected.
      if (e.isNetwork) {
        state = SessionState.signedOut;
        api.token = null;
      } else {
        await signOut();
        return;
      }
    }
    notifyListeners();
  }

  /// Throws [ApiException] with a message fit for the screen.
  Future<void> signIn(String email, String password) async {
    final token = await api.login(email, password);
    api.token = token;
    try {
      user = await api.me();
    } catch (_) {
      api.token = null;
      rethrow;
    }
    await tokens.write(token);
    state = SessionState.signedIn;
    notifyListeners();
  }

  Future<void> giveConsent() async {
    await api.giveConsent();
    user = await api.me();
    notifyListeners();
  }

  Future<void> signOut() async {
    api.token = null;
    user = null;
    await tokens.clear();
    state = SessionState.signedOut;
    notifyListeners();
  }
}
