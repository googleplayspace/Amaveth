import 'package:flutter/material.dart';

import '../core/amount_calculator.dart';

class AmountCalculator extends StatefulWidget {
  final String initial;
  const AmountCalculator({super.key, this.initial = ''});
  @override
  State<AmountCalculator> createState() => _AmountCalculatorState();
}

class _AmountCalculatorState extends State<AmountCalculator> {
  late String expression = widget.initial;
  String? error;
  bool evaluated = false;
  void key(String key) => setState(() {
    error = null;
    if (key == 'C') {
      expression = '';
      evaluated = false;
    } else if (key == '⌫') {
      if (expression.isNotEmpty) {
        expression = expression.substring(0, expression.length - 1);
      }
      evaluated = false;
    } else if (key == '=') {
      try {
        expression = (calculateMinorUnits(expression) / 100).toStringAsFixed(2);
        evaluated = true;
      } on FormatException catch (e) {
        error = e.message;
      }
    } else if (expression.length < 120) {
      if (evaluated && RegExp(r'[0-9.]').hasMatch(key)) expression = '';
      if (key == '.' &&
          (expression.isEmpty || RegExp(r'[+−×÷]$').hasMatch(expression))) {
        expression += '0';
      }
      expression += key;
      evaluated = false;
    }
  });
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Amount Calculator'),
    content: SizedBox(
      width: 320,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                expression.isEmpty ? '0' : expression,
                key: const ValueKey('calculator-expression'),
                style: const TextStyle(fontSize: 24),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Multiplication and division come before addition and subtraction. Results are rounded to 2 decimal places.',
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 12),
            for (final row in const [
              ['7', '8', '9', '÷'],
              ['4', '5', '6', '×'],
              ['1', '2', '3', '−'],
              ['0', '.', '=', '+'],
              ['C', '⌫'],
            ])
              Row(
                children: [
                  for (final value in row)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: OutlinedButton(
                          key: ValueKey('calc-$value'),
                          onPressed: () => key(value),
                          child: Text(value),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          try {
            Navigator.pop(context, calculateMinorUnits(expression));
          } on FormatException catch (e) {
            setState(() => error = e.message);
          }
        },
        child: const Text('Use amount'),
      ),
    ],
  );
}
