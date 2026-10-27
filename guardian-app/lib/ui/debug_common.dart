import 'package:flutter/material.dart';

import 'theme.dart';

// Shared by the debug screen and the field-test panel.

const kMono = TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 14);
const kSection = TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 0.8, color: kMuted);

/// A label on the left, a monospace value on the right.
Widget kvRow(String k, String v) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 4),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(k, style: const TextStyle(fontSize: 14, color: kMuted)),
      const SizedBox(width: 12),
      Expanded(
        child: Text(v, textAlign: TextAlign.right, style: kMono),
      ),
    ],
  ),
);
