import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/session.dart';
import '../theme.dart';
import 'privacy_notice.dart';

/// Privacy consent (FR-22), shown once to Surveyors before their first survey.
class ConsentScreen extends StatefulWidget {
  const ConsentScreen({super.key, required this.session});

  final Session session;

  @override
  State<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends State<ConsentScreen> {
  bool _agreed = false;
  bool _busy = false;
  String? _error;

  Future<void> _agree() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.giveConsent();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Before your first survey')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            Text('PRIVACY NOTICE', style: mono(size: 15)),
            const SizedBox(height: 4),
            const Text(
              privacyNoticeVersion,
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 12),
            for (final section in privacyNotice)
              _InfoCard(title: section.title, body: section.body),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _agreed,
              onChanged: (v) => setState(() => _agreed = v ?? false),
              title: const Text(
                'I have read the privacy notice and I agree to the use of my '
                'data as described.',
              ),
            ),
            if (_error != null)
              Text(
                _error!,
                style: const TextStyle(color: AppColors.dead, fontSize: 15),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _agreed && !_busy ? _agree : null,
              child: const Text('Agree and continue'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _busy ? null : widget.session.signOut,
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: glowCard(strength: 0.06),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 15),
          ),
        ],
      ),
    );
  }
}
