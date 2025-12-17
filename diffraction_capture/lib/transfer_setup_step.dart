import 'package:flutter/material.dart';

class TransferSetupStep extends StatelessWidget {
  const TransferSetupStep({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const [
        Text(
          'Transfer Setup',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        SizedBox(height: 12),
        Text('Ensure upload path exists before capture. Configure as needed.'),
      ],
    );
  }
}
