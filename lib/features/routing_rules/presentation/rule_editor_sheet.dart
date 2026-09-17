import 'package:flutter/material.dart';

import '../../../core/models/network_interface_info.dart';
import '../../../core/models/routing_rule.dart';
import '../../../core/utils/destination_parser.dart';
import '../domain/netpilot_controller.dart';

class RuleEditorSheet extends StatefulWidget {
  const RuleEditorSheet({
    super.key,
    required this.controller,
    this.existing,
  });

  final NetPilotController controller;
  final RoutingRule? existing;

  @override
  State<RuleEditorSheet> createState() => _RuleEditorSheetState();
}

class _RuleEditorSheetState extends State<RuleEditorSheet> {
  late final TextEditingController _destination;
  late final TextEditingController _label;
  String? _interfaceId;
  String? _error;
  List<String> _previewIps = [];
  bool _resolving = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _destination = TextEditingController(text: existing?.rawDestination ?? '');
    _label = TextEditingController(text: existing?.label ?? '');
    _interfaceId = existing?.interfaceId ??
        widget.controller.activeInterfaces
            .where((i) => i.kind == NetworkInterfaceKind.ethernet)
            .map((i) => i.interfaceName)
            .cast<String?>()
            .firstWhere((_) => true, orElse: () => null) ??
        widget.controller.activeInterfaces
            .map((i) => i.interfaceName)
            .cast<String?>()
            .firstWhere((_) => true, orElse: () => null);
    _previewIps = existing?.resolvedIps ?? [];
  }

  @override
  void dispose() {
    _destination.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    setState(() {
      _error = null;
      _resolving = true;
    });
    try {
      final parsed = widget.controller.previewDestination(_destination.text);
      if (parsed.kind == DestinationKind.hostname ||
          parsed.kind == DestinationKind.url) {
        final ips = await widget.controller.resolvePreview(
          parsed.normalized,
          interfaceId: _interfaceId,
        );
        setState(() => _previewIps = ips);
        if (ips.isEmpty) {
          setState(() => _error = 'No A records for ${parsed.normalized}');
        }
      } else if (parsed.kind == DestinationKind.ipv4) {
        setState(() => _previewIps = [parsed.normalized]);
      } else {
        setState(() => _previewIps = [parsed.normalized]);
      }
    } on DestinationParseException catch (e) {
      setState(() {
        _error = e.message;
        _previewIps = [];
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _resolving = false);
    }
  }

  Future<void> _save() async {
    if (_interfaceId == null) {
      setState(() => _error = 'Select a LAN interface');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.upsertRule(
        id: widget.existing?.id,
        rawDestination: _destination.text,
        interfaceId: _interfaceId!,
        label: _label.text.trim().isEmpty ? null : _label.text.trim(),
        enabled: widget.existing?.enabled ?? true,
      );
      if (mounted) Navigator.of(context).pop();
    } on DestinationParseException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ifaces = widget.controller.activeInterfaces;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.existing == null ? 'Add routing rule' : 'Edit routing rule',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _destination,
            decoration: const InputDecoration(
              labelText: 'Destination',
              hintText: 'intranet.company.local or 10.0.0.0/8 or https://…',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _label,
            decoration: const InputDecoration(
              labelText: 'Label (optional)',
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            // ignore: deprecated_member_use
            value: _interfaceId,
            decoration: const InputDecoration(labelText: 'Send via interface'),
            items: ifaces
                .map(
                  (i) => DropdownMenuItem(
                    value: i.interfaceName,
                    child: Text(
                      '${i.name.isEmpty ? i.interfaceName : i.name} (${i.interfaceName})'
                      '${i.isDefaultRoute ? ' · default' : ''}',
                    ),
                  ),
                )
                .toList(),
            onChanged: (v) => setState(() => _interfaceId = v),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _resolving ? null : _preview,
                icon: _resolving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.travel_explore),
                label: const Text('Resolve preview'),
              ),
              const SizedBox(width: 12),
              if (_previewIps.isNotEmpty)
                Expanded(
                  child: Text(
                    '→ ${_previewIps.join(', ')}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save & apply'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
