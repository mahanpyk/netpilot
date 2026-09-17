import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/app_routing_rule.dart';
import '../../core/models/network_interface_info.dart';
import '../../core/models/routing_rule.dart';
import '../../core/platform/network_platform.dart';
import '../network_interfaces/presentation/interface_card.dart';
import '../app_routing/domain/app_routing_controller.dart';
import '../app_routing/presentation/apps_view.dart';
import '../routing_rules/domain/netpilot_controller.dart';
import '../routing_rules/presentation/rule_editor_sheet.dart';
import '../routing_rules/presentation/rule_tile.dart';

enum _Tab { rules, apps, networks, settings }

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.controller,
    required this.appRoutingController,
    required this.themeMode,
    required this.onThemeChanged,
  });

  final NetPilotController controller;
  final AppRoutingController appRoutingController;
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
    widget.appRoutingController.addListener(_onChange);
  }

  @override
  void dispose() {
    c.removeListener(_onChange);
    widget.appRoutingController.removeListener(_onChange);
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
                busy: c.busy,
                onTab: (value) => setState(() => _tab = value),
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
                        _Tab.apps => AppsView(
                          controller: widget.appRoutingController,
                        ),
                        _Tab.networks => _NetworksView(
                          interfaces: c.interfaces,
                        ),
                        _Tab.settings => _SettingsView(
                          helperStatus: c.helperStatus,
                          appRoutingController: widget.appRoutingController,
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
    required this.busy,
    required this.onTab,
    required this.onRefresh,
  });

  final _Tab tab;
  final bool busy;
  final ValueChanged<_Tab> onTab;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (defaultTargetPlatform == TargetPlatform.macOS) ...[
          const _WindowControls(),
          const SizedBox(width: 18),
        ],
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
              value: _Tab.apps,
              icon: Icon(Icons.apps),
              label: Text('Apps'),
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
                        primary: true,
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
                            onSubRuleToggle: (subRuleId, enabled) => controller
                                .setSubRuleEnabled(rule.id, subRuleId, enabled),
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
                        primary: true,
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
    required this.appRoutingController,
    required this.busy,
    required this.isDark,
    required this.onTheme,
    required this.onInstall,
  });

  final HelperStatus helperStatus;
  final AppRoutingController appRoutingController;
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
              Text(
                appRoutingController.hostPlatform ==
                        AppRoutingHostPlatform.windows
                    ? 'Appearance, Windows Service, and WFP Driver status.'
                    : 'Appearance and privileged routing helper status.',
              ),
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
                title: Text(
                  appRoutingController.hostPlatform ==
                          AppRoutingHostPlatform.windows
                      ? 'Windows Routing Engine'
                      : 'Privileged helper',
                ),
                subtitle: Text(
                  helperStatus.message ?? 'Status: ${helperStatus.status}',
                ),
                trailing: helperStatus.enabled
                    ? OutlinedButton.icon(
                        onPressed: busy ? null : onInstall,
                        icon: const Icon(Icons.build_outlined),
                        label: const Text('Repair'),
                      )
                    : FilledButton.icon(
                        onPressed: busy ? null : onInstall,
                        icon: const Icon(Icons.build_outlined),
                        label: const Text('Install / Repair'),
                      ),
              ),
              if (appRoutingController.hostPlatform ==
                  AppRoutingHostPlatform.windows) ...[
                _statusRow(
                  'Windows Service',
                  appRoutingController.status.serviceStatus ?? 'unknown',
                ),
                _statusRow(
                  'WFP Driver',
                  appRoutingController.status.driverStatus ?? 'unknown',
                ),
                _statusRow(
                  'Test Mode',
                  appRoutingController.status.testMode ? 'enabled' : 'disabled',
                ),
                _statusRow(
                  'Reboot required',
                  appRoutingController.status.rebootRequired ? 'yes' : 'no',
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusRow(String label, String value) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    trailing: Text(value),
  );
}

class _WindowControls extends StatelessWidget {
  const _WindowControls();

  static const _channel = MethodChannel('com.netpilot.netpilotDesktop/network');

  Future<void> _run(String action) {
    return _channel.invokeMethod<void>('windowAction', {'action': action});
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(18);
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? const [Color(0x3DFFFFFF), Color(0x147F8A93)]
                  : const [Color(0xCFFFFFFF), Color(0x70E2E8EA)],
            ),
            border: Border.all(
              color: isDark ? const Color(0x32FFFFFF) : const Color(0x9FFFFFFF),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.12),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
              BoxShadow(
                color: Colors.white.withValues(alpha: isDark ? 0.06 : 0.7),
                blurRadius: 1,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _WindowButton(
                tooltip: 'Close',
                color: const Color(0xFFFF5B57),
                icon: Icons.close_rounded,
                onPressed: () => _run('close'),
              ),
              const SizedBox(width: 5),
              _WindowButton(
                tooltip: 'Minimize',
                color: const Color(0xFFFFBD2E),
                icon: Icons.remove_rounded,
                onPressed: () => _run('minimize'),
              ),
              const SizedBox(width: 5),
              _WindowButton(
                tooltip: 'Zoom',
                color: const Color(0xFF29C941),
                icon: Icons.open_in_full_rounded,
                onPressed: () => _run('zoom'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.tooltip,
    required this.color,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final Color color;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: Semantics(
        button: true,
        label: widget.tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() {
            _hovered = false;
            _pressed = false;
          }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            child: AnimatedScale(
              scale: _pressed ? 0.88 : (_hovered ? 1.06 : 1),
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOutCubic,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.lerp(
                        widget.color,
                        Colors.white,
                        _hovered ? 0.38 : 0.24,
                      )!,
                      Color.lerp(
                        widget.color,
                        Colors.black,
                        _pressed ? 0.18 : 0.08,
                      )!,
                    ],
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(
                      alpha: _hovered ? 0.62 : 0.34,
                    ),
                    width: 0.8,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: widget.color.withValues(
                        alpha: _hovered ? 0.42 : 0.22,
                      ),
                      blurRadius: _hovered ? 10 : 5,
                      offset: const Offset(0, 2),
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: AnimatedOpacity(
                  opacity: _hovered ? 1 : 0.78,
                  duration: const Duration(milliseconds: 140),
                  child: Icon(
                    widget.icon,
                    size: widget.tooltip == 'Zoom' ? 9 : 12,
                    color: Colors.black.withValues(alpha: 0.68),
                  ),
                ),
              ),
            ),
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
