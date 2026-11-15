import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/models.dart';
import '../theme.dart';

/// A floor's plan image, fetched with the sign-in token. Shows a placeholder
/// when the floor has no plan or the image cannot be loaded.
class PlanThumb extends StatelessWidget {
  const PlanThumb({
    super.key,
    required this.api,
    required this.floor,
    this.size = 56,
    this.cacheBust,
  });

  final ApiClient api;
  final Floor floor;
  final double size;

  /// Changes when the plan was replaced, so the new image is fetched.
  final Object? cacheBust;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.outline),
      ),
      child: Icon(
        floor.hasPlan ? Icons.broken_image_outlined : Icons.map_outlined,
        color: AppColors.textMuted,
        semanticLabel: floor.hasPlan ? 'Plan could not load' : 'No floor plan',
      ),
    );
    final url = floor.planUrl;
    if (url == null) return placeholder;
    final uri = api
        .planUri(url)
        .replace(
          queryParameters: cacheBust == null ? null : {'v': '$cacheBust'},
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.network(
        uri.toString(),
        headers: api.authHeaders,
        width: size,
        height: size,
        fit: BoxFit.cover,
        semanticLabel: 'Floor plan of ${floor.label}',
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}
