import 'package:flutter/material.dart';

import '../../core/models/network_interface_info.dart';
import '../../core/models/routing_rule.dart';
import '../routing_rules/domain/netpilot_controller.dart';
import '../routing_rules/presentation/rule_editor_sheet.dart';
import '../network_interfaces/presentation/interface_card.dart';
import '../routing_rules/presentation/rule_tile.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});

  final NetPilotController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  NetPilotController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
  }

  @override
  void dispose() {
    c.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _openEditor({RoutingRule? rule}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => RuleEditorSheet(
        controller: c,
        existing: rule,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('NetPilot'),
        actions: [
          IconButton(
            tooltip: 'Refresh DNS & apply',
            onPressed: c.busy ? null : () => c.refreshResolutions(),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('Add rule'),
      ),
      body: c.loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (c.bannerError != null)
                  MaterialBanner(
                    content: Text(c.bannerError!),
                    leading: const Icon(Icons.warning_amber_rounded),
                    actions: [
                      if (!c.helperStatus.enabled)
                        TextButton(
                          onPressed: c.busy ? null : () => c.installHelper(),
                          child: const Text('Install helper'),
                        ),
                      TextButton(
                        onPressed: () {
                          // Clear by re-apply / refresh status
                          c.refreshHelperStatus();
                        },
                        child: const Text('Dismiss'),
                      ),
                    ],
                  ),
                if (!c.helperStatus.enabled)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Card(
                      color: theme.colorScheme.secondaryContainer
                          .withValues(alpha: 0.45),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Icon(
                              Icons.security,
                              color: theme.colorScheme.onSecondaryContainer,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Privileged helper status: ${c.helperStatus.status}. '
                                'Install and approve Login Items to apply routes.',
                              ),
                            ),
                            FilledButton(
                              onPressed:
                                  c.busy ? null : () => c.installHelper(),
                              child: const Text('Install'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 900;
                      final interfacesPane = _InterfacesPane(
                        interfaces: c.interfaces,
                      );
                      final rulesPane = _RulesPane(
                        rules: c.rules,
                        interfaces: c.interfaces,
                        busy: c.busy,
                        onEdit: (r) => _openEditor(rule: r),
                        onDelete: c.deleteRule,
                        onToggle: c.setRuleEnabled,
                      );
                      if (wide) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: 340,
                              child: interfacesPane,
                            ),
                            const VerticalDivider(width: 1),
                            Expanded(child: rulesPane),
                          ],
                        );
                      }
                      return ListView(
                        children: [
                          SizedBox(height: 280, child: interfacesPane),
                          const Divider(height: 1),
                          SizedBox(
                            height: constraints.maxHeight > 400
                                ? constraints.maxHeight - 280
                                : 400,
                            child: rulesPane,
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _InterfacesPane extends StatelessWidget {
  const _InterfacesPane({required this.interfaces});

  final List<NetworkInterfaceInfo> interfaces;

  @override
  Widget build(BuildContext context) {
    final active = interfaces.where((i) => i.isActive).toList();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Connected networks',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Wi‑Fi can stay default; LAN rules send intranet hosts the other way.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: active.isEmpty
                ? const Center(child: Text('No active IPv4 interfaces'))
                : ListView.separated(
                    itemCount: active.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) =>
                        InterfaceCard(info: active[index]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _RulesPane extends StatelessWidget {
  const _RulesPane({
    required this.rules,
    required this.interfaces,
    required this.busy,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
  });

  final List<RoutingRule> rules;
  final List<NetworkInterfaceInfo> interfaces;
  final bool busy;
  final ValueChanged<RoutingRule> onEdit;
  final ValueChanged<String> onDelete;
  final void Function(String id, bool enabled) onToggle;

  String _ifaceLabel(String id) {
    final match = interfaces.cast<NetworkInterfaceInfo?>().firstWhere(
          (i) => i?.id == id || i?.interfaceName == id,
          orElse: () => null,
        );
    if (match == null) return id;
    return '${match.name} (${match.interfaceName})';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Routing rules', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Destinations use hostname / URL host / IPv4 / CIDR. Paths are ignored.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: rules.isEmpty
                ? const Center(
                    child: Text('No rules yet — add an intranet host or CIDR'),
                  )
                : ListView.separated(
                    itemCount: rules.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final rule = rules[index];
                      return RuleTile(
                        rule: rule,
                        interfaceLabel: _ifaceLabel(rule.interfaceId),
                        onEdit: () => onEdit(rule),
                        onDelete: () => onDelete(rule.id),
                        onToggle: (v) => onToggle(rule.id, v),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
