import 'package:flutter/material.dart';

import '../../../core/models/routing_rule.dart';

class RuleTile extends StatefulWidget {
  const RuleTile({
    super.key,
    required this.rule,
    required this.interfaceLabel,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
    required this.onSubRuleToggle,
  });

  final RoutingRule rule;
  final String interfaceLabel;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;
  final void Function(String subRuleId, bool enabled) onSubRuleToggle;

  @override
  State<RuleTile> createState() => _RuleTileState();
}

class _RuleTileState extends State<RuleTile> {
  bool _expanded = false;

  Color _statusColor(BuildContext context, RuleStatus status) {
    final scheme = Theme.of(context).colorScheme;
    return switch (status) {
      RuleStatus.applied => const Color(0xFF1B7F4C),
      RuleStatus.pending => scheme.outline,
      RuleStatus.unresolved => const Color(0xFFB26A00),
      RuleStatus.error => scheme.error,
    };
  }

  @override
  Widget build(BuildContext context) {
    final rule = widget.rule;
    final theme = Theme.of(context);
    final hasSubRules = rule.subRules.isNotEmpty;
    return Card(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Switch(value: rule.enabled, onChanged: widget.onToggle),
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
                        '${rule.kind.name} · via ${widget.interfaceLabel}',
                        style: theme.textTheme.bodySmall,
                      ),
                      if (rule.resolvedIps.isNotEmpty)
                        Text(
                          'IPs: ${rule.resolvedIps.join(', ')}',
                          style: theme.textTheme.bodySmall,
                        ),
                      if (rule.dependencyScanStatus ==
                          DependencyScanStatus.pending)
                        Text(
                          'Scanning dependencies…',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      if (rule.dependencyScanStatus ==
                          DependencyScanStatus.failed)
                        Text(
                          'Dependency scan failed: ${rule.dependencyScanError ?? 'Unknown error'}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFFB26A00),
                          ),
                        ),
                      if (rule.lastError != null)
                        Text(
                          rule.lastError!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                ),
                if (hasSubRules)
                  Tooltip(
                    message: _expanded
                        ? 'Hide discovered dependencies'
                        : 'Show ${rule.subRules.length} discovered dependencies',
                    child: TextButton.icon(
                      key: ValueKey('subrules-${rule.id}'),
                      onPressed: () => setState(() => _expanded = !_expanded),
                      icon: Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.account_tree_outlined,
                        size: 18,
                      ),
                      label: Text('${rule.subRules.length}'),
                    ),
                  ),
                const SizedBox(width: 4),
                _StatusChip(
                  status: rule.status,
                  color: _statusColor(context, rule.status),
                ),
                IconButton(
                  tooltip: 'Edit and rescan',
                  onPressed: widget.onEdit,
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: 'Delete',
                  onPressed: widget.onDelete,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _expanded && hasSubRules
                ? Column(
                    key: ValueKey('subrule-list-${rule.id}'),
                    children: [
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
                        child: Row(
                          children: [
                            Icon(
                              Icons.travel_explore_rounded,
                              size: 16,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Discovered dependencies',
                              style: theme.textTheme.labelLarge,
                            ),
                            const Spacer(),
                            Text(
                              'Inherited route · ${widget.interfaceLabel}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      for (final subRule in rule.subRules)
                        _SubRuleRow(
                          key: ValueKey('subrule-${subRule.id}'),
                          subRule: subRule,
                          parentEnabled: rule.enabled,
                          color: _statusColor(context, subRule.status),
                          onChanged: (enabled) =>
                              widget.onSubRuleToggle(subRule.id, enabled),
                        ),
                      const SizedBox(height: 8),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _SubRuleRow extends StatelessWidget {
  const _SubRuleRow({
    super.key,
    required this.subRule,
    required this.parentEnabled,
    required this.color,
    required this.onChanged,
  });

  final RoutingSubRule subRule;
  final bool parentEnabled;
  final Color color;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Row(
        children: [
          const SizedBox(width: 8),
          Switch(
            key: ValueKey('subrule-toggle-${subRule.id}'),
            value: subRule.enabled,
            onChanged: parentEnabled ? onChanged : null,
          ),
          const SizedBox(width: 10),
          Icon(Icons.subdirectory_arrow_right_rounded, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(subRule.destination, style: theme.textTheme.bodyMedium),
                Text(
                  subRule.resolvedIps.isEmpty
                      ? 'No IPv4 address resolved'
                      : subRule.resolvedIps.join(', '),
                  style: theme.textTheme.bodySmall,
                ),
                if (subRule.lastError != null)
                  Text(
                    subRule.lastError!,
                    style: theme.textTheme.bodySmall?.copyWith(color: color),
                  ),
              ],
            ),
          ),
          _StatusChip(status: subRule.status, color: color),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status, required this.color});

  final RuleStatus status;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(status.name),
      visualDensity: VisualDensity.compact,
      side: BorderSide(color: color.withValues(alpha: 0.4)),
      labelStyle: TextStyle(color: color, fontSize: 12),
    );
  }
}
