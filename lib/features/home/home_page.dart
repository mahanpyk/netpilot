import 'package:flutter/material.dart';

import '../../core/models/network_interface_info.dart';
import '../../core/models/routing_rule.dart';
import '../../core/platform/network_platform.dart';
import '../network_interfaces/presentation/interface_card.dart';
import '../routing_rules/domain/netpilot_controller.dart';
import '../routing_rules/presentation/rule_editor_sheet.dart';
import '../routing_rules/presentation/rule_tile.dart';

enum _Tab { rules, networks, settings }

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.controller,
    required this.themeMode,
    required this.onThemeChanged,
  });

  final NetPilotController controller;
  final ThemeMode themeMode;
  final ValueChanged<bool> onThemeChanged;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  _Tab _tab = _Tab.rules;
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

  Future<void> _openEditor({RoutingRule? rule}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => RuleEditorSheet(controller: c, existing: rule),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 20, 28, 24),
          child: Column(
            children: [
              _TopBar(
                tab: _tab,
                isDark: widget.themeMode == ThemeMode.dark,
                busy: c.busy,
                onTab: (value) => setState(() => _tab = value),
                onTheme: widget.onThemeChanged,
                onRefresh: c.refreshResolutions,
              ),
              const SizedBox(height: 22),
              if (c.bannerError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _ErrorBanner(
                    message: c.bannerError!,
                    onInstall: c.helperStatus.enabled ? null : c.installHelper,
                    onDismiss: c.refreshHelperStatus,
                  ),
                ),
              Expanded(
                child: c.loading
                    ? const Center(child: CircularProgressIndicator())
                    : switch (_tab) {
                        _Tab.rules => _RulesView(
                          controller: c,
                          onEdit: (rule) => _openEditor(rule: rule),
                        ),
                        _Tab.networks => _NetworksView(
                          interfaces: c.interfaces,
                        ),
                        _Tab.settings => _SettingsView(
                          helperStatus: c.helperStatus,
                          busy: c.busy,
                          isDark: widget.themeMode == ThemeMode.dark,
                          onTheme: widget.onThemeChanged,
                          onInstall: c.installHelper,
                        ),
                      },
              ),
              if (_tab == _Tab.rules) ...[
                const SizedBox(height: 16),
                _Diagnostics(
                  message: c.bannerError,
                  helperEnabled: c.helperStatus.enabled,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.tab,
    required this.isDark,
    required this.busy,
    required this.onTab,
    required this.onTheme,
    required this.onRefresh,
  });

  final _Tab tab;
  final bool isDark;
  final bool busy;
  final ValueChanged<_Tab> onTab;
  final ValueChanged<bool> onTheme;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: colors.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            Icons.alt_route_rounded,
            color: colors.onPrimaryContainer,
          ),
        ),
        const SizedBox(width: 10),
        Text('NetPilot', style: Theme.of(context).textTheme.headlineSmall),
        const Spacer(),
        SegmentedButton<_Tab>(
          segments: const [
            ButtonSegment(
              value: _Tab.rules,
              icon: Icon(Icons.rule),
              label: Text('Rules'),
            ),
            ButtonSegment(
              value: _Tab.networks,
              icon: Icon(Icons.wifi),
              label: Text('Networks'),
            ),
            ButtonSegment(
              value: _Tab.settings,
              icon: Icon(Icons.settings_outlined),
              label: Text('Settings'),
            ),
          ],
          selected: {tab},
          showSelectedIcon: false,
          onSelectionChanged: (selection) => onTab(selection.first),
        ),
        const Spacer(),
        IconButton(
          tooltip: isDark ? 'Use light theme' : 'Use dark theme',
          onPressed: () => onTheme(!isDark),
          icon: Icon(
            isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
          ),
        ),
        IconButton(
          tooltip: 'Refresh DNS & apply',
          onPressed: busy ? null : onRefresh,
          icon: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        ),
      ],
    );
  }
}

class _RulesView extends StatelessWidget {
  const _RulesView({required this.controller, required this.onEdit});
  final NetPilotController controller;
  final ValueChanged<RoutingRule?> onEdit;

  String _interfaceLabel(String id) {
    final match = controller.interfaces
        .cast<NetworkInterfaceInfo?>()
        .firstWhere(
          (item) => item?.id == id || item?.interfaceName == id,
          orElse: () => null,
        );
    return match == null ? id : '${match.name} (${match.interfaceName})';
  }

  @override
  Widget build(BuildContext context) {
    final rules = controller.rules;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Rules',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Choose which destinations use each connected network.',
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: () => onEdit(null),
                  icon: const Icon(Icons.add),
                  label: const Text('Add rule'),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Expanded(
              child: rules.isEmpty
                  ? const _EmptyRules()
                  : Scrollbar(
                      child: ListView.separated(
                        primary: false,
                        itemCount: rules.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final rule = rules[index];
                          return RuleTile(
                            rule: rule,
                            interfaceLabel: _interfaceLabel(rule.interfaceId),
                            onEdit: () => onEdit(rule),
                            onDelete: () => controller.deleteRule(rule.id),
                            onToggle: (enabled) =>
                                controller.setRuleEnabled(rule.id, enabled),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyRules extends StatelessWidget {
  const _EmptyRules();
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.rule_folder_outlined,
          size: 48,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 12),
        Text('No rules yet', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        const Text('Add an intranet hostname, IPv4 address, or CIDR to begin.'),
      ],
    ),
  );
}

class _NetworksView extends StatelessWidget {
  const _NetworksView({required this.interfaces});
  final List<NetworkInterfaceInfo> interfaces;

  @override
  Widget build(BuildContext context) {
    final active = interfaces.where((item) => item.isActive).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Networks', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 4),
            const Text(
              'Connected interfaces and their current IPv4 configuration.',
            ),
            const SizedBox(height: 18),
            Expanded(
              child: active.isEmpty
                  ? const Center(child: Text('No active IPv4 interfaces'))
                  : Scrollbar(
                      child: ListView.separated(
                        primary: false,
                        itemCount: active.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (context, index) =>
                            InterfaceCard(info: active[index]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsView extends StatelessWidget {
  const _SettingsView({
    required this.helperStatus,
    required this.busy,
    required this.isDark,
    required this.onTheme,
    required this.onInstall,
  });

  final HelperStatus helperStatus;
  final bool busy;
  final bool isDark;
  final ValueChanged<bool> onTheme;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: 640,
        child: Card(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                'Settings',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 4),
              const Text('Appearance and privileged routing helper status.'),
              const SizedBox(height: 20),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Dark theme'),
                subtitle: const Text(
                  'Use a neutral graphite interface with green accents.',
                ),
                value: isDark,
                onChanged: onTheme,
              ),
              const Divider(height: 32),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.security_outlined, color: colors.primary),
                title: const Text('Privileged helper'),
                subtitle: Text(
                  helperStatus.message ?? 'Status: ${helperStatus.status}',
                ),
                trailing: helperStatus.enabled
                    ? Chip(
                        label: const Text('Enabled'),
                        backgroundColor: colors.primaryContainer,
                      )
                    : FilledButton(
                        onPressed: busy ? null : onInstall,
                        child: const Text('Install'),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Diagnostics extends StatelessWidget {
  const _Diagnostics({required this.message, required this.helperEnabled});
  final String? message;
  final bool helperEnabled;

  @override
  Widget build(BuildContext context) {
    final summary =
        message ??
        (helperEnabled
            ? 'Route logs are available in the Flutter terminal.'
            : 'The route helper is not enabled.');
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.terminal_outlined),
        title: const Text('Diagnostics'),
        subtitle: Text(summary),
        childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        children: [
          SelectableText(
            message ?? 'Run with flutter run -d macos; route failures appear with the [NetPilot] prefix.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({
    required this.message,
    required this.onInstall,
    required this.onDismiss,
  });
  final String message;
  final VoidCallback? onInstall;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return MaterialBanner(
      content: Text(message),
      leading: const Icon(Icons.warning_amber_rounded),
      actions: [
        if (onInstall != null)
          TextButton(onPressed: onInstall, child: const Text('Install helper')),
        TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
      ],
    );
  }
}
