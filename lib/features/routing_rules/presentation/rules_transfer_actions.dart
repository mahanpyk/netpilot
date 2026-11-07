import 'package:flutter/material.dart';

import '../../../core/models/network_interface_info.dart';
import '../../../core/models/routing_rule.dart';
import '../data/rules_transfer.dart';
import '../data/rules_transfer_file.dart';
import '../domain/netpilot_controller.dart';

class RulesTransferActions extends StatefulWidget {
  const RulesTransferActions({
    super.key,
    required this.controller,
    this.files = const DesktopRulesTransferFile(),
  });

  final NetPilotController controller;
  final RulesTransferFile files;

  @override
  State<RulesTransferActions> createState() => _RulesTransferActionsState();
}

class _RulesTransferActionsState extends State<RulesTransferActions> {
  bool _working = false;
  static const _transfer = RulesTransfer();

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _export() async {
    setState(() => _working = true);
    try {
      final payload = _transfer.encode(widget.controller.rules);
      if (await widget.files.write(payload)) _message('Rules exported.');
    } catch (error) {
      _message('Export failed: $error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _import() async {
    setState(() => _working = true);
    try {
      final text = await widget.files.read();
      if (text == null || !mounted) return;
      final rules = _transfer.decode(text);
      if (rules.isEmpty) {
        _message('This backup contains no rules.');
        return;
      }
      final networks = widget.controller.activeInterfaces;
      if (networks.isEmpty) {
        _message('Connect a network before importing rules.');
        return;
      }
      final selection = await showDialog<_ImportSelection>(
        context: context,
        builder: (_) => _ImportDialog(rules: rules, networks: networks),
      );
      if (selection == null || !mounted) return;
      final count = await widget.controller.importRules(
        rules,
        interfaceMapping: selection.mapping,
        activate: selection.activate,
      );
      _message(
        'Imported $count rule(s); ${rules.length - count} duplicate(s) skipped.'
        '${selection.activate ? '' : ' Imported rules are paused; enable them when ready.'}',
      );
    } catch (error) {
      _message('Import failed: $error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final disabled =
            _working || widget.controller.busy || widget.controller.loading;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: disabled ? null : _import,
              icon: const Icon(Icons.file_upload_outlined),
              label: const Text('Import'),
            ),
            OutlinedButton.icon(
              onPressed: disabled || widget.controller.rules.isEmpty
                  ? null
                  : _export,
              icon: const Icon(Icons.file_download_outlined),
              label: const Text('Export'),
            ),
            if (_working)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        );
      },
    );
  }
}

class _ImportSelection {
  const _ImportSelection(this.mapping, this.activate);
  final Map<String, String> mapping;
  final bool activate;
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.rules, required this.networks});
  final List<RoutingRule> rules;
  final List<NetworkInterfaceInfo> networks;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _mapping = <String, String>{};
  bool _activate = false;

  @override
  Widget build(BuildContext context) {
    final sources = widget.rules.map((rule) => rule.interfaceId).toSet();
    return AlertDialog(
      title: const Text('Import rules'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.rules.length} rule(s) found. Choose a network on this device for each source network. Existing rules are kept; matching destinations on the same network are skipped.',
              ),
              const SizedBox(height: 16),
              for (final source in sources) ...[
                Text(
                  'Source network: $source',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  widget.rules
                      .where((rule) => rule.interfaceId == source)
                      .map((rule) => rule.normalizedDestination)
                      .join(', '),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  key: ValueKey('import-network-$source'),
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Network on this device',
                  ),
                  items: [
                    for (final network in widget.networks)
                      DropdownMenuItem(
                        value: network.id,
                        child: Text(
                          '${network.name} (${network.interfaceName})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _mapping[source] = value);
                  },
                ),
                const SizedBox(height: 16),
              ],
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _activate,
                title: const Text('Enable imported rules'),
                subtitle: const Text(
                  'Off by default. Previously disabled rules stay disabled. DNS is resolved again on this device; saved LAN IPv4 mappings are preserved.',
                ),
                onChanged: (value) =>
                    setState(() => _activate = value ?? false),
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
          onPressed: _mapping.length != sources.length
              ? null
              : () => Navigator.pop(
                  context,
                  _ImportSelection(Map.of(_mapping), _activate),
                ),
          child: const Text('Import rules'),
        ),
      ],
    );
  }
}
