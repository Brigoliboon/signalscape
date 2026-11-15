import 'package:flutter/material.dart';

import 'data/api_client.dart';
import 'data/session.dart';
import 'data/token_store.dart';
import 'screens/consent_screen.dart';
import 'screens/pick_screen.dart';
import 'screens/sign_in_screen.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final session = Session(api: ApiClient(), tokens: TokenStore());
  runApp(SignalScapeApp(session: session));
}

class SignalScapeApp extends StatefulWidget {
  const SignalScapeApp({super.key, required this.session});

  final Session session;

  @override
  State<SignalScapeApp> createState() => _SignalScapeAppState();
}

class _SignalScapeAppState extends State<SignalScapeApp> {
  @override
  void initState() {
    super.initState();
    widget.session.restore();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SignalScape',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) {
          final s = widget.session;
          switch (s.state) {
            case SessionState.loading:
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            case SessionState.signedOut:
              return SignInScreen(session: s);
            case SessionState.signedIn:
              return s.user!.needsConsent
                  ? ConsentScreen(session: s)
                  : PickScreen(session: s);
          }
        },
      ),
    );
  }
}
