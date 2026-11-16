import 'package:flutter/material.dart';

import '../theme.dart';

/// The 2D map / 3D view switch that sits in the app bar of both screens, so
/// moving between them is always the same control in the same place.
class ViewSwitch extends StatelessWidget {
  const ViewSwitch({super.key, required this.is3d, required this.onSwitch});

  /// Which of the two screens this switch is on.
  final bool is3d;

  /// Called when the other segment is tapped.
  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: SegmentedButton<bool>(
        key: const ValueKey('view-switch'),
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(
          minimumSize: const Size(0, kTarget),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        segments: const [
          ButtonSegment(value: false, label: Text('2D map')),
          ButtonSegment(value: true, label: Text('3D')),
        ],
        selected: {is3d},
        onSelectionChanged: (picked) {
          if (picked.first != is3d) onSwitch();
        },
      ),
    );
  }
}
