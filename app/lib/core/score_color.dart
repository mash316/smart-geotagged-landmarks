import 'package:flutter/material.dart';

Color scoreToColor(double score, double minScore, double maxScore) {
  if (maxScore <= minScore) return Colors.green;

  final normalized = ((score - minScore) / (maxScore - minScore)).clamp(0.0, 1.0);
  final hue = 120.0 - (normalized * 120.0);
  return HSVColor.fromAHSV(1.0, hue, 0.8, 0.9).toColor();
}
