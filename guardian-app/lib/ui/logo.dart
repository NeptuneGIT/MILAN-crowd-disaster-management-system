import 'package:flutter/material.dart';

import 'theme.dart';

/// The MILAN mark: two figures holding hands. Drawn on a 96-unit grid, so it stays crisp at any size.
class MilanMark extends StatelessWidget {
  const MilanMark({super.key, this.size = 32, this.color = kInk, this.accent = const Color(0xFFFFF3E0)});
  final double size;
  final Color color, accent;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _MarkPainter(color, accent));
}

/// Mark plus the name, for headers.
class MilanLogo extends StatelessWidget {
  const MilanLogo({super.key, this.size = 34});
  final double size;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      MilanMark(size: size),
      const SizedBox(width: 10),
      const Text(
        'MILAN',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 3, color: kInk),
      ),
    ],
  );
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.color, this.accent);
  final Color color, accent;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 96;
    canvas.scale(k);
    canvas.drawCircle(const Offset(26, 20), 9, Paint()..color = color);
    canvas.drawCircle(const Offset(70, 20), 9, Paint()..color = accent);
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(26, 38), const Offset(26, 82), line);
    canvas.drawLine(const Offset(70, 38), const Offset(70, 82), line);
    canvas.drawPath(
      Path()
        ..moveTo(26, 50)
        ..quadraticBezierTo(48, 74, 70, 50),
      line,
    );
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.color != color || old.accent != accent;
}
