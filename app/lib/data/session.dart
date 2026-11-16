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

  /// Creates the account, then signs in with it. Throws [ApiException]; if the
  /// account was created but the sign-in failed, the message says so.
  Future<void> register(String name, String email, String password) async {
    await api.register(name, email, password);
    try {
      await signIn(email, password);
    } on ApiException catch (e) {
      throw ApiException(
        e.statusCode,
        'Account created, but signing in failed: ${e.message} Go back and sign in.',
      );
    }
  }

  Future<void> giveConsent() async {
    await api.giveConsent();
    user = await api.me();
    notifyListeners();
  }

  /// Saves the profile and keeps the signed-in user up to date. Throws
  /// [ApiException].
  Future<void> updateProfile({String? name, int? goodDbm, int? deadDbm}) async {
    user = await api.updateProfile(
      name: name,
      goodDbm: goodDbm,
      deadDbm: deadDbm,
    );
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
