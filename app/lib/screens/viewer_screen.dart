import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../data/api_client.dart';
import '../theme.dart';

/// The Three.js coverage page served by the API (FR-16), in a WebView.
class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key, required this.api, required this.surveyId});

  final ApiClient api;
  final String surveyId;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  late final WebViewController _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final uri = widget.api.viewerUri(widget.surveyId);
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppColors.background)
      ..setNavigationDelegate(
        NavigationDelegate(
          // Only our own server may be shown in here.
          onNavigationRequest: (r) => Uri.parse(r.url).host == uri.host
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (e) {
            if (mounted && (e.isForMainFrame ?? true)) {
              setState(() => _error = e.description);
            }
          },
        ),
      )
      ..loadRequest(uri);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Coverage in 3D')),
      body: SafeArea(
        child: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_loading && _error == null)
              const Center(child: CircularProgressIndicator()),
            if (_error != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    "Couldn't load the 3D view: $_error",
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
