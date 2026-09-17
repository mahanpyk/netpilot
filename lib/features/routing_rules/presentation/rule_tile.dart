import 'package:flutter/material.dart';

import '../../../core/models/routing_rule.dart';

class RuleTile extends StatelessWidget {
  const RuleTile({
    super.key,
    required this.rule,
    required this.interfaceLabel,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
  });

  final RoutingRule rule;
  final String interfaceLabel;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;

  Color _statusColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (rule.status) {
      RuleStatus.applied => const Color(0xFF1B7F4C),
      RuleStatus.pending => scheme.outline,
      RuleStatus.unresolved => const Color(0xFFB26A00),
      RuleStatus.error => scheme.error,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Switch(value: rule.enabled, onChanged: onToggle),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    rule.label?.isNotEmpty == true
                        ? rule.label!
                        : rule.normalizedDestination,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${rule.kind.name} · via $interfaceLabel',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (rule.resolvedIps.isNotEmpty)
                    Text(
                      'IPs: ${rule.resolvedIps.join(', ')}',
                      style: theme.textTheme.bodySmall,
                    ),
                  if (rule.lastError != null)
                    Text(
                      rule.lastError!,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                ],
              ),
            ),
            Chip(
              label: Text(rule.status.name),
              visualDensity: VisualDensity.compact,
              side: BorderSide(color: _statusColor(context).withValues(alpha: 0.4)),
              labelStyle: TextStyle(color: _statusColor(context), fontSize: 12),
            ),
            IconButton(
              tooltip: 'Edit',
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: 'Delete',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}
