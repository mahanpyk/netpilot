import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/models/app_routing_rule.dart';
import '../../../core/models/network_interface_info.dart';
import '../../../core/platform/app_routing_platform.dart';
import '../domain/app_routing_controller.dart';

class AppsView extends StatelessWidget {
  const AppsView({super.key, required this.controller});

  final AppRoutingController controller;

  Future<void> _add(BuildContext context) async {
    final app = await controller.selectApplication();
    if (app == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _AppRuleDialog(controller: controller, app: app),
    );
  }

  Future<void> _edit(BuildContext context, AppRoutingRule rule) {
    return showDialog<void>(
      context: context,
      builder: (context) => _AppRuleDialog(controller: controller, rule: rule),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (controller.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        _ExtensionCard(controller: controller),
        const SizedBox(height: 12),
        Expanded(
          child: Card(
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
                              'Application routing',
                              style: Theme.of(context).textTheme.headlineMedium,
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Pin signed apps and their bundled helpers to a physical network.',
                            ),
                          ],
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: controller.busy ? null : () => _add(context),
                        icon: const Icon(Icons.add),
                        label: const Text('Add application'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Enable per-app routing'),
                    subtitle: const Text(
                      'Changes stay pending until you apply and restart the proxy.',
                    ),
                    value: controller.masterEnabled,
                    onChanged: controller.busy
                        ? null
                        : controller.setMasterEnabled,
                  ),
                  if (controller.error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        controller.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  Expanded(
                    child: controller.rules.isEmpty
                        ? const _EmptyApps()
                        : Scrollbar(
                            child: ListView.separated(
                              primary: true,
                              itemCount: controller.rules.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, index) {
                                final rule = controller.rules[index];
                                return _AppRuleCard(
                                  rule: rule,
                                  metrics:
                                      controller.status.ruleMetrics[rule.id] ??
                                      const AppRoutingRuleMetrics(),
                                  interfaceLabel: _interfaceLabel(
                                    controller.physicalInterfaces,
                                    rule.interfaceId,
                                  ),
                                  onToggle: (enabled) => controller
                                      .setRuleEnabled(rule.id, enabled),
                                  onEdit: () => _edit(context, rule),
                                  onDelete: () =>
                                      controller.deleteRule(rule.id),
                                );
                              },
                            ),
                          ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      if (controller.hasPendingChanges)
                        const Chip(
                          avatar: Icon(Icons.pending_actions, size: 17),
                          label: Text('Pending changes'),
                        ),
                      const Spacer(),
                      FilledButton.icon(
                        key: const ValueKey('apply-app-routing'),
                        onPressed:
                            controller.busy ||
                                !controller.hasPendingChanges ||
                                !controller.status.extensionReady
                            ? null
                            : controller.applyAndRestart,
                        icon: controller.busy
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.restart_alt),
                        label: Text(
                          controller.busy
                              ? 'Reconnecting traffic…'
                              : 'Apply & Restart Proxy',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

String _interfaceLabel(
  List<NetworkInterfaceInfo> interfaces,
  String interfaceId,
) {
  for (final item in interfaces) {
    if (item.id == interfaceId || item.interfaceName == interfaceId) {
      return '${item.name} (${item.interfaceName})';
    }
  }
  return interfaceId;
}

class _ExtensionCard extends StatelessWidget {
  const _ExtensionCard({required this.controller});

  final AppRoutingController controller;

  @override
  Widget build(BuildContext context) {
    final status = controller.status;
    final ready = status.extensionReady;
    final color = ready
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.tertiary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          children: [
            Icon(
              ready ? Icons.verified_user_outlined : Icons.extension_outlined,
              color: color,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ready
                        ? 'System Extension installed'
                        : 'System Extension setup required',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    status.message ??
                        'Proxy: ${status.proxyStatus} · '
                            '${status.activeFlows} active flows · '
                            '${_bytes(status.bytesIn + status.bytesOut)} transferred',
                  ),
                ],
              ),
            ),
            if (!ready)
              FilledButton(
                onPressed: controller.busy ? null : controller.installExtension,
                child: const Text('Install & Approve'),
              )
            else
              IconButton(
                tooltip: 'Refresh status',
                onPressed: controller.refreshStatus,
                icon: const Icon(Icons.refresh),
              ),
          ],
        ),
      ),
    );
  }
}

class _AppRuleCard extends StatelessWidget {
  const _AppRuleCard({
    required this.rule,
    required this.interfaceLabel,
    required this.metrics,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final AppRoutingRule rule;
  final String interfaceLabel;
  final AppRoutingRuleMetrics metrics;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final runtimeError = metrics.lastError ?? rule.lastError;
    final runtimeSummary =
        ' · ${metrics.activeFlows} flows · '
        '${_bytes(metrics.bytesIn + metrics.bytesOut)}';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: ListTile(
        leading: _AppIcon(base64Value: rule.iconPngBase64),
        title: Text(rule.displayName),
        subtitle: Text(
          '$interfaceLabel · ${rule.failurePolicy.name}\n'
          '${rule.helperSigningIdentifiers.length} bundled helpers$runtimeSummary · '
          '${runtimeError ?? rule.signingIdentifier}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        isThreeLine: true,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch.adaptive(
              key: ValueKey('app-rule-toggle-${rule.id}'),
              value: rule.enabled,
              onChanged: onToggle,
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

class _AppRuleDialog extends StatefulWidget {
  const _AppRuleDialog({required this.controller, this.app, this.rule});

  final AppRoutingController controller;
  final AppDescriptor? app;
  final AppRoutingRule? rule;

  @override
  State<_AppRuleDialog> createState() => _AppRuleDialogState();
}

class _AppRuleDialogState extends State<_AppRuleDialog> {
  late String? interfaceId =
      widget.rule?.interfaceId ??
      (widget.controller.physicalInterfaces.isEmpty
          ? null
          : widget.controller.physicalInterfaces.first.interfaceName);
  late AppRoutingFailurePolicy policy =
      widget.rule?.failurePolicy ?? AppRoutingFailurePolicy.block;

  @override
  Widget build(BuildContext context) {
    final interfaces = widget.controller.physicalInterfaces;
    final knownInterface = interfaces.any(
      (item) => item.interfaceName == interfaceId || item.id == interfaceId,
    );
    final name =
        widget.rule?.displayName ?? widget.app?.displayName ?? 'Application';
    return AlertDialog(
      title: Text(widget.rule == null ? 'Route $name' : 'Edit $name'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              initialValue: interfaceId,
              decoration: const InputDecoration(
                labelText: 'Physical interface',
              ),
              items: [
                if (interfaceId != null && !knownInterface)
                  DropdownMenuItem(
                    value: interfaceId,
                    child: Text('Unavailable ($interfaceId)'),
                  ),
                for (final item in interfaces)
                  DropdownMenuItem(
                    value: item.interfaceName,
                    child: Text('${item.name} (${item.interfaceName})'),
                  ),
              ],
              onChanged: (value) => setState(() => interfaceId = value),
            ),
            const SizedBox(height: 16),
            SegmentedButton<AppRoutingFailurePolicy>(
              segments: const [
                ButtonSegment(
                  value: AppRoutingFailurePolicy.block,
                  icon: Icon(Icons.block),
                  label: Text('Block'),
                ),
                ButtonSegment(
                  value: AppRoutingFailurePolicy.fallback,
                  icon: Icon(Icons.call_split),
                  label: Text('Fallback'),
                ),
              ],
              selected: {policy},
              onSelectionChanged: (value) =>
                  setState(() => policy = value.first),
            ),
            const SizedBox(height: 10),
            Text(
              policy == AppRoutingFailurePolicy.block
                  ? 'Close matching flows when this interface is unavailable.'
                  : 'Use the normal macOS route when this interface is unavailable.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: interfaceId == null
              ? null
              : () async {
                  if (widget.rule != null) {
                    await widget.controller.updateRule(
                      rule: widget.rule!,
                      interfaceId: interfaceId!,
                      failurePolicy: policy,
                    );
                  } else {
                    await widget.controller.upsertRule(
                      app: widget.app!,
                      interfaceId: interfaceId!,
                      failurePolicy: policy,
                    );
                  }
                  if (context.mounted) Navigator.pop(context);
                },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.base64Value});

  final String? base64Value;

  @override
  Widget build(BuildContext context) {
    Uint8List? bytes;
    try {
      if (base64Value != null) bytes = base64Decode(base64Value!);
    } catch (_) {}
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox.square(
        dimension: 42,
        child: bytes == null
            ? ColoredBox(
                color: Theme.of(context).colorScheme.primaryContainer,
                child: const Icon(Icons.apps),
              )
            : Image.memory(bytes, fit: BoxFit.cover),
      ),
    );
  }
}

class _EmptyApps extends StatelessWidget {
  const _EmptyApps();

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.apps_outlined,
          size: 48,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 10),
        Text('No applications', style: Theme.of(context).textTheme.titleLarge),
        const Text(
          'Add a signed .app bundle to create a split-tunneling rule.',
        ),
      ],
    ),
  );
}

String _bytes(int value) {
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
}
